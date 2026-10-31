// AI [128]: per-stack memory-side cache + banked DRAM timing model.
//
// Timing only. The data still lives in Stack::dram_stack and is read/written exactly as before
// (close requests at issue, far requests when the target stack drains its channel). This model
// only decides WHEN a load/atomic result is handed back to the core, and it accounts for the
// traffic that stores generate (dirty lines, writebacks).
//
// Pieces:
//   * one cache per stack, holding only that stack's addresses (no coherence needed)
//     sets/ways/line parametrizable, tree-PLRU, write-back, write-allocate, atomics in the cache,
//     MSHRs that merge requests to a line, a port limit (requests accepted per cycle)
//   * DRAM behind it: channels x banks, FR-FCFS per channel, open or closed page,
//     tCL/tCWL/tRCD/tRP/tRAS/tWR given in ns and converted with the core frequency
//   * sliding-window bandwidth cap on DRAM<->cache data: at most k bytes in any n cycles,
//     k = BW(GB/s) / f(GHz) * n
//   * profiles selected with DRAEM_MEM_PROFILE, every field overridable by env var (see from_env)

use hashbrown::HashMap;
use std::cmp::Reverse;
use std::collections::{BinaryHeap, VecDeque};
use std::sync::OnceLock;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum PagePolicy {
    Open,
    Closed,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MemKind {
    Read,
    Write,
    Atomic,
}

#[derive(Clone, Debug)]
pub struct MemConfig {
    pub profile: String,
    pub legacy: bool,          // old behavior: every result after a fixed latency, no cache/DRAM model
    pub legacy_latency: u64,   // cycles (old DRAM_LATENCY_CLOSE / DRAM_LATENCY_FAR = 6)
    pub freq_ghz: f64,
    // cache
    pub sets: usize,
    pub ways: usize,
    pub line: usize,
    pub hit_ns: f64,
    pub atomic_extra_cycles: u64,
    pub ports: usize, // requests the cache accepts per cycle
    pub mshrs: usize,
    pub set_hash: bool, // AI [151]: XOR/rotate-hash the set index (DRAEM_CACHE_HASH=0 turns it off)
    // DRAM
    pub channels: usize,
    pub banks: usize,
    pub row_bytes: usize,
    pub channel_gbs: f64,
    pub t_cl: f64,
    pub t_cwl: f64,
    pub t_rcd_rd: f64,
    pub t_rcd_wr: f64,
    pub t_rp: f64,
    pub t_ras: f64,
    pub t_wr: f64,
    pub io_ns: f64, // controller + PHY + link, round trip, added to every DRAM access
    pub page: PagePolicy,
    // bandwidth cap
    pub bw_gbs: f64,
    pub bw_window: usize, // n
    // cross-stack link, one way
    pub far_ns: f64,
    // AI [131]: link bandwidth caps (same k-bytes-per-n-cycles window; 0 = unlimited)
    pub core_link_gbs: f64,  // stack <-> its own cores, each direction (local requests in, local replies out)
    pub stack_link_gbs: f64, // stack <-> other stacks, each direction (far requests + far replies)
    pub req_hdr_bytes: u64,  // request message: address + op + core/register tag (store/atomic data adds 4)
    pub reply_bytes: u64,    // reply message: data + core/register tag
}

/// Same config converted to core cycles.
#[derive(Clone, Debug)]
pub struct Cyc {
    pub hit: u64,
    pub far: u64,
    pub io_half: f64,
    pub cl: f64,
    pub cwl: f64,
    pub rcd_rd: f64,
    pub rcd_wr: f64,
    pub rp: f64,
    pub ras: f64,
    pub wr: f64,
    pub burst: f64,     // cycles one line occupies a channel's data bus
    pub bw_bytes: u64,  // k
}

fn ns_to_cyc(ns: f64, f: f64) -> f64 {
    ns * f
}

impl MemConfig {
    fn base(profile: &str) -> MemConfig {
        // Cache defaults: 4096 sets x 16 ways x 64 B = 4 MB per stack (32 MB chip), 10 ns hit (estimate).
        let mut c = MemConfig {
            profile: profile.to_string(),
            legacy: false,
            legacy_latency: 6,
            freq_ghz: 2.0,
            sets: 4096,
            ways: 16,
            line: 64,
            hit_ns: 10.0,
            atomic_extra_cycles: 1,
            ports: 128, // AI [133] (Alex): rough design, real caches coalesce heavily
            mshrs: 1 << 20, // AI [134] (Alex): effectively unlimited; this design has no traditional cache
            set_hash: true,
            channels: 32,
            banks: 16,
            row_bytes: 1024,
            channel_gbs: 25.6,
            t_cl: 12.5,
            t_cwl: 6.25,
            t_rcd_rd: 19.375,
            t_rcd_wr: 9.375,
            t_rp: 16.25,
            t_ras: 28.125,
            t_wr: 20.625,
            io_ns: 10.0,
            page: PagePolicy::Open,
            bw_gbs: 0.0,
            bw_window: 50,
            far_ns: 5.0,
            core_link_gbs: 2048.0, // AI [133]: ~128 8-byte requests/cycle at 2 GHz
            stack_link_gbs: 1024.0, // AI [133]: ~64 8-byte requests/cycle at 2 GHz
            req_hdr_bytes: 8,
            reply_bytes: 8,
        };
        let (kind, stacked) = match profile.strip_suffix("_stacked") {
            Some(k) => (k, true),
            None => (profile, false),
        };
        match kind {
            "legacy" => {
                c.legacy = true;
            }
            "hbm3" => {
                // One HBM3 stack per DRAEM stack: 16 channels x 2 pseudo-channels of 32 bits at 6.4 Gb/s = 819.2 GB/s.
                // Timings: Ramulator 2 preset HBM3_6400Mbps (tCK 0.625 ns; nCL 20, nRCDRD 31, nRCDWR 15, nRP 26,
                // nRAS 45, nWR 33, nCWL 10). Ramulator marks these as its own estimate. 16 banks per PC, 1 KB page.
                c.channels = 32;
                c.banks = 16;
                c.row_bytes = 1024;
                c.channel_gbs = 25.6;
                c.t_cl = 12.5;
                c.t_cwl = 6.25;
                c.t_rcd_rd = 19.375;
                c.t_rcd_wr = 9.375;
                c.t_rp = 16.25;
                c.t_ras = 28.125;
                c.t_wr = 20.625;
                c.io_ns = 10.0; // 2.5D interposer (estimate)
            }
            "gddr6" | "gddr6x" => {
                // Two x32 devices per DRAEM stack = 4 channels of 16 bits.
                // GDDR6 at 16 Gb/s = 32 GB/s per channel (128 GB/s per stack); GDDR6X (PAM4) at 21 Gb/s = 42 GB/s.
                // Timings: Samsung K4Z80325BC via Ramulator 2 preset GDDR6_14000_1350mV (tCK 0.572 ns; nCL 24,
                // nRCDRD 27, nRCDWR 16, nRP 27, nRAS 53, nWR 27, nCWL 6). 16 banks per channel, 2 KB page.
                // GDDR6X has no public timing table; the same array timings are assumed.
                c.channels = 4;
                c.banks = 16;
                c.row_bytes = 2048;
                c.channel_gbs = if kind == "gddr6x" { 42.0 } else { 32.0 };
                c.t_cl = 13.728;
                c.t_cwl = 3.432;
                c.t_rcd_rd = 15.444;
                c.t_rcd_wr = 9.152;
                c.t_rp = 15.444;
                c.t_ras = 30.316;
                c.t_wr = 15.444;
                c.io_ns = 20.0; // off-package PHY + board (estimate)
            }
            "gddr7" => {
                // AI [150] (Alex): RTX 5090-class GDDR7. Two x32 devices per DRAEM stack; each GDDR7 device has 4 independent
                // x8 channels (GDDR6: 2 x16), so 8 channels of 8 bits per stack. PAM3 at 28 Gb/s = 28 GB/s per channel
                // (224 GB/s per stack, 1792 GB/s over 8 stacks = the 5090's 512-bit bus).
                // No public GDDR7 timing table: banks, page size and array timings are assumed equal to the GDDR6 preset above.
                c.channels = 8;
                c.banks = 16;
                c.row_bytes = 2048;
                c.channel_gbs = 28.0;
                c.t_cl = 13.728;
                c.t_cwl = 3.432;
                c.t_rcd_rd = 15.444;
                c.t_rcd_wr = 9.152;
                c.t_rp = 15.444;
                c.t_ras = 30.316;
                c.t_wr = 15.444;
                c.io_ns = 20.0; // off-package PHY + board (estimate, same as GDDR6)
            }
            "ddr5" => {
                // One DDR5-6400 DIMM per DRAEM stack = 2 sub-channels of 32 bits = 25.6 GB/s each.
                // JEDEC DDR5-6400B: CL52-52-52 (16.25 ns), tRAS 32 ns, tWR 30 ns, CWL = CL-2.
                // 32 banks (8 groups x 4), 1 KB page per x8 device x 4 devices = 4 KB row per sub-channel.
                c.channels = 2;
                c.banks = 32;
                c.row_bytes = 4096;
                c.channel_gbs = 25.6;
                c.t_cl = 16.25;
                c.t_cwl = 15.625;
                c.t_rcd_rd = 16.25;
                c.t_rcd_wr = 16.25;
                c.t_rp = 16.25;
                c.t_ras = 32.0;
                c.t_wr = 30.0;
                c.io_ns = 20.0; // off-package PHY + DIMM (estimate)
            }
            other => panic!("Unknown DRAEM_MEM_PROFILE '{}'. Use legacy, hbm3, gddr6, gddr6x, gddr7 or ddr5, optionally with _stacked", other),
        }
        if stacked {
            // DRAM 3D-stacked on the logic die: same array timings and bandwidth, but no off-package PHY / board
            // flight time. Interface round trip estimated at 4 ns.
            c.io_ns = 4.0;
        }
        c
    }

    pub fn from_env() -> MemConfig {
        fn env_f(k: &str) -> Option<f64> {
            std::env::var(k).ok().and_then(|v| v.trim().parse().ok())
        }
        fn env_u(k: &str) -> Option<usize> {
            std::env::var(k).ok().and_then(|v| v.trim().parse().ok())
        }
        let profile = std::env::var("DRAEM_MEM_PROFILE").ok().map(|s| s.trim().to_lowercase()).filter(|s| !s.is_empty()).unwrap_or("hbm3".to_string());
        let mut c = MemConfig::base(&profile);
        if let Some(v) = env_f("DRAEM_FREQ_GHZ") { c.freq_ghz = v; }
        if let Ok(v) = std::env::var("DRAEM_CACHE") {
            // "sets,ways,line"
            let p: Vec<usize> = v.split(',').filter_map(|s| s.trim().parse().ok()).collect();
            assert!(p.len() == 3, "DRAEM_CACHE must be sets,ways,line");
            c.sets = p[0];
            c.ways = p[1];
            c.line = p[2];
        }
        if let Some(v) = env_f("DRAEM_CACHE_HIT_NS") { c.hit_ns = v; }
        if let Some(v) = env_u("DRAEM_CACHE_PORTS") { c.ports = v; }
        if let Some(v) = env_u("DRAEM_CACHE_MSHRS") { c.mshrs = v; }
        if let Some(v) = env_u("DRAEM_CACHE_HASH") { c.set_hash = v != 0; }
        if let Some(v) = env_u("DRAEM_CHANNELS") { c.channels = v; }
        if let Some(v) = env_u("DRAEM_BANKS") { c.banks = v; }
        if let Some(v) = env_u("DRAEM_ROW_BYTES") { c.row_bytes = v; }
        if let Some(v) = env_f("DRAEM_CHANNEL_GBS") { c.channel_gbs = v; }
        if let Some(v) = env_f("DRAEM_IO_NS") { c.io_ns = v; }
        if let Some(v) = env_f("DRAEM_FAR_NS") { c.far_ns = v; }
        if let Some(v) = env_f("DRAEM_BW_GBS") { c.bw_gbs = v; }
        if let Some(v) = env_u("DRAEM_BW_WINDOW") { c.bw_window = v; }
        if let Some(v) = env_f("DRAEM_CORE_LINK_GBS") { c.core_link_gbs = v; }
        if let Some(v) = env_f("DRAEM_STACK_LINK_GBS") { c.stack_link_gbs = v; }
        if let Ok(v) = std::env::var("DRAEM_PAGE") {
            c.page = match v.trim().to_lowercase().as_str() {
                "open" => PagePolicy::Open,
                "closed" | "close" => PagePolicy::Closed,
                o => panic!("DRAEM_PAGE must be open or closed, got {}", o),
            };
        }
        c.validate();
        c
    }

    fn validate(&self) {
        if self.legacy {
            return;
        }
        assert!(self.ways.is_power_of_two() && self.ways <= 64, "cache ways must be a power of 2 (tree-PLRU), <= 64");
        assert!(self.sets >= 1 && self.line.is_power_of_two() && self.line >= 4, "bad cache geometry");
        assert!(self.row_bytes % self.line == 0, "row size must be a multiple of the line size");
        assert!(self.channels >= 1 && self.banks >= 1 && self.ports >= 1 && self.mshrs >= 1);
        for (name, g) in [("DRAEM_CORE_LINK_GBS", self.core_link_gbs), ("DRAEM_STACK_LINK_GBS", self.stack_link_gbs)] {
            if g > 0.0 {
                let k = (g / self.freq_ghz * self.bw_window as f64).floor() as u64;
                assert!(k >= self.req_hdr_bytes + 4, "{} too small for one message per window ({} B per {} cycles)", name, k, self.bw_window);
            }
        }
        let k = self.cyc().bw_bytes;
        assert!(k >= self.line as u64, "bandwidth window too small: k = {} bytes < one line ({} B); raise DRAEM_BW_WINDOW", k, self.line);
    }

    /// Bandwidth cap in GB/s; 0 means "sum of the channel peaks".
    pub fn eff_bw(&self) -> f64 {
        if self.bw_gbs > 0.0 { self.bw_gbs } else { self.channel_gbs * self.channels as f64 }
    }

    pub fn cyc(&self) -> Cyc {
        let f = self.freq_ghz;
        Cyc {
            hit: ns_to_cyc(self.hit_ns, f).ceil().max(1.0) as u64,
            far: if self.legacy { 0 } else { ns_to_cyc(self.far_ns, f).ceil() as u64 },
            io_half: ns_to_cyc(self.io_ns, f) / 2.0,
            cl: ns_to_cyc(self.t_cl, f),
            cwl: ns_to_cyc(self.t_cwl, f),
            rcd_rd: ns_to_cyc(self.t_rcd_rd, f),
            rcd_wr: ns_to_cyc(self.t_rcd_wr, f),
            rp: ns_to_cyc(self.t_rp, f),
            ras: ns_to_cyc(self.t_ras, f),
            wr: ns_to_cyc(self.t_wr, f),
            // bytes / (GB/s) = ns; * GHz = cycles
            burst: self.line as f64 / self.channel_gbs * f,
            bw_bytes: (self.eff_bw() / f * self.bw_window as f64).floor() as u64,
        }
    }

    pub fn describe(&self) -> String {
        if self.legacy {
            return format!("MEMCFG profile {} (legacy: fixed {} cycle DRAM latency, no cache)", self.profile, self.legacy_latency);
        }
        let y = self.cyc();
        format!(
            "MEMCFG profile {} freq {} GHz | cache {} sets x {} ways x {} B = {} KB/stack, hit {} ns = {} cyc, ports {}/cyc, mshrs {} | \
             DRAM {} ch x {} banks, row {} B, {} GB/s/ch, page {:?}, tCL {:.1} tCWL {:.1} tRCDrd {:.1} tRCDwr {:.1} tRP {:.1} tRAS {:.1} tWR {:.1} cyc, \
             burst {:.2} cyc/line, io round trip {} ns | DRAM BW cap {} GB/s = {} B per {} cyc | far link {} ns = {} cyc each way | \
             core link cap {} GB/s, stack link cap {} GB/s per direction (0 = none), msgs: request {}+4 B, reply {} B",
            self.profile, self.freq_ghz, self.sets, self.ways, self.line, self.sets * self.ways * self.line / 1024, self.hit_ns, y.hit,
            self.ports, self.mshrs, self.channels, self.banks, self.row_bytes, self.channel_gbs, self.page, y.cl, y.cwl, y.rcd_rd, y.rcd_wr,
            y.rp, y.ras, y.wr, y.burst, self.io_ns, self.eff_bw(), y.bw_bytes, self.bw_window, self.far_ns, y.far,
            self.core_link_gbs, self.stack_link_gbs, self.req_hdr_bytes, self.reply_bytes
        )
    }
}

static MEM_CFG: OnceLock<MemConfig> = OnceLock::new();

pub fn cfg() -> &'static MemConfig {
    MEM_CFG.get_or_init(MemConfig::from_env)
}

