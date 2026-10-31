use half::f16;
use std::cell::UnsafeCell;
use std::io::{self, Write};
use std::marker::PhantomData;
use std::mem::MaybeUninit;
use std::ptr::{self, NonNull};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::Sender;
// AI debug [40]: per-(core, pc) tally of atomic adds to one DRAM word (root queue count)
pub const QCNT_WATCH_ADDR: usize = 1_115_000_008;
pub static QCNT_LOG: std::sync::OnceLock<std::sync::Mutex<std::collections::BTreeMap<(u32, u16), (i64, u64)>>> = std::sync::OnceLock::new();

use crate::{CORES_IN_X_STACK, CoreLog, dram_read_word};

pub const FP_PIPE_STAGES: usize = 4;
pub const DIV_LATENCY: usize = 32;
pub const DRAM_LATENCY_FAR: u64 = 6;
pub const DRAM_LATENCY_CLOSE: u64 = 6;
// AI debug [85]: hit counters
pub static NOC_WATCH_PC: [std::sync::atomic::AtomicU32; 6] = [std::sync::atomic::AtomicU32::new(u32::MAX), std::sync::atomic::AtomicU32::new(u32::MAX), std::sync::atomic::AtomicU32::new(u32::MAX), std::sync::atomic::AtomicU32::new(u32::MAX), std::sync::atomic::AtomicU32::new(u32::MAX), std::sync::atomic::AtomicU32::new(u32::MAX)]; // AI [102]: 0-2 branch, 3-5 leaf
pub static NOC_WATCH_N: [std::sync::atomic::AtomicU64; 6] = [std::sync::atomic::AtomicU64::new(0), std::sync::atomic::AtomicU64::new(0), std::sync::atomic::AtomicU64::new(0), std::sync::atomic::AtomicU64::new(0), std::sync::atomic::AtomicU64::new(0), std::sync::atomic::AtomicU64::new(0)];
pub static DESCEND_PC: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(u32::MAX); // AI [104]
pub static DESCEND_NULL_N: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
pub static LEAF_HIT_PC: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(u32::MAX);
pub static BRANCH_HIT_PC: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(u32::MAX);
pub static LEAF_WATCH_PC: [std::sync::atomic::AtomicU32; 4] = [std::sync::atomic::AtomicU32::new(u32::MAX), std::sync::atomic::AtomicU32::new(u32::MAX), std::sync::atomic::AtomicU32::new(u32::MAX), std::sync::atomic::AtomicU32::new(u32::MAX)]; // AI [86]
pub static LEAF_WATCH_N: [std::sync::atomic::AtomicU64; 4] = [std::sync::atomic::AtomicU64::new(0), std::sync::atomic::AtomicU64::new(0), std::sync::atomic::AtomicU64::new(0), std::sync::atomic::AtomicU64::new(0)];
thread_local! {
    // AI [129] debug: DRAM requests issued per (firmware: 0 leaf / 1 branch, PC word, target stack), per stack thread
    pub static DRAM_PC_HIST: std::cell::RefCell<Vec<u64>> = std::cell::RefCell::new(Vec::new());
    // AI [132] debug: instructions executed per (firmware: 0 leaf / 1 branch, PC word), per stack thread
    pub static PC_EXEC_HIST: std::cell::RefCell<Vec<u64>> = std::cell::RefCell::new(Vec::new());
}
pub static LEAF_HITS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
pub static BRANCH_HITS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
pub const REGS_PER_CONTEXT: usize = 16;
pub const SRAM_SIZE: usize = 64 * 1024; // AI [102]: was 48KB (Alex: up to 64KB)
pub const NUM_NOC_PIPES: usize = 64;
pub const HIGH_CAPACITY_NOC_PIPE_CNT: usize = 16;
pub const HIGH_CAPACITY_PIPE_SLOTS: usize = 16;
pub const OUTPUT_NOC_FIFO_CAPACITY: usize = 1;
pub const PRIORITIZE_X: bool = false;
pub const CORES_IN_X: u16 = 32;
pub const CORES_IN_Y: u16 = 32;
pub static BOOT_CLOBBER_N: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0); // AI [97]
pub static STRAY_N: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0); // AI debug [153]: STRAY lines printed (capped)
pub static REBOOT_STATE_N: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0); // AI debug [153]
pub static HS_N: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0); // AI debug [156]: HS lines printed (capped)
pub static DUMP_REQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0); // AI debug [158]: ((core + 1) << 8) | ctx of a STRAY sender to dump (0 = none)
pub static HS_DUMPS: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0); // AI debug [158]: sender dumps done (capped)
// AI debug [159] (Alex: cycle-by-cycle history, ~100K cycles): per-core ring of one u32 per cycle, DRAEM_CYC_RING entries (power of 2,
//   default 131072 = 512 KB per core, ~4 GB for 8192 cores; 0 = off). Entry = pc (bits 0-15) | ctx (16-19) | issued (bit 20) | valid (bit 21).
pub fn cyc_ring_len() -> usize { static L: std::sync::OnceLock<usize> = std::sync::OnceLock::new(); *L.get_or_init(|| std::env::var("DRAEM_CYC_RING").ok().and_then(|v| v.trim().parse::<usize>().ok()).map(|n| if n == 0 { 0 } else { n.next_power_of_two() }).unwrap_or(131072)) }
#[derive(Clone, Copy, Default)]
pub struct MboxRec { pub src_core: u16, pub src_ctx: u8, pub src_isb: u8, pub src_pc: u16, pub value: u32, pub sent: u64, pub arrived: u64, pub expected: bool } // AI debug [153]
pub const DRAM_STACK_SIZE: usize = 1 << 31;
pub const DRAM_STACK_SIZE_LOG2: usize = 31;
pub const NOC_FIFO_SIZE: usize = 2; // AI [160]: was 1. Pops now free a slot for the producer only the next cycle (deterministic across threads), so a
                                     //   1-cycle link needs 2 slots to carry one flit per cycle (credit round trip); 1 slot would halve back-to-back throughput.
pub const NOC_FIFO_LATENCY: usize = 1;
// AI [60]: per-instruction tracing is now switchable at run time: DRAEM_TRACE=0 turns it off (default on, as before).
pub static DEBUG_FLAG: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
#[inline]
pub fn debug_on() -> bool { *DEBUG_FLAG.get_or_init(|| std::env::var("DRAEM_TRACE").map(|v| v.trim() != "0").unwrap_or(true)) && SIM_CYCLE.load(std::sync::atomic::Ordering::Relaxed) >= *TRACE_FROM.get_or_init(|| std::env::var("DRAEM_TRACE_FROM").ok().and_then(|v| v.trim().parse().ok()).unwrap_or(0)) }
// AI [105]: tracing starts at cycle DRAEM_TRACE_FROM (default 0); main.rs stores the current cycle each cycle. Execution is unchanged.
pub static SIM_CYCLE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
pub static TRACE_FROM: std::sync::OnceLock<u64> = std::sync::OnceLock::new();
pub static ENTERED_SNAP: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0); // AI [B4]: RAYS_ENTERED (stack 2) for the INFLIGHT line
pub const NOC_UTIL_EPOCH_LEN: usize = 10000; // AI [B4] (20M-cycle runs; Alex: 10K): was 200. Per-core per-epoch stats are Vec<usize> (8 B): 20M / 200 = 100K epochs x 8192 cores x 9 metrics ~ 59 GB of RAM; 10000 -> ~1.2 GB
pub const READY_SAMPLE: u64 = 16; // AI [144]: cycles between ready-context samples
pub const CTX_CNT: usize = 16;
// Router-generated rejects for ray requests (mailbox 32/33) that arrive at a full mailbox.
pub const RAY_REQUEST_MAILBOX_EVEN: u16 = 32;
pub const RAY_REQUEST_MAILBOX_ODD: u16 = 33;
pub const REJECT_RAY_CODE: u32 = 7;
pub const NOC_CLONE_NACK: u32 = 0xE000_0004; // AI [113]: router bounce for a full pipe 34 (clone firmware treats it like BUSY)
pub const REJECT_SEND_FIFO_CAPACITY: usize = 4;
struct Inner<T> {
    buffer: Box<[UnsafeCell<MaybeUninit<T>>]>,
    capacity: usize,
    head: AtomicUsize, // producer writes
    tail: AtomicUsize, // consumer writes
    pop_mark: std::sync::atomic::AtomicU64, // AI [160]: (cycle << 16) | pops the consumer made in that cycle (NoC links only)
}

unsafe impl<T: Send> Send for Inner<T> {}
unsafe impl<T: Send> Sync for Inner<T> {}

impl<T> Inner<T> {
    fn with_capacity(capacity: usize) -> Self {
        assert!(capacity > 0, "capacity must be non-zero");
        let mut v = Vec::with_capacity(capacity);
        for _ in 0..capacity {
            v.push(UnsafeCell::new(MaybeUninit::uninit()));
        }
        Self {
            buffer: v.into_boxed_slice(),
            capacity,
            head: AtomicUsize::new(0),
            tail: AtomicUsize::new(0),
            pop_mark: std::sync::atomic::AtomicU64::new(0),
        }
    }

    #[inline]
    fn capacity(&self) -> usize {
        self.capacity
    }

    #[inline]
    fn len(&self) -> usize {
        let h = self.head.load(Ordering::Acquire);
        let t = self.tail.load(Ordering::Acquire);
        h.wrapping_sub(t)
    }

    #[inline]
    fn is_empty(&self) -> bool {
        self.len() == 0
    }

    #[inline]
    fn is_full(&self) -> bool {
        self.len() == self.capacity
    }

    // Canonical SPSC ops used by both modes:

    #[inline]
    fn push(&self, value: T) -> Result<(), T> {
        let head = self.head.load(Ordering::Relaxed);
        let tail = self.tail.load(Ordering::Acquire);

        if head.wrapping_sub(tail) == self.capacity {
            return Err(value);
        }

        let idx = head % self.capacity;
        unsafe {
            (*self.buffer[idx].get()).write(value);
        }

        self.head.store(head.wrapping_add(1), Ordering::Release);
        Ok(())
    }

    #[inline]
    fn pop(&self) -> Option<T> {
        let tail = self.tail.load(Ordering::Relaxed);
        let head = self.head.load(Ordering::Acquire);

        if tail == head {
            return None;
        }

        let idx = tail % self.capacity;
        let value = unsafe { (*self.buffer[idx].get()).assume_init_read() };

        self.tail.store(tail.wrapping_add(1), Ordering::Release);
        Some(value)
    }

    /// AI [160]: record a consumer pop made in `cyc`.
    #[inline]
    fn note_pop(&self, cyc: u64) {
        let m = self.pop_mark.load(Ordering::Relaxed);
        let v = if m >> 16 == cyc { m + 1 } else { (cyc << 16) | 1 };
        self.pop_mark.store(v, Ordering::Release);
    }

    /// AI [160]: occupancy as of the start of cycle `cyc`: slots the consumer freed during `cyc` count as still taken, so a producer
    ///   in another thread sees the same answer whether or not the consumer has run yet this cycle.
    #[inline]
    fn len_at_start(&self, cyc: u64) -> usize {
        let m = self.pop_mark.load(Ordering::Acquire);
        let popped = if m >> 16 == cyc { (m & 0xFFFF) as usize } else { 0 };
        self.len() + popped
    }

    #[inline]
    fn peek_ptr(&self) -> Option<NonNull<T>> {
        let tail = self.tail.load(Ordering::Relaxed);
        let head = self.head.load(Ordering::Acquire);

        if tail == head {
            return None;
        }

        let idx = tail % self.capacity;
        let p = unsafe { (*self.buffer[idx].get()).as_ptr() as *mut T };
        Some(NonNull::new(p).unwrap())
    }
}

impl<T> Drop for Inner<T> {
    fn drop(&mut self) {
        // drain remaining elements
        let mut t = self.tail.load(Ordering::Relaxed);
        let h = self.head.load(Ordering::Relaxed);

        while t != h {
            let idx = t % self.capacity;
            unsafe {
                ptr::drop_in_place((*self.buffer[idx].get()).as_mut_ptr());
            }
            t = t.wrapping_add(1);
        }
    }
}

// ===================== Peek guards =====================

pub struct PeekGuard<'a, T> {
    ptr: NonNull<T>,
    _borrow: PhantomData<&'a mut ()>, // ties to a mutable borrow of the owner handle
}

impl<'a, T> std::ops::Deref for PeekGuard<'a, T> {
    type Target = T;
    fn deref(&self) -> &T {
        unsafe { self.ptr.as_ref() }
    }
}

// ===================== Normal (single-thread) queue =====================

pub struct SpscQueue<T> {
    inner: Inner<T>,
}
impl<T: Clone> Clone for SpscQueue<T> {
    fn clone(&self) -> Self {
        let cap = self.inner.capacity();

        let mut new = SpscQueue::new(cap);

        // Snapshot current contents
        let len = self.inner.len();
        let tail = self.inner.tail.load(Ordering::Relaxed);

        for i in 0..len {
            let idx = (tail + i) % cap;
            let val = unsafe { (*self.inner.buffer[idx].get()).assume_init_ref().clone() };
            let _ = new.push(val);
        }

        new
    }
}
impl<T> SpscQueue<T> {
    pub fn new(capacity: usize) -> Self {
        Self {
            inner: Inner::with_capacity(capacity),
        }
    }

    #[inline]
    pub fn push(&mut self, value: T) -> Result<(), T> {
        // &mut self guarantees “normal use” (no concurrent producer/consumer)
        self.inner.push(value)
    }

    #[inline]
    pub fn pop(&mut self) -> Option<T> {
        self.inner.pop()
    }

    #[inline]
    pub fn peek<'a>(&'a mut self) -> Option<PeekGuard<'a, T>> {
        let ptr = self.inner.peek_ptr()?;
        Some(PeekGuard {
            ptr,
            _borrow: PhantomData,
        })
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.inner.len()
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }

    #[inline]
    pub fn is_full(&self) -> bool {
        self.inner.is_full()
    }

    #[inline]
    pub fn capacity(&self) -> usize {
        self.inner.capacity()
    }

    /// Consume the queue and split into producer/consumer handles for two threads.
    pub fn split(self) -> (Feeder<T>, Eater<T>) {
        let arc = Arc::new(self.inner);
        (Feeder { q: arc.clone() }, Eater { q: arc })
    }
}

// ===================== Split endpoints =====================

pub struct Feeder<T> {
    q: Arc<Inner<T>>,
}

pub struct Eater<T> {
    q: Arc<Inner<T>>,
}

impl<T> Feeder<T> {
    #[inline]
    pub fn push(&mut self, value: T) -> Result<(), T> {
        self.q.push(value)
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.q.len()
    }

    #[inline]
    pub fn is_full(&self) -> bool {
        self.q.is_full()
    }

    #[inline]
    pub fn capacity(&self) -> usize {
        self.q.capacity()
    }
}

impl<T> Eater<T> {
    #[inline]
    pub fn pop(&mut self) -> Option<T> {
        self.q.pop()
    }

    #[inline]
    pub fn peek<'a>(&'a mut self) -> Option<PeekGuard<'a, T>> {
        let ptr = self.q.peek_ptr()?;
        Some(PeekGuard {
            ptr,
            _borrow: PhantomData,
        })
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.q.len()
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.q.is_empty()
    }

    #[inline]
    pub fn capacity(&self) -> usize {
        self.q.capacity()
    }
}






pub const NOC_PRIORITY_THRESHOLD: u16 = 32;

#[inline]
fn flit_lane(mailbox_id: u16) -> usize {
    if mailbox_id < NOC_PRIORITY_THRESHOLD { 0 } else { 1 }
}

// Two independent SPSC lanes. Lane 0 = high priority (mailbox < 32),
// lane 1 = low priority (mailbox >= 32). Each lane has its own capacity;
// flits never switch lanes between hops.
struct PrioritizedInner {
    lanes: [Inner<Flit>; 2],
}

// Each lane is itself an SPSC; the wrapper preserves SPSC discipline
// because all pushes go through one Feeder and all pops through one Eater.
unsafe impl Send for PrioritizedInner {}
unsafe impl Sync for PrioritizedInner {}

impl PrioritizedInner {
    fn with_capacity_per_lane(capacity: usize) -> Self {
        Self {
            lanes: [
                Inner::with_capacity(capacity),
                Inner::with_capacity(capacity),
            ],
        }
    }

    #[inline]
    fn push(&self, flit: Flit) -> Result<(), Flit> {
        let lane = flit_lane(flit.mailbox_id);
        self.lanes[lane].push(flit)
    }

    /// Strict priority: high lane wins.
    #[inline]
    fn pop(&self) -> Option<Flit> {
        if let Some(f) = self.lanes[0].pop() {
            return Some(f);
        }
        self.lanes[1].pop()
    }

    /// Strict priority: high lane wins.
    #[inline]
    fn peek_ptr(&self) -> Option<NonNull<Flit>> {
        if let Some(p) = self.lanes[0].peek_ptr() {
            return Some(p);
        }
        self.lanes[1].peek_ptr()
    }

    #[inline]
    fn len(&self) -> usize {
        self.lanes[0].len() + self.lanes[1].len()
    }

    #[inline]
    fn is_empty(&self) -> bool {
        self.lanes[0].is_empty() && self.lanes[1].is_empty()
    }

    /// Conservative: returns true if EITHER lane is full. Use is_full_for
    /// for accurate per-flit admission checks.
    #[inline]
    fn is_full_any(&self) -> bool {
        self.lanes[0].is_full() || self.lanes[1].is_full()
    }

    #[inline]
    fn is_full_for(&self, mailbox_id: u16) -> bool {
        self.lanes[flit_lane(mailbox_id)].is_full()
    }

    /// AI [160]: deterministic admission across threads (start-of-cycle occupancy).
    #[inline]
    fn is_full_for_at(&self, mailbox_id: u16, cyc: u64) -> bool {
        let l = &self.lanes[flit_lane(mailbox_id)];
        l.len_at_start(cyc) >= l.capacity()
    }

    /// AI [160]: lane whose head the consumer should take in `cyc`: lane 0 if its head is ready, else lane 1 if its head is ready,
    ///   else none. A flit pushed during `cyc` by another thread is never ready in `cyc` (latency >= 1), so a race on its visibility
    ///   can no longer change which lane is served.
    #[inline]
    fn ready_lane(&self, cyc: u64) -> Option<usize> {
        for lane in 0..2 {
            if let Some(p) = self.lanes[lane].peek_ptr() {
                if unsafe { p.as_ref() }.cycle_to_read <= cyc { return Some(lane); }
            }
        }
        None
    }

    #[inline]
    fn capacity_per_lane(&self) -> usize {
        self.lanes[0].capacity()
    }
}

pub struct PrioritizedFlitQueue {
    inner: PrioritizedInner,
}

impl PrioritizedFlitQueue {
    pub fn new(capacity_per_lane: usize) -> Self {
        Self {
            inner: PrioritizedInner::with_capacity_per_lane(capacity_per_lane),
        }
    }

    #[inline]
    pub fn push(&mut self, flit: Flit) -> Result<(), Flit> {
        self.inner.push(flit)
    }

    #[inline]
    pub fn pop(&mut self) -> Option<Flit> {
        self.inner.pop()
    }

    #[inline]
    pub fn peek<'a>(&'a mut self) -> Option<PeekGuard<'a, Flit>> {
        let ptr = self.inner.peek_ptr()?;
        Some(PeekGuard {
            ptr,
            _borrow: PhantomData,
        })
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.inner.len()
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }

    /// Returns true if EITHER lane is full. For accurate admission checks
    /// when you have a specific flit, use is_full_for.
    #[inline]
    pub fn is_full(&self) -> bool {
        self.inner.is_full_any()
    }

    #[inline]
    pub fn is_full_for(&self, mailbox_id: u16) -> bool {
        self.inner.is_full_for(mailbox_id)
    }

    #[inline]
    pub fn capacity(&self) -> usize {
        self.inner.capacity_per_lane()
    }

    pub fn split(self) -> (PrioritizedFlitFeeder, PrioritizedFlitEater) {
        let arc = Arc::new(self.inner);
        (
            PrioritizedFlitFeeder { q: arc.clone() },
            PrioritizedFlitEater { q: arc },
        )
    }
}

pub struct PrioritizedFlitFeeder {
    q: Arc<PrioritizedInner>,
}

pub struct PrioritizedFlitEater {
    q: Arc<PrioritizedInner>,
}

impl PrioritizedFlitFeeder {
    #[inline]
    pub fn push(&mut self, flit: Flit) -> Result<(), Flit> {
        self.q.push(flit)
    }

    #[inline]
    pub fn is_full(&self) -> bool {
        self.q.is_full_any()
    }

    #[inline]
    pub fn is_full_for(&self, mailbox_id: u16) -> bool {
        self.q.is_full_for(mailbox_id)
    }

    #[inline]
    pub fn is_full_for_at(&self, mailbox_id: u16, cyc: u64) -> bool { // AI [160]
        self.q.is_full_for_at(mailbox_id, cyc)
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.q.len()
    }

    #[inline]
    pub fn capacity(&self) -> usize {
        self.q.capacity_per_lane()
    }
}

impl PrioritizedFlitEater {
    /// AI [160]: peek the flit this consumer may take in `cyc` (see ready_lane); None if no head is ready.
    #[inline]
    pub fn peek_ready<'a>(&'a mut self, cyc: u64) -> Option<PeekGuard<'a, Flit>> {
        let lane = self.q.ready_lane(cyc)?;
        let ptr = self.q.lanes[lane].peek_ptr()?;
        Some(PeekGuard { ptr, _borrow: PhantomData })
    }

    /// AI [160]: pop the same flit peek_ready returned, and record the pop for the producer's start-of-cycle view.
    #[inline]
    pub fn pop_ready(&mut self, cyc: u64) -> Option<Flit> {
        let lane = self.q.ready_lane(cyc)?;
        let f = self.q.lanes[lane].pop();
        if f.is_some() { self.q.lanes[lane].note_pop(cyc); }
        f
    }

    #[inline]
    pub fn pop(&mut self) -> Option<Flit> {
        self.q.pop()
    }

    #[inline]
    pub fn peek<'a>(&'a mut self) -> Option<PeekGuard<'a, Flit>> {
        let ptr = self.q.peek_ptr()?;
        Some(PeekGuard {
            ptr,
            _borrow: PhantomData,
        })
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.q.len()
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.q.is_empty()
    }

    #[inline]
    pub fn capacity(&self) -> usize {
        self.q.capacity_per_lane()
    }
}