/// Where a load/atomic result goes.
#[derive(Clone, Copy, Debug)]
pub struct Reply {
    pub origin_stack: usize,
    pub core_id: u32,
    pub register_index: usize,
    pub value: u32,
}

#[derive(Clone, Copy, Debug)]
pub struct MemReq {
    pub arrival: u64, // cycle the request reaches this stack's cache
    pub addr: usize,  // byte address within the stack
    pub kind: MemKind,
    pub reply: Option<Reply>,
}

/// A finished request: the reply may be consumed at cycle `ready` (at this stack; the caller adds the return link).
#[derive(Clone, Copy, Debug)]
pub struct Done {
    pub ready: u64,
    pub reply: Reply,
}

struct Mshr {
    fill_done: Option<u64>,
    dirty: bool,
    accepted: u64,
    waiting: Vec<(Reply, MemKind, u64)>, // (reply, kind, arrival)
}

#[derive(Clone, Copy)]
struct DramTxn {
    line: u64,
    bank: usize,
    row: u64,
    write: bool,
    ready: u64, // earliest cycle it may be scheduled (after tag lookup + half the io trip)
    seq: u64,   // age, for FR-FCFS
}

#[derive(Clone, Copy)]
struct Bank {
    open_row: Option<u64>,
    act_t: f64,
    next_act: f64,
    next_pre: f64,
    next_col: f64,
    busy_until: f64,
}

struct Channel {
    bq: Vec<VecDeque<DramTxn>>, // AI [134]: per-bank queues (scales to thousands of outstanding misses)
    queued: usize,
    banks: Vec<Bank>,
    bus: Vec<(f64, f64)>, // booked data-bus intervals [start, end), sorted; later commands may fill earlier gaps
}

#[derive(Default, Clone, Debug)]
pub struct MemStats {
    pub accesses: u64,
    pub reads: u64,
    pub writes: u64,
    pub atomics: u64,
    pub hits: u64,
    pub misses: u64,
    pub merges: u64,
    pub fills: u64,
    pub writebacks: u64,
    pub row_hits: u64,
    pub row_empty: u64,
    pub row_conflicts: u64,
    pub dram_bytes: u64,
    pub bw_delays: u64,     // channel-cycles a transfer was held back by the bandwidth cap
    pub mshr_stall_cycles: u64,
    pub port_stall_cycles: u64, // cycles with requests left in the input queue
    pub max_inq: usize,
    pub miss_lat_sum: u64,  // accept -> fill_done, over misses
    pub reply_lat_sum: u64, // arrival -> ready, over replies
    pub replies: u64,
}

const BW_RING: usize = 1 << 16;

/// AI [131]: a k-bytes-per-n-cycles window for a link direction. try_now() for cycle-stepped queues (head waits if the
/// window is full); reserve_fifo() for messages that must be timed when issued (far requests leave in issue order):
/// an unbounded FIFO computed eagerly, each message departs at the first slot after the previous one with room.
pub struct BwWindow {
    buf: VecDeque<u32>, // AI [131b]: bytes per cycle from cycle `base` on; grows as far ahead as needed (unbounded FIFO)
    base: u64,
    n: u64,
    k: u64,
    on: bool,
    frontier: u64,
    pub held: u64,  // cycles messages waited on this window
    pub bytes: u64,
}

impl BwWindow {
    pub fn new(gbs: f64, freq: f64, n: usize) -> BwWindow {
        let on = gbs > 0.0;
        BwWindow { buf: VecDeque::new(), base: 0, n: n as u64, k: (gbs / freq * n as f64).floor() as u64, on, frontier: 0, held: 0, bytes: 0 }
    }

    fn clear(&mut self, now: u64) {
        while self.base + self.n + 1 < now {
            self.buf.pop_front();
            self.base += 1;
        }
    }

    fn at(&self, c: u64) -> u64 {
        if c < self.base { return 0; }
        self.buf.get((c - self.base) as usize).copied().unwrap_or(0) as u64
    }

    fn put(&mut self, c: u64, bytes: u64) {
        let i = (c - self.base) as usize;
        if self.buf.len() <= i {
            self.buf.resize(i + 1, 0);
        }
        self.buf[i] += bytes as u32;
    }

    fn fits(&self, s: u64, bytes: u64) -> bool {
        let n = self.n;
        let lo = s.saturating_sub(n - 1);
        let mut sum: u64 = (lo..=s).map(|c| self.at(c)).sum();
        if sum + bytes > self.k {
            return false;
        }
        let mut e = s;
        while e + 1 < s + n {
            e += 1;
            sum += self.at(e);
            if e >= n && e - n >= lo {
                sum -= self.at(e - n);
            }
            if sum + bytes > self.k {
                return false;
            }
        }
        true
    }

    pub fn try_now(&mut self, now: u64, bytes: u64) -> bool {
        self.bytes += bytes;
        if !self.on {
            return true;
        }
        self.clear(now);
        if self.fits(now, bytes) {
            self.put(now, bytes);
            true
        } else {
            self.bytes -= bytes;
            self.held += 1;
            false
        }
    }