pub struct BidirectionalNoc {
    eater: PrioritizedFlitEater,
    feeder: PrioritizedFlitFeeder,
    latency: usize,
}
impl BidirectionalNoc {
    pub fn new(
        eater: PrioritizedFlitEater,
        feeder: PrioritizedFlitFeeder,
        latency: usize,
    ) -> Self {
        Self {
            eater,
            feeder,
            latency,
        }
    }
}





struct PipelineStage {
    cycle_to_read: u64,
    calculated_val: u32,
    register_index: usize,
}
#[derive(Clone)]
pub struct Flit {
    cycle_to_read: u64,
    value_to_send: u32,
    mailbox_id: u16,
    destination_x: u16,
    destination_y: u16,
    origin_x: u16,
    origin_y: u16,
    // AI debug [153]: who sent it (router-generated rejects / NACKs: src_ctx 0xFE / 0xFD, src_pc 0)
    src_ctx: u8,
    src_isb: u8,
    src_pc: u16,
    sent_cycle: u64,
}



#[derive(PartialEq, Eq, Copy, Clone, Debug)]
pub enum Operation {
    // Integer ALU
    Add,
    Sub,
    And,
    Or,
    Xor,
    Sll,
    Srl,
    Sra,
    Mul,
    Div,
    Mod,

    FPAdd,
    FPMul,
    FPSub,
    FPMac,
    FPEQ,
    FPLT,
    FPSetAccumulator,
    FPStoreAccumulator,
    FPMinMax,

    // Memory
    StoreByte,
    StoreHalf,
    StoreWord,
    LoadByteSigned,
    LoadByteUnsigned,
    LoadHalfSigned,
    LoadHalfUnsigned,
    LoadWord,
    AtomicAdd,

    // Control
    BranchEq,
    BranchNe,
    BranchLTE,
    BranchGT,
    BranchLTEU,
    BranchGTU,
    Jump,

    BlockVal,
    NonBlockVal,
    Yield,
    GetThreadOwnership,
    SetCtx,
    RelinquishOwnership,
    EnableInterrupts,
    DisableInterrupts,
    SetMemoryBits,
    SwitchCtx,

    ReadSignedByteDram,
    ReadUnsignedByteDram,
    ReadSignedHalfDram,
    ReadUnsignedHalfDram,
    ReadWordDram,
    StoreWordDram,
    StoreHalfDram,
    StoreByteDram,
    AtomicAddDram,
    SendFlit,
    GetLowClock,
}
#[derive(Copy, Clone)]
enum FpType {
    Fp32,
    Fp16,
    Fp8,
}
#[derive(Copy, Clone)]
struct DecodedInstruction {
    raw_instruction: u32,
    operation: Operation,
    fp_type: FpType,
    sr1: usize,
    sr2: usize,
    dr: usize,
    branch_hint: bool,
    imm_0: u32,
    imm_1: u32,
    is_imm: bool,
    pc: u16,
}
impl DecodedInstruction {
    pub fn dump(&self, context_in_progress: usize, reg_file: &Vec<u32>) {
        println!("DecodedInstruction {{");
        println!("  raw_instruction: 0x{:08X}", self.raw_instruction);
        println!("  operation: {:?}", self.operation);
        println!("  fp_type: unimplemented for now");
        println!("  sr1: {}", self.sr1);
        println!(
            "  sr1_val: 0x{:08X} ({})",
            reg_file[context_in_progress * REGS_PER_CONTEXT + self.sr1],
            reg_file[context_in_progress * REGS_PER_CONTEXT + self.sr1]
        );
        println!("  sr2: {}", self.sr2);
        println!(
            "  sr2_val: 0x{:08X} ({})",
            reg_file[context_in_progress * REGS_PER_CONTEXT + self.sr2],
            reg_file[context_in_progress * REGS_PER_CONTEXT + self.sr2]
        );
        println!("  dr: {}", self.dr);
        println!("  branch_hint: {}", self.branch_hint);
        println!("  imm_0: 0x{:08X} ({})", self.imm_0, self.imm_0);
        println!("  imm_1: 0x{:08X} ({})", self.imm_1, self.imm_1);
        println!("  is_imm: {}", self.is_imm);
        println!("  pc: 0x{:04X} ({})", self.pc, self.pc);
        println!("  context: {}", context_in_progress);
        println!("}}");
    }
}
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct Fp8E4M3 {
    bits: u8,
}
impl Fp8E4M3 {
    pub fn from_bits(bits: u8) -> Self {
        Self { bits }
    }

    pub fn to_bits(self) -> u8 {
        self.bits
    }

    pub fn to_f32(self) -> f32 {
        let sign = if self.bits & 0x80 != 0 { -1.0 } else { 1.0 };
        let exp = (self.bits >> 3) & 0x0F;
        let mant = self.bits & 0x07;

        if exp == 0 {
            // subnormal
            sign * (mant as f32) * 2f32.powi(-6)
        } else if exp == 0x0F {
            // inf / NaN
            if mant == 0 {
                sign * f32::INFINITY
            } else {
                f32::NAN
            }
        } else {
            let e = (exp as i32) - 7;
            let m = 1.0 + (mant as f32) / 8.0;
            sign * m * 2f32.powi(e)
        }
    }
}
impl Fp8E4M3 {
    pub fn from_f32(x: f32) -> Self {
        if x.is_nan() {
            return Self { bits: 0x7F };
        }
        if x.is_infinite() {
            return Self {
                bits: if x.is_sign_negative() { 0xF8 } else { 0x78 },
            };
        }
        if x == 0.0 {
            return Self { bits: 0 };
        }

        let sign = if x.is_sign_negative() { 0x80 } else { 0 };
        let abs = x.abs();

        let exp = abs.log2().floor() as i32;
        let mant = abs / 2f32.powi(exp) - 1.0;

        let biased_exp = exp + 7;

        if biased_exp <= 0 {
            // subnormal
            let m = (abs * 2f32.powi(6)).round() as u8;
            return Self {
                bits: sign | (m & 0x07),
            };
        }

        if biased_exp >= 0x0F {
            // overflow → inf
            return Self { bits: sign | 0x78 };
        }

        let mant_bits = (mant * 8.0).round() as u8 & 0x07;

        Self {
            bits: sign | ((biased_exp as u8) << 3) | mant_bits,
        }
    }
}
#[inline]
pub fn fp8_add(a: u8, b: u8) -> u8 {
    let fa = Fp8E4M3::from_bits(a).to_f32();
    let fb = Fp8E4M3::from_bits(b).to_f32();
    Fp8E4M3::from_f32(fa + fb).to_bits()
}
#[inline]
pub fn fp8_sub(a: u8, b: u8) -> u8 {
    let fa = Fp8E4M3::from_bits(a).to_f32();
    let fb = Fp8E4M3::from_bits(b).to_f32();
    Fp8E4M3::from_f32(fa - fb).to_bits()
}
#[inline]
pub fn fp8_mul(a: u8, b: u8) -> u8 {
    let fa = Fp8E4M3::from_bits(a).to_f32();
    let fb = Fp8E4M3::from_bits(b).to_f32();
    Fp8E4M3::from_f32(fa * fb).to_bits()
}

fn decode_instruction(instruction_word: u32, pc: u16) -> DecodedInstruction {
    // Dummy implementation for illustration purposes
    let op_type = match instruction_word & 0x7F {
        0 => Operation::Add,
        1 => Operation::Sub,
        2 => Operation::And,
        3 => Operation::Or,
        4 => Operation::Xor,
        5 => Operation::Sll,
        6 => Operation::Srl,
        7 => Operation::Sra,
        8 => Operation::Mul,
        9 => Operation::Div,
        10 => Operation::FPAdd,
        11 => Operation::FPMul,
        12 => Operation::FPSub,
        13 => Operation::FPMac,
        14 => Operation::FPEQ,
        15 => Operation::FPLT,
        16 => Operation::FPSetAccumulator,
        17 => Operation::FPStoreAccumulator,
        18 => Operation::FPMinMax,
        19 => Operation::BranchEq,
        20 => Operation::BranchNe,
        21 => Operation::BranchLTE,
        22 => Operation::BranchGT,
        23 => Operation::Jump,
        24 => Operation::StoreByte,
        25 => Operation::StoreHalf,
        26 => Operation::StoreWord,
        27 => Operation::LoadByteSigned,
        28 => Operation::LoadByteUnsigned,
        29 => Operation::LoadHalfSigned,
        30 => Operation::LoadHalfUnsigned,
        31 => Operation::LoadWord,
        32 => Operation::BlockVal,
        33 => Operation::NonBlockVal,
        34 => Operation::Yield,
        35 => Operation::GetThreadOwnership,
        36 => Operation::SetCtx,
        37 => Operation::RelinquishOwnership,
        38 => Operation::EnableInterrupts,
        39 => Operation::SetMemoryBits,
        40 => Operation::ReadSignedByteDram,
        41 => Operation::ReadUnsignedByteDram,
        42 => Operation::ReadSignedHalfDram,
        43 => Operation::ReadUnsignedHalfDram,
        44 => Operation::ReadWordDram,
        45 => Operation::StoreWordDram,
        46 => Operation::StoreHalfDram,
        47 => Operation::StoreByteDram,
        48 => Operation::AtomicAddDram,
        49 => Operation::SendFlit,
        50 => Operation::Mod,
        51 => Operation::AtomicAdd,
        52 => Operation::GetLowClock,
        53 => Operation::BranchLTEU,
        54 => Operation::BranchGTU,
        55 => Operation::DisableInterrupts,
        56 => Operation::SwitchCtx,
        _ => panic!(
            "UNKNOWN OPERATION: opcode = {} (0x{:02X}), full word = 0x{:08X}",
            instruction_word & 0x7F,
            instruction_word & 0x7F,
            instruction_word
        ),
    };
    let fp_type = match (instruction_word >> 20) & 0x3 {
        0 => FpType::Fp32,
        1 => FpType::Fp16,
        2 => FpType::Fp8,
        _ => FpType::Fp32,
    };

    let dr_index = (instruction_word >> 7) as usize & 0xF;
    let sr1_index = (instruction_word >> 11) as usize & 0xF;
    // Conditional branches compare dr against sr1 (sr2 slot holds the target). Includes unsigned 53/54.
    let opcode = instruction_word & 0x7F;
    let sr2_index = if (opcode >= 19 && opcode < 23) || opcode == 53 || opcode == 54 {
        dr_index
    } else {
        ((instruction_word >> 16) & 0xF) as usize
    };
    let imm_0 = (instruction_word >> 16) & 0xFFFF;
    let imm_1 = (instruction_word >> 15) & 0x1;
    DecodedInstruction {
        raw_instruction: instruction_word,
        operation: op_type,
        fp_type: fp_type,
        sr1: sr1_index,
        sr2: sr2_index,
        dr: dr_index,
        branch_hint: imm_1 == 1,
        imm_0: imm_0 as u16 as i16 as u32,
        imm_1: imm_1,
        is_imm: imm_1 == 1,
        pc,
    }
}

fn num_source_registers(instr: &DecodedInstruction) -> u8 {
    use Operation::*;

    match instr.operation {
        Yield | GetThreadOwnership | RelinquishOwnership | NonBlockVal | SetCtx => 0,
        Jump | FPSetAccumulator | SetMemoryBits => 1,
        StoreByte | StoreHalf | StoreWord | AtomicAdd | Add | Sub | And | Or | Xor | Sll | Srl
        | Sra => {
            if instr.is_imm {
                1
            } else {
                2
            }
        }
        LoadByteSigned | LoadByteUnsigned | LoadHalfSigned | LoadHalfUnsigned | LoadWord
        | EnableInterrupts | DisableInterrupts => {
            if instr.is_imm {
                0
            } else {
                1
            }
        }

        Mul | Div | Mod => 2,
        FPAdd | FPMul | FPSub | FPEQ | FPLT | FPMinMax => 2,
        FPMac => 2,
        FPStoreAccumulator | GetLowClock => 0,
        BranchEq | BranchNe | BranchLTE | BranchGT | BranchGTU | BranchLTEU => 2,
        BlockVal | SwitchCtx => 0,

        ReadSignedByteDram | ReadUnsignedByteDram | ReadSignedHalfDram | ReadUnsignedHalfDram
        | ReadWordDram => 1,
        StoreWordDram | StoreHalfDram | StoreByteDram | AtomicAddDram | SendFlit => 2,
    }
}

#[derive(Clone)]
pub struct LongDramOp {
    pub(crate) register_index: usize,
    pub(crate) calculated_val: u32,
    pub(crate) core_id: u32,
    pub(crate) ready_cycle: u64, // AI [128]: cycle the core may consume it (memory model completion + return link)
    pub(crate) sent_cycle: u64,  // AI [160]: cycle the servicing stack sent it (cross-stack replies are applied only in a later cycle)
    pub(crate) src_stack: usize, // AI [160]: servicing stack (deterministic tie order)
}

#[derive(Clone)]
pub struct LongDramRequest {
    pub(crate) register_index: usize,
    pub(crate) address: usize,
    pub(crate) op: Operation,
    pub(crate) value_to_write: u32,
    pub(crate) core_id: u32,
    pub(crate) origin_stack: usize,
    pub(crate) issue_cycle: u64, // AI [128]: for the far-link arrival time at the target stack's cache
}







/// Outcome of a routing attempt: did the flit move, and where did the contention happen?
enum RouteOutcome {
    Sent,              // flit was forwarded; caller should consider it consumed
    Blocked(Direction), // outbound feeder full; caller may want to bump congestion
    NoSuchNoc,         // the chosen outbound NOC doesn't exist (edge of mesh)
}

#[derive(Clone, Copy)]
enum Direction {
    Right,
    Left,
    Up,
    Down,
}

pub struct Core {
    core_id: u32,
    top_bits_dram_stack: usize,

    x_dim: u16,
    y_dim: u16,
    fetch_pc: Option<u16>,
    fp_pipe: SpscQueue<PipelineStage>,
    dram_long_response: Option<Eater<LongDramOp>>, //input from other dram stack
    dram_long_request: Option<Vec<Sender<LongDramRequest>>>, //output to other dram stacks
    fp_accumulation: Vec<u32>,
    div_seq: SpscQueue<PipelineStage>,
    context_cnt: usize,
    dram_pending: Vec<LongDramOp>, // AI [128]: DRAM replies received but not yet due (replaces the fixed-latency dram_long_queue / dram_short_queue)
    context_in_progress: usize,
    register_file: Vec<u32>,
    register_ready: Vec<bool>,
    up_noc: Option<BidirectionalNoc>,    //upwards core
    down_noc: Option<BidirectionalNoc>,  //downwards core
    left_noc: Option<BidirectionalNoc>,  //leftwards core
    right_noc: Option<BidirectionalNoc>, //rightwards core
    up_noc_util: Vec<usize>,
    up_noc_congestion: Vec<usize>,
    down_noc_util: Vec<usize>,
    down_noc_congestion: Vec<usize>,
    left_noc_util: Vec<usize>,
    left_noc_congestion: Vec<usize>,
    right_noc_util: Vec<usize>,
    right_noc_congestion: Vec<usize>,
    mailbox_congestion: Vec<usize>,
    core_busy: Vec<usize>,
    ready_hist: [u64; 16], // AI [144] debug: samples (every READY_SAMPLE cycles) by how many worker contexts (0-14) could issue
    dram_bytes_read_close: usize,
    dram_bytes_read_far: usize,
    dram_bytes_wrote_close: usize,
    dram_bytes_wrote_far: usize,
    flits_sent: usize,
    flits_received: usize,
    flit_sent_manhattan_distance_traversed: usize,
    flit_received_manhattan_distance_traversed: usize,
    ctx_ownership: i8,
    runnable: Vec<bool>,
    sram: [u8; SRAM_SIZE],
    memory_bits: [u32; REGS_PER_CONTEXT],

    pc: [u16; REGS_PER_CONTEXT],

    output_noc_send: PrioritizedFlitQueue,
    reject_send: PrioritizedFlitQueue, // router-generated ray rejects, separate from thread sends
    auto_rejects: usize,
    pc_hist: Vec<(u16, u32)>, // AI debug [44]: per-context ring of the last 256 executed (pc, cycle)
    pc_hist_idx: [usize; 16],
    cyc_ring: Vec<u32>,          // AI debug [159]: per-cycle (pc, ctx, issued) ring, cyc_ring_len() entries
    cyc_rec: u32,                // AI debug [159]: this cycle's entry (set when an instruction issues)
    mailbox_full_reported: [bool; NUM_NOC_PIPES], // debug: print first full-mailbox stall per mailbox
    mbox_last: [(u16, u16, u32, u64); 16], // AI debug [123]: last delivery per data mailbox 0-15: origin x, y, value, cycle
    data_expect: [i32; 16],      // AI debug [153]: data words still owed to each data mailbox 0-15 by ACKs this core sent
    req_pending: [(u16, u64, u32); 16], // AI debug [156]: per context, the ray request (32/33) awaiting a reply: dest core (0xFFFF none), cycle, word
    ack_to: [(u16, u64); 16],    // AI debug [156]: per context, the requester core of this core's last ray ACK and its cycle
    ack_recv: [(u32, u8, u64); 16], // AI debug [157]: per context, the last ACK word it received, data words it may still send on it, cycle
    trace_ctx: usize,            // AI debug [158]: context being traced after an HS event
    trace_left: u16,             // AI debug [158]: instructions of trace_ctx still to print
    clone_go_cycle: u64,         // AI debug [153]: cycle of this core's last NoC-clone GO (pipe 0 stream legit for a while after)
    mbox_ring: Vec<MboxRec>,     // AI debug [153]: last 8 deliveries per data mailbox 0-15 (16 x 8)
    mbox_ring_idx: [u8; 16],
    noc_recv_fifo: Vec<SpscQueue<u32>>,
    interrupt_enable: Vec<Vec<bool>>,

    fetched_value: Option<u32>,

    decoded_instruction: Option<DecodedInstruction>,
    cycle: u64,
}
impl Core {
    pub fn new(id: u32, x_dim: u16, y_dim: u16, dram_top_bits: usize) -> Self {
        let init_time_mem: [u32; 12] = [
            0x00008002, //PC = 0x00000000,     line: and r0, r0, 0 #00
            0x000007A7, //PC = 0x00000004,     line: setmembits r0 #04
            0x000000AC, //PC = 0x00000008,     line: lw_d  r1, r0, 0      #08
            0x00048100, //PC = 0x0000000C,     line: add r2, r0, 4     #0C
            0x002C8180, //PC = 0x00000010,     line: add r3, r0, done #10
            0x0000122C, //PC = 0x00000014,     line:     lw_d  r4, r2, 0 #14
            0x00001A1A, //PC = 0x00000018,     line:     sw  r4, r3, 0 #18
            0x00049100, //PC = 0x0000001C,     line:     add r2, r2, 4 #1C
            0x00049980, //PC = 0x00000020,     line:     add r3, r3, 4 #20
            0x00018000, //PC = 0x00000024,     line:     add r0, r0, 1 #24
            0x00148096, //PC = 0x00000028,     line:     bgt r1, r0, loop, true #28
            0xDEADBEEF, //PC = 0x0000002C,     line:     .data 0xDEADBEEF # i should try to support blt and bgte as well
        ];
        let mut sram_array = [0u8; SRAM_SIZE];
        for i in 0..init_time_mem.len() {
            let word = init_time_mem[i];
            let base_address = (i * 4) as u16;
            sram_array[base_address as usize] = (word & 0xFF) as u8;
            sram_array[base_address as usize + 1] = ((word & 0xFF00) >> 8) as u8;
            sram_array[base_address as usize + 2] = ((word & 0xFF0000) >> 16) as u8;
            sram_array[base_address as usize + 3] = ((word & 0xFF000000) >> 24) as u8;
        }
        let mut regfile = vec![0u32; CTX_CNT * REGS_PER_CONTEXT];
        for i in 0..CTX_CNT {
            regfile[i * REGS_PER_CONTEXT + REGS_PER_CONTEXT - 1] =
                (id * REGS_PER_CONTEXT as u32 + i as u32) as u32;
        }
        Self {
            core_id: id,
            x_dim,
            y_dim,
            fetch_pc: None,
            fp_pipe: SpscQueue::<PipelineStage>::new(FP_PIPE_STAGES),
            dram_pending: Vec::new(), // AI [128]
            context_cnt: 1,
            ctx_ownership: 0,
            context_in_progress: 0,
            fp_accumulation: vec![(0.0f32).to_bits(); CTX_CNT],
            register_file: regfile,
            register_ready: vec![true; CTX_CNT * REGS_PER_CONTEXT],
            memory_bits: [0u32; CTX_CNT],
            up_noc: None,
            down_noc: None,
            left_noc: None,
            right_noc: None,
            runnable: vec![false; CTX_CNT],
            sram: sram_array,
            pc: [0u16; CTX_CNT],

            noc_recv_fifo: {
                let mut noc_input_pipes = vec![];
                for _ in 0..HIGH_CAPACITY_NOC_PIPE_CNT {
                    noc_input_pipes.push(SpscQueue::<u32>::new(HIGH_CAPACITY_PIPE_SLOTS));
                }
                for pipe in HIGH_CAPACITY_NOC_PIPE_CNT..NUM_NOC_PIPES {
                    // AI [112]/[138]: pipes 32-63 (ray requests, NoC-clone handshake and spares) hold 4 flits (was 1), so a word waiting to be read
                    // does not immediately block lane 1 at the router. 16-31 (one response per context) stay at 1 slot.
                    // AI [138]: the ray-request mailboxes 32/33 hold 4 as well (the router still bounces a reject when full).
                    noc_input_pipes.push(SpscQueue::<u32>::new(if pipe >= 32 { 4 } else { 1 })); // AI [138] (Alex): 32/33 too (was 1)
                }

                noc_input_pipes
            },
            interrupt_enable: vec![vec![false; NUM_NOC_PIPES]; CTX_CNT],
            div_seq: SpscQueue::<PipelineStage>::new(1),
            fetched_value: None,
            decoded_instruction: None,
            cycle: 0,
            output_noc_send: PrioritizedFlitQueue::new(OUTPUT_NOC_FIFO_CAPACITY),
            reject_send: PrioritizedFlitQueue::new(REJECT_SEND_FIFO_CAPACITY),
            auto_rejects: 0,
            pc_hist: vec![(0, 0); 16 * 256],
            pc_hist_idx: [0; 16],
            cyc_ring: vec![0u32; cyc_ring_len()],
            cyc_rec: 0,
            mailbox_full_reported: [false; NUM_NOC_PIPES],
            mbox_last: [(0, 0, 0, 0); 16],
            data_expect: [0; 16],
            req_pending: [(0xFFFF, 0, 0); 16],
            ack_to: [(0xFFFF, 0); 16],
            ack_recv: [(0, 0, 0); 16],
            trace_ctx: 0,
            trace_left: 0,
            clone_go_cycle: 0,
            mbox_ring: vec![MboxRec::default(); 16 * 8],
            mbox_ring_idx: [0; 16],
            top_bits_dram_stack: dram_top_bits,
            dram_long_request: None,
            dram_long_response: None,
            dram_bytes_read_close: 0,
            dram_bytes_read_far: 0,
            dram_bytes_wrote_close: 0,
            dram_bytes_wrote_far: 0,
            flits_sent: 0,
            flit_sent_manhattan_distance_traversed: 0,
            flits_received: 0,
            flit_received_manhattan_distance_traversed: 0,
            up_noc_util: vec![],
            up_noc_congestion: vec![],
            down_noc_util: vec![],
            down_noc_congestion: vec![],
            left_noc_util: vec![],
            left_noc_congestion: vec![],
            right_noc_util: vec![],
            right_noc_congestion: vec![],
            mailbox_congestion: vec![],
            core_busy: vec![],
            ready_hist: [0; 16], // AI [144]
        }
    }
    fn dump_instruction(&self, inst: &DecodedInstruction) {
        inst.dump(self.context_in_progress, &self.register_file);
    }
    pub fn get_log(&self) -> CoreLog {
        CoreLog {
            up_noc_util: self.up_noc_util.clone(),
            up_noc_congestion: self.up_noc_congestion.clone(),
            down_noc_util: self.down_noc_util.clone(),
            down_noc_congestion: self.down_noc_congestion.clone(),
            left_noc_util: self.left_noc_util.clone(),
            left_noc_congestion: self.left_noc_congestion.clone(),
            right_noc_util: self.right_noc_util.clone(),
            right_noc_congestion: self.right_noc_congestion.clone(),
            mailbox_congestion: self.mailbox_congestion.clone(),
            core_busy: self.core_busy.clone(),

            dram_bytes_read_close: self.dram_bytes_read_close,
            dram_bytes_read_far: self.dram_bytes_read_far,
            dram_bytes_wrote_close: self.dram_bytes_wrote_close,
            dram_bytes_wrote_far: self.dram_bytes_wrote_far,

            flits_sent: self.flits_sent,
            flits_received: self.flits_received,
            flit_sent_manhattan_distance_traversed: self.flit_sent_manhattan_distance_traversed,
            flit_received_manhattan_distance_traversed: self
                .flit_received_manhattan_distance_traversed,
            auto_rejects: self.auto_rejects,
        }
    }

#[inline]
    fn route_direction(&self, dest_x: u16, dest_y: u16) -> Option<Direction> {
        if dest_x == self.x_dim && dest_y == self.y_dim {
            return None;
        }
        let go_x = if PRIORITIZE_X {
            dest_x != self.x_dim
        } else {
            dest_y == self.y_dim
        };
        Some(if go_x {
            if dest_x > self.x_dim { Direction::Right } else { Direction::Left }
        } else {
            if dest_y > self.y_dim { Direction::Down } else { Direction::Up }
        })
    }