    pub fn reserve_fifo(&mut self, now: u64, bytes: u64) -> u64 {
        self.bytes += bytes;
        if !self.on {
            return now;
        }
        self.clear(now);
        let mut s = now.max(self.frontier);
        while !self.fits(s, bytes) {
            s += 1;
        }
        self.put(s, bytes);
        self.frontier = s;
        self.held += s - now;
        s
    }
}

pub struct MemSystem {
    pub stack_id: usize,
    cfg: MemConfig,
    y: Cyc,
    delayed: BinaryHeap<Reverse<(u64, u64)>>, // (arrival, seq) -> delayed_reqs
    delayed_reqs: HashMap<u64, MemReq>,
    seq: u64,
    inq: VecDeque<MemReq>,
    tags: Vec<u64>, // line + 1, 0 = invalid
    dirty: Vec<bool>,
    plru: Vec<u64>,
    mshr: HashMap<u64, Mshr>,
    fills: BinaryHeap<Reverse<(u64, u64)>>, // (fill_done, line)
    chans: Vec<Channel>,
    bw_ring: Vec<u32>,
    bw_cleared: u64,
    // AI [131] links
    local_q: VecDeque<MemReq>,                 // local requests waiting for the core->cache link
    rep_local: BinaryHeap<Reverse<(u64, u64)>>, // (ready, seq) replies to this stack's cores
    rep_far: BinaryHeap<Reverse<(u64, u64)>>,   // replies to other stacks' cores
    rep_in: BinaryHeap<Reverse<(u64, u64)>>,    // replies from other stacks arriving here
    rep_store: HashMap<u64, Done>,
    pub core_in: BwWindow,
    pub core_out: BwWindow,
    pub link_in: BwWindow,
    pub link_out: BwWindow,
    pub out: Vec<Done>, // final: origin == this stack -> deliver to the core at `ready`; else send to origin (caller adds the far latency)
    pub stats: MemStats,
}

fn plru_touch(bits: &mut u64, ways: usize, way: usize) {
    // bit = 1: the victim is in the right half of this node
    let (mut node, mut lo, mut size) = (0usize, 0usize, ways);
    while size > 1 {
        let half = size / 2;
        if way < lo + half {
            *bits |= 1u64 << node; // used left -> victim right
            node = 2 * node + 1;
        } else {
            *bits &= !(1u64 << node); // used right -> victim left
            lo += half;
            node = 2 * node + 2;
        }
        size = half;
    }
}

fn plru_victim(bits: u64, ways: usize) -> usize {
    let (mut node, mut lo, mut size) = (0usize, 0usize, ways);
    while size > 1 {
        let half = size / 2;
        if (bits >> node) & 1 == 1 {
            lo += half;
            node = 2 * node + 2;
        } else {
            node = 2 * node + 1;
        }
        size = half;
    }
    lo
}

impl MemSystem {
    pub fn new(stack_id: usize) -> MemSystem {
        MemSystem::with_config(stack_id, cfg().clone())
    }

    pub fn with_config(stack_id: usize, cfg: MemConfig) -> MemSystem {
        cfg.validate();
        let y = cfg.cyc();
        let (nlines, nsets, nch, nb) = if cfg.legacy { (0, 0, 0, 0) } else { (cfg.sets * cfg.ways, cfg.sets, cfg.channels, cfg.banks) };
        let bank0 = Bank { open_row: None, act_t: -1e18, next_act: 0.0, next_pre: 0.0, next_col: 0.0, busy_until: 0.0 };
        MemSystem {
            stack_id,
            y,
            delayed: BinaryHeap::new(),
            delayed_reqs: HashMap::new(),
            seq: 0,
            inq: VecDeque::new(),
            tags: vec![0; nlines],
            dirty: vec![false; nlines],
            plru: vec![0; nsets],
            mshr: HashMap::new(),
            fills: BinaryHeap::new(),
            chans: (0..nch).map(|_| Channel { bq: (0..nb).map(|_| VecDeque::new()).collect(), queued: 0, banks: vec![bank0; nb], bus: Vec::new() }).collect(),
            bw_ring: vec![0; if cfg.legacy { 0 } else { BW_RING }],
            bw_cleared: 0,
            local_q: VecDeque::new(),
            rep_local: BinaryHeap::new(),
            rep_far: BinaryHeap::new(),
            rep_in: BinaryHeap::new(),
            rep_store: HashMap::new(),
            core_in: BwWindow::new(if cfg.legacy { 0.0 } else { cfg.core_link_gbs }, cfg.freq_ghz, cfg.bw_window),
            core_out: BwWindow::new(if cfg.legacy { 0.0 } else { cfg.core_link_gbs }, cfg.freq_ghz, cfg.bw_window),
            link_in: BwWindow::new(if cfg.legacy { 0.0 } else { cfg.stack_link_gbs }, cfg.freq_ghz, cfg.bw_window),
            link_out: BwWindow::new(if cfg.legacy { 0.0 } else { cfg.stack_link_gbs }, cfg.freq_ghz, cfg.bw_window),
            out: Vec::new(),
            stats: MemStats::default(),
            cfg,
        }
    }

    pub fn far_cycles(&self) -> u64 {
        self.y.far
    }

    fn req_bytes(&self, k: MemKind) -> u64 {
        self.cfg.req_hdr_bytes + if k == MemKind::Read { 0 } else { 4 }
    }

    fn legacy_submit(&mut self, req: MemReq) {
        self.count(req.kind);
        if let Some(r) = req.reply {
            self.out.push(Done { ready: req.arrival + self.cfg.legacy_latency, reply: r });
        }
    }

    /// A request from one of this stack's own cores (issued at `now`); it crosses the core->cache link.
    pub fn submit_local(&mut self, req: MemReq, _now: u64) {
        if self.cfg.legacy {
            return self.legacy_submit(req);
        }
        self.local_q.push_back(req);
    }

    /// A request from another stack; req.arrival = when it reaches this stack's link (departure + far latency).
    pub fn submit_far(&mut self, req: MemReq, _now: u64) {
        if self.cfg.legacy {
            return self.legacy_submit(req);
        }
        self.seq += 1;
        self.delayed.push(Reverse((req.arrival, self.seq)));
        self.delayed_reqs.insert(self.seq, req);
    }

    /// Departure cycle of a far request issued by one of this stack's cores at `now` (stack->stack link, in issue order).
    pub fn depart_far(&mut self, now: u64, kind: MemKind) -> u64 {
        if self.cfg.legacy {
            return now;
        }
        let b = self.req_bytes(kind);
        self.link_out.reserve_fifo(now, b)
    }

    /// A reply from another stack for one of this stack's cores; d.ready = when it reaches this stack's link.
    pub fn far_reply_in(&mut self, d: Done) {
        if self.cfg.legacy {
            self.out.push(d);
            return;
        }
        self.seq += 1;
        self.rep_in.push(Reverse((d.ready, self.seq)));
        self.rep_store.insert(self.seq, d);
    }

    fn reply_at(&mut self, r: Reply, kind: MemKind, ready: u64, arrival: u64) {
        let ready = if kind == MemKind::Atomic { ready + self.cfg.atomic_extra_cycles } else { ready };
        self.stats.replies += 1;
        self.stats.reply_lat_sum += ready.saturating_sub(arrival);
        self.seq += 1;
        if r.origin_stack == self.stack_id {
            self.rep_local.push(Reverse((ready, self.seq)));
        } else {
            self.rep_far.push(Reverse((ready, self.seq)));
        }
        self.rep_store.insert(self.seq, Done { ready, reply: r });
    }

    /// AI [151]: cache set of a line. Plain `line % sets` put every queue header (64 KB apart = 1024 lines) into 4 of the
    ///   4096 sets (period 256 KB), so ~950 polled headers per stack fought over 64 lines. Like [130]'s channel hash, the
    ///   set is rotated by a hash of the bits above the index: consecutive lines still go to consecutive sets, but
    ///   power-of-2 strides spread out. Tags hold the full line number, so lookups stay exact.
    fn set_of(&self, line: u64) -> usize {
        let s = self.cfg.sets as u64;
        if !self.cfg.set_hash {
            return (line % s) as usize;
        }
        let mut z = (line / s).wrapping_add(0x9E37_79B9_7F4A_7C15);
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^= z >> 31;
        ((line % s + z % s) % s) as usize
    }

    fn map(&self, line: u64) -> (usize, usize, u64) {
        // line-interleaved across channels, then a row's worth of lines, then banks, then rows.
        // AI [130]: channel and bank are offset by a hash of the higher bits (like the XOR hashing real controllers use), so
        //   power-of-2 strided structures (per-core / per-queue arrays 64 KB apart) do not all land on one channel and bank.
        //   Still a bijection: for a fixed row group the channel offset is a rotation, for a fixed row the bank offset is too.
        fn h(x: u64) -> u64 {
            let mut z = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^ (z >> 31)
        }
        let c = self.cfg.channels as u64;
        let nb = self.cfg.banks as u64;
        let lines_per_row = (self.cfg.row_bytes / self.cfg.line) as u64;
        let rr = line / c / lines_per_row; // row group: bank_raw + banks * row
        let ch = ((line % c + h(rr)) % c) as usize;
        let row = rr / nb;
        let bank = ((rr % nb + h(row ^ 0x5555)) % nb) as usize;
        (ch, bank, row)
    }

    fn enqueue_dram(&mut self, line: u64, write: bool, ready: u64) {
        let (ch, bank, row) = self.map(line);
        self.seq += 1;
        let sq = self.seq;
        self.chans[ch].bq[bank].push_back(DramTxn { line, bank, row, write, ready, seq: sq });
        self.chans[ch].queued += 1;
    }

    pub fn tick(&mut self, now: u64) {
        if self.cfg.legacy {
            return;
        }
        // keep the bandwidth ring clean behind the window
        let n = self.cfg.bw_window as u64;
        while self.bw_cleared + n + 1 < now {
            self.bw_ring[(self.bw_cleared as usize) % BW_RING] = 0;
            self.bw_cleared += 1;
        }
        // 1a. local requests over the core->cache link
        while let Some(r) = self.local_q.front() {
            let b = self.req_bytes(r.kind);
            if !self.core_in.try_now(now, b) {
                break;
            }
            let r = self.local_q.pop_front().unwrap();
            self.inq.push_back(r);
        }
        // 1b. far requests whose link delay has elapsed, over this stack's incoming link
        while let Some(Reverse((t, sq))) = self.delayed.peek().copied() {
            if t > now {
                break;
            }
            let b = self.req_bytes(self.delayed_reqs[&sq].kind);
            if !self.link_in.try_now(now, b) {
                break;
            }
            self.delayed.pop();
            let r = self.delayed_reqs.remove(&sq).unwrap();
            self.inq.push_back(r);
        }
        // 1c. replies from other stacks for this stack's cores, over the incoming link
        while let Some(Reverse((t, sq))) = self.rep_in.peek().copied() {
            if t > now || !self.link_in.try_now(now, self.cfg.reply_bytes) {
                break;
            }
            self.rep_in.pop();
            let mut d = self.rep_store.remove(&sq).unwrap();
            d.ready = now;
            self.out.push(d);
        }
        // 2. fills that have landed
        while let Some(Reverse((t, line))) = self.fills.peek().copied() {
            if t > now {
                break;
            }
            self.fills.pop();
            self.install(line, now);
        }
        // 3. accept up to `ports` requests, in order
        let mut accepted = 0;
        while accepted < self.cfg.ports {
            let req = match self.inq.front() {
                Some(r) => *r,
                None => break,
            };
            if !self.access(req, now) {
                self.stats.mshr_stall_cycles += 1;
                break;
            }
            self.inq.pop_front();
            accepted += 1;
        }
        if !self.inq.is_empty() {
            self.stats.port_stall_cycles += 1;
            self.stats.max_inq = self.stats.max_inq.max(self.inq.len());
        }
        // 4. DRAM: one command per channel per cycle, FR-FCFS among ready banks
        for ch in 0..self.chans.len() {
            self.schedule_channel(ch, now);
        }
        // 5. finished replies leave: to this stack's cores over the cache->core link, to other stacks over the outgoing link
        while let Some(Reverse((t, sq))) = self.rep_local.peek().copied() {
            if t > now || !self.core_out.try_now(now, self.cfg.reply_bytes) {
                break;
            }
            self.rep_local.pop();
            let mut d = self.rep_store.remove(&sq).unwrap();
            d.ready = now;
            self.out.push(d);
        }
        while let Some(Reverse((t, sq))) = self.rep_far.peek().copied() {
            if t > now || !self.link_out.try_now(now, self.cfg.reply_bytes) {
                break;
            }
            self.rep_far.pop();
            let mut d = self.rep_store.remove(&sq).unwrap();
            d.ready = now;
            self.out.push(d);
        }
    }

    /// Returns false if the request cannot be accepted this cycle (MSHRs full).
    fn access(&mut self, req: MemReq, now: u64) -> bool {
        let line = (req.addr / self.cfg.line) as u64;
        let set = self.set_of(line);
        let base = set * self.cfg.ways;
        let writes = req.kind != MemKind::Read;
        // hit?
        for w in 0..self.cfg.ways {
            if self.tags[base + w] == line + 1 {
                self.count(req.kind);
                self.stats.hits += 1;
                plru_touch(&mut self.plru[set], self.cfg.ways, w);
                if writes {
                    self.dirty[base + w] = true;
                }
                if let Some(r) = req.reply {
                    self.reply_at(r, req.kind, now + self.y.hit, req.arrival);
                }
                return true;
            }
        }
        // pending miss to the same line?
        if let Some(m) = self.mshr.get_mut(&line) {
            m.dirty |= writes;
            let fd = m.fill_done;
            if let Some(r) = req.reply {
                match fd {
                    Some(t) => {
                        let ready = t.max(now + self.y.hit);
                        self.reply_at(r, req.kind, ready, req.arrival);
                    }
                    None => self.mshr.get_mut(&line).unwrap().waiting.push((r, req.kind, req.arrival)),
                }
            }
            self.count(req.kind);
            self.stats.merges += 1;
            return true;
        }
        // new miss
        if self.mshr.len() >= self.cfg.mshrs {
            return false;
        }
        self.count(req.kind);
        self.stats.misses += 1;
        let mut m = Mshr { fill_done: None, dirty: writes, accepted: now, waiting: Vec::new() };
        if let Some(r) = req.reply {
            m.waiting.push((r, req.kind, req.arrival));
        }
        self.mshr.insert(line, m);
        let ready = now + self.y.hit + self.y.io_half.ceil() as u64;
        self.enqueue_dram(line, false, ready);
        true
    }