    #[inline]
    fn has_noc(&self, dir: Direction) -> bool {
        match dir {
            Direction::Right => self.right_noc.is_some(),
            Direction::Left  => self.left_noc.is_some(),
            Direction::Up    => self.up_noc.is_some(),
            Direction::Down  => self.down_noc.is_some(),
        }
    }

    /// True if the outbound lane for this mailbox in `dir` is full.
    /// Only call when has_noc(dir) is true.
    #[inline]
    fn lane_full(&self, dir: Direction, mailbox: u16) -> bool {
        match dir {
            Direction::Right => self.right_noc.as_ref().unwrap().feeder.is_full_for_at(mailbox, self.cycle), // AI [160]
            Direction::Left  => self.left_noc.as_ref().unwrap().feeder.is_full_for_at(mailbox, self.cycle),
            Direction::Up    => self.up_noc.as_ref().unwrap().feeder.is_full_for_at(mailbox, self.cycle),
            Direction::Down  => self.down_noc.as_ref().unwrap().feeder.is_full_for_at(mailbox, self.cycle),
        }
    }

    #[inline]
    fn bump_util(&mut self, dir: Direction) {
        let epoch = self.cycle as usize / NOC_UTIL_EPOCH_LEN;
        let v = match dir {
            Direction::Right => &mut self.right_noc_util,
            Direction::Left  => &mut self.left_noc_util,
            Direction::Up    => &mut self.up_noc_util,
            Direction::Down  => &mut self.down_noc_util,
        };
        while v.len() <= epoch { v.push(0); }
        v[epoch] += 1;
    }

    #[inline]
    fn bump_congestion(&mut self, dir: Direction) {
        let epoch = self.cycle as usize / NOC_UTIL_EPOCH_LEN;
        let v = match dir {
            Direction::Right => &mut self.right_noc_congestion,
            Direction::Left  => &mut self.left_noc_congestion,
            Direction::Up    => &mut self.up_noc_congestion,
            Direction::Down  => &mut self.down_noc_congestion,
        };
        while v.len() <= epoch { v.push(0); }
        v[epoch] += 1;
    }

    #[inline]
    fn bump_mailbox_congestion(&mut self) {
        let epoch = self.cycle as usize / NOC_UTIL_EPOCH_LEN;
        while self.mailbox_congestion.len() <= epoch {
            self.mailbox_congestion.push(0);
        }
        self.mailbox_congestion[epoch] += 1;
    }

    /// Push `flit` into the outbound NOC in direction `dir`. Caller must have
    /// verified has_noc(dir) and !lane_full(dir, flit.mailbox_id).
    #[inline]
    fn forward_to(&mut self, dir: Direction, mut flit: Flit) {
        let noc = match dir {
            Direction::Right => self.right_noc.as_mut().unwrap(),
            Direction::Left  => self.left_noc.as_mut().unwrap(),
            Direction::Up    => self.up_noc.as_mut().unwrap(),
            Direction::Down  => self.down_noc.as_mut().unwrap(),
        };
        flit.cycle_to_read = self.cycle + noc.latency as u64;
        let _ = noc.feeder.push(flit);
    }

    #[inline]
    fn pop_inbound(&mut self, from: Direction) -> Flit {
        match from {
            Direction::Right => { let c = self.cycle; self.right_noc.as_mut().unwrap().eater.pop_ready(c).unwrap() } // AI [160]
            Direction::Left  => { let c = self.cycle; self.left_noc.as_mut().unwrap().eater.pop_ready(c).unwrap() }
            Direction::Up    => { let c = self.cycle; self.up_noc.as_mut().unwrap().eater.pop_ready(c).unwrap() }
            Direction::Down  => { let c = self.cycle; self.down_noc.as_mut().unwrap().eater.pop_ready(c).unwrap() }
        }
    }

    // ========================================================================
    // Per-cycle NOC tick
    // ========================================================================

    fn cycle_noc(&mut self) {
        self.cycle_output_send();
        self.cycle_inbound(Direction::Left);
        self.cycle_inbound(Direction::Right);
        self.cycle_inbound(Direction::Up);
        self.cycle_inbound(Direction::Down);
    }

    /// Drain one flit (if any) from output_noc_send onto the appropriate outbound NOC.
    fn cycle_output_send(&mut self) {
        if self.cycle_reject_send() {
            return;
        }
        // Peek to learn destination + mailbox without committing to pop.
        let (dest_x, dest_y, mailbox, val, orig_x, orig_y) = match self.output_noc_send.peek() {
            Some(f) => (f.destination_x, f.destination_y, f.mailbox_id, f.value_to_send, f.origin_x, f.origin_y),
            None => return,
        };

        let dir = match self.route_direction(dest_x, dest_y) {
            Some(d) => d,
            // A flit addressed to this core sitting in our own send queue is a bug.
            None => panic!(
                "core ({},{}) has flit in output_noc_send addressed to self (mailbox {})",
                self.x_dim, self.y_dim, mailbox
            ),
        };

        // No outbound port that direction → routing bug. Stay silent (no util/congestion).
        if !self.has_noc(dir) {
            return;
        }

        // Lane full → tried but couldn't.
        if self.lane_full(dir, mailbox) {
            self.bump_congestion(dir);
            return;
        }

        // Commit: util goes up, flit moves.
        self.bump_util(dir);
        let flit = self.output_noc_send.pop().unwrap();
        self.forward_to(dir, flit);
    }

    /// Drain one router-generated reject onto the NoC. Returns true if a flit was injected.
    fn cycle_reject_send(&mut self) -> bool {
        let (dest_x, dest_y, mailbox) = match self.reject_send.peek() {
            Some(f) => (f.destination_x, f.destination_y, f.mailbox_id),
            None => return false,
        };
        let dir = match self.route_direction(dest_x, dest_y) {
            Some(d) => d,
            None => {
                // Reject addressed to ourselves: deliver straight into the response mailbox.
                if self.noc_recv_fifo[mailbox as usize].is_full() {
                    return false;
                }
                let flit = self.reject_send.pop().unwrap();
                let _ = self.noc_recv_fifo[mailbox as usize].push(flit.value_to_send);
                self.flits_received += 1;
                return true;
            }
        };
        if !self.has_noc(dir) {
            return false;
        }
        if self.lane_full(dir, mailbox) {
            self.bump_congestion(dir);
            return false;
        }
        self.bump_util(dir);
        let flit = self.reject_send.pop().unwrap();
        self.flits_sent += 1;
        self.forward_to(dir, flit);
        true
    }

    /// Drain one flit (if any has arrived) from the eater on direction `from`,
    /// either delivering it locally or forwarding it onward.
    fn cycle_inbound(&mut self, from: Direction) {
        // Peek: capture fields and check arrival cycle, then release the borrow.
        let (dest_x, dest_y, mailbox, ready, val, orig_x, orig_y) = {
            let noc_opt = match from {
                Direction::Right => self.right_noc.as_mut(),
                Direction::Left  => self.left_noc.as_mut(),
                Direction::Up    => self.up_noc.as_mut(),
                Direction::Down  => self.down_noc.as_mut(),
            };
            let Some(noc) = noc_opt else { return; };
            if noc.eater.is_empty() { return; }
            let Some(f) = noc.eater.peek_ready(self.cycle) else { return; }; // AI [160]: only a head that is ready this cycle
            (f.destination_x, f.destination_y, f.mailbox_id, f.cycle_to_read <= self.cycle, f.value_to_send, f.origin_x, f.origin_y)
        };
        if orig_x == 27 && orig_y == 34 && mailbox == 0 {
            println!("flit processing at {}, {} going to {}, {}, orig {}, {}", self.core_id / 128, self.core_id % 128, dest_x, dest_y, orig_x, orig_y);
        }
        if !ready {
            if orig_x == 27 && orig_y == 34 && mailbox == 0 {
                println!("flit BLOCKED at {}, {} going to {}, {}", self.core_id / 128, self.core_id % 128, dest_x, dest_y);
            }
            return;
        }

        // Local delivery.
        if dest_x == self.x_dim && dest_y == self.y_dim {
            if self.noc_recv_fifo[mailbox as usize].is_full() {
                // Ray requests never stall the mesh: bounce a well-formed reject back to the requester.
                if mailbox == RAY_REQUEST_MAILBOX_EVEN || mailbox == RAY_REQUEST_MAILBOX_ODD {
                    // Reject lives on the high-priority (response) lane; if that queue is full, stall
                    // this request (request waiting on response is the allowed dependency direction).
                    if self.reject_send.is_full_for(16) {
                        self.bump_mailbox_congestion();
                        return;
                    }
                    let flit = self.pop_inbound(from);
                    // request word = node_id << 17 | r15, r15 = core_id * 16 + ctx
                    let req = flit.value_to_send;
                    let requester = (req >> 4) & 0x1FFF;
                    let reject = Flit {
                        destination_x: (requester % (CORES_IN_X * CORES_IN_X_STACK) as u32) as u16,
                        destination_y: (requester / (CORES_IN_X * CORES_IN_X_STACK) as u32) as u16,
                        mailbox_id: 16 + (req & 0xF) as u16,
                        value_to_send: REJECT_RAY_CODE << 24,
                        cycle_to_read: self.cycle + 1,
                        origin_x: self.x_dim,
                        origin_y: self.y_dim,
                        src_ctx: 0xFE, src_isb: 0, src_pc: 0, sent_cycle: self.cycle, // AI debug [153]
                    };
                    let _ = self.reject_send.push(reject);
                    self.auto_rejects += 1;
                    self.flits_received += 1;
                    return;
                }
                // AI [113]: a full NoC-clone request pipe 34 never stalls the mesh either: NACK the requester on its
                // response mailbox 16 (clones ask from context 0 during boot), like the 32/33 reject. Only REQUESTs use 34.
                if mailbox == 34 {
                    if self.reject_send.is_full_for(16) {
                        self.bump_mailbox_congestion();
                        return;
                    }
                    let _ = self.pop_inbound(from);
                    let nack = Flit {
                        destination_x: orig_x,
                        destination_y: orig_y,
                        mailbox_id: 16,
                        value_to_send: NOC_CLONE_NACK,
                        cycle_to_read: self.cycle + 1,
                        origin_x: self.x_dim,
                        origin_y: self.y_dim,
                        src_ctx: 0xFD, src_isb: 0, src_pc: 0, sent_cycle: self.cycle, // AI debug [153]
                    };
                    let _ = self.reject_send.push(nack);
                    self.auto_rejects += 1;
                    self.flits_received += 1;
                    return;
                }
                if !self.mailbox_full_reported[mailbox as usize] {
                    self.mailbox_full_reported[mailbox as usize] = true;
                    println!("MAILBOX FULL: core {} mailbox {} cycle {} value 0x{:08X} from ({}, {})", self.core_id, mailbox, self.cycle, val, orig_x, orig_y);
                }
                self.bump_mailbox_congestion();
                return;
            }
            let flit = self.pop_inbound(from);
            if (flit.mailbox_id as usize) < 16 { self.mbox_last[flit.mailbox_id as usize] = (flit.origin_x, flit.origin_y, flit.value_to_send, self.cycle as u64); } // AI debug [123]
            if (16..32).contains(&(flit.mailbox_id as usize)) && flit.value_to_send >> 31 == 0 { // AI debug [156]: reply side of the handshake
                let c = flit.mailbox_id as usize - 16;
                let src_core = flit.origin_y * (CORES_IN_X * CORES_IN_X_STACK) + flit.origin_x;
                let p = self.req_pending[c];
                if (p.0 == 0xFFFF || p.0 != src_core) && HS_N.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 3000 {
                    println!("HS {} core {} ctx {} value 0x{:08X} hdr {} from core {} ctx {} {} pc 0x{:04X} sent {} arrived {} | pending dest {} since {} word 0x{:08X} | my ctx pc 0x{:04X} fill {}",
                        if p.0 == 0xFFFF { "REPLY_NO_REQ" } else { "REPLY_WRONG_SRC" }, self.core_id, c, flit.value_to_send, flit.value_to_send >> 24, src_core, flit.src_ctx,
                        if flit.src_isb != 0 { "branch" } else { "leaf" }, flit.src_pc, flit.sent_cycle, self.cycle, p.0, p.1, p.2, self.pc[c], self.noc_recv_fifo[flit.mailbox_id as usize].len());
                }
                if flit.value_to_send >> 24 == 5 { // AI debug [157]: this context may now send 16 data words to the core / pipe named in the ACK
                    if self.ack_recv[c].1 != 0 && HS_N.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 3000 {
                        println!("HS ACK_OVERLAP core {} ctx {} new ack 0x{:08X} from core {} at {} | old ack 0x{:08X} at {} words left {}", self.core_id, c, flit.value_to_send, src_core, self.cycle, self.ack_recv[c].0, self.ack_recv[c].2, self.ack_recv[c].1);
                                    self.hs_dump(c, "ACK_OVERLAP"); // AI debug [158]
                    }
                    self.ack_recv[c] = (flit.value_to_send, 16, self.cycle);
                }
                self.req_pending[c] = (0xFFFF, 0, 0);
            }
            if (flit.mailbox_id as usize) < 16 { // AI debug [153]: account every data-mailbox delivery against the ACKs this core sent
                let m = flit.mailbox_id as usize;
                let src_core = flit.origin_y * (CORES_IN_X * CORES_IN_X_STACK) + flit.origin_x;
                if self.data_expect[m] > 0 && self.ack_to[m].0 != src_core && HS_N.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 3000 { // AI debug [156]
                    println!("HS DATA_WRONG_SRC core {} pipe {} value 0x{:08X} from core {} ctx {} {} pc 0x{:04X} sent {} arrived {} | acked core {} at {} owed {}",
                        self.core_id, m, flit.value_to_send, src_core, flit.src_ctx, if flit.src_isb != 0 { "branch" } else { "leaf" }, flit.src_pc, flit.sent_cycle, self.cycle, self.ack_to[m].0, self.ack_to[m].1, self.data_expect[m]);
                }
                let expected = if self.data_expect[m] > 0 { self.data_expect[m] -= 1; true }
                               else { m == 0 && self.cycle.saturating_sub(self.clone_go_cycle) < 1_000_000 && self.clone_go_cycle > 0 };
                let k = self.mbox_ring_idx[m] as usize;
                self.mbox_ring[m * 8 + k] = MboxRec { src_core, src_ctx: flit.src_ctx, src_isb: flit.src_isb, src_pc: flit.src_pc, value: flit.value_to_send, sent: flit.sent_cycle, arrived: self.cycle, expected };
                self.mbox_ring_idx[m] = ((k + 1) & 7) as u8;
                if !expected && STRAY_N.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 2000 {
                    println!("STRAY core {} pipe {} value 0x{:08X} from core {} ctx {} {} pc 0x{:04X} sent {} arrived {} | my ctx {} pc 0x{:04X} fill {} expect {:?}",
                        self.core_id, m, flit.value_to_send, src_core, flit.src_ctx, if flit.src_isb != 0 { "branch" } else { "leaf" }, flit.src_pc, flit.sent_cycle, self.cycle,
                        m, self.pc[m], self.noc_recv_fifo[m].len(), self.data_expect);
                    println!("STRAY_ACK core {} pipe {} last ack to core {} at {}", self.core_id, m, self.ack_to[m].0, self.ack_to[m].1); // AI debug [156]
                    let _ = DUMP_REQ.compare_exchange(0, ((src_core as u64 + 1) << 8) | flit.src_ctx as u64, std::sync::atomic::Ordering::Relaxed, std::sync::atomic::Ordering::Relaxed); // AI debug [158]
                }
            }
            let _ = self.noc_recv_fifo[flit.mailbox_id as usize].push(flit.value_to_send);
            self.flits_received += 1;
            self.flit_received_manhattan_distance_traversed +=
                (flit.origin_x as i64 - flit.destination_x as i64).unsigned_abs() as usize
                + (flit.origin_y as i64 - flit.destination_y as i64).unsigned_abs() as usize;
            return;
        }

        // Forward.
        let dir = self.route_direction(dest_x, dest_y).unwrap();
        if !self.has_noc(dir) {
            // Routing bug (e.g. flit headed off the edge). Silent — don't drop, don't pop.
            return;
        }
        if self.lane_full(dir, mailbox) {
            self.bump_congestion(dir);
            return;
        }
        self.bump_util(dir);
        let flit = self.pop_inbound(from);
        self.forward_to(dir, flit);
    }