    fn count(&mut self, k: MemKind) {
        self.stats.accesses += 1;
        match k {
            MemKind::Read => self.stats.reads += 1,
            MemKind::Write => self.stats.writes += 1,
            MemKind::Atomic => self.stats.atomics += 1,
        }
    }

    fn install(&mut self, line: u64, now: u64) {
        let m = self.mshr.remove(&line).expect("fill without MSHR");
        debug_assert!(m.waiting.is_empty());
        let set = self.set_of(line);
        let base = set * self.cfg.ways;
        let way = (0..self.cfg.ways).find(|w| self.tags[base + w] == 0).unwrap_or_else(|| plru_victim(self.plru[set], self.cfg.ways));
        let old = self.tags[base + way];
        if old != 0 && self.dirty[base + way] {
            self.stats.writebacks += 1;
            let ready = now + self.y.io_half.ceil() as u64;
            self.enqueue_dram(old - 1, true, ready);
        }
        self.tags[base + way] = line + 1;
        self.dirty[base + way] = m.dirty;
        plru_touch(&mut self.plru[set], self.cfg.ways, way);
    }

    /// Earliest cycle >= `start` at which `bytes` can start without any n-cycle window exceeding k bytes.
    fn bw_find(&self, start: f64, bytes: u32, now: u64) -> u64 {
        let n = self.cfg.bw_window as u64;
        let k = self.y.bw_bytes;
        let mut s = start.floor().max(now as f64) as u64;
        loop {
            assert!(s + n < now + (BW_RING as u64) - n - 2, "bandwidth ring horizon exceeded (stack {}, now {}, s {})", self.stack_id, now, s);
            // windows ending at e = s .. s+n-1; window e covers [e-n+1, e]
            let lo = s.saturating_sub(n - 1);
            let mut sum: u64 = (lo..=s).map(|c| self.bw_ring[(c as usize) % BW_RING] as u64).sum();
            let mut ok = sum + bytes as u64 <= k;
            let mut e = s;
            while ok && e + 1 < s + n {
                e += 1;
                sum += self.bw_ring[(e as usize) % BW_RING] as u64;
                if e >= n {
                    let drop = e - n;
                    if drop >= lo {
                        sum -= self.bw_ring[(drop as usize) % BW_RING] as u64;
                    }
                }
                ok = sum + bytes as u64 <= k;
            }
            if ok {
                return s;
            }
            s += 1;
        }
    }

    /// Timing of issuing txn `x` on its bank at cycle t: (col, activation time if any, row case 0 hit / 1 empty / 2 conflict, data want).
    fn plan(&self, ch: usize, x: &DramTxn, t: f64) -> (f64, Option<f64>, u8, f64) {
        let y = &self.y;
        let b = &self.chans[ch].banks[x.bank];
        let rcd = if x.write { y.rcd_wr } else { y.rcd_rd };
        let (col, act, case) = match b.open_row {
            Some(r) if r == x.row => (t.max(b.next_col), None, 0u8),
            Some(_) => {
                let pre = t.max(b.next_pre);
                let act = (pre + y.rp).max(b.next_act);
                (act + rcd, Some(act), 2u8)
            }
            None => {
                let act = t.max(b.next_act);
                (act + rcd, Some(act), 1u8)
            }
        };
        let lat = if x.write { y.cwl } else { y.cl };
        (col, act, case, self.bus_slot(ch, col + lat))
    }

    /// Earliest start >= `from` where one burst fits between booked bus intervals.
    fn bus_slot(&self, ch: usize, from: f64) -> f64 {
        let mut c = from;
        for &(s, e) in self.chans[ch].bus.iter() {
            if c + self.y.burst <= s + 1e-9 {
                break;
            }
            if e > c {
                c = e;
            }
        }
        c
    }