    pub fn give_far_dram(&mut self, dram_vec: Vec<Sender<LongDramRequest>>) {
        self.dram_long_request = Some(dram_vec);
    }
    pub fn give_far_dram_response(&mut self, dram_vec: Eater<LongDramOp>) {
        self.dram_long_response = Some(dram_vec);
    }
    pub fn give_up_noc(&mut self, up_noc: BidirectionalNoc) {
        self.up_noc = Some(up_noc);
    }
    pub fn give_down_noc(&mut self, down_noc: BidirectionalNoc) {
        self.down_noc = Some(down_noc);
    }
    pub fn give_left_noc(&mut self, left_noc: BidirectionalNoc) {
        self.left_noc = Some(left_noc);
    }
    pub fn give_right_noc(&mut self, right_noc: BidirectionalNoc) {
        self.right_noc = Some(right_noc);
    }
    pub fn get_stack(&self) -> usize {
        self.top_bits_dram_stack
    }
    // AI debug [57]: called from main.rs when a core panics: per-context pc/membits and the faulting context's last 32 executed pcs
    // AI debug [65]: (ctx_ownership, per-context pcs, runnable flags, is_branch from the SRAM header word at 0x38)
    pub fn debug_hist(&self, c: usize, n: usize) -> String { (256 - n..256).map(|i| { let (p, cy) = self.pc_hist[c * 256 + ((self.pc_hist_idx[c] + i) & 255)]; format!("{:04X}@{}", p, cy) }).collect::<Vec<_>>().join(" ") } // AI [82]
    pub fn debug_membits(&self, ctx: usize) -> u32 { self.memory_bits[ctx] } // AI [92]
    pub fn debug_reg(&self, ctx: usize, r: usize) -> u32 { self.register_file[ctx * REGS_PER_CONTEXT + r] } // AI [79]
    pub fn debug_state(&self) -> (i8, Vec<u16>, Vec<bool>, u32) {
        (self.ctx_ownership, self.pc.to_vec(), self.runnable.clone(), self.read_sram_word(&0x38u16))
    }
    /// AI debug [158]: dump one context's recent PC history and registers, then trace its next 200 instructions (HS_TRACE).
    pub fn hs_dump(&mut self, c: usize, why: &str) {
        if HS_DUMPS.fetch_add(1, std::sync::atomic::Ordering::Relaxed) >= 40 { return; }
        let hist: Vec<String> = (192..256).map(|i| { let (p, cy) = self.pc_hist[c * 256 + ((self.pc_hist_idx[c] + i) & 255)]; format!("{:04X}@{}", p, cy) }).collect();
        println!("HS_DUMP {} core {} ctx {} cycle {} isb {} pc 0x{:04X} membits {} runnable {} ctx_own {} | ack_recv 0x{:08X} left {} at {} | req_pending {} at {} word 0x{:08X}",
            why, self.core_id, c, self.cycle, self.read_sram_word(&0x38u16), self.pc[c], self.memory_bits[c], self.runnable[c], self.ctx_ownership,
            self.ack_recv[c].0, self.ack_recv[c].1, self.ack_recv[c].2, self.req_pending[c].0, self.req_pending[c].1, self.req_pending[c].2);
        let regs: Vec<String> = (0..REGS_PER_CONTEXT).map(|r| format!("r{}={:08X}", r, self.register_file[c * REGS_PER_CONTEXT + r])).collect();
        println!("HS_REGS core {} ctx {} {}", self.core_id, c, regs.join(" "));
        println!("HS_HIST core {} ctx {} {}", self.core_id, c, hist.join(" "));
        if !self.cyc_ring.is_empty() { // AI debug [159]: the whole core, cycle by cycle, oldest first. Token = ctx.pc (hex); '*' = no instruction issued.
            //   One line per 64 cycles: 'HS_CYC core C from cycle X: tok tok ...' (runs of an identical token are written as tok xN).
            let n = self.cyc_ring.len().min(self.cycle as usize);
            let m = self.cyc_ring.len() - 1;
            let start = self.cycle as usize - n;
            let mut line = String::new();
            let (mut prev, mut run) = (u32::MAX, 0usize);
            let flush = |line: &mut String, prev: u32, run: usize| {
                if run == 0 { return; }
                let tok = if prev & (1 << 21) == 0 { "?".to_string() } else { format!("{}{:X}.{:04X}", if prev & (1 << 20) == 0 { "*" } else { "" }, (prev >> 16) & 0xF, prev & 0xFFFF) };
                if run > 1 { line.push_str(&format!("{}x{} ", tok, run)); } else { line.push_str(&tok); line.push(' '); }
            };
            for i in 0..n {
                let cyc = start + i;
                let e = self.cyc_ring[cyc & m];
                if e == prev { run += 1; } else { flush(&mut line, prev, run); prev = e; run = 1; }
                if (i + 1) % 64 == 0 || i + 1 == n {
                    flush(&mut line, prev, run); run = 0; prev = u32::MAX;
                    println!("HS_CYC core {} from cycle {}: {}", self.core_id, cyc + 1 - (if (i + 1) % 64 == 0 { 64 } else { (i + 1) % 64 }), line.trim_end());
                    line.clear();
                }
            }
        }
        self.trace_ctx = c;
        self.trace_left = 200;
    }
    pub fn debug_dump(&self) {
        let c = self.context_in_progress;
        println!("CORE_DUMP core {} ctx {} pcs {:?} membits {:?}", self.core_id, c, self.pc, self.memory_bits);
        let hist: Vec<String> = (224..256).map(|i| { let (p, cy) = self.pc_hist[c * 256 + ((self.pc_hist_idx[c] + i) & 255)]; format!("{:04X}@{}", p, cy) }).collect();
        println!("CORE_DUMP_HIST core {} ctx {} {}", self.core_id, c, hist.join(" "));
        let m = self.mbox_last[c & 15]; println!("CORE_DUMP_MBOX core {} ctx {} last data-mailbox flit: origin ({}, {}) = core {} value 0x{:08X} cycle {} fill {}", self.core_id, c, m.0, m.1, m.1 as u32 * 128 + m.0 as u32, m.2, m.3, self.noc_recv_fifo[c & 15].len()); // AI debug [123]
        let p = c & 15; // AI debug [153]: last 8 deliveries to this context's data mailbox, oldest first
        for i in 0..8 {
            let r = self.mbox_ring[p * 8 + ((self.mbox_ring_idx[p] as usize + i) & 7)];
            if r.arrived == 0 { continue; }
            println!("CORE_DUMP_RING core {} pipe {} from core {} ctx {} {} pc 0x{:04X} value 0x{:08X} sent {} arrived {} expected {}", self.core_id, p, r.src_core, r.src_ctx, if r.src_isb != 0 { "branch" } else { "leaf" }, r.src_pc, r.value, r.sent, r.arrived, r.expected);
        }
        println!("CORE_DUMP_EXPECT core {} expect {:?}", self.core_id, self.data_expect);
    }
    pub fn get_core_id(&self) -> u32 {
        self.core_id
    }
    pub fn get_x_index(&self) -> usize {
        self.x_dim as usize
    }
    pub fn get_y_index(&self) -> usize {
        self.y_dim as usize
    }
    pub fn get_local_read(&self) -> usize {
        self.dram_bytes_read_close
    }
    pub fn get_local_write(&self) -> usize {
        self.dram_bytes_wrote_close
    }
    pub fn get_foreign_read(&self) -> usize {
        self.dram_bytes_read_far
    }
    pub fn get_foreign_write(&self) -> usize {
        self.dram_bytes_wrote_far
    }
    pub fn write_to_sram(&mut self, mut base_address: u16, data: &Vec<u32>, words: usize) {
        assert!(
            base_address as usize + words * 4 <= SRAM_SIZE,
            "SRAM WRITE OUT OF BOUNDS!"
        );
        assert!(data.len() >= words, "SRAM WRITE SIZE MISMATCH");
        for word_index in 0..words {
            self.write_sram_word(data[word_index], &base_address);
            base_address += 4;
        }
    }
    fn write_sram_byte(&mut self, byte: u8, address: &u16) {
        if (*address as usize) < 0x2C && self.cycle > 300_000 && BOOT_CLOBBER_N.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 40 { println!("BOOT_CLOBBER core {} ctx {} pc {:04X} addr {} val {} cycle {}", self.core_id, self.context_in_progress, self.pc[self.context_in_progress], address, byte, self.cycle); } // AI [97]
        assert!(
            *address as usize <= SRAM_SIZE,
            "SRAM WRITE OUT OF BOUNDS, core: {}",
            self.core_id
        );
        self.sram[*address as usize] = byte;
    }
    fn write_sram_half(&mut self, half: u16, address: &u16) {
        if (*address as usize) < 0x2C && self.cycle > 300_000 && BOOT_CLOBBER_N.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 40 { println!("BOOT_CLOBBER core {} ctx {} pc {:04X} addr {} val {} cycle {}", self.core_id, self.context_in_progress, self.pc[self.context_in_progress], address, half, self.cycle); } // AI [97]
        assert!(
            *address as usize <= SRAM_SIZE,
            "SRAM WRITE OUT OF BOUNDS, core: {}",
            self.core_id
        );
        assert!(*address & 0x1 == 0, "HALF NOT ALIGNED!");
        self.sram[*address as usize] = (half & 0xFF) as u8;
        self.sram[*address as usize + 1] = ((half & 0xFF00) >> 8) as u8;
    }
    fn write_sram_word(&mut self, word: u32, address: &u16) {
        if (*address as usize) < 0x2C && self.cycle > 300_000 && BOOT_CLOBBER_N.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 40 { println!("BOOT_CLOBBER core {} ctx {} pc {:04X} addr {} val {} cycle {}", self.core_id, self.context_in_progress, self.pc[self.context_in_progress], address, word, self.cycle); } // AI [97]
        assert!(
            *address as usize <= SRAM_SIZE,
            "SRAM WRITE OUT OF BOUNDS, core: {}",
            self.core_id
        );
        if *address & 0x3 != 0 {
            self.dump_instruction(&self.decoded_instruction.unwrap());
            assert!(
                *address & 0x3 == 0,
                "WORD NOT ALIGNED!, core: {}",
                self.core_id
            );
        }
        self.sram[*address as usize] = (word & 0xFF) as u8;
        self.sram[*address as usize + 1] = ((word & 0xFF00) >> 8) as u8;
        self.sram[*address as usize + 2] = ((word & 0xFF0000) >> 16) as u8;
        self.sram[*address as usize + 3] = ((word & 0xFF000000) >> 24) as u8;
        // if *address < 2010 && *address > 2000 {
        //     println!("Write to address: {} was successful", address);
        // }
    }
    pub fn read_sram_byte_unsigned(&self, address: &u16) -> u32 {
        let index = *address as usize;
        *self.sram.get(index).expect(&format!("Failed to read SRAM byte unsigned at PC 0x{:08X}, index out of bounds: tried to access index {} when SRAM size is {}", self.pc[self.context_in_progress], index, SRAM_SIZE)) as u32
    }

    pub fn read_sram_byte_signed(&self, address: &u16) -> u32 {
        let index = *address as usize;
        ((*self.sram.get(index).expect(&format!("Failed to read SRAM byte signed at PC 0x{:08X}, index out of bounds: tried to access index {} when SRAM size is {}", self.pc[self.context_in_progress], index, SRAM_SIZE)) as i8) as i32) as u32
    }
    pub fn read_sram_half_unsigned(&self, address: &u16) -> u32 {
        assert!(
            *address & 0x1 == 0,
            "UNSIGNED HALF NOT ALIGNED! at PC 0x{:08X} on core {} and context {}",
            self.pc[self.context_in_progress],
            self.core_id,
            self.context_in_progress
        );
        let index_low = *address as usize;
        let index_high = index_low + 1;
        let low_half = *self.sram.get(index_low).expect(&format!("Failed to read SRAM half unsigned at PC 0x{:08X}, index out of bounds (low byte): tried to access index {} when SRAM size is {}", self.pc[self.context_in_progress], index_low, SRAM_SIZE)) as u32;
        let high_half = (*self.sram.get(index_high).expect(&format!("Failed to read SRAM half unsigned at PC 0x{:08X}, index out of bounds (high byte): tried to access index {} when SRAM size is {}", self.pc[self.context_in_progress], index_high, SRAM_SIZE)) as u32) << 8;
        low_half | high_half
    }
    pub fn read_sram_half_signed(&self, address: &u16) -> u32 {
        assert!(
            *address & 0x1 == 0,
            "SIGNED HALF NOT ALIGNED! at PC 0x{:08X} on core {}",
            self.pc[self.context_in_progress],
            self.core_id
        );
        let index_low = *address as usize;
        let index_high = index_low + 1;
        let lo = *self.sram.get(index_low).expect(&format!("Failed to read SRAM half signed at PC 0x{:08X}, index out of bounds (low byte): tried to access index {} when SRAM size is {}", self.pc[self.context_in_progress], index_low, SRAM_SIZE));
        let hi = *self.sram.get(index_high).expect(&format!("Failed to read SRAM half signed at PC 0x{:08X}, index out of bounds (high byte): tried to access index {} when SRAM size is {}", self.pc[self.context_in_progress], index_high, SRAM_SIZE));

        let val = u16::from_le_bytes([lo, hi]) as i16;
        val as i32 as u32
    }
    /// AI [144] debug: could context c issue its next instruction this cycle? Schedulable (runnable, or the running / owning context), and the
    /// operands (and, as the issue logic requires, the destination for WAW) are ready. A context spinning in a poll loop counts.
    fn ctx_can_issue(&self, c: usize) -> bool {
        // runnable is cleared for a getowner owner and is still false for context 0 during boot, yet both run: count them too
        if !(self.runnable[c] || c == self.context_in_progress || self.ctx_ownership == c as i8) {
            return false;
        }
        let pc = self.pc[c];
        let word = self.read_sram_word(&pc);
        if word & 0x7F > 56 {
            return false; // not an instruction word (cannot be decoded)
        }
        let ins = decode_instruction(word, pc);
        let b = c * REGS_PER_CONTEXT;
        let srcs_ready = match num_source_registers(&ins) {
            0 => true,
            1 => self.register_ready[b + ins.sr1],
            _ => self.register_ready[b + ins.sr1] && self.register_ready[b + ins.sr2],
        };
        srcs_ready && (ins.dr == REGS_PER_CONTEXT - 1 || self.register_ready[b + ins.dr])
    }

    /// AI debug [155]: NoC window stats over epochs [e0, e1) (NOC_UTIL_EPOCH_LEN cycles each). Returns per direction (R, L, U, D):
    ///   flits forwarded and congestion stalls, plus mailbox-congestion stalls, context-switch (no-issue) cycles, a mask of the
    ///   links this core has, and its cumulative router auto-rejects.
    pub fn noc_window(&self, e0: usize, e1: usize) -> ([u64; 4], [u64; 4], u64, u64, u8, u64) {
        let s = |v: &Vec<usize>| -> u64 { (e0..e1.min(v.len())).map(|i| v[i] as u64).sum() };
        let util = [s(&self.right_noc_util), s(&self.left_noc_util), s(&self.up_noc_util), s(&self.down_noc_util)];
        let cong = [s(&self.right_noc_congestion), s(&self.left_noc_congestion), s(&self.up_noc_congestion), s(&self.down_noc_congestion)];
        let mask = (self.right_noc.is_some() as u8) | ((self.left_noc.is_some() as u8) << 1) | ((self.up_noc.is_some() as u8) << 2) | ((self.down_noc.is_some() as u8) << 3);
        (util, cong, s(&self.mailbox_congestion), s(&self.core_busy), mask, self.auto_rejects as u64)
    }
    /// AI [160]: hash of this core's architectural state (pcs, registers, ready bits, membits, SRAM, mailbox fill) for determinism checks.
    pub fn state_hash(&self) -> u64 {
        let mut h: u64 = 0xcbf29ce484222325;
        let mut mix = |x: u64| { h ^= x; h = h.wrapping_mul(0x100000001b3); };
        for p in self.pc.iter() { mix(*p as u64); }
        for r in self.register_file.iter() { mix(*r as u64); }
        for (i, b) in self.register_ready.iter().enumerate() { if !*b { mix(i as u64 | 0x8000_0000); } }
        for m in self.memory_bits.iter() { mix(*m as u64); }
        for w in self.sram.chunks(8) { let mut x = 0u64; for (i, b) in w.iter().enumerate() { x |= (*b as u64) << (8 * i); } mix(x); }
        for f in self.noc_recv_fifo.iter() { mix(f.len() as u64); }
        mix(self.context_in_progress as u64);
        h
    }
    pub fn ready_hist(&self) -> &[u64; 16] {
        &self.ready_hist
    }

    #[inline]
    fn note_dram_pc(&self, addr: usize) { // AI [129] debug: who is hammering DRAM
        let isb = (self.read_sram_word(&0x38u16) != 0) as usize;
        let pcw = (self.pc[self.context_in_progress] as usize / 4) & 4095;
        let tgt = (addr / DRAM_STACK_SIZE) & 7;
        DRAM_PC_HIST.with(|h| {
            let mut h = h.borrow_mut();
            if h.is_empty() { h.resize(2 * 4096 * 8, 0); }
            h[(isb * 4096 + pcw) * 8 + tgt] += 1;
        });
    }

    pub fn read_sram_word(&self, address: &u16) -> u32 {
        assert!(
            address & 0x3 == 0,
            "WORD NOT ALIGNED! address = 0x{:04X} ({}), core_id: {}, ctx {}, pc 0x{:04X}, fetch_pc {:?}", // AI: added ctx/pc for debugging
            address,
            address,
            self.core_id,
            self.context_in_progress,
            self.pc[self.context_in_progress],
            self.fetch_pc
        );
        let index0 = *address as usize;
        let index1 = index0 + 1;
        let index2 = index0 + 2;
        let index3 = index0 + 3;
        let val = u32::from_le_bytes([
            *self.sram.get(index0).expect(&format!("Failed to read SRAM word at PC 0x{:08X}, index out of bounds (byte 0): tried to access index {} when SRAM size is {}", self.pc[self.context_in_progress], index0, SRAM_SIZE)),
            *self.sram.get(index1).expect(&format!("Failed to read SRAM word at PC 0x{:08X}, index out of bounds (byte 1): tried to access index {} when SRAM size is {}", self.pc[self.context_in_progress], index1, SRAM_SIZE)),
            *self.sram.get(index2).expect(&format!("Failed to read SRAM word at PC 0x{:08X}, index out of bounds (byte 2): tried to access index {} when SRAM size is {}", self.pc[self.context_in_progress], index2, SRAM_SIZE)),
            *self.sram.get(index3).expect(&format!("Failed to read SRAM word at PC 0x{:08X}, index out of bounds (byte 3): tried to access index {} when SRAM size is {}", self.pc[self.context_in_progress], index3, SRAM_SIZE)),
        ]);
        val
    }