    fn schedule_channel(&mut self, ch: usize, now: u64) {
        let t = now as f64;
        self.chans[ch].bus.retain(|iv| iv.1 > t);
        let open = self.cfg.page == PagePolicy::Open;
        let lat_min = self.y.cl.min(self.y.cwl);
        // FR-FCFS: ready txns on idle banks, row hits first, then by age. One command per channel per cycle.
        // A txn is held back if its data would wait more than one burst for the bus (the controller does not
        // issue a command whose data cannot go out), or if the bandwidth cap would push it more than a cycle.
        // candidates: per idle bank, its oldest row hit among the first 16 queued, else its oldest ready txn
        let mut order: Vec<(u64, usize, usize)> = Vec::new(); // (age seq, bank, index in the bank queue)
        {
            let c = &self.chans[ch];
            if c.queued == 0 {
                return;
            }
            let mut rest: Vec<(u64, usize, usize)> = Vec::new();
            for (bk, q) in c.bq.iter().enumerate() {
                if q.is_empty() || c.banks[bk].busy_until > t {
                    continue;
                }
                let mut any = None;
                let mut hit = None;
                for (i, x) in q.iter().take(16).enumerate() {
                    if x.ready > now {
                        continue;
                    }
                    if any.is_none() {
                        any = Some((x.seq, bk, i));
                    }
                    if open && c.banks[bk].open_row == Some(x.row) {
                        hit = Some((x.seq, bk, i));
                        break;
                    }
                }
                if let Some(h) = hit {
                    order.push(h);
                } else if let Some(a) = any {
                    rest.push(a);
                }
            }
            order.sort_unstable();
            rest.sort_unstable();
            order.extend(rest);
        }
        let mut held_by_bw = false;
        for (_, bk, i) in order {
            let x = self.chans[ch].bq[bk][i];
            let (col, act, case, want) = self.plan(ch, &x, t);
            let natural = col + if x.write { self.y.cwl } else { self.y.cl };
            if want > natural + self.y.burst && want > t + lat_min + self.y.burst {
                continue; // bus booked too far ahead for this one
            }
            let s_ok = self.bw_find(want, self.cfg.line as u32, now);
            if s_ok > want.floor() as u64 {
                held_by_bw = true;
                continue;
            }
            self.issue(ch, (bk, i), x, col, act, case, want, s_ok, now);
            return;
        }
        if held_by_bw {
            self.stats.bw_delays += 1;
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn issue(&mut self, ch: usize, i: (usize, usize), x: DramTxn, col: f64, act: Option<f64>, case: u8, want: f64, s_ok: u64, now: u64) {
        let y = self.y.clone();
        let open = self.cfg.page == PagePolicy::Open;
        self.chans[ch].bq[i.0].remove(i.1);
        self.chans[ch].queued -= 1;
        match case {
            0 => self.stats.row_hits += 1,
            1 => self.stats.row_empty += 1,
            _ => self.stats.row_conflicts += 1,
        }
        self.bw_ring[(s_ok as usize) % BW_RING] += self.cfg.line as u32;
        let data_start = want.max(s_ok as f64);
        let data_end = data_start + y.burst;
        let bus = &mut self.chans[ch].bus;
        let pos = bus.iter().position(|iv| iv.0 > data_start).unwrap_or(bus.len());
        bus.insert(pos, (data_start, data_end));
        self.stats.dram_bytes += self.cfg.line as u64;
        let mut b = self.chans[ch].banks[x.bank];
        if let Some(a) = act {
            b.act_t = a;
        }
        b.next_col = col + y.burst;
        b.busy_until = col;
        let pre_ok = (b.act_t + y.ras).max(if x.write { data_end + y.wr } else { col + y.burst });
        if open {
            b.open_row = Some(x.row);
            b.next_pre = pre_ok;
        } else {
            b.open_row = None;
            b.next_act = pre_ok + y.rp;
        }
        self.chans[ch].banks[x.bank] = b;
        if x.write {
            return;
        }
        // fill: data reaches the cache after the return half of the io trip
        let fill_done = (data_end + y.io_half).ceil() as u64;
        self.stats.fills += 1;
        self.fills.push(Reverse((fill_done, x.line)));
        let m = self.mshr.get_mut(&x.line).expect("fill txn without MSHR");
        m.fill_done = Some(fill_done);
        let waiting = std::mem::take(&mut m.waiting);
        let accepted = m.accepted;
        for (r, k, arr) in waiting {
            self.reply_at(r, k, fill_done, arr);
        }
        self.stats.miss_lat_sum += fill_done - accepted;
        let _ = now;
    }

    pub fn summary(&self, cycle: u64) -> String {
        let s = &self.stats;
        let hr = if s.accesses > 0 { 100.0 * s.hits as f64 / s.accesses as f64 } else { 0.0 };
        let rows = (s.row_hits + s.row_empty + s.row_conflicts).max(1) as f64;
        format!(
            "MEMSTAT stack {} cycle {} acc {} (rd {} wr {} at {}) hit {:.1}% miss {} merge {} wb {} | row hit {:.1}% empty {:.1}% conflict {:.1}% | \
             dram {} MB = {:.1} GB/s | avg miss {:.0} cyc avg reply {:.1} cyc | bw-held {} ch-cyc mshr-stall {} port-stall {} max inq {} | mshr now {} inq now {} | \
             links GB/s (held): core-in {:.1} ({}) core-out {:.1} ({}) stack-in {:.1} ({}) stack-out {:.1} ({}) | waiting: core-in {} stack-in req {} reply-out {} reply-in {}",
            self.stack_id, cycle, s.accesses, s.reads, s.writes, s.atomics, hr, s.misses, s.merges, s.writebacks,
            100.0 * s.row_hits as f64 / rows, 100.0 * s.row_empty as f64 / rows, 100.0 * s.row_conflicts as f64 / rows,
            s.dram_bytes >> 20, if cycle > 0 { s.dram_bytes as f64 / cycle as f64 * self.cfg.freq_ghz } else { 0.0 },
            if s.fills > 0 { s.miss_lat_sum as f64 / s.fills as f64 } else { 0.0 },
            if s.replies > 0 { s.reply_lat_sum as f64 / s.replies as f64 } else { 0.0 },
            s.bw_delays, s.mshr_stall_cycles, s.port_stall_cycles, s.max_inq, self.mshr.len(), self.inq.len(),
            self.core_in.bytes as f64 / cycle.max(1) as f64 * self.cfg.freq_ghz, self.core_in.held,
            self.core_out.bytes as f64 / cycle.max(1) as f64 * self.cfg.freq_ghz, self.core_out.held,
            self.link_in.bytes as f64 / cycle.max(1) as f64 * self.cfg.freq_ghz, self.link_in.held,
            self.link_out.bytes as f64 / cycle.max(1) as f64 * self.cfg.freq_ghz, self.link_out.held,
            self.local_q.len(), self.delayed.len(), self.rep_local.len() + self.rep_far.len(), self.rep_in.len()
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rd(addr: usize, t: u64, reg: usize) -> MemReq {
        MemReq { arrival: t, addr, kind: MemKind::Read, reply: Some(Reply { origin_stack: 0, core_id: 0, register_index: reg, value: 0 }) }
    }

    fn run(m: &mut MemSystem, from: u64, to: u64) -> Vec<Done> {
        let mut v = Vec::new();
        for t in from..to {
            m.tick(t);
            v.extend(m.out.drain(..));
        }
        v
    }

    #[test]
    fn miss_then_hit_latency() {
        let c = MemConfig::base("hbm3");
        let y = c.cyc();
        let mut m = MemSystem::with_config(0, c.clone());
        m.submit_local(rd(0, 0, 1), 0);
        let d = run(&mut m, 0, 400);
        assert_eq!(d.len(), 1);
        // tag lookup + half io, ACT, tRCD, tCL, burst, half io
        let issue = (y.hit + y.io_half.ceil() as u64) as f64;
        let exp = (issue + y.rcd_rd + y.cl + y.burst + y.io_half).ceil() as u64;
        assert_eq!(d[0].ready, exp, "miss latency");
        m.submit_local(rd(4, 400, 2), 400);
        let d = run(&mut m, 400, 500);
        assert_eq!(d[0].ready, 400 + y.hit, "hit latency");
        println!("miss {} cyc, hit {} cyc", exp, y.hit);
    }

    #[test]
    fn merge_and_atomic() {
        let c = MemConfig::base("hbm3");
        let mut m = MemSystem::with_config(0, c.clone());
        m.submit_local(rd(64, 0, 1), 0);
        m.submit_local(MemReq { arrival: 0, addr: 68, kind: MemKind::Atomic, reply: Some(Reply { origin_stack: 0, core_id: 0, register_index: 2, value: 0 }) }, 0);
        let d = run(&mut m, 0, 400);
        assert_eq!(d.len(), 2);
        assert_eq!(d[1].ready, d[0].ready + c.atomic_extra_cycles);
        assert_eq!(m.stats.misses, 1);
        assert_eq!(m.stats.merges, 1);
    }

    #[test]
    fn eviction_writeback() {
        let mut c = MemConfig::base("hbm3");
        c.sets = 1;
        c.ways = 2;
        let mut m = MemSystem::with_config(0, c);
        // dirty line 0, then two more lines in the same (only) set -> line 0 is evicted dirty
        m.submit_local(MemReq { arrival: 0, addr: 0, kind: MemKind::Write, reply: None }, 0);
        run(&mut m, 0, 300);
        m.submit_local(rd(64, 300, 1), 300);
        run(&mut m, 300, 600);
        m.submit_local(rd(128, 600, 2), 600);
        run(&mut m, 600, 900);
        assert_eq!(m.stats.writebacks, 1);
        assert_eq!(m.stats.misses, 3);
    }

    #[test]
    fn row_buffer_policy() {
        for (page, want_hits) in [(PagePolicy::Open, true), (PagePolicy::Closed, false)] {
            let mut c = MemConfig::base("ddr5");
            c.page = page;
            let mut m = MemSystem::with_config(0, c.clone());
            // lines 0, 2, 4, ... all map to channel 0, same row
            for i in 0..8 {
                m.submit_local(rd(i * 2 * 64, 0, i), 0);
            }
            run(&mut m, 0, 2000);
            assert_eq!(m.stats.row_hits > 0, want_hits, "{:?}", page);
        }
    }

    #[test]
    fn bandwidth_cap_holds() {
        let mut c = MemConfig::base("hbm3");
        c.bw_gbs = 100.0; // well below the 819 GB/s channel sum so the cap binds
        c.bw_window = 50;
        c.mshrs = 4096;
        c.ports = 64;
        let y = c.cyc();
        let mut m = MemSystem::with_config(0, c.clone());
        let mut reg = 0;
        let n = c.bw_window;
        let (mut worst, mut total) = (0u64, 0u64);
        for t in 0..3000u64 {
            for k in 0..4 {
                m.submit_local(rd(((t * 4 + k) as usize) * 64 * 97, t, reg), t);
                reg += 1;
            }
            m.tick(t);
            m.out.clear();
            // nothing can be placed before `now` any more, so the window ending at t is final
            if t as usize >= n {
                let s: u64 = (t as usize + 1 - n..=t as usize).map(|x| m.bw_ring[x % BW_RING] as u64).sum();
                worst = worst.max(s);
                total += m.bw_ring[t as usize % BW_RING] as u64;
            }
        }
        assert!(worst <= y.bw_bytes, "window carried {} > cap {}", worst, y.bw_bytes);
        assert!(m.stats.bw_delays > 0);
        println!("cap {} B / {} cyc, worst window {}, avg {:.1} B/cyc (cap {:.1})", y.bw_bytes, n, worst, total as f64 / (3000 - n) as f64, y.bw_bytes as f64 / n as f64);
        assert!(total as f64 / (3000 - n) as f64 > 0.9 * y.bw_bytes as f64 / n as f64, "cap should be nearly saturated");
    }

    #[test]
    fn plru_tree() {
        let mut b = 0u64;
        for w in 0..8 {
            plru_touch(&mut b, 8, w);
            assert_ne!(plru_victim(b, 8), w);
        }
        // after touching 0..7 in order, the victim is 0 (least recently used)
        assert_eq!(plru_victim(b, 8), 0);
        plru_touch(&mut b, 8, 0);
        assert_ne!(plru_victim(b, 8), 0);
    }

    #[test]
    fn streaming_throughput() {
        for prof in ["hbm3", "gddr6", "gddr6x", "ddr5"] {
            for seq in [true, false] {
                let mut c = MemConfig::base(prof);
                c.mshrs = 4096;
                c.ports = 64;
                let y = c.cyc();
                let mut m = MemSystem::with_config(0, c.clone());
                let mut reg = 0usize;
                let mut x: u64 = 12345;
                for t in 0..20000u64 {
                    for _ in 0..16 {
                        let a = if seq { reg * 64 } else { x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407); ((x >> 20) as usize % (1 << 30)) & !63 };
                        m.submit_local(rd(a, t, reg), t);
                        reg += 1;
                    }
                    m.tick(t);
                    m.out.clear();
                }
                let peak = c.eff_bw() / c.freq_ghz;
                let got = m.stats.dram_bytes as f64 / 20000.0;
                println!("{} {}: bwheld {} {:.1} B/cyc of {:.1} peak ({:.0}%), row hit {:.0}%", prof, m.stats.bw_delays, if seq { "seq" } else { "rand" }, got, peak, 100.0 * got / peak,
                    100.0 * m.stats.row_hits as f64 / (m.stats.row_hits + m.stats.row_empty + m.stats.row_conflicts) as f64);
                let _ = y;
                if seq { assert!(got > 0.8 * peak, "sequential stream should reach most of peak"); }
            }
        }
    }

    #[test]
    fn strided_64k_sets_spread() {
        // AI [151]: 1024 queue headers 64 KB apart must not share a handful of cache sets
        let c = MemConfig::base("hbm3");
        let m = MemSystem::with_config(0, c.clone());
        let sets: std::collections::HashSet<usize> = (0..1024u64).map(|k| m.set_of(k * 65536 / 64)).collect();
        assert!(sets.len() >= 600, "64 KB stride uses only {} cache sets", sets.len());
        let mut c2 = c.clone();
        c2.set_hash = false;
        let m2 = MemSystem::with_config(0, c2);
        let sets2: std::collections::HashSet<usize> = (0..1024u64).map(|k| m2.set_of(k * 65536 / 64)).collect();
        assert!(sets2.len() == 4, "unhashed index should alias to 4 sets, got {}", sets2.len());
    }

    #[test]
    fn strided_64k_spreads() {
        // AI [130]: per-core structures 64 KB apart used to all map to channel 0
        let c = MemConfig::base("hbm3");
        let mut m = MemSystem::with_config(0, c.clone());
        let mut chans = std::collections::HashSet::new();
        for k in 0..1024u64 {
            chans.insert(m.map(k * 65536 / 64).0);
        }
        assert!(chans.len() >= 28, "64 KB stride hits only {} of 32 channels", chans.len());
        let mut reg = 0usize;
        for t in 0..5000u64 {
            for _ in 0..4 {
                m.submit_local(rd((reg % 8192) * 65536 + (reg / 8192) * 64, t, reg), t);
                reg += 1;
            }
            m.tick(t);
            m.out.clear();
        }
        println!("64KB stride: {} channels, {:.1} B/cyc", chans.len(), m.stats.dram_bytes as f64 / 5000.0);
        assert!(m.stats.dram_bytes as f64 / 5000.0 > 80.0); // ~256 MSHRs / ~150-cycle misses (Little), not one channel
    }

    #[test]
    fn link_windows_cap() {
        // AI [131]: reserve_fifo and try_now never exceed k bytes per n cycles and nearly saturate under overload
        for fifo in [true, false] {
            let mut w = BwWindow::new(64.0, 2.0, 50); // 32 B/cycle, k = 1600
            let mut placed = vec![0u64; 20000];
            let mut q = 0u64;
            for t in 0..10000u64 {
                for _ in 0..8 {
                    if fifo {
                        let s = w.reserve_fifo(t, 12);
                        if (s as usize) < placed.len() { placed[s as usize] += 12; }
                    } else {
                        q += 1;
                    }
                }
                if !fifo {
                    while q > 0 && w.try_now(t, 12) { q -= 1; placed[t as usize] += 12; }
                }
                if t > 9000 { break; }
            }
            let worst = (50..9000).map(|e| placed[e + 1 - 50..=e].iter().sum::<u64>()).max().unwrap();
            let avg = placed[100..9000].iter().sum::<u64>() as f64 / 8900.0;
            println!("fifo {} worst window {} (k 1600) avg {:.1} B/cyc (cap 32)", fifo, worst, avg);
            assert!(worst <= 1600 && avg > 28.0);
        }
    }

    #[test]
    fn far_round_trip() {
        // a far read: depart over stack A's out link, served by stack B, reply back over B's out and A's in link
        let c = MemConfig::base("hbm3");
        let y = c.cyc();
        let mut a = MemSystem::with_config(0, c.clone());
        let mut b = MemSystem::with_config(1, c.clone());
        let dep = a.depart_far(0, MemKind::Read);
        b.submit_far(MemReq { arrival: dep + y.far, addr: 0, kind: MemKind::Read, reply: Some(Reply { origin_stack: 0, core_id: 0, register_index: 3, value: 7 }) }, 0);
        let mut got = None;
        for t in 0..1000u64 {
            b.tick(t);
            for d in b.out.drain(..) { a.far_reply_in(Done { ready: d.ready + y.far, reply: d.reply }); }
            a.tick(t);
            for d in a.out.drain(..) { got = Some(d); }
            if got.is_some() { break; }
        }
        let d = got.expect("no reply");
        assert_eq!(d.reply.value, 7);
        println!("far miss round trip {} cycles", d.ready);
        assert_eq!(d.ready, 109 + 2 * y.far);
    }
}