    pub fn tick(
        &mut self,
        dram: &mut Vec<u32>,
        mem: &mut crate::memory::MemSystem, // AI [128]: this stack's cache/DRAM timing model
        cores_to_monitor: &Vec<u32>,
        context_to_monitor: &i32,
    ) {
        while self.fp_pipe.peek().is_some()
            && self.fp_pipe.peek().unwrap().cycle_to_read <= self.cycle
        {
            let fp_stage = self.fp_pipe.pop().unwrap();
            if fp_stage.register_index % REGS_PER_CONTEXT != REGS_PER_CONTEXT - 1 { self.register_file[fp_stage.register_index] = fp_stage.calculated_val; } // AI [80]: r15 is the read-only hardware id
            self.register_ready[fp_stage.register_index] = true;
        }

        while self.div_seq.peek().is_some()
            && self.div_seq.peek().unwrap().cycle_to_read <= self.cycle
        {
            let div_stage = self.div_seq.pop().unwrap();
            if div_stage.register_index % REGS_PER_CONTEXT != REGS_PER_CONTEXT - 1 { self.register_file[div_stage.register_index] = div_stage.calculated_val; } // AI [80]
            self.register_ready[div_stage.register_index] = true;
        }

        // AI [128]: DRAM replies (close and far) arrive tagged with their register and the cycle they are due.
        //   They can complete out of order now (cache hits vs misses); the WAW interlock [81] keeps one reply in flight per register.
        if let Some(resp) = self.dram_long_response.as_mut() {
            while let Some(op) = resp.pop() {
                self.dram_pending.push(op);
            }
        }
        let mut i = 0;
        while i < self.dram_pending.len() {
            if self.dram_pending[i].ready_cycle <= self.cycle {
                let op = self.dram_pending.swap_remove(i);
                let idx = op.register_index;
                if idx % REGS_PER_CONTEXT != REGS_PER_CONTEXT - 1 {
                    assert!(!self.register_ready[idx], "DRAM REPLY FOR A REGISTER NOT WAITING ON ONE: core {} reg {} cycle {}", self.core_id, idx, self.cycle);
                    self.register_file[idx] = op.calculated_val; // AI [80]: r15 is the read-only hardware id
                }
                self.register_ready[idx] = true;
            } else {
                i += 1;
            }
        }

        self.cycle_noc();

        if self.cycle % READY_SAMPLE == 0 { // AI [144] debug: how many worker contexts could issue (context 15 = the interrupt loop, left out)
            let n = (0..15).filter(|&c| self.ctx_can_issue(c)).count();
            self.ready_hist[n] += 1;
        }

        let mut flush = false;
        let mut long_latency_op = false;
        let mut switch_ctx = false;
        if let Some(instruction_to_execute) = self.decoded_instruction {
            let number_of_instructions = num_source_registers(&instruction_to_execute);
            match number_of_instructions {
                0 => {}
                1 => {
                    switch_ctx = !self.register_ready
                        [instruction_to_execute.sr1 + self.context_in_progress * REGS_PER_CONTEXT];
                }
                2 => {
                    let sr1_ready = self.register_ready
                        [instruction_to_execute.sr1 + self.context_in_progress * REGS_PER_CONTEXT];
                    let sr2_ready = self.register_ready
                        [instruction_to_execute.sr2 + self.context_in_progress * REGS_PER_CONTEXT];
                    switch_ctx = !(sr1_ready && sr2_ready);
                }
                _ => panic!("INVALID NUMBER OF SOURCE REGISTERS"),
            }
            if let Operation::StoreByte
            | Operation::StoreByteDram
            | Operation::StoreHalf
            | Operation::StoreHalfDram
            | Operation::StoreWord
            | Operation::StoreWordDram
            | Operation::BranchEq
            | Operation::BranchGT
            | Operation::BranchGTU
            | Operation::BranchLTE
            | Operation::BranchLTEU
            | Operation::BranchNe = instruction_to_execute.operation
            {
                let dr_ready = self.register_ready
                    [instruction_to_execute.dr + self.context_in_progress * REGS_PER_CONTEXT];
                if !dr_ready {
                    switch_ctx = true;
                }
            } else if instruction_to_execute.dr != REGS_PER_CONTEXT - 1
                && !self.register_ready[instruction_to_execute.dr + self.context_in_progress * REGS_PER_CONTEXT]
            {
                // AI [81]: write-after-write interlock. An instruction that writes a register with a long-latency (DRAM/div/fp) result
                //   still in flight must wait, or that late result overwrites the newer value (run 47: the pool head mask in r4 was
                //   overwritten by a far atomadd reply, so consumers waited on duplicate slots while 749 ready slots were never taken).
                switch_ctx = true;
            }
            if let Operation::Div | Operation::Mod = instruction_to_execute.operation {
                if !self.div_seq.is_empty() {
                    // println!("DIV BUSY RN BBY");
                    switch_ctx = true;
                }
            }
            assert!(
                instruction_to_execute.pc == self.pc[self.context_in_progress],
                "PC MISMATCH DURING EXECUTION"
            );

            if !switch_ctx {
                { // AI debug [85]: count leaf triangle hits and branch COMPLETE_RAY hits (PCs set by main.rs)
                    let pcv = self.pc[self.context_in_progress] as u32;
                    if pcv == DESCEND_PC.load(std::sync::atomic::Ordering::Relaxed) && self.read_sram_word(&0x38u16) == 0 { // AI [104]: leaf descends to a null child?
                        let b = self.context_in_progress * REGS_PER_CONTEXT;
                        let r1 = self.register_file[b + 1] as u16;
                        if self.read_sram_half_unsigned(&r1.wrapping_add(24)) == 0xFFFF && DESCEND_NULL_N.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 20 {
                            let regs: Vec<String> = (0..16).map(|r| format!("{:X}", self.register_file[b + r])).collect();
                            let r0 = self.register_file[b] as u16;
                            let ray: Vec<String> = (0..16).map(|w| format!("{:X}", self.read_sram_word(&r0.wrapping_add(4 * w)))).collect();
                            let nodeb = r1.wrapping_sub(24) & !1;
                            let node: Vec<String> = (0..12).map(|w| format!("{:X}", self.read_sram_word(&(r1.wrapping_sub(r1 & 2)).wrapping_add(4 * w)))).collect();
                            let _ = nodeb;
                            println!("DESCEND_NULL core {} ctx {} cycle {} regs {} ray {} node@{:X} {}", self.core_id, self.context_in_progress, self.cycle, regs.join(" "), ray.join(" "), r1 & !2, node.join(" "));
                        }
                    }
                    for w in 0..6 { if pcv == NOC_WATCH_PC[w].load(std::sync::atomic::Ordering::Relaxed) && ((self.read_sram_word(&0x38u16) != 0) == (w < 3)) { NOC_WATCH_N[w].fetch_add(1, std::sync::atomic::Ordering::Relaxed); } } // AI [102]
                    for w in 0..4 { if pcv == LEAF_WATCH_PC[w].load(std::sync::atomic::Ordering::Relaxed) && self.read_sram_word(&0x38u16) == 0 { LEAF_WATCH_N[w].fetch_add(1, std::sync::atomic::Ordering::Relaxed); } } // AI [86]
                    if pcv == LEAF_HIT_PC.load(std::sync::atomic::Ordering::Relaxed) || pcv == BRANCH_HIT_PC.load(std::sync::atomic::Ordering::Relaxed) {
                        let isb = self.read_sram_word(&0x38u16) != 0;
                        if !isb && pcv == LEAF_HIT_PC.load(std::sync::atomic::Ordering::Relaxed) { LEAF_HITS.fetch_add(1, std::sync::atomic::Ordering::Relaxed); }
                        if isb && pcv == BRANCH_HIT_PC.load(std::sync::atomic::Ordering::Relaxed) { BRANCH_HITS.fetch_add(1, std::sync::atomic::Ordering::Relaxed); }
                    }
                }
                { // AI [132] debug: execution count per PC (ray-path statistics: NoC vs DRAM forwards, bounce / shadow rays)
                    let isb = (self.read_sram_word(&0x38u16) != 0) as usize;
                    let pcw = (self.pc[self.context_in_progress] as usize / 4) & 4095;
                    PC_EXEC_HIST.with(|h| {
                        let mut h = h.borrow_mut();
                        if h.is_empty() { h.resize(2 * 4096, 0); }
                        h[isb * 4096 + pcw] += 1;
                    });
                }
                { // AI debug [44]
                    let c = self.context_in_progress;
                    let k = self.pc_hist_idx[c];
                    self.pc_hist[c * 256 + k] = (self.pc[c], self.cycle as u32);
                    self.pc_hist_idx[c] = (k + 1) & 255;
                    self.cyc_rec = (self.pc[c] as u32) | ((c as u32) << 16) | (1 << 20) | (1 << 21); // AI debug [159]
                    if self.trace_left > 0 && self.trace_ctx == c { // AI debug [158]
                        self.trace_left -= 1;
                        let rf = |r: usize| self.register_file[c * REGS_PER_CONTEXT + r];
                        println!("HS_TRACE core {} ctx {} pc 0x{:04X} cycle {} r8 {:08X} r9 {:08X} r10 {:08X} r12 {:08X} r14 {:08X}", self.core_id, c, self.pc[c], self.cycle, rf(8), rf(9), rf(10), rf(12), rf(14));
                    }
                }
                if self.pc[self.context_in_progress] == 0 && self.cycle > 1000 { // AI debug [53]: a core rebooting through the bootloader = a clone
                    println!("CLONE_REBOOT core {} ctx {} cycle {}", self.core_id, self.context_in_progress, self.cycle);
                    { // AI debug [153]: data still owed or queued at a reboot lands in the new image's mailboxes
                        let fills: Vec<usize> = (0..16).map(|m| self.noc_recv_fifo[m].len()).collect();
                        if (self.data_expect.iter().any(|&e| e != 0) || fills.iter().any(|&f| f != 0)) && REBOOT_STATE_N.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 2000 {
                            println!("REBOOT_STATE core {} cycle {} expect {:?} fill {:?}", self.core_id, self.cycle, self.data_expect, fills);
                        }
                    }
                }
                let mut core_in_list = false;
                for i in cores_to_monitor {
                    if self.core_id == *i {
                        core_in_list = true;
                    }
                }
                if debug_on()
                    && (core_in_list || cores_to_monitor.len() == 0)
                    && (*context_to_monitor == self.context_in_progress as i32
                        || *context_to_monitor < 0)
                {
                    println!(
                        "Core {} executing instruction x{:08X} ({:?}) at PC 0x{:08X} in context {} at cycle: {}, dr: {}, pre-dr_val: {}, sr1: {}, sr1_val: {}, is_imm: {}, sr2: {}, sr2_val: {},imm_val: {}",
                        self.core_id,
                        instruction_to_execute.raw_instruction,
                        instruction_to_execute.operation,
                        instruction_to_execute.pc,
                        self.context_in_progress,
                        self.cycle,
                        instruction_to_execute.dr,
                        self.register_file
                            [self.context_in_progress * CTX_CNT + instruction_to_execute.dr],
                        instruction_to_execute.sr1,
                        self.register_file
                            [self.context_in_progress * CTX_CNT + instruction_to_execute.sr1],
                        instruction_to_execute.imm_1,
                        instruction_to_execute.sr2,
                        self.register_file
                            [self.context_in_progress * CTX_CNT + instruction_to_execute.sr2],
                        instruction_to_execute.imm_0
                    );
                    io::stdout().flush().unwrap();
                }
                match instruction_to_execute.operation {
                    Operation::Add => {
                        let sr2_val = if instruction_to_execute.is_imm {
                            instruction_to_execute.imm_0 as i16 as i32 as u32
                        } else {
                            self.register_file[instruction_to_execute.sr2
                                + self.context_in_progress * REGS_PER_CONTEXT]
                        };
                        self.register_file[instruction_to_execute.dr
                            + self.context_in_progress * REGS_PER_CONTEXT] =
                            ((self.register_file[instruction_to_execute.sr1
                                + self.context_in_progress * REGS_PER_CONTEXT]
                                as i32)
                                .wrapping_add(sr2_val as i32)) as u32;
                        if debug_on()
                            && (core_in_list || cores_to_monitor.is_empty())
                            && (*context_to_monitor == self.context_in_progress as i32
                                || *context_to_monitor < 0)
                        {
                            if self.pc[self.context_in_progress] == 0x1D74 {
                                println!("STACK NEW: {}", self.register_file[instruction_to_execute.dr
                            + self.context_in_progress * REGS_PER_CONTEXT]);
                            }
                        }
                        self.pc[self.context_in_progress] += 4;

                    }
                    Operation::Sub => {
                        let sr2_val = if instruction_to_execute.is_imm {
                            instruction_to_execute.imm_0 as i16 as i32 as u32
                        } else {
                            self.register_file[instruction_to_execute.sr2
                                + self.context_in_progress * REGS_PER_CONTEXT]
                        };
                        let result = if instruction_to_execute.is_imm {
                            (sr2_val as i32).wrapping_sub(
                                self.register_file[instruction_to_execute.sr1
                                    + self.context_in_progress * REGS_PER_CONTEXT]
                                    as i32,
                            ) as u32
                        } else {
                            ((self.register_file[instruction_to_execute.sr1
                                + self.context_in_progress * REGS_PER_CONTEXT]
                                as i32)
                                .wrapping_sub(sr2_val as i32)) as u32
                        };
                        self.register_file[instruction_to_execute.dr
                            + self.context_in_progress * REGS_PER_CONTEXT] = result;
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::And => {
                        let sr2_val = if instruction_to_execute.is_imm {
                            instruction_to_execute.imm_0 as i16 as i32 as u32
                        } else {
                            self.register_file[instruction_to_execute.sr2
                                + self.context_in_progress * REGS_PER_CONTEXT]
                        };
                        self.register_file[instruction_to_execute.dr
                            + self.context_in_progress * REGS_PER_CONTEXT] = self.register_file
                            [instruction_to_execute.sr1
                                + self.context_in_progress * REGS_PER_CONTEXT]
                            & sr2_val;
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::Or => {
                        let sr2_val = if instruction_to_execute.is_imm {
                            instruction_to_execute.imm_0 as i16 as i32 as u32
                        } else {
                            self.register_file[instruction_to_execute.sr2
                                + self.context_in_progress * REGS_PER_CONTEXT]
                        };
                        self.register_file[instruction_to_execute.dr
                            + self.context_in_progress * REGS_PER_CONTEXT] = self.register_file
                            [instruction_to_execute.sr1
                                + self.context_in_progress * REGS_PER_CONTEXT]
                            | sr2_val;
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::Xor => {
                        let sr2_val = if instruction_to_execute.is_imm {
                            instruction_to_execute.imm_0 as i16 as i32 as u32
                        } else {
                            self.register_file[instruction_to_execute.sr2
                                + self.context_in_progress * REGS_PER_CONTEXT]
                        };
                        self.register_file[instruction_to_execute.dr
                            + self.context_in_progress * REGS_PER_CONTEXT] = self.register_file
                            [instruction_to_execute.sr1
                                + self.context_in_progress * REGS_PER_CONTEXT]
                            ^ sr2_val;
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::Sll => {
                        let sr2_val = if instruction_to_execute.is_imm {
                            instruction_to_execute.imm_0
                        } else {
                            self.register_file[instruction_to_execute.sr2
                                + self.context_in_progress * REGS_PER_CONTEXT]
                        };
                        self.register_file[instruction_to_execute.dr
                            + self.context_in_progress * REGS_PER_CONTEXT] = self.register_file
                            [instruction_to_execute.sr1
                                + self.context_in_progress * REGS_PER_CONTEXT]
                            << sr2_val;
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::Srl => {
                        let sr2_val = if instruction_to_execute.is_imm {
                            instruction_to_execute.imm_0
                        } else {
                            self.register_file[instruction_to_execute.sr2
                                + self.context_in_progress * REGS_PER_CONTEXT]
                        };
                        self.register_file[instruction_to_execute.dr
                            + self.context_in_progress * REGS_PER_CONTEXT] = self.register_file
                            [instruction_to_execute.sr1
                                + self.context_in_progress * REGS_PER_CONTEXT]
                            >> sr2_val;
                        if debug_on()
                            && (core_in_list || cores_to_monitor.len() == 0)
                            && (*context_to_monitor == self.context_in_progress as i32
                                || *context_to_monitor < 0)
                        {
                            if 0x1698 == self.pc[self.context_in_progress] {
                                println!("Node ID taken ALEX: {}", self.register_file[11]);
                            }
                        }
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::Sra => {
                        let sr2_val = if instruction_to_execute.is_imm {
                            instruction_to_execute.imm_0
                        } else {
                            self.register_file[instruction_to_execute.sr2
                                + self.context_in_progress * REGS_PER_CONTEXT]
                        };
                        self.register_file[instruction_to_execute.dr
                            + self.context_in_progress * REGS_PER_CONTEXT] =
                            ((self.register_file[instruction_to_execute.sr1
                                + self.context_in_progress * REGS_PER_CONTEXT]
                                as i32)
                                >> sr2_val) as u32;
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::Mul => {
                        long_latency_op = true;
                        let sr2_val = if instruction_to_execute.is_imm {
                            instruction_to_execute.imm_0 as i16 as i32 as u32
                        } else {
                            self.register_file[instruction_to_execute.sr2
                                + self.context_in_progress * REGS_PER_CONTEXT]
                        };
                        let mul_result = self.register_file[instruction_to_execute.sr1
                            + self.context_in_progress * REGS_PER_CONTEXT]
                            .wrapping_mul(sr2_val);
                        assert!(!self.fp_pipe.is_full(), "FP PIPE IS FULL");
                        let mul_pipe_stage: PipelineStage = PipelineStage {
                            cycle_to_read: self.cycle + FP_PIPE_STAGES as u64,
                            calculated_val: mul_result,
                            register_index: instruction_to_execute.dr
                                + self.context_in_progress * REGS_PER_CONTEXT,
                        };
                        let _ = self.fp_pipe.push(mul_pipe_stage);
                        self.pc[self.context_in_progress] += 4;
                        if self.core_id == 0 && instruction_to_execute.imm_1 == 0 {
                            println!(
                                "MUL RESULT: {}, context: {}",
                                mul_result as i32, self.context_in_progress
                            );
                        }
                    }
                    Operation::Div => {
                        long_latency_op = true;
                        let sr2_val = if instruction_to_execute.is_imm {
                            instruction_to_execute.imm_0 as i16 as i32 as u32
                        } else {
                            self.register_file[instruction_to_execute.sr2
                                + self.context_in_progress * REGS_PER_CONTEXT]
                        };
                        let div_result = self.register_file[instruction_to_execute.sr1
                            + self.context_in_progress * REGS_PER_CONTEXT]
                            / sr2_val;
                        let div_pipe_stage: PipelineStage = PipelineStage {
                            cycle_to_read: self.cycle + DIV_LATENCY as u64,
                            calculated_val: div_result,
                            register_index: instruction_to_execute.dr
                                + self.context_in_progress * REGS_PER_CONTEXT,
                        };
                        if self.div_seq.is_full() {
                            switch_ctx = true;
                            println!("DIV BUSY RN @ Core {}, context {}", self.core_id, self.context_in_progress);
                        } else {
                            let _ = self.div_seq.push(div_pipe_stage);
                            self.pc[self.context_in_progress] += 4;
                        }
                    }
                    Operation::Mod => {
                        long_latency_op = true;
                        let sr2_val = if instruction_to_execute.is_imm {
                            instruction_to_execute.imm_0 as i16 as i32 as u32
                        } else {
                            self.register_file[instruction_to_execute.sr2
                                + self.context_in_progress * REGS_PER_CONTEXT]
                        };
                        let div_result = self.register_file[instruction_to_execute.sr1
                            + self.context_in_progress * REGS_PER_CONTEXT]
                            % sr2_val;
                        let div_pipe_stage: PipelineStage = PipelineStage {
                            cycle_to_read: self.cycle + DIV_LATENCY as u64,
                            calculated_val: div_result,
                            register_index: instruction_to_execute.dr
                                + self.context_in_progress * REGS_PER_CONTEXT,
                        };
                        if self.div_seq.is_full() {
                            switch_ctx = true;
                            println!("MOD BUSY RN @ Core {}, context {}", self.core_id, self.context_in_progress);
                        } else {
                            let _ = self.div_seq.push(div_pipe_stage);
                            self.pc[self.context_in_progress] += 4;
                        }
                    }
                    Operation::FPAdd => {
                        long_latency_op = true;

                        let idx1 = instruction_to_execute.sr1
                            + self.context_in_progress * REGS_PER_CONTEXT;
                        let idx2 = instruction_to_execute.sr2
                            + self.context_in_progress * REGS_PER_CONTEXT;

                        let fpadd_result = match instruction_to_execute.fp_type {
                            FpType::Fp32 => {
                                let a = f32::from_bits(self.register_file[idx1]);
                                let b = f32::from_bits(self.register_file[idx2]);
                                (a + b).to_bits()
                            }
                            FpType::Fp16 => {
                                let a = f16::from_bits(self.register_file[idx1] as u16);
                                let b = f16::from_bits(self.register_file[idx2] as u16);
                                (a + b).to_bits() as u32
                            }
                            FpType::Fp8 => {
                                let a = self.register_file[idx1] as u8;
                                let b = self.register_file[idx2] as u8;
                                fp8_add(a, b) as u32
                            }
                        };

                        assert!(!self.fp_pipe.is_full(), "FP PIPE IS FULL");

                        let fpadd_pipe_stage: PipelineStage = PipelineStage {
                            cycle_to_read: self.cycle + FP_PIPE_STAGES as u64,
                            calculated_val: fpadd_result,
                            register_index: instruction_to_execute.dr
                                + self.context_in_progress * REGS_PER_CONTEXT,
                        };

                        let _ = self.fp_pipe.push(fpadd_pipe_stage);
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::FPMul => {
                        long_latency_op = true;

                        let idx1 = instruction_to_execute.sr1
                            + self.context_in_progress * REGS_PER_CONTEXT;
                        let idx2 = instruction_to_execute.sr2
                            + self.context_in_progress * REGS_PER_CONTEXT;

                        let fpmul_result = match instruction_to_execute.fp_type {
                            FpType::Fp32 => {
                                let a = f32::from_bits(self.register_file[idx1]);
                                let b = f32::from_bits(self.register_file[idx2]);
                                (a * b).to_bits()
                            }
                            FpType::Fp16 => {
                                let a = f16::from_bits(self.register_file[idx1] as u16);
                                let b = f16::from_bits(self.register_file[idx2] as u16);
                                (a * b).to_bits() as u32
                            }
                            FpType::Fp8 => {
                                let a = self.register_file[idx1] as u8;
                                let b = self.register_file[idx2] as u8;
                                fp8_mul(a, b) as u32
                            }
                        };

                        assert!(!self.fp_pipe.is_full(), "FP PIPE IS FULL");

                        let fpmul_pipe_stage: PipelineStage = PipelineStage {
                            cycle_to_read: self.cycle + FP_PIPE_STAGES as u64,
                            calculated_val: fpmul_result,
                            register_index: instruction_to_execute.dr
                                + self.context_in_progress * REGS_PER_CONTEXT,
                        };

                        let _ = self.fp_pipe.push(fpmul_pipe_stage);
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::FPSub => {
                        long_latency_op = true;

                        let idx1 = instruction_to_execute.sr1
                            + self.context_in_progress * REGS_PER_CONTEXT;
                        let idx2 = instruction_to_execute.sr2
                            + self.context_in_progress * REGS_PER_CONTEXT;

                        let fpsub_result = match instruction_to_execute.fp_type {
                            FpType::Fp32 => {
                                let a = f32::from_bits(self.register_file[idx1]);
                                let b = f32::from_bits(self.register_file[idx2]);
                                (a - b).to_bits()
                            }
                            FpType::Fp16 => {
                                let a = f16::from_bits(self.register_file[idx1] as u16);
                                let b = f16::from_bits(self.register_file[idx2] as u16);
                                (a - b).to_bits() as u32
                            }
                            FpType::Fp8 => {
                                let a = self.register_file[idx1] as u8;
                                let b = self.register_file[idx2] as u8;
                                fp8_sub(a, b) as u32
                            }
                        };

                        assert!(!self.fp_pipe.is_full(), "FP PIPE IS FULL");

                        let fpsub_pipe_stage: PipelineStage = PipelineStage {
                            cycle_to_read: self.cycle + FP_PIPE_STAGES as u64,
                            calculated_val: fpsub_result,
                            register_index: instruction_to_execute.dr
                                + self.context_in_progress * REGS_PER_CONTEXT,
                        };

                        let _ = self.fp_pipe.push(fpsub_pipe_stage);
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::FPMac => {
                        let idx1 = instruction_to_execute.sr1
                            + self.context_in_progress * REGS_PER_CONTEXT;
                        let idx2 = instruction_to_execute.sr2
                            + self.context_in_progress * REGS_PER_CONTEXT;

                        let fpmac_result = match instruction_to_execute.fp_type {
                            FpType::Fp32 => {
                                let a = f32::from_bits(self.register_file[idx1]);
                                let b = f32::from_bits(self.register_file[idx2]);
                                (a * b
                                    + f32::from_bits(
                                        self.fp_accumulation[self.context_in_progress],
                                    ))
                                .to_bits()
                            }
                            FpType::Fp16 => {
                                let a = f32::from(f16::from_bits(self.register_file[idx1] as u16));
                                let b = f32::from(f16::from_bits(self.register_file[idx2] as u16));
                                let acc =
                                    f32::from_bits(self.fp_accumulation[self.context_in_progress]);
                                (a * b + acc).to_bits()
                            }
                            FpType::Fp8 => {
                                let a = Fp8E4M3::from_bits(self.register_file[idx1] as u8).to_f32();
                                let b = Fp8E4M3::from_bits(self.register_file[idx2] as u8).to_f32();
                                let acc =
                                    f32::from_bits(self.fp_accumulation[self.context_in_progress]);

                                (a * b + acc).to_bits()
                            }
                        };

                        self.fp_accumulation[self.context_in_progress] = fpmac_result;
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::FPEQ => {
                        long_latency_op = true;

                        let idx1 = instruction_to_execute.sr1
                            + self.context_in_progress * REGS_PER_CONTEXT;
                        let idx2 = instruction_to_execute.sr2
                            + self.context_in_progress * REGS_PER_CONTEXT;

                        let fpeq_result = match instruction_to_execute.fp_type {
                            FpType::Fp32 => {
                                let a = f32::from_bits(self.register_file[idx1]);
                                let b = f32::from_bits(self.register_file[idx2]);

                                if a.is_nan() || b.is_nan() {
                                    0
                                } else if a == b {
                                    1
                                } else {
                                    0
                                }
                            }

                            FpType::Fp16 => {
                                let a = f32::from(f16::from_bits(self.register_file[idx1] as u16));
                                let b = f32::from(f16::from_bits(self.register_file[idx2] as u16));

                                if a.is_nan() || b.is_nan() {
                                    0
                                } else if a == b {
                                    1
                                } else {
                                    0
                                }
                            }

                            FpType::Fp8 => {
                                let a = Fp8E4M3::from_bits(self.register_file[idx1] as u8).to_f32();
                                let b = Fp8E4M3::from_bits(self.register_file[idx2] as u8).to_f32();

                                if a.is_nan() || b.is_nan() {
                                    0
                                } else if a == b {
                                    1
                                } else {
                                    0
                                }
                            }
                        };

                        assert!(!self.fp_pipe.is_full(), "FP PIPE IS FULL");

                        let _ = self.fp_pipe.push(PipelineStage {
                            cycle_to_read: self.cycle + FP_PIPE_STAGES as u64,
                            calculated_val: fpeq_result,
                            register_index: instruction_to_execute.dr
                                + self.context_in_progress * REGS_PER_CONTEXT,
                        });
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::FPLT => {
                        long_latency_op = true;

                        let idx1 = instruction_to_execute.sr1
                            + self.context_in_progress * REGS_PER_CONTEXT;
                        let idx2 = instruction_to_execute.sr2
                            + self.context_in_progress * REGS_PER_CONTEXT;

                        let fplt_result = match instruction_to_execute.fp_type {
                            FpType::Fp32 => {
                                let a = f32::from_bits(self.register_file[idx1]);
                                let b = f32::from_bits(self.register_file[idx2]);

                                if a.is_nan() || b.is_nan() {
                                    0
                                } else if a < b {
                                    1
                                } else {
                                    0
                                }
                            }

                            FpType::Fp16 => {
                                let a = f32::from(f16::from_bits(self.register_file[idx1] as u16));
                                let b = f32::from(f16::from_bits(self.register_file[idx2] as u16));

                                if a.is_nan() || b.is_nan() {
                                    0
                                } else if a < b {
                                    1
                                } else {
                                    0
                                }
                            }

                            FpType::Fp8 => {
                                let a = Fp8E4M3::from_bits(self.register_file[idx1] as u8).to_f32();
                                let b = Fp8E4M3::from_bits(self.register_file[idx2] as u8).to_f32();

                                if a.is_nan() || b.is_nan() {
                                    0
                                } else if a < b {
                                    1
                                } else {
                                    0
                                }
                            }
                        };

                        assert!(!self.fp_pipe.is_full(), "FP PIPE IS FULL");

                        let _ = self.fp_pipe.push(PipelineStage {
                            cycle_to_read: self.cycle + FP_PIPE_STAGES as u64,
                            calculated_val: fplt_result,
                            register_index: instruction_to_execute.dr
                                + self.context_in_progress * REGS_PER_CONTEXT,
                        });
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::FPSetAccumulator => {
                        let register = self.register_file[instruction_to_execute.sr1
                            + self.context_in_progress * REGS_PER_CONTEXT];
                        let value_to_set = match instruction_to_execute.fp_type {
                            FpType::Fp32 => register,
                            FpType::Fp16 => f32::from(f16::from_bits(register as u16)).to_bits(),
                            FpType::Fp8 => Fp8E4M3::from_bits(register as u8).to_f32().to_bits(),
                        };
                        self.fp_accumulation[self.context_in_progress] = value_to_set;
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::FPStoreAccumulator => {
                        let accumulated_value = match instruction_to_execute.fp_type {
                            FpType::Fp32 => self.fp_accumulation[self.context_in_progress],
                            FpType::Fp16 => f16::from_f32(f32::from_bits(
                                self.fp_accumulation[self.context_in_progress],
                            ))
                            .to_bits() as u32,
                            FpType::Fp8 => Fp8E4M3::from_f32(f32::from_bits(
                                self.fp_accumulation[self.context_in_progress],
                            ))
                            .to_bits() as u32,
                        };
                        long_latency_op = true;
                        let _ = self.fp_pipe.push(PipelineStage {
                            cycle_to_read: self.cycle + FP_PIPE_STAGES as u64,
                            calculated_val: accumulated_value,
                            register_index: instruction_to_execute.dr
                                + self.context_in_progress * REGS_PER_CONTEXT,
                        });
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::FPMinMax => {
                        let idx1 = instruction_to_execute.sr1
                            + self.context_in_progress * REGS_PER_CONTEXT;
                        let idx2 = instruction_to_execute.sr2
                            + self.context_in_progress * REGS_PER_CONTEXT;

                        let fpminmax_result = match instruction_to_execute.fp_type {
                            FpType::Fp32 => {
                                let a = f32::from_bits(self.register_file[idx1]);
                                let b = f32::from_bits(self.register_file[idx2]);

                                (match (a < b) == (instruction_to_execute.imm_1 == 0) {
                                    true => a,
                                    false => b,
                                })
                                .to_bits()
                            }
                            FpType::Fp16 => {
                                let a = f32::from(f16::from_bits(self.register_file[idx1] as u16));
                                let b = f32::from(f16::from_bits(self.register_file[idx2] as u16));
                                (match (a < b) == (instruction_to_execute.imm_1 == 0) {
                                    true => a,
                                    false => b,
                                })
                                .to_bits()
                            }
                            FpType::Fp8 => {
                                let a = Fp8E4M3::from_bits(self.register_file[idx1] as u8).to_f32();
                                let b = Fp8E4M3::from_bits(self.register_file[idx2] as u8).to_f32();
                                (match (a < b) == (instruction_to_execute.imm_1 == 0) {
                                    true => a,
                                    false => b,
                                })
                                .to_bits()
                            }
                        };
                        assert!(!self.fp_pipe.is_full(), "FP PIPE IS FULL");
                        long_latency_op = true;

                        let fpminmax_pipe_stage: PipelineStage = PipelineStage {
                            cycle_to_read: self.cycle + FP_PIPE_STAGES as u64,
                            calculated_val: fpminmax_result,
                            register_index: instruction_to_execute.dr
                                + self.context_in_progress * REGS_PER_CONTEXT,
                        };

                        let _ = self.fp_pipe.push(fpminmax_pipe_stage);
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::StoreByte => {
                        let byte = self.register_file[instruction_to_execute.dr
                            + self.context_in_progress * REGS_PER_CONTEXT]
                            as u8;
                        if instruction_to_execute.is_imm {
                            self.write_sram_byte(byte, &(instruction_to_execute.imm_0 as u16));
                            if debug_on()
                                && (core_in_list || cores_to_monitor.len() == 0)
                                && (*context_to_monitor == self.context_in_progress as i32
                                    || *context_to_monitor < 0)
                            {
                                println!(
                                    "Local Write to {:0x} - Value: {}",
                                    &(instruction_to_execute.imm_0),
                                    byte
                                );
                            }
                        } else {
                            let address = (self.register_file[instruction_to_execute.sr1
                                + self.context_in_progress * REGS_PER_CONTEXT]
                                as u32
                                + instruction_to_execute.imm_0)
                                as u16;
                            self.write_sram_byte(byte, &address);
                            if debug_on()
                                && (core_in_list || cores_to_monitor.len() == 0)
                                && (*context_to_monitor == self.context_in_progress as i32
                                    || *context_to_monitor < 0)
                            {
                                println!("Local Write to {:0x} - Value: {}", address, byte);
                            }
                        }
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::StoreHalf => {
                        let half = self.register_file[instruction_to_execute.dr
                            + self.context_in_progress * REGS_PER_CONTEXT]
                            as u16;
                        let address = if instruction_to_execute.is_imm {
                            instruction_to_execute.imm_0 as u16
                        } else {
                            (self.register_file[instruction_to_execute.sr1
                                + self.context_in_progress * REGS_PER_CONTEXT]
                                as u32
                                + instruction_to_execute.imm_0) as u16
                        };
                        self.write_sram_half(half, &(address));
                        self.pc[self.context_in_progress] += 4;
                        if debug_on()
                            && (core_in_list || cores_to_monitor.len() == 0)
                            && (*context_to_monitor == self.context_in_progress as i32
                                || *context_to_monitor < 0)
                        {
                            println!("Local Write to {:0x} - Value: {}", address, half);
                        }
                    }
                    Operation::StoreWord => {
                        let word = self.register_file[instruction_to_execute.dr
                            + self.context_in_progress * REGS_PER_CONTEXT]
                            as u32;
                        let address = if instruction_to_execute.is_imm {
                            instruction_to_execute.imm_0 as u16
                        } else {
                            (self.register_file[instruction_to_execute.sr1
                                + self.context_in_progress * REGS_PER_CONTEXT]
                                as u32
                                + instruction_to_execute.imm_0) as u16
                        };
                        self.write_sram_word(word, &address);

                        self.pc[self.context_in_progress] += 4;
                        if debug_on()
                            && (core_in_list || cores_to_monitor.len() == 0)
                            && (*context_to_monitor == self.context_in_progress as i32
                                || *context_to_monitor < 0)
                        {
                            if self.pc[self.context_in_progress] == 0x1728 {
                                println!("End of dfs download");
                            }
                            println!("Local Write to {:0x} - Value: {}", address, word);
                        }
                    }
                    Operation::LoadByteSigned
                    | Operation::LoadByteUnsigned
                    | Operation::LoadHalfSigned
                    | Operation::LoadHalfUnsigned
                    | Operation::LoadWord => {
                        let address = if instruction_to_execute.imm_1 != 0 {
                            instruction_to_execute.imm_0 as u16
                        } else {
                            self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr1] as u16
                                + instruction_to_execute.imm_0 as u16
                        };

                        // AI debug [41]: branch RESOLVE_START_NODE lookup (`lhu r1, r1, LEAF_CORE_LOOKUP_TABLE` at PC 0x0BF4 after [53]; update if branch code above it moves) with an index past entry 128
                        if matches!(instruction_to_execute.operation, Operation::LoadHalfUnsigned)
                            && self.pc[self.context_in_progress] == 0x0BFC
                            && self.register_file[self.context_in_progress * REGS_PER_CONTEXT + instruction_to_execute.sr1] > 256
                        {
                            let base = self.context_in_progress * REGS_PER_CONTEXT;
                            let ray = self.register_file[base] as u16;
                            let words: Vec<String> = (0..16).map(|i| format!("{:08X}", self.read_sram_word(&(ray + 4 * i)))).collect();
                            println!("BAD_START_INDEX core {} ctx {} cycle {} index*2 {} ray@{} [{}]", self.core_id, self.context_in_progress, self.cycle, self.register_file[base + instruction_to_execute.sr1], ray, words.join(" "));
                            let c = self.context_in_progress; // AI debug [44]: local queue headers + this context's recent PC history
                            let lq: Vec<u32> = [0x2AC4u16, 0x2AC8, 0x2ACC, 0x2AC4 + 1036, 0x2AC8 + 1036, 0x2ACC + 1036] /* LOCAL_RAY_QUEUE after [66]; update if branch data layout moves */.iter().map(|a| self.read_sram_word(a)).collect();
                            let hist: Vec<String> = (0..256).map(|i| { let (p, cy) = self.pc_hist[c * 256 + ((self.pc_hist_idx[c] + i) & 255)]; format!("{:04X}@{}", p, cy) }).collect();
                            println!("BAD_START_LQ core {} ctx {} even(h,t,c) {} {} {} odd(h,t,c) {} {} {}", self.core_id, c, lq[0], lq[1], lq[2] as i32, lq[3], lq[4], lq[5] as i32);
                            println!("BAD_START_HIST core {} ctx {} {}", self.core_id, c, hist.join(" "));
                        }
                        let value = match instruction_to_execute.operation {
                            Operation::LoadByteSigned => self.read_sram_byte_signed(&address),

                            Operation::LoadByteUnsigned => self.read_sram_byte_unsigned(&address),

                            Operation::LoadHalfSigned => self.read_sram_half_signed(&address),

                            Operation::LoadHalfUnsigned => self.read_sram_half_unsigned(&address),

                            Operation::LoadWord => self.read_sram_word(&address),

                            _ => unreachable!(),
                        };
                        self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                            + instruction_to_execute.dr] = value;

                        if debug_on()
                            && (core_in_list || cores_to_monitor.len() == 0)
                            && (*context_to_monitor == self.context_in_progress as i32
                                || *context_to_monitor < 0)
                        {
                            println!("Local Read from {:0x} - Value: {}", address, value);
                            if self.pc[self.context_in_progress] == 0x1514 {
                                println!("NODE_ID EXAMINED: {}", value);
                            }
                            if 0x1288 == self.pc[self.context_in_progress] {
                                let base =  self.register_file
                                        [self.context_in_progress * REGS_PER_CONTEXT + 1]
                                        as u16;
                                let read_word = |s: &mut Self, off: u16| {
                                    s.read_sram_word(&base.wrapping_add(off))
                                };
                                let read_half = |s: &mut Self, off: u16| {
                                    s.read_sram_half_unsigned(&base.wrapping_add(off))
                                };
                                let read_byte = |s: &mut Self, off: u16| {
                                    s.read_sram_byte_unsigned(&base.wrapping_add(off))
                                };

                                let x_min = f32::from_bits(read_word(self, 0));
                                let x_max = f32::from_bits(read_word(self, 4));
                                let y_min = f32::from_bits(read_word(self, 8));
                                let y_max = f32::from_bits(read_word(self, 12));
                                let z_min = f32::from_bits(read_word(self, 16));
                                let z_max = f32::from_bits(read_word(self, 20));

                                let left_child = read_half(self, 24) as u16;
                                let right_child = read_half(self, 26) as u16;
                                let parent = read_half(self, 28) as u16;
                                let core_owner = read_half(self, 30) as u16;

                                let is_right = read_byte(self, 32) as u8;
                                // pad bytes at 33, 34, 35 — skipped

                                let queue_low_bit_addr = read_word(self, 36);
                                let queue_high_bit_addr = read_half(self, 40) as u16;
                                let prev_index = read_half(self, 42) as u16;
                                let node_id = read_word(self, 44);

                                let is_leaf = left_child == 0 && right_child == 0;

                                println!(
                                    "AABB Node @ 0x{:04X} (ctx {})",
                                    base, self.context_in_progress
                                );
                                println!("  x range = [{:>12.6}, {:>12.6}]", x_min, x_max);
                                println!("  y range = [{:>12.6}, {:>12.6}]", y_min, y_max);
                                println!("  z range = [{:>12.6}, {:>12.6}]", z_min, z_max);
                                println!(
                                    "  left_child  = 0x{:04X}{}",
                                    left_child,
                                    if left_child == 0 { " (none)" } else { "" }
                                );
                                println!(
                                    "  right_child = 0x{:04X}{}",
                                    right_child,
                                    if right_child == 0 { " (none)" } else { "" }
                                );
                                println!("  parent      = 0x{:04X}", parent);
                                println!(
                                    "  core_owner  = 0x{:04X}{}",
                                    core_owner,
                                    if core_owner == 0xFFFF { " (none)" } else { "" }
                                );
                                println!("  is_right    = {}", is_right);
                                println!("  is_leaf     = {}", is_leaf);
                                println!("  queue_low_bit_addr  = 0x{:08X}", queue_low_bit_addr);
                                println!("  queue_high_bit_addr = 0x{:04X}", queue_high_bit_addr);
                                println!("  prev_index  = {}", prev_index);
                                println!("  node_id     = 0x{:08X} ({})", node_id, node_id);

                            }
                        }
                        self.pc[self.context_in_progress] += 4;
                    }

                    Operation::AtomicAdd => {
                        let address = self.register_file[instruction_to_execute.sr1
                            + self.context_in_progress * REGS_PER_CONTEXT]
                            as u32 as u16;
                        let old_val = self.read_sram_word(&address);
                        let increment = if instruction_to_execute.is_imm {
                            instruction_to_execute.imm_0
                        } else {
                            self.register_file[instruction_to_execute.sr2
                                + self.context_in_progress * REGS_PER_CONTEXT]
                        };
                        self.write_sram_word(old_val + increment, &address);
                        self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                            + instruction_to_execute.dr] = old_val;
                        if debug_on()
                            && (core_in_list || cores_to_monitor.is_empty())
                            && (*context_to_monitor == self.context_in_progress as i32
                                || *context_to_monitor < 0)
                        {
                            println!("Local Atomadd from {:0x} - Old Value: {}", address, old_val);
                            if self.pc[self.context_in_progress] == 0x1D90 {
                                println!("DFS ALLOC HERE");
                            }
                        }
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::BranchEq => {
                        if debug_on()
                            && (core_in_list || cores_to_monitor.len() == 0)
                            && (*context_to_monitor == self.context_in_progress as i32
                                || *context_to_monitor < 0)
                        {
                            if self.pc[self.context_in_progress] == 0x102C {
                                let base = self.register_file
                                    [self.context_in_progress * REGS_PER_CONTEXT]
                                    as u16;

                                let read_word = |s: &mut Self, off: u16| {
                                    s.read_sram_word(&base.wrapping_add(off))
                                };
                                let read_half = |s: &mut Self, off: u16| {
                                    s.read_sram_half_unsigned(&base.wrapping_add(off))
                                };
                                let read_byte = |s: &mut Self, off: u16| {
                                    s.read_sram_byte_unsigned(&base.wrapping_add(off))
                                };

                                let ox = f32::from_bits(read_word(self, 0));
                                let oy = f32::from_bits(read_word(self, 4));
                                let oz = f32::from_bits(read_word(self, 8));
                                let dx = f32::from_bits(read_word(self, 12));
                                let dy = f32::from_bits(read_word(self, 16));
                                let dz = f32::from_bits(read_word(self, 20));
                                let inv_dx = f32::from_bits(read_word(self, 24));
                                let inv_dy = f32::from_bits(read_word(self, 28));
                                let inv_dz = f32::from_bits(read_word(self, 32));
                                let t_max = f32::from_bits(read_word(self, 36));

                                let leaf_node_starting_point = read_word(self, 40);
                                let check_left = read_word(self, 44);
                                let check_right = read_word(self, 48);

                                let pix_x = read_half(self, 52) as u16;
                                let pix_y = read_half(self, 54) as u16;

                                let tri_index = read_word(self, 56);

                                let bounce_count = read_byte(self, 60) as u8;
                                let light_id = read_byte(self, 61) as u8;
                                let ray_depth = read_byte(self, 62) as u8;
                                let active_ray = read_byte(self, 63) as u8;

                                println!("Ray @ 0x{:04X} (ctx {})", base, self.context_in_progress);
                                println!(
                                    "  origin    = ({:>12.6}, {:>12.6}, {:>12.6})",
                                    ox, oy, oz
                                );
                                println!(
                                    "  direction = ({:>12.6}, {:>12.6}, {:>12.6})",
                                    dx, dy, dz
                                );
                                println!(
                                    "  inv_dir   = ({:>12.6}, {:>12.6}, {:>12.6})",
                                    inv_dx, inv_dy, inv_dz
                                );
                                println!("  t_max     = {}", t_max);
                                println!(
                                    "  leaf_node_starting_point = 0x{:08X}",
                                    leaf_node_starting_point
                                );
                                println!("  check_left  = 0x{:08X}", check_left);
                                println!("  check_right = 0x{:08X}", check_right);
                                println!("  pixel       = ({}, {})", pix_x, pix_y);
                                println!(
                                    "  tri_index   = 0x{:08X}{}",
                                    tri_index,
                                    if tri_index == 0xFFFF_FFFF {
                                        " (no hit)"
                                    } else {
                                        ""
                                    }
                                );
                                println!("  bounce_count = {}", bounce_count);
                                println!("  light_id     = {}", light_id);
                                println!("  ray_depth    = {}", ray_depth);
                                println!("  active_ray   = {}", active_ray);
                            }
                            if self.pc[self.context_in_progress] == 0x051C
                                || self.pc[self.context_in_progress] == 0x1E34
                            {
                                let base = if self.pc[self.context_in_progress] != 0x1E34 {
                                    self.register_file
                                        [self.context_in_progress * REGS_PER_CONTEXT + 1]
                                        as u16
                                } else {
                                    self.register_file
                                        [self.context_in_progress * REGS_PER_CONTEXT + 13]
                                        as u16
                                };

                                let read_word = |s: &mut Self, off: u16| {
                                    s.read_sram_word(&base.wrapping_add(off))
                                };
                                let read_half = |s: &mut Self, off: u16| {
                                    s.read_sram_half_unsigned(&base.wrapping_add(off))
                                };
                                let read_byte = |s: &mut Self, off: u16| {
                                    s.read_sram_byte_unsigned(&base.wrapping_add(off))
                                };

                                let x_min = f32::from_bits(read_word(self, 0));
                                let x_max = f32::from_bits(read_word(self, 4));
                                let y_min = f32::from_bits(read_word(self, 8));
                                let y_max = f32::from_bits(read_word(self, 12));
                                let z_min = f32::from_bits(read_word(self, 16));
                                let z_max = f32::from_bits(read_word(self, 20));

                                let left_child = read_half(self, 24) as u16;
                                let right_child = read_half(self, 26) as u16;
                                let parent = read_half(self, 28) as u16;
                                let core_owner = read_half(self, 30) as u16;

                                let is_right = read_byte(self, 32) as u8;
                                // pad bytes at 33, 34, 35 — skipped

                                let queue_low_bit_addr = read_word(self, 36);
                                let queue_high_bit_addr = read_half(self, 40) as u16;
                                let prev_index = read_half(self, 42) as u16;
                                let node_id = read_word(self, 44);

                                let is_leaf = left_child == 0 && right_child == 0;

                                println!(
                                    "AABB Node @ 0x{:04X} (ctx {})",
                                    base, self.context_in_progress
                                );
                                println!("  x range = [{:>12.6}, {:>12.6}]", x_min, x_max);
                                println!("  y range = [{:>12.6}, {:>12.6}]", y_min, y_max);
                                println!("  z range = [{:>12.6}, {:>12.6}]", z_min, z_max);
                                println!(
                                    "  left_child  = 0x{:04X}{}",
                                    left_child,
                                    if left_child == 0 { " (none)" } else { "" }
                                );
                                println!(
                                    "  right_child = 0x{:04X}{}",
                                    right_child,
                                    if right_child == 0 { " (none)" } else { "" }
                                );
                                println!("  parent      = 0x{:04X}", parent);
                                println!(
                                    "  core_owner  = 0x{:04X}{}",
                                    core_owner,
                                    if core_owner == 0xFFFF { " (none)" } else { "" }
                                );
                                println!("  is_right    = {}", is_right);
                                println!("  is_leaf     = {}", is_leaf);
                                println!("  queue_low_bit_addr  = 0x{:08X}", queue_low_bit_addr);
                                println!("  queue_high_bit_addr = 0x{:04X}", queue_high_bit_addr);
                                println!("  prev_index  = {}", prev_index);
                                println!("  node_id     = 0x{:08X} ({})", node_id, node_id);

                                if self.pc[self.context_in_progress] == 0x051C {
                                    let base = self.register_file
                                        [self.context_in_progress * REGS_PER_CONTEXT]
                                        as u16;

                                    let read_word = |s: &mut Self, off: u16| {
                                        s.read_sram_word(&base.wrapping_add(off))
                                    };
                                    let read_half = |s: &mut Self, off: u16| {
                                        s.read_sram_half_unsigned(&base.wrapping_add(off))
                                    };
                                    let read_byte = |s: &mut Self, off: u16| {
                                        s.read_sram_byte_unsigned(&base.wrapping_add(off))
                                    };

                                    let ox = f32::from_bits(read_word(self, 0));
                                    let oy = f32::from_bits(read_word(self, 4));
                                    let oz = f32::from_bits(read_word(self, 8));
                                    let dx = f32::from_bits(read_word(self, 12));
                                    let dy = f32::from_bits(read_word(self, 16));
                                    let dz = f32::from_bits(read_word(self, 20));
                                    let inv_dx = f32::from_bits(read_word(self, 24));
                                    let inv_dy = f32::from_bits(read_word(self, 28));
                                    let inv_dz = f32::from_bits(read_word(self, 32));
                                    let t_max = f32::from_bits(read_word(self, 36));

                                    let leaf_node_starting_point = read_word(self, 40);
                                    let check_left = read_word(self, 44);
                                    let check_right = read_word(self, 48);

                                    let pix_x = read_half(self, 52) as u16;
                                    let pix_y = read_half(self, 54) as u16;

                                    let tri_index = read_word(self, 56);

                                    let bounce_count = read_byte(self, 60) as u8;
                                    let light_id = read_byte(self, 61) as u8;
                                    let ray_depth = read_byte(self, 62) as u8;
                                    let active_ray = read_byte(self, 63) as u8;

                                    println!(
                                        "Ray @ 0x{:04X} (ctx {})",
                                        base, self.context_in_progress
                                    );
                                    println!(
                                        "  origin    = ({:>12.6}, {:>12.6}, {:>12.6})",
                                        ox, oy, oz
                                    );
                                    println!(
                                        "  direction = ({:>12.6}, {:>12.6}, {:>12.6})",
                                        dx, dy, dz
                                    );
                                    println!(
                                        "  inv_dir   = ({:>12.6}, {:>12.6}, {:>12.6})",
                                        inv_dx, inv_dy, inv_dz
                                    );
                                    println!("  t_max     = {}", t_max);
                                    println!(
                                        "  leaf_node_starting_point = 0x{:08X}",
                                        leaf_node_starting_point
                                    );
                                    println!("  check_left  = 0x{:08X}", check_left);
                                    println!("  check_right = 0x{:08X}", check_right);
                                    println!("  pixel       = ({}, {})", pix_x, pix_y);
                                    println!(
                                        "  tri_index   = 0x{:08X}{}",
                                        tri_index,
                                        if tri_index == 0xFFFF_FFFF {
                                            " (no hit)"
                                        } else {
                                            ""
                                        }
                                    );
                                    println!("  bounce_count = {}", bounce_count);
                                    println!("  light_id     = {}", light_id);
                                    println!("  ray_depth    = {}", ray_depth);
                                    println!("  active_ray   = {}", active_ray);
                                }
                            }
                        }
                        if self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                            + instruction_to_execute.dr]
                            == self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr1]
                        {
                            self.pc[self.context_in_progress] = instruction_to_execute.imm_0 as u16;
                            flush = !instruction_to_execute.branch_hint;
                        } else {
                            self.pc[self.context_in_progress] += 4;
                            flush = instruction_to_execute.branch_hint;
                        }
                    }
                    Operation::BranchNe => {
                        if self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                            + instruction_to_execute.dr]
                            != self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr1]
                        {
                            self.pc[self.context_in_progress] = instruction_to_execute.imm_0 as u16;
                            flush = !instruction_to_execute.branch_hint;
                        } else {
                            self.pc[self.context_in_progress] += 4;
                            flush = instruction_to_execute.branch_hint;
                        }
                    }
                    Operation::BranchLTE => {
                        let is_lt = self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                            + instruction_to_execute.dr] as i32
                            <= self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr1] as i32;
                        if is_lt {
                            self.pc[self.context_in_progress] = instruction_to_execute.imm_0 as u16;
                            flush = !instruction_to_execute.branch_hint;
                        } else {
                            self.pc[self.context_in_progress] += 4;
                            flush = instruction_to_execute.branch_hint;
                        }
                    }
                    Operation::BranchGT => {
                        let is_gt = self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                            + instruction_to_execute.dr] as i32
                            > self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr1] as i32;
                        if is_gt {
                            self.pc[self.context_in_progress] = instruction_to_execute.imm_0 as u16;
                            flush = !instruction_to_execute.branch_hint;
                        } else {
                            self.pc[self.context_in_progress] += 4;
                            flush = instruction_to_execute.branch_hint;
                        }
                    }
                    Operation::BranchGTU => {
                        let is_gt = self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                            + instruction_to_execute.dr]
                            > self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr1];
                        if is_gt {
                            self.pc[self.context_in_progress] = instruction_to_execute.imm_0 as u16;
                            flush = !instruction_to_execute.branch_hint;
                        } else {
                            self.pc[self.context_in_progress] += 4;
                            flush = instruction_to_execute.branch_hint;
                        }
                    }
                    Operation::BranchLTEU => {
                        let is_lt = self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                            + instruction_to_execute.dr]
                            <= self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr1];
                        if is_lt {
                            self.pc[self.context_in_progress] = instruction_to_execute.imm_0 as u16;
                            flush = !instruction_to_execute.branch_hint;
                        } else {
                            self.pc[self.context_in_progress] += 4;
                            flush = instruction_to_execute.branch_hint;
                        }
                    }
                    Operation::Jump => {
                        let temp = self.pc[self.context_in_progress] as u32 + 4;
                        self.pc[self.context_in_progress] = if instruction_to_execute.is_imm {
                            instruction_to_execute.imm_0 as u16
                        } else {
                            flush = true;
                            self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr2] as u16
                        };
                        self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                            + instruction_to_execute.dr] = temp;
                    }
                    Operation::BlockVal => {
                        let fifo_idx = if instruction_to_execute.imm_1 != 0 {
                            instruction_to_execute.imm_0 as usize
                        } else {
                            self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr1] as usize
                                & 0x3F
                        };
                        if fifo_idx >= NUM_NOC_PIPES {
                            self.dump_instruction(&self.decoded_instruction.unwrap());
                            panic!("BAD PIPE INDEX");
                        }
                        if let Some(val) = self.noc_recv_fifo[fifo_idx].pop() {
                            self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.dr] = val;
                            self.pc[self.context_in_progress] += 4;
                            println!("Core {} at context {} is clearing interrupt from mailbox pipe {}", self.core_id, self.context_in_progress ,fifo_idx);
                        } else {
                            switch_ctx = true;
                        }
                    }
                    Operation::NonBlockVal => {
                        let fifo_idx = if instruction_to_execute.imm_1 != 0 {
                            instruction_to_execute.imm_0 as usize
                        } else {
                            self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr1] as usize
                                & 0x3F
                        };

                        let fill = self.noc_recv_fifo[fifo_idx].len();

                        self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                            + instruction_to_execute.dr] = fill as u32;

                        self.pc[self.context_in_progress] += 4;

                        // Info about mailbox being checked
                        if debug_on()
                            && (core_in_list || cores_to_monitor.len() == 0)
                            && (*context_to_monitor == self.context_in_progress as i32
                                || *context_to_monitor < 0)
                        {
                            println!(
                                "Core {} at context {} is checking mailbox pipe {} - fill level is {}",
                                self.core_id, self.context_in_progress, fifo_idx, fill
                            );
                        }
                    }
                    Operation::Yield => {
                        switch_ctx = true;
                        if self.ctx_ownership >= 0 {
                            self.runnable[self.context_in_progress] = false;
                            assert!(
                                self.ctx_ownership as usize != self.context_in_progress,
                                "Dumb programmer"
                            );
                        } else {
                            let mut interrupt_pending = false;
                            let mut index = 0;
                            for fifo in &self.noc_recv_fifo {
                                if !fifo.is_empty()
                                    && self.interrupt_enable[self.context_in_progress][index]
                                {
                                    interrupt_pending = true;
                                    break;
                                }
                                index += 1;
                            }
                            if interrupt_pending {
                                self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                    + instruction_to_execute.dr] =
                                    self.pc[self.context_in_progress] as u32;
                                self.pc[self.context_in_progress] =
                                    (SRAM_SIZE - NUM_NOC_PIPES * 4 + index * 4) as u16;
                            } else {
                                self.pc[self.context_in_progress] += 4;
                            }
                        }
                    }
                    Operation::GetThreadOwnership => {
                        self.runnable[self.context_in_progress] = false;
                        let mut any_runnable = false;
                        if self.ctx_ownership < 0 {
                            self.ctx_ownership = self.context_in_progress as i8;
                        }
                        assert!(
                            self.ctx_ownership == self.context_in_progress as i8,
                            "ANOTHER Dumb programmer!"
                        );
                        for context in &self.runnable {
                            if *context {
                                any_runnable = true;
                            }
                        }
                        if !any_runnable {
                            self.pc[self.context_in_progress] += 4;
                        } else {
                            switch_ctx = true;
                        }
                    }
                    Operation::SetCtx => {
                        let mut cur_index = self.context_in_progress;
                        assert!(
                            instruction_to_execute.imm_0 <= REGS_PER_CONTEXT as u32,
                            "STUPID PROGRAMMER"
                        );
                        assert!(instruction_to_execute.imm_0 > 0, "STUPID PROGRAMMER");
                        for _ in 0..instruction_to_execute.imm_0 {
                            self.runnable[cur_index] = true;
                            cur_index = (cur_index + 1) % REGS_PER_CONTEXT;
                        }
                        while cur_index != self.context_in_progress {
                            self.runnable[cur_index] = false;
                            cur_index = (cur_index + 1) % REGS_PER_CONTEXT;
                        }
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::RelinquishOwnership => {
                        if self.ctx_ownership != self.context_in_progress as i8 {
                            println!("BAD CORE: {}", self.core_id);
                            self.dump_instruction(&self.decoded_instruction.unwrap());
                            println!(
                                "self.context_in_progress: {}, self.ctx_ownership: {}",
                                self.context_in_progress, self.ctx_ownership
                            );
                        }
                        assert!(
                            self.ctx_ownership == self.context_in_progress as i8,
                            "STUPID PROGRAMMER"
                        );
                        self.ctx_ownership = -1;
                        // switch_ctx = true;
                        self.pc[self.context_in_progress] += 4;
                        if instruction_to_execute.imm_1 != 0 {
                            for context in 0..CTX_CNT {
                                self.pc[context] = self.pc[self.context_in_progress];
                            }
                        }
                    }
                    Operation::EnableInterrupts => {
                        let pipe = if instruction_to_execute.imm_1 != 0 {
                            instruction_to_execute.imm_0 as usize
                        } else {
                            self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr2] as usize
                        };
                        assert!(
                            pipe < NUM_NOC_PIPES,
                            "IMM IS LESS THAN NUMBER OF NOC PIPES DUMMY"
                        );
                        self.interrupt_enable[self.context_in_progress][pipe] = true;
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::DisableInterrupts => {
                        let pipe = if instruction_to_execute.imm_1 != 0 {
                            instruction_to_execute.imm_0 as usize
                        } else {
                            self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr2] as usize
                        };
                        assert!(
                            pipe < NUM_NOC_PIPES,
                            "IMM IS LESS THAN NUMBER OF NOC PIPES DUMMY"
                        );
                        self.interrupt_enable[self.context_in_progress][pipe] = false;
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::SetMemoryBits => {
                        let temp = self.memory_bits[self.context_in_progress];

                        self.memory_bits[self.context_in_progress] =
                            self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr1];
                        self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                            + instruction_to_execute.dr] = temp;

                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::ReadSignedByteDram => {
                        long_latency_op = true;
                        let dram_address = (if instruction_to_execute.imm_1 != 0 {
                            instruction_to_execute.imm_0 as u16 as usize
                        } else {
                            (self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr1] as u32
                                + instruction_to_execute.imm_0) as usize
                        }) | (self.memory_bits[self.context_in_progress]
                            as usize)
                            << 32;
                        self.note_dram_pc(dram_address); // AI [129] debug
                        if self.top_bits_dram_stack != dram_address / DRAM_STACK_SIZE {
                            self.dram_bytes_read_far += 1;
                            let long_dram_request = LongDramRequest {
                                register_index: instruction_to_execute.dr
                                    + self.context_in_progress * REGS_PER_CONTEXT,
                                address: dram_address,
                                op: instruction_to_execute.operation,
                                value_to_write: 0,
                                core_id: self.core_id,
                                origin_stack: self.top_bits_dram_stack,
                                issue_cycle: mem.depart_far(self.cycle, crate::memory::MemKind::Read), // AI [128]/[131]: departure over this stack's outgoing link
                            };
                            if let Some(dram_request) = &self.dram_long_request {
                                let could_send = dram_request[dram_address / DRAM_STACK_SIZE]
                                    .send(long_dram_request);
                                assert!(
                                    could_send.is_ok(),
                                    "Failed to send Request between OS Threads"
                                );
                            }
                            let internal_long_dram_op = PipelineStage {
                                cycle_to_read: self.cycle + DRAM_LATENCY_FAR,
                                calculated_val: 0,
                                register_index: instruction_to_execute.dr
                                    + self.context_in_progress * REGS_PER_CONTEXT,
                            };
                            let _ = internal_long_dram_op; // AI [128]: no fixed-latency placeholder; the reply is tagged
                        } else {
                            self.dram_bytes_read_close += 1;
                            let value = dram[(dram_address % DRAM_STACK_SIZE) / 4];
                            let byte_offset = dram_address % 4;
                            let load_dispatch = PipelineStage {
                                cycle_to_read: self.cycle + DRAM_LATENCY_CLOSE,
                                calculated_val: ((value >> (byte_offset * 8)) & 0xFF) as i8 as i32
                                    as u32,
                                register_index: instruction_to_execute.dr
                                    + self.context_in_progress * REGS_PER_CONTEXT,
                            };
                            mem.submit_local(crate::memory::MemReq { arrival: self.cycle, addr: dram_address % DRAM_STACK_SIZE, kind: crate::memory::MemKind::Read, reply: Some(crate::memory::Reply { origin_stack: self.top_bits_dram_stack, core_id: self.core_id, register_index: load_dispatch.register_index, value: load_dispatch.calculated_val }) }, self.cycle); // AI [128]
                        }

                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::ReadUnsignedByteDram => {
                        long_latency_op = true;
                        let dram_address = (if instruction_to_execute.imm_1 != 0 {
                            instruction_to_execute.imm_0 as u16 as usize
                        } else {
                            (self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr1] as u32
                                + instruction_to_execute.imm_0) as usize
                        }) | (self.memory_bits[self.context_in_progress]
                            as usize)
                            << 32;
                        self.note_dram_pc(dram_address); // AI [129] debug
                        if self.top_bits_dram_stack != dram_address / DRAM_STACK_SIZE {
                            self.dram_bytes_read_far += 1;
                            let long_dram_request = LongDramRequest {
                                register_index: instruction_to_execute.dr
                                    + self.context_in_progress * REGS_PER_CONTEXT,
                                address: dram_address,
                                op: instruction_to_execute.operation,
                                value_to_write: 0,
                                core_id: self.core_id,
                                origin_stack: self.top_bits_dram_stack,
                                issue_cycle: mem.depart_far(self.cycle, crate::memory::MemKind::Read), // AI [128]/[131]: departure over this stack's outgoing link
                            };
                            if let Some(dram_request) = &self.dram_long_request {
                                let could_send = dram_request[dram_address / DRAM_STACK_SIZE]
                                    .send(long_dram_request);
                                assert!(
                                    could_send.is_ok(),
                                    "Failed to send Request between OS Threads"
                                );
                            }
                            let internal_long_dram_op = PipelineStage {
                                cycle_to_read: self.cycle + DRAM_LATENCY_FAR,
                                calculated_val: 0,
                                register_index: instruction_to_execute.dr
                                    + self.context_in_progress * REGS_PER_CONTEXT,
                            };
                            let _ = internal_long_dram_op; // AI [128]: no fixed-latency placeholder; the reply is tagged
                        } else {
                            self.dram_bytes_read_close += 1;
                            let value = dram[(dram_address % DRAM_STACK_SIZE) / 4];
                            let byte_offset = dram_address % 4;
                            let load_dispatch = PipelineStage {
                                cycle_to_read: self.cycle + DRAM_LATENCY_CLOSE,
                                calculated_val: ((value >> (byte_offset * 8)) & 0xFF) as u8 as u32,
                                register_index: instruction_to_execute.dr
                                    + self.context_in_progress * REGS_PER_CONTEXT,
                            };
                            mem.submit_local(crate::memory::MemReq { arrival: self.cycle, addr: dram_address % DRAM_STACK_SIZE, kind: crate::memory::MemKind::Read, reply: Some(crate::memory::Reply { origin_stack: self.top_bits_dram_stack, core_id: self.core_id, register_index: load_dispatch.register_index, value: load_dispatch.calculated_val }) }, self.cycle); // AI [128]
                        }
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::ReadSignedHalfDram => {
                        long_latency_op = true;
                        let dram_address = (if instruction_to_execute.imm_1 != 0 {
                            instruction_to_execute.imm_0 as u16 as usize
                        } else {
                            (self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr1] as u32
                                + instruction_to_execute.imm_0) as usize
                        }) | (self.memory_bits[self.context_in_progress]
                            as usize)
                            << 32;
                        assert!(
                            dram_address & 0x1 == 0,
                            "DRAM Half LOADS CAN'T BE UNALIGNED; PC: {:08X}, DRAM ADDRESS: {:08X}",
                            self.pc[self.context_in_progress],
                            dram_address
                        );
                        self.note_dram_pc(dram_address); // AI [129] debug
                        if self.top_bits_dram_stack != dram_address / DRAM_STACK_SIZE {
                            self.dram_bytes_read_far += 2;
                            let long_dram_request = LongDramRequest {
                                register_index: instruction_to_execute.dr
                                    + self.context_in_progress * REGS_PER_CONTEXT,
                                address: dram_address,
                                op: instruction_to_execute.operation,
                                value_to_write: 0,
                                core_id: self.core_id,
                                origin_stack: self.top_bits_dram_stack,
                                issue_cycle: mem.depart_far(self.cycle, crate::memory::MemKind::Read), // AI [128]/[131]: departure over this stack's outgoing link
                            };
                            if let Some(dram_request) = &self.dram_long_request {
                                let could_send = dram_request[dram_address / DRAM_STACK_SIZE]
                                    .send(long_dram_request);
                                assert!(
                                    could_send.is_ok(),
                                    "Failed to send Request between OS Threads"
                                );
                            }
                            let internal_long_dram_op = PipelineStage {
                                cycle_to_read: self.cycle + DRAM_LATENCY_FAR,
                                calculated_val: 0,
                                register_index: instruction_to_execute.dr
                                    + self.context_in_progress * REGS_PER_CONTEXT,
                            };
                            let _ = internal_long_dram_op; // AI [128]: no fixed-latency placeholder; the reply is tagged
                        } else {
                            self.dram_bytes_read_close += 2;
                            let value = dram[(dram_address % DRAM_STACK_SIZE) / 4];
                            let byte_offset = dram_address & 0x2; //will be either 0 or 2
                            let load_dispatch = PipelineStage {
                                cycle_to_read: self.cycle + DRAM_LATENCY_CLOSE,
                                calculated_val: ((value >> (byte_offset * 8)) & 0xFFFF) as i16
                                    as i32 as u32,
                                register_index: instruction_to_execute.dr
                                    + self.context_in_progress * REGS_PER_CONTEXT,
                            };
                            mem.submit_local(crate::memory::MemReq { arrival: self.cycle, addr: dram_address % DRAM_STACK_SIZE, kind: crate::memory::MemKind::Read, reply: Some(crate::memory::Reply { origin_stack: self.top_bits_dram_stack, core_id: self.core_id, register_index: load_dispatch.register_index, value: load_dispatch.calculated_val }) }, self.cycle); // AI [128]
                        }
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::ReadUnsignedHalfDram => {
                        long_latency_op = true;
                        let dram_address = (if instruction_to_execute.imm_1 != 0 {
                            instruction_to_execute.imm_0 as u16 as usize
                        } else {
                            (self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr1] as u32
                                + instruction_to_execute.imm_0) as usize
                        }) | (self.memory_bits[self.context_in_progress]
                            as usize)
                            << 32;
                        assert!(
                            dram_address & 0x1 == 0,
                            "DRAM Half LOADS CAN'T BE UNALIGNED; PC: {:08X}, DRAM ADDRESS: {:08X}",
                            self.pc[self.context_in_progress],
                            dram_address
                        );
                        self.note_dram_pc(dram_address); // AI [129] debug
                        if self.top_bits_dram_stack != dram_address / DRAM_STACK_SIZE {
                            self.dram_bytes_read_far += 2;
                            let long_dram_request = LongDramRequest {
                                register_index: instruction_to_execute.dr
                                    + self.context_in_progress * REGS_PER_CONTEXT,
                                address: dram_address,
                                op: instruction_to_execute.operation,
                                value_to_write: 0,
                                core_id: self.core_id,
                                origin_stack: self.top_bits_dram_stack,
                                issue_cycle: mem.depart_far(self.cycle, crate::memory::MemKind::Read), // AI [128]/[131]: departure over this stack's outgoing link
                            };
                            if let Some(dram_request) = &self.dram_long_request {
                                let could_send = dram_request[dram_address / DRAM_STACK_SIZE]
                                    .send(long_dram_request);
                                assert!(
                                    could_send.is_ok(),
                                    "Failed to send Request between OS Threads"
                                );
                            }
                            let internal_long_dram_op = PipelineStage {
                                cycle_to_read: self.cycle + DRAM_LATENCY_FAR,
                                calculated_val: 0,
                                register_index: instruction_to_execute.dr
                                    + self.context_in_progress * REGS_PER_CONTEXT,
                            };
                            let _ = internal_long_dram_op; // AI [128]: no fixed-latency placeholder; the reply is tagged
                        } else {
                            self.dram_bytes_read_close += 2;
                            let value = dram[(dram_address % DRAM_STACK_SIZE) / 4];

                            let byte_offset = dram_address & 0x2; //will be either 0 or 2
                            let load_dispatch = PipelineStage {
                                cycle_to_read: self.cycle + DRAM_LATENCY_CLOSE,
                                calculated_val: ((value >> (byte_offset * 8)) & 0xFFFF) as u16
                                    as u32,
                                register_index: instruction_to_execute.dr
                                    + self.context_in_progress * REGS_PER_CONTEXT,
                            };
                            mem.submit_local(crate::memory::MemReq { arrival: self.cycle, addr: dram_address % DRAM_STACK_SIZE, kind: crate::memory::MemKind::Read, reply: Some(crate::memory::Reply { origin_stack: self.top_bits_dram_stack, core_id: self.core_id, register_index: load_dispatch.register_index, value: load_dispatch.calculated_val }) }, self.cycle); // AI [128]
                        }
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::ReadWordDram => {
                        long_latency_op = true;
                        let dram_address = (if instruction_to_execute.imm_1 != 0 {
                            instruction_to_execute.imm_0 as u16 as usize
                        } else {
                            (self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr1] as u32
                                + instruction_to_execute.imm_0) as usize
                        }) | (self.memory_bits[self.context_in_progress]
                            as usize)
                            << 32;
                        assert!(
                            dram_address & 0x3 == 0,
                            "DRAM Word LOADS CAN'T BE UNALIGNED; PC: {:08X}, DRAM ADDRESS: {:08X}",
                            self.pc[self.context_in_progress],
                            dram_address
                        );
                        if debug_on()
                            && (core_in_list || cores_to_monitor.len() == 0)
                            && (*context_to_monitor == self.context_in_progress as i32
                                || *context_to_monitor < 0)
                        {
                            println!("address: {}", dram_address);
                        }
                        // println!("DRAM ADDRESS FOR CORE {}: {:08X}", self.core_id, dram_address);
                        self.note_dram_pc(dram_address); // AI [129] debug
                        if self.top_bits_dram_stack != dram_address / DRAM_STACK_SIZE {
                            self.dram_bytes_read_far += 4;
                            let long_dram_request = LongDramRequest {
                                register_index: instruction_to_execute.dr
                                    + self.context_in_progress * REGS_PER_CONTEXT,
                                address: dram_address,
                                op: instruction_to_execute.operation,
                                value_to_write: 0,
                                core_id: self.core_id,
                                origin_stack: self.top_bits_dram_stack,
                                issue_cycle: mem.depart_far(self.cycle, crate::memory::MemKind::Read), // AI [128]/[131]: departure over this stack's outgoing link
                            };
                            if let Some(dram_request) = &self.dram_long_request {
                                let could_send = dram_request[dram_address / DRAM_STACK_SIZE]
                                    .send(long_dram_request);
                                assert!(
                                    could_send.is_ok(),
                                    "Failed to send Request between OS Threads"
                                );
                            }
                            let internal_long_dram_op = PipelineStage {
                                cycle_to_read: self.cycle + DRAM_LATENCY_FAR,
                                calculated_val: 0,
                                register_index: instruction_to_execute.dr
                                    + self.context_in_progress * REGS_PER_CONTEXT,
                            };
                            let _ = internal_long_dram_op; // AI [128]: no fixed-latency placeholder; the reply is tagged
                        } else {
                            self.dram_bytes_read_close += 4;
                            let value = dram[(dram_address % DRAM_STACK_SIZE) / 4];
                            let load_dispatch = PipelineStage {
                                cycle_to_read: self.cycle + DRAM_LATENCY_CLOSE,
                                calculated_val: value,
                                register_index: instruction_to_execute.dr
                                    + self.context_in_progress * REGS_PER_CONTEXT,
                            };
                            mem.submit_local(crate::memory::MemReq { arrival: self.cycle, addr: dram_address % DRAM_STACK_SIZE, kind: crate::memory::MemKind::Read, reply: Some(crate::memory::Reply { origin_stack: self.top_bits_dram_stack, core_id: self.core_id, register_index: load_dispatch.register_index, value: load_dispatch.calculated_val }) }, self.cycle); // AI [128]
                            if debug_on()
                                && (core_in_list || cores_to_monitor.len() == 0)
                                && (*context_to_monitor == self.context_in_progress as i32
                                    || *context_to_monitor < 0)
                            {
                                println!("Read to {:0x} - Value: {}", dram_address, value);
                            }
                        }
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::StoreWordDram => {
                        let dram_address = (if instruction_to_execute.imm_1 != 0 {
                            instruction_to_execute.imm_0 as u16 as usize
                        } else {
                            (self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr1] as u32
                                + instruction_to_execute.imm_0) as usize
                        }) | (self.memory_bits[self.context_in_progress]
                            as usize)
                            << 32;
                        assert!(
                            dram_address & 0x3 == 0,
                            "DRAM Word STORES CAN'T BE UNALIGNED; PC: {:08X}, DRAM ADDRESS: {:08X}, CORE {}",
                            self.pc[self.context_in_progress],
                            dram_address,
                            self.core_id
                        );

                        let value_to_store = self.register_file[self.context_in_progress
                            * REGS_PER_CONTEXT
                            + instruction_to_execute.dr];
                        self.note_dram_pc(dram_address); // AI [129] debug
                        if self.top_bits_dram_stack != dram_address / DRAM_STACK_SIZE {
                            self.dram_bytes_wrote_far += 4;
                            let long_dram_request = LongDramRequest {
                                register_index: 0,
                                address: dram_address,
                                op: instruction_to_execute.operation,
                                value_to_write: value_to_store,
                                core_id: self.core_id,
                                origin_stack: self.top_bits_dram_stack,
                                issue_cycle: mem.depart_far(self.cycle, crate::memory::MemKind::Write), // AI [128]/[131]: departure over this stack's outgoing link
                            };
                            if let Some(dram_request) = &self.dram_long_request {
                                let could_send = dram_request[dram_address / DRAM_STACK_SIZE]
                                    .send(long_dram_request);
                                assert!(
                                    could_send.is_ok(),
                                    "Failed to send Request between OS Threads"
                                );
                            }
                        } else {
                            self.dram_bytes_wrote_close += 4;
                            dram[(dram_address % DRAM_STACK_SIZE) / 4] = value_to_store;
                            mem.submit_local(crate::memory::MemReq { arrival: self.cycle, addr: dram_address % DRAM_STACK_SIZE, kind: crate::memory::MemKind::Write, reply: None }, self.cycle); // AI [128]
                        }
                        self.pc[self.context_in_progress] += 4;



                    }
                    Operation::StoreHalfDram => {
                        let dram_address = (if instruction_to_execute.imm_1 != 0 {
                            instruction_to_execute.imm_0 as u16 as usize
                        } else {
                            (self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr1] as u32
                                + instruction_to_execute.imm_0) as usize
                        }) | (self.memory_bits[self.context_in_progress]
                            as usize)
                            << 32;
                        assert!(
                            dram_address & 0x1 == 0,
                            "DRAM Half STORES CAN'T BE UNALIGNED; PC: {:08X}, DRAM ADDRESS: {:08X}, CORE {}",
                            self.pc[self.context_in_progress],
                            dram_address,
                            self.core_id
                        );
                        let value_to_store = self.register_file[self.context_in_progress
                            * REGS_PER_CONTEXT
                            + instruction_to_execute.dr]
                            & 0xFFFF;
                        self.note_dram_pc(dram_address); // AI [129] debug
                        if self.top_bits_dram_stack != dram_address / DRAM_STACK_SIZE {
                            self.dram_bytes_wrote_far += 2;
                            let long_dram_request = LongDramRequest {
                                register_index: 0,
                                address: dram_address,
                                op: instruction_to_execute.operation,
                                value_to_write: value_to_store,
                                core_id: self.core_id,
                                origin_stack: self.top_bits_dram_stack,
                                issue_cycle: mem.depart_far(self.cycle, crate::memory::MemKind::Write), // AI [128]/[131]: departure over this stack's outgoing link
                            };
                            if let Some(dram_request) = &self.dram_long_request {
                                let could_send = dram_request[dram_address / DRAM_STACK_SIZE]
                                    .send(long_dram_request);
                                assert!(
                                    could_send.is_ok(),
                                    "Failed to send Request between OS Threads"
                                );
                            }
                        } else {
                            self.dram_bytes_wrote_close += 2;
                            let old_value = dram[(dram_address % DRAM_STACK_SIZE) / 4];
                            let byte_offset = dram_address & 0x2;
                            let mut value_to_store = (value_to_store as u32) << (byte_offset * 8);
                            value_to_store =
                                (old_value & !(0xFFFF << (byte_offset * 8))) | value_to_store;
                            dram[(dram_address % DRAM_STACK_SIZE) / 4] = value_to_store;
                            mem.submit_local(crate::memory::MemReq { arrival: self.cycle, addr: dram_address % DRAM_STACK_SIZE, kind: crate::memory::MemKind::Write, reply: None }, self.cycle); // AI [128]
                        }
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::StoreByteDram => {
                        let dram_address = (if instruction_to_execute.imm_1 != 0 {
                            instruction_to_execute.imm_0 as u16 as usize
                        } else {
                            (self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr1] as u32
                                + instruction_to_execute.imm_0) as usize
                        }) | (self.memory_bits[self.context_in_progress]
                            as usize)
                            << 32;
                        let value_to_store = self.register_file[self.context_in_progress
                            * REGS_PER_CONTEXT
                            + instruction_to_execute.dr]
                            & 0xFF;
                        self.note_dram_pc(dram_address); // AI [129] debug
                        if self.top_bits_dram_stack != dram_address / DRAM_STACK_SIZE {
                            self.dram_bytes_wrote_far += 1;
                            let long_dram_request = LongDramRequest {
                                register_index: 0,
                                address: dram_address,
                                op: instruction_to_execute.operation,
                                value_to_write: value_to_store,
                                core_id: self.core_id,
                                origin_stack: self.top_bits_dram_stack,
                                issue_cycle: mem.depart_far(self.cycle, crate::memory::MemKind::Write), // AI [128]/[131]: departure over this stack's outgoing link
                            };
                            if let Some(dram_request) = &self.dram_long_request {
                                let could_send = dram_request[dram_address / DRAM_STACK_SIZE]
                                    .send(long_dram_request);
                                assert!(
                                    could_send.is_ok(),
                                    "Failed to send Request between OS Threads"
                                );
                            }
                        } else {
                            self.dram_bytes_wrote_close += 1;
                            let old_value = dram[(dram_address % DRAM_STACK_SIZE) / 4];
                            let byte_offset = dram_address & 0x3;
                            let mut value_to_store = (value_to_store as u32) << (byte_offset * 8);
                            value_to_store =
                                (old_value & !(0xFF << (byte_offset * 8))) | value_to_store;
                            dram[(dram_address % DRAM_STACK_SIZE) / 4] = value_to_store;
                            mem.submit_local(crate::memory::MemReq { arrival: self.cycle, addr: dram_address % DRAM_STACK_SIZE, kind: crate::memory::MemKind::Write, reply: None }, self.cycle); // AI [128]
                        }
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::AtomicAddDram => {
                        long_latency_op = true;
                        let dram_address =
                            self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr1] as usize
                                | (self.memory_bits[self.context_in_progress] as usize) << 32;
                        if debug_on()
                            && (core_in_list || cores_to_monitor.is_empty())
                            && (*context_to_monitor == self.context_in_progress as i32
                                || *context_to_monitor < 0)
                        {
                            println!("Global Atomadd from {:0x}", dram_address);
                        }
                        if dram_address == 168_000_000 {
                            /* This DRAM address should be RAYS-COMPLETED, need to know info about what core completes it */
                            println!("CORE {} COMPLETED A RAY! Context: {}, Cycle: {}", self.core_id, self.context_in_progress, self.cycle);
                        }
                        let value_to_store = if instruction_to_execute.is_imm {
                            instruction_to_execute.imm_0
                        } else {
                            self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                                + instruction_to_execute.sr2]
                        };
                        // AI debug [40]: tally every atomic add to the watched queue-count word, keyed by (core, pc)
                        if dram_address == QCNT_WATCH_ADDR {
                            let mut m = QCNT_LOG.get_or_init(|| std::sync::Mutex::new(std::collections::BTreeMap::new())).lock().unwrap();
                            let e = m.entry((self.core_id, self.pc[self.context_in_progress])).or_insert((0i64, 0u64));
                            e.0 += value_to_store as i32 as i64;
                            e.1 += 1;
                        }
                        assert!(
                            dram_address & 0x3 == 0,
                            "DRAM Word LOADS CAN'T BE UNALIGNED; PC: {:08X}, DRAM ADDRESS: {:08X}, CORE {}",
                            self.pc[self.context_in_progress],
                            dram_address,
                            self.core_id
                        );
                        self.note_dram_pc(dram_address); // AI [129] debug
                        if self.top_bits_dram_stack != dram_address / DRAM_STACK_SIZE {
                            self.dram_bytes_wrote_far += 4;
                            self.dram_bytes_read_far += 4;
                            let long_dram_request = LongDramRequest {
                                register_index: instruction_to_execute.dr
                                    + self.context_in_progress * REGS_PER_CONTEXT,
                                address: dram_address,
                                op: instruction_to_execute.operation,
                                value_to_write: value_to_store,
                                core_id: self.core_id,
                                origin_stack: self.top_bits_dram_stack,
                                issue_cycle: mem.depart_far(self.cycle, crate::memory::MemKind::Atomic), // AI [128]/[131]: departure over this stack's outgoing link
                            };
                            if let Some(dram_request) = &self.dram_long_request {
                                let could_send = dram_request[dram_address / DRAM_STACK_SIZE]
                                    .send(long_dram_request);
                                assert!(
                                    could_send.is_ok(),
                                    "Failed to send Request between OS Threads"
                                );
                            }
                            let internal_long_dram_op = PipelineStage {
                                cycle_to_read: self.cycle + DRAM_LATENCY_FAR,
                                calculated_val: 0,
                                register_index: instruction_to_execute.dr
                                    + self.context_in_progress * REGS_PER_CONTEXT,
                            };
                            let _ = internal_long_dram_op; // AI [128]: no fixed-latency placeholder; the reply is tagged
                        } else {
                            self.dram_bytes_wrote_close += 4;
                            self.dram_bytes_read_close += 4;
                            let old_value = dram[(dram_address % DRAM_STACK_SIZE) / 4];
                            dram[(dram_address % DRAM_STACK_SIZE) / 4] = old_value + value_to_store;
                            let load_dispatch = PipelineStage {
                                cycle_to_read: self.cycle + DRAM_LATENCY_CLOSE,
                                calculated_val: old_value,
                                register_index: instruction_to_execute.dr
                                    + self.context_in_progress * REGS_PER_CONTEXT,
                            };
                            mem.submit_local(crate::memory::MemReq { arrival: self.cycle, addr: dram_address % DRAM_STACK_SIZE, kind: crate::memory::MemKind::Atomic, reply: Some(crate::memory::Reply { origin_stack: self.top_bits_dram_stack, core_id: self.core_id, register_index: load_dispatch.register_index, value: load_dispatch.calculated_val }) }, self.cycle); // AI [128]
                        }
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::SendFlit => {
                        let full_address = self.register_file[self.context_in_progress
                            * REGS_PER_CONTEXT
                            + instruction_to_execute.sr1];
                        let value_to_send = self.register_file[self.context_in_progress
                            * REGS_PER_CONTEXT
                            + instruction_to_execute.dr];

                        // let mailbox_bits = (NUM_NOC_PIPES as u32).trailing_zeros();
                        let mailbox_mask = (NUM_NOC_PIPES as u32) - 1;

                        let (core_address, mailbox_index) = if instruction_to_execute.imm_1 != 0 {
                            (full_address, instruction_to_execute.imm_0 as u32)
                        } else {
                            (full_address >> 6, full_address & mailbox_mask)
                        };

                        let outgoing_flit = Flit {
                            destination_x: (core_address % (CORES_IN_X * CORES_IN_X_STACK) as u32)
                                as u16,
                            destination_y: (core_address / (CORES_IN_X * CORES_IN_X_STACK) as u32)
                                as u16,
                            mailbox_id: mailbox_index as u16,
                            value_to_send,
                            cycle_to_read: self.cycle + 1,
                            origin_x: self.x_dim,
                            origin_y: self.y_dim,
                            src_ctx: self.context_in_progress as u8, // AI debug [153]
                            src_isb: (self.read_sram_word(&0x38u16) != 0) as u8,
                            src_pc: self.pc[self.context_in_progress] as u16,
                            sent_cycle: self.cycle,
                        };
                        /* Rejection Flits -> top 8 its of the 32 bit value isn't 5*/
                        // if (mailbox_index as u16 == 33 || mailbox_index as u16 == 13 || mailbox_index as u16 == 29) {
                        // if (value_to_send >> 24) & 7 != 5 {
                        //     println!("Core {} at context {} is sending a flit with value {:08X} that will reject the incoming value from the receiver. Flit destination: ({}, {}), Mailbox: {}, Cycle: {}", self.core_id, self.context_in_progress, value_to_send, outgoing_flit.destination_x, outgoing_flit.destination_y, outgoing_flit.mailbox_id, self.cycle);
                        // }
                        // }

                        self.flits_sent += 1;
                        self.flit_sent_manhattan_distance_traversed +=
                            (outgoing_flit.origin_x as i64 - outgoing_flit.destination_x as i64)
                                .abs() as usize
                                + (outgoing_flit.origin_y as i64
                                    - outgoing_flit.destination_y as i64)
                                    .abs() as usize;
                        if self.output_noc_send.is_full_for(outgoing_flit.mailbox_id) {
                            switch_ctx = true;
                            // println!("Core {} at context {} is trying to send a flit but the output buffer is full. Flit destination: ({}, {}), Mailbox: {}, Value: {}, Cycle: {}", self.core_id, self.context_in_progress, outgoing_flit.destination_x, outgoing_flit.destination_y, outgoing_flit.mailbox_id, outgoing_flit.value_to_send, self.cycle);
                        } else {
                            let _ = self.output_noc_send.push(outgoing_flit.clone());
                            self.pc[self.context_in_progress] += 4;
                            // AI debug [153]: a ray ACK (5 << 24 | my core * 16 + ctx, to a response mailbox 16-31) promises 16 words on my
                            //   data mailbox ctx; a NoC-clone GO (0xC0000000 | id) means a geometry stream on my pipe 0.
                            if (16..32).contains(&mailbox_index) {
                                if value_to_send >> 24 == 5 { self.data_expect[(value_to_send & 0xF) as usize] += 16; self.ack_to[(value_to_send & 0xF) as usize] = (core_address as u16, self.cycle); }
                                if value_to_send >> 30 == 3 { self.clone_go_cycle = self.cycle; }
                            }
                            // AI debug [156]: sender side of the ray handshake. A context sends one request on 32/33 and must get exactly one
                            //   reply (ACK 5 / reject 7 / wrong core 8 / router auto-reject) on 16 + ctx from that same core.
                            if mailbox_index == 32 || mailbox_index == 33 {
                                let c = self.context_in_progress;
                                if self.req_pending[c].0 != 0xFFFF && HS_N.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 3000 {
                                    println!("HS REQ_OVERWRITE core {} ctx {} pc 0x{:04X} new dest {} cycle {} | old dest {} cycle {} word 0x{:08X}", self.core_id, c, self.pc[c].wrapping_sub(4), core_address, self.cycle, self.req_pending[c].0, self.req_pending[c].1, self.req_pending[c].2);
                                }
                                self.req_pending[c] = (core_address as u16, self.cycle, value_to_send);
                                if self.ack_recv[c].1 != 0 && HS_N.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 3000 { // AI debug [157]
                                    println!("HS STREAM_ABANDONED core {} ctx {} pc 0x{:04X} cycle {} new request to core {} | ack 0x{:08X} at {} words left {}", self.core_id, self.context_in_progress, self.pc[self.context_in_progress].wrapping_sub(4), self.cycle, core_address, self.ack_recv[c].0, self.ack_recv[c].2, self.ack_recv[c].1);
                                    self.hs_dump(c, "STREAM_ABANDONED"); // AI debug [158]
                                }
                            }
                            if mailbox_index < 16 { // AI debug [157]: sender side of a ray stream: every data word must follow an ACK from that core / pipe
                                let c = self.context_in_progress;
                                let a = self.ack_recv[c];
                                let (ack_core, ack_pipe) = ((a.0 >> 4) & 0x1FFF, a.0 & 0xF);
                                if a.1 > 0 && ack_core == core_address && ack_pipe == mailbox_index {
                                    self.ack_recv[c].1 -= 1;
                                } else if mailbox_index != 0 && HS_N.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 3000 {
                                    println!("HS SEND_NO_ACK core {} ctx {} pc 0x{:04X} cycle {} to core {} pipe {} value 0x{:08X} | last ack 0x{:08X} (core {} pipe {}) at {} words left {}",
                                        self.core_id, c, self.pc[c].wrapping_sub(4), self.cycle, core_address, mailbox_index, value_to_send, a.0, ack_core, ack_pipe, a.2, a.1);
                                    self.hs_dump(c, "SEND_NO_ACK"); // AI debug [158]
                                }
                            }
                        }
                        // if debug_on()
                        //     && (core_in_list || cores_to_monitor.len() == 0)
                        //     && (*context_to_monitor == self.context_in_progress as i32
                        //         || *context_to_monitor < 0)
                        // {
                            // println!("SENT FLIT: CORE: {}, VALUE: {}, MAILBOX: {}", 
                            //     outgoing_flit.destination_x + outgoing_flit.destination_y * (CORES_IN_X * CORES_IN_X_STACK), 
                            //     outgoing_flit.value_to_send, outgoing_flit.mailbox_id
                            // );
                        // }


                    }
                    Operation::GetLowClock => {
                        self.register_file[self.context_in_progress * REGS_PER_CONTEXT
                            + instruction_to_execute.dr] = self.cycle as u32;
                        self.pc[self.context_in_progress] += 4;
                    }
                    Operation::SwitchCtx => {
                        switch_ctx = true;
                        self.pc[self.context_in_progress] += 4;
                    }
                }
            } else {
                while self.core_busy.len() <= self.cycle as usize / NOC_UTIL_EPOCH_LEN {
                    self.core_busy.push(0);
                }
                self.core_busy[self.cycle as usize / NOC_UTIL_EPOCH_LEN] += 1
            }
            self.register_file
                [REGS_PER_CONTEXT * self.context_in_progress + REGS_PER_CONTEXT - 1] =
                (CTX_CNT * self.core_id as usize + self.context_in_progress) as u32;
            if long_latency_op && instruction_to_execute.dr != REGS_PER_CONTEXT - 1 {
                self.register_ready
                    [REGS_PER_CONTEXT * self.context_in_progress + instruction_to_execute.dr] =
                    false;
            }
            if switch_ctx {
                let mut next_ctx = None;
                let mut search_idx = (self.context_in_progress + 1) % CTX_CNT;
                while search_idx != self.context_in_progress {
                    if self.runnable[search_idx] {
                        next_ctx = Some(search_idx);
                        break;
                    }
                    search_idx = (search_idx + 1) % CTX_CNT;
                }
                self.context_in_progress = match next_ctx {
                    Some(idx) => idx,
                    None => {
                        if self.ctx_ownership == -1 {
                            self.context_in_progress
                        } else {
                            self.ctx_ownership.try_into().expect("There was no owner")
                        }
                    }
                };
                flush = true;
            }
        }
        let next_fetched_value: Option<u32>;
        let next_fetch_pc: Option<u16>;
        let next_decoded: Option<DecodedInstruction>;

        if !flush {
            match (self.fetched_value, self.fetch_pc) {
                (Some(word), Some(pc)) => {
                    next_decoded = Some(decode_instruction(word, pc));
                }
                (None, None) => {
                    next_decoded = None;
                }
                _ => {
                    panic!(
                        "FETCH/PC PAIRING BROKEN: fetched_value and fetch_pc must be both Some or both None"
                    );
                }
            }
        } else {
            next_decoded = None;
        }

        let next_req_pc: u16 = if flush {
            self.pc[self.context_in_progress]
        } else if let Some(instr) = &next_decoded {
            let is_control = matches!(
                instr.operation,
                Operation::BranchNe
                    | Operation::BranchEq
                    | Operation::BranchGT
                    | Operation::BranchLTE
                    | Operation::BranchLTEU
                    | Operation::BranchGTU
            );

            if (is_control && instr.branch_hint)
                || (instr.operation == Operation::Jump && instr.is_imm)
            {
                instr.imm_0 as u16
            } else {
                (instr.pc as u16).wrapping_add(4)
            }
        } else {
            self.pc[self.context_in_progress]
        };

        next_fetched_value = Some(self.read_sram_word(&next_req_pc));
        next_fetch_pc = Some(next_req_pc);

        self.fetched_value = next_fetched_value;
        self.fetch_pc = next_fetch_pc;

        self.decoded_instruction = next_decoded;

        if !self.cyc_ring.is_empty() { // AI debug [159]: no instruction issued this cycle -> record the context in progress and its pc, issued = 0
            let c = self.context_in_progress;
            let e = if self.cyc_rec != 0 { self.cyc_rec } else { (self.pc[c] as u32) | ((c as u32) << 16) | (1 << 21) };
            let m = self.cyc_ring.len() - 1;
            self.cyc_ring[(self.cycle as usize) & m] = e;
            self.cyc_rec = 0;
        }
        self.cycle += 1;
    }
}
