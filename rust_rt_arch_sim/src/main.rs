use crate::auto_gen_code::get_init_vector;
use crate::core::{
    BidirectionalNoc, CORES_IN_X, CORES_IN_Y, Core, debug_on, DRAM_STACK_SIZE, Feeder, LongDramOp, LongDramRequest, NOC_FIFO_LATENCY, NOC_FIFO_SIZE, Operation, PrioritizedFlitQueue, SpscQueue
};
use crate::matrices::{MAT_A, MAT_B, MAT_C};
use crate::parse_bvh::{QPoint, assemble_tree, read_indices, read_nodes, read_triangles, subtree_leaf_size};
pub mod auto_gen_code;
pub mod core;
pub mod matrices;
pub mod memory; // AI [128]: per-stack cache + DRAM timing model
pub mod parse_bvh;
use half::f16;
use hashbrown::{HashMap, HashSet};
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Barrier};
use std::{io, thread};

use ndarray::{Array2, Array3};
use ndarray_npy::write_npy;
use std::fs::create_dir_all;

const CORES_IN_X_STACK: u16 = 4;
const CORES_IN_Y_STACK: u16 = 2;
const PRINT_STATS: bool = true;

struct Stack {
    cores: Vec<Core>,
    dram_stack: Vec<u32>,
    service_other_stack: Receiver<LongDramRequest>,
    return_result_to_stack: Vec<Sender<LongDramOp>>,
    receive_dram_result_from_stack: Receiver<LongDramOp>,
    forward_dram_result_to_core: Vec<Feeder<LongDramOp>>,
    core_hash: HashMap<u32, usize>,
    mem: crate::memory::MemSystem, // AI [128]
    local_read: usize,
    local_write: usize,
    foreign_read: usize,
    foreign_write: usize,
}

fn assemble_stacks() -> Vec<Stack> {
    let mut mesh: Vec<Vec<Core>> = Vec::new();
    let mut dram_inputs_to_stack: Vec<Vec<Feeder<LongDramOp>>> = vec![];
    for _ in 0..CORES_IN_Y * CORES_IN_Y_STACK {
        mesh.push(vec![]);
    }
    println!("Assembling mesh of cores...");
    for y_stack in 0..CORES_IN_Y_STACK {
        for x_stack in 0..CORES_IN_X_STACK {
            dram_inputs_to_stack.push(vec![]);
            for y in 0..CORES_IN_Y {
                for x in 0..CORES_IN_X {
                    let y_index = y_stack * CORES_IN_Y + y;
                    let x_index = x_stack * CORES_IN_X + x;
                    let core_index = y_index * CORES_IN_X * CORES_IN_X_STACK + x_index;
                    let dram_top_bits = (y_stack * CORES_IN_X_STACK + x_stack) as usize;
                    mesh[y_index as usize].push(Core::new(
                        core_index as u32,
                        x_index,
                        y_index,
                        dram_top_bits,
                    ));
                }
            }
        }
    }
    println!("Cores assembled.");
    let mut far_dram_receivers: Vec<Receiver<LongDramRequest>> = Vec::new();
    let mut far_dram_senders: Vec<Sender<LongDramRequest>> = Vec::new();

    for _i in 0..CORES_IN_Y_STACK * CORES_IN_X_STACK {
        for _j in 0..CORES_IN_Y_STACK * CORES_IN_X_STACK {
            let (sender, receiver) = std::sync::mpsc::channel();
            far_dram_receivers.push(receiver);
            far_dram_senders.push(sender);
        }
    }

    println!("Organized far DRAM channels.");
    for y_stack in 0..CORES_IN_Y_STACK {
        for x_stack in 0..CORES_IN_X_STACK {
            for y in 0..CORES_IN_Y {
                for x in 0..CORES_IN_X {
                    let y_index = y_stack * CORES_IN_Y + y;
                    let x_index = x_stack * CORES_IN_X + x;
                    mesh[y_index as usize][x_index as usize]
                        .give_far_dram(far_dram_senders.clone());
                }
            }
        }
    }
    println!("Given far DRAM channels to cores.");
    for y in 0..CORES_IN_Y * CORES_IN_Y_STACK {
        for x in 0..CORES_IN_X * CORES_IN_X_STACK - 1 {
            println!(
                "INIT HORIZONTAL NOC BETWEEN ({}, {}) AND ({}, {})",
                x,
                y,
                x + 1,
                y
            );
            let rightwards = PrioritizedFlitQueue::new(NOC_FIFO_SIZE);
            let leftwards = PrioritizedFlitQueue::new(NOC_FIFO_SIZE);
            let (rightwards_feeder, rightwards_eater) = rightwards.split();
            let (leftwards_feeder, leftwards_eater) = leftwards.split();
            let right_side =
                BidirectionalNoc::new(rightwards_eater, leftwards_feeder, NOC_FIFO_LATENCY);
            let left_side =
                BidirectionalNoc::new(leftwards_eater, rightwards_feeder, NOC_FIFO_LATENCY);
            mesh[y as usize][x as usize].give_right_noc(right_side);
            mesh[y as usize][(x + 1) as usize].give_left_noc(left_side);
        }
    }
    println!("Horizontal NOCs connected.");
    for x in 0..CORES_IN_X * CORES_IN_X_STACK {
        for y in 0..CORES_IN_Y * CORES_IN_Y_STACK - 1 {
            println!(
                "INIT VERTICAL NOC BETWEEN ({}, {}) AND ({}, {})",
                x,
                y,
                x,
                y + 1
            );
            let upwards = PrioritizedFlitQueue::new(NOC_FIFO_SIZE);
            let downwards = PrioritizedFlitQueue::new(NOC_FIFO_SIZE);
            let (upwards_feeder, upwards_eater) = upwards.split();
            let (downwards_feeder, downwards_eater) = downwards.split();
            let up_side = BidirectionalNoc::new(upwards_eater, downwards_feeder, NOC_FIFO_LATENCY);
            let down_side =
                BidirectionalNoc::new(downwards_eater, upwards_feeder, NOC_FIFO_LATENCY);
            mesh[(y + 1) as usize][x as usize].give_up_noc(up_side);
            mesh[y as usize][x as usize].give_down_noc(down_side);
        }
    }
    println!("Vertical NOCs connected.");

    let num_stacks = (CORES_IN_X_STACK as usize) * (CORES_IN_Y_STACK as usize);

    let mut stacks: Vec<Stack> = Vec::with_capacity(num_stacks);
    let mut service_other_stack_senders: Vec<Sender<LongDramOp>> = Vec::with_capacity(num_stacks);

    println!("{}", crate::memory::cfg().describe()); // AI [128]
    for (_i, service_rx) in far_dram_receivers.into_iter().take(num_stacks).enumerate() {
        let (tx, rx) = std::sync::mpsc::channel::<LongDramOp>();
        service_other_stack_senders.push(tx);

        stacks.push(Stack {
            cores: Vec::new(),
            dram_stack: vec![0; DRAM_STACK_SIZE / 4],
            service_other_stack: service_rx,
            return_result_to_stack: Vec::new(),
            receive_dram_result_from_stack: rx,
            forward_dram_result_to_core: Vec::new(),
            core_hash: HashMap::new(),
            mem: crate::memory::MemSystem::new(_i), // AI [128]
            local_read: 0,
            local_write: 0,
            foreign_read: 0,
            foreign_write: 0,
        });
    }
    println!("Initialized stacks.");
    for stack in stacks.iter_mut() {
        stack.return_result_to_stack = service_other_stack_senders.clone();
    }

    for row in mesh {
        for core in row {
            let stack_index = core.get_stack() as usize;
            stacks[stack_index].cores.push(core);
        }
    }
    println!("Cores assigned to stacks.");
    for stack in stacks.iter_mut() {
        for (core_index, core) in stack.cores.iter_mut().enumerate() {
            stack.core_hash.insert(core.get_core_id(), core_index);
        }
    }
    println!("Core hash maps created.");
    for stack in stacks.iter_mut() {
        for core in stack.cores.iter_mut() {
            let (feeder, eater) = SpscQueue::new(1024).split(); // AI [128]: replies can now be dated in the future and arrive out of order; 16 ctx x 14 regs max in flight
            stack.forward_dram_result_to_core.push(feeder);
            core.give_far_dram_response(eater);
        }
    }
    println!("DRAM response channels given to cores.");
    stacks
}

#[inline]
fn dram_word_index(addr: usize) -> usize {
    addr >> 2
}

#[inline]
fn dram_byte_offset(addr: usize) -> usize {
    addr & 0x3
}

fn dram_read_signed_byte(dram: &Vec<u32>, addr: usize) -> u32 {
    let word = dram[dram_word_index(addr)];
    let off = dram_byte_offset(addr);
    let byte = ((word >> (off * 8)) & 0xFF) as u8;
    (byte as i8 as i32) as u32
}
fn dram_read_unsigned_byte(dram: &Vec<u32>, addr: usize) -> u32 {
    let word = dram[dram_word_index(addr)];
    let off = dram_byte_offset(addr);
    (word >> (off * 8)) & 0xFF
}
fn dram_read_signed_half(dram: &Vec<u32>, addr: usize) -> u32 {
    assert!(
        addr & 0x1 == 0,
        "DRAM Half LOADS CAN'T BE UNALIGNED (addr = 0x{:X} / {})",
        addr,
        addr
    );
    let word = dram[dram_word_index(addr)];
    let off = addr & 0x2;
    let half = ((word >> (off * 8)) & 0xFFFF) as u16;
    (half as i16 as i32) as u32
}
fn dram_read_unsigned_half(dram: &Vec<u32>, addr: usize) -> u32 {
    assert!(
        addr & 0x1 == 0,
        "DRAM Half LOADS CAN'T BE UNALIGNED (addr = 0x{:X} / {})",
        addr,
        addr
    );
    let word = dram[dram_word_index(addr)];
    let off = addr & 0x2;
    (word >> (off * 8)) & 0xFFFF
}
fn dram_read_word(dram: &Vec<u32>, addr: usize) -> u32 {
    assert!(
        addr & 0x3 == 0,
        "DRAM Word LOADS CAN'T BE UNALIGNED (addr = 0x{:X} / {})",
        addr,
        addr
    );
    dram[dram_word_index(addr)]
}
fn dram_store_byte(dram: &mut Vec<u32>, addr: usize, value: u32) {
    let idx = dram_word_index(addr);
    let off = dram_byte_offset(addr);
    let mask = !(0xFF << (off * 8));
    dram[idx] = (dram[idx] & mask) | ((value & 0xFF) << (off * 8));
}
fn dram_store_half(dram: &mut Vec<u32>, addr: usize, value: u32) {
    assert!(
        addr & 0x1 == 0,
        "DRAM Half STORES CAN'T BE UNALIGNED (addr = 0x{:X} / {})",
        addr,
        addr
    );
    let idx = dram_word_index(addr);
    let off = addr & 0x2;
    let mask = !(0xFFFF << (off * 8));
    dram[idx] = (dram[idx] & mask) | ((value & 0xFFFF) << (off * 8));
}
fn dram_store_word(dram: &mut Vec<u32>, addr: usize, value: u32) {
    assert!(
        addr & 0x3 == 0,
        "DRAM Word STORES CAN'T BE UNALIGNED (addr = 0x{:X} / {})",
        addr,
        addr
    );
    dram[dram_word_index(addr)] = value;
}
fn dram_atomic_add(dram: &mut Vec<u32>, addr: usize, value: u32) -> u32 {
    assert!(
        addr & 0x3 == 0,
        "DRAM Word ATOMIC ADD CAN'T BE UNALIGNED (addr = 0x{:X} / {})",
        addr,
        addr
    );
    let idx = dram_word_index(addr);
    let old = dram[idx];
    dram[idx] = old.wrapping_add(value);
    old
}
#[derive(Clone)]
pub struct CoreLog {
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
    dram_bytes_read_close: usize,
    dram_bytes_read_far: usize,
    dram_bytes_wrote_close: usize,
    dram_bytes_wrote_far: usize,
    flits_sent: usize,
    flits_received: usize,
    flit_sent_manhattan_distance_traversed: usize,
    flit_received_manhattan_distance_traversed: usize,
    pub auto_rejects: usize,
}
#[derive(Clone)]
struct StackLog {
    core_logs: Vec<Vec<Option<CoreLog>>>,
    local_read: usize,
    local_write: usize,
    foreign_read: usize,
    foreign_write: usize,
    stack_id: usize,
}
fn service_far_dram_request(
    dram_stack: &mut Vec<u32>,
    mem: &mut crate::memory::MemSystem, // AI [128]: the value is still computed here; the timing comes from the memory model
    request: LongDramRequest,
    now: u64,
) -> (usize, usize) {
    let modified_address = request.address % DRAM_STACK_SIZE;
    let (read, written, response_load) = match request.op {
        Operation::StoreByteDram => {
            dram_store_byte(dram_stack, modified_address, request.value_to_write);
            (0, 1, None)
        }
        Operation::StoreHalfDram => {
            dram_store_half(dram_stack, modified_address, request.value_to_write);
            (0, 2, None)
        }
        Operation::StoreWordDram => {
            dram_store_word(dram_stack, modified_address, request.value_to_write);
            (0, 4, None)
        }
        Operation::AtomicAddDram => {
            let old_value = dram_atomic_add(dram_stack, modified_address, request.value_to_write);
            (4, 4, Some(old_value))
        }
        Operation::ReadSignedByteDram => (
            1,
            0,
            Some(dram_read_signed_byte(dram_stack, modified_address)),
        ),
        Operation::ReadUnsignedByteDram => (
            1,
            0,
            Some(dram_read_unsigned_byte(dram_stack, modified_address)),
        ),
        Operation::ReadSignedHalfDram => (
            2,
            0,
            Some(dram_read_signed_half(dram_stack, modified_address)),
        ),
        Operation::ReadUnsignedHalfDram => (
            2,
            0,
            Some(dram_read_unsigned_half(dram_stack, modified_address)),
        ),
        Operation::ReadWordDram => (4, 0, Some(dram_read_word(dram_stack, modified_address))),
        _ => {
            panic!("Unsupported DRAM Operation!")
        }
    };
    // AI [128]: the reply (if any) is sent back by the stack loop once the memory model completes the request
    let kind = match request.op {
        Operation::StoreByteDram | Operation::StoreHalfDram | Operation::StoreWordDram => crate::memory::MemKind::Write,
        Operation::AtomicAddDram => crate::memory::MemKind::Atomic,
        _ => crate::memory::MemKind::Read,
    };
    let reply = response_load.map(|v| crate::memory::Reply { origin_stack: request.origin_stack, core_id: request.core_id, register_index: request.register_index, value: v });
    let arrival = (request.issue_cycle + mem.far_cycles()).max(now);
    mem.submit_far(crate::memory::MemReq { arrival, addr: modified_address, kind, reply }, now); // AI [131]: crosses this stack's incoming link
    (read as usize, written as usize)
}

#[derive(Copy, Clone, Eq, Hash, PartialEq)]
enum Metric {
    UpUtil,
    UpCong,
    DownUtil,
    DownCong,
    LeftUtil,
    LeftCong,
    RightUtil,
    RightCong,
    MailboxCong,
    CoreBusy,
}

fn metric_name(m: Metric) -> &'static str {
    match m {
        Metric::UpUtil => "up_noc_util",
        Metric::UpCong => "up_noc_congestion",
        Metric::DownUtil => "down_noc_util",
        Metric::DownCong => "down_noc_congestion",
        Metric::LeftUtil => "left_noc_util",
        Metric::LeftCong => "left_noc_congestion",
        Metric::RightUtil => "right_noc_util",
        Metric::RightCong => "right_noc_congestion",
        Metric::MailboxCong => "mailbox_congestion",
        Metric::CoreBusy => "core_busy",
    }
}

fn series_for_metric<'a>(cl: &'a CoreLog, m: Metric) -> &'a [usize] {
    match m {
        Metric::UpUtil => &cl.up_noc_util,
        Metric::UpCong => &cl.up_noc_congestion,
        Metric::DownUtil => &cl.down_noc_util,
        Metric::DownCong => &cl.down_noc_congestion,
        Metric::LeftUtil => &cl.left_noc_util,
        Metric::LeftCong => &cl.left_noc_congestion,
        Metric::RightUtil => &cl.right_noc_util,
        Metric::RightCong => &cl.right_noc_congestion,
        Metric::MailboxCong => &cl.mailbox_congestion,
        Metric::CoreBusy => &cl.core_busy,
    }
}

fn dump_logs_for_viz(
    log_vec: &[StackLog],
    out_dir: &str,
    cores_in_x: usize,
    cores_in_y: usize,
    cores_in_x_stack: usize,
    cores_in_y_stack: usize,
) -> Result<(), Box<dyn std::error::Error>> {
    create_dir_all(out_dir)?;

    let stacks_per_row = cores_in_x_stack;
    let stack_x_dim = cores_in_x;
    let stack_y_dim = cores_in_y;

    let total_x = stacks_per_row * stack_x_dim;
    let total_y = cores_in_y_stack * stack_y_dim;

    // Metrics you want as videos
    let metrics = [
        Metric::UpUtil,
        Metric::UpCong,
        Metric::DownUtil,
        Metric::DownCong,
        Metric::LeftUtil,
        Metric::LeftCong,
        Metric::RightUtil,
        Metric::RightCong,
        Metric::MailboxCong,
        Metric::CoreBusy,
    ];

    // Find max T per metric across all cores (normalize lengths)
    let mut max_t = std::collections::HashMap::<Metric, usize>::new();
    for &m in &metrics {
        let mut t = 0usize;
        for s in log_vec {
            for row in &s.core_logs {
                for cell in row {
                    if let Some(cl) = cell.as_ref() {
                        t = t.max(series_for_metric(cl, m).len());
                    }
                }
            }
        }
        max_t.insert(m, t);
    }

    // Write scalar heatmaps (bytes read/write close/far, flits sent/recv)
    let mut bytes_read_close = Array2::<u64>::zeros((total_y, total_x));
    let mut bytes_read_far = Array2::<u64>::zeros((total_y, total_x));
    let mut bytes_wrote_close = Array2::<u64>::zeros((total_y, total_x));
    let mut bytes_wrote_far = Array2::<u64>::zeros((total_y, total_x));
    let mut flits_sent = Array2::<u64>::zeros((total_y, total_x));
    let mut flits_recv = Array2::<u64>::zeros((total_y, total_x));
    let mut flits_sent_manhattan = Array2::<u64>::zeros((total_y, total_x));
    let mut flits_recv_manhattan = Array2::<u64>::zeros((total_y, total_x));
    let mut auto_rejects = Array2::<u64>::zeros((total_y, total_x));
    // Also per-stack totals CSV
    {
        let mut w = csv::Writer::from_path(format!("{}/stack_totals.csv", out_dir))?;
        w.write_record([
            "stack_id",
            "local_read",
            "local_write",
            "foreign_read",
            "foreign_write",
        ])?;
        for s in log_vec {
            w.write_record([
                s.stack_id.to_string(),
                s.local_read.to_string(),
                s.local_write.to_string(),
                s.foreign_read.to_string(),
                s.foreign_write.to_string(),
            ])?;
        }
        w.flush()?;
    }

    // Fill scalar maps + build & write time-series tensors
    for &m in &metrics {
        let t = *max_t.get(&m).unwrap();
        let mut tensor = Array3::<u32>::zeros((t.max(1), total_y, total_x)); // [T,Y,X]
        // note: t could be 0 if nothing logged; keep shape non-empty

        for s in log_vec {
            let stack_x = s.stack_id % cores_in_x_stack;
            let stack_y = s.stack_id / cores_in_x_stack;

            for (i, row) in s.core_logs.iter().enumerate() {
                for (j, cell) in row.iter().enumerate() {
                    let Some(cl) = cell.as_ref() else {
                        continue;
                    };

                    let gx = stack_x * stack_x_dim + j;
                    let gy = stack_y * stack_y_dim + i;

                    // Scalar maps
                    bytes_read_close[(gy, gx)] = cl.dram_bytes_read_close as u64;
                    bytes_read_far[(gy, gx)] = cl.dram_bytes_read_far as u64;
                    bytes_wrote_close[(gy, gx)] = cl.dram_bytes_wrote_close as u64;
                    bytes_wrote_far[(gy, gx)] = cl.dram_bytes_wrote_far as u64;
                    flits_sent[(gy, gx)] = cl.flits_sent as u64;
                    flits_recv[(gy, gx)] = cl.flits_received as u64;
                    flits_sent_manhattan[(gy, gx)] =
                        cl.flit_sent_manhattan_distance_traversed as u64;
                    flits_recv_manhattan[(gy, gx)] =
                        cl.flit_received_manhattan_distance_traversed as u64;
                    auto_rejects[(gy, gx)] = cl.auto_rejects as u64;
                    // Time series tensor, padded with last value
                    let series = series_for_metric(cl, m);
                    if series.is_empty() {
                        continue;
                    }
                    let last = *series.last().unwrap() as u32;
                    for ti in 0..t {
                        let v = if ti < series.len() {
                            series[ti] as u32
                        } else {
                            last
                        };
                        tensor[(ti, gy, gx)] = v;
                    }
                }
            }
        }

        write_npy(format!("{}/{}.npy", out_dir, metric_name(m)), &tensor)?;
    }

    // Write scalar maps
    write_npy(
        format!("{}/bytes_read_close.npy", out_dir),
        &bytes_read_close,
    )?;
    write_npy(format!("{}/bytes_read_far.npy", out_dir), &bytes_read_far)?;
    write_npy(
        format!("{}/bytes_wrote_close.npy", out_dir),
        &bytes_wrote_close,
    )?;
    write_npy(format!("{}/bytes_wrote_far.npy", out_dir), &bytes_wrote_far)?;
    write_npy(format!("{}/flits_sent.npy", out_dir), &flits_sent)?;
    write_npy(format!("{}/flits_received.npy", out_dir), &flits_recv)?;
    write_npy(
        format!("{}/flits_sent_manhattan.npy", out_dir),
        &flits_sent_manhattan,
    )?;
    write_npy(
        format!("{}/flits_received_manhattan.npy", out_dir),
        &flits_recv_manhattan,
    )?;
    write_npy(format!("{}/auto_rejects.npy", out_dir), &auto_rejects)?;
    println!("TOTAL ROUTER AUTO-REJECTS: {}", auto_rejects.sum());
    println!("WROTE ALL LOGS");
    Ok(())
}
use std::fs::File;
use std::io::{BufRead, BufReader, Write};

fn read_placements(path: String) -> std::io::Result<Vec<(u32, u32, u32)>> {
    let file = File::open(path)?;
    let reader = BufReader::new(file);

    let mut result = Vec::new();

    for (i, line) in reader.lines().enumerate() {
        let line = line?;

        // Skip header
        if i == 0 {
            continue;
        }

        let parts: Vec<&str> = line.split(',').collect();
        if parts.len() < 3 {
            continue; // skip malformed lines
        }

        let x = parts[0].parse::<u32>().unwrap();
        let y = parts[1].parse::<u32>().unwrap();
        let node_id = parts[2].parse::<u32>().unwrap();

        result.push((x, y, node_id));
    }

    Ok(result)
}

// AI [67]: stall detector. Stack 0 sets STOP_AT when traversals stop moving; every stack thread ends (and dumps) at that cycle.
static STOP_AT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(u64::MAX);

// AI [74]: SRAM address of a branch firmware label, taken from the first instruction in branch_core_code.txt that names it
// (lw/sw/add with a label immediate keep the address in the top 16 bits). Returns 0 if not found.
fn branch_label_addr(name: &str) -> u16 { label_addr("branch_core_code.txt", name) }
// AI [79]: PC of the first branch instruction whose source text contains `pat` (0 if none)
fn branch_pc_of(pat: &str) -> u16 {
    for line in include_str!("../../assembler/rust_assembler_mimd/src/branch_core_code.txt").lines() {
        if let (Some(p), Some(q)) = (line.find("PC = 0x"), line.find("line:")) { if line[q..].contains(pat) { return u32::from_str_radix(&line[p + 7..p + 15], 16).unwrap_or(0) as u16; } }
    }
    0
}
// AI [85]: PC of the first leaf instruction whose source text contains `pat`
fn leaf_pc_of(pat: &str) -> u16 {
    for line in include_str!("../../assembler/rust_assembler_mimd/src/leaf_core_code.txt").lines() {
        if let (Some(p), Some(q)) = (line.find("PC = 0x"), line.find("line:")) { if line[q..].contains(pat) { return u32::from_str_radix(&line[p + 7..p + 15], 16).unwrap_or(0) as u16; } }
    }
    0
}
fn label_addr(file: &str, name: &str) -> u16 {
    // AI [78]: embedded at compile time (same build as auto_gen_code.rs), so a .txt regenerated during a run cannot skew the dump
    let txt = if file.starts_with("leaf") { include_str!("../../assembler/rust_assembler_mimd/src/leaf_core_code.txt") } else { include_str!("../../assembler/rust_assembler_mimd/src/branch_core_code.txt") };
    let key = format!(", {}", name);
    for line in txt.lines() {
        if let Some(pos) = line.find("line:") { let src = &line[pos..]; if src.contains(&key) && !src.contains("#AI[64]") {
            if let Ok(w) = u32::from_str_radix(line.trim_start().trim_start_matches("0x").split(',').next().unwrap_or(""), 16) { return (w >> 16) as u16; } } }
    }
    0
}

fn node_id_lists(path: String) -> std::io::Result<Vec<(u32, u32, u32, u32)>> {
    let file = File::open(path)?;
    let reader = BufReader::new(file);

    let mut result = Vec::new();

    for (i, line) in reader.lines().enumerate() {
        let line = line?;
        if i == 0 {
            continue;
        }

        let parts: Vec<&str> = line.split(',').collect();
        if parts.len() < 5 {
            continue;
        }

        let kind = parts[3];
        if kind == "empty" || kind.ends_with("_dup") {
            continue;
        }

        let Ok(node_id) = parts[2].parse::<u32>() else {
            continue;
        };
        let x = parts[0].parse::<u32>().unwrap();
        let y = parts[1].parse::<u32>().unwrap();
        let is_branch = if kind.contains("branch") { 1u32 } else { 0u32 };

        result.push((x, y, node_id, is_branch));
    }

    Ok(result)
}

use std::fs::read_to_string;

pub struct Triangle {
    pub red: f32,
    pub green: f32,
    pub blue: f32,
    pub roughness: f32,
    pub metallic: f32,
    pub x_norm: f32,
    pub y_norm: f32,
    pub z_norm: f32,
}

pub fn load_triangles() -> Vec<Triangle> {
    let text = read_to_string("scene.txt")
        .or_else(|_| read_to_string("src/scene.txt"))
        .unwrap();

    let mut lines = text.lines();
    lines.next(); // skip header

    lines
        .map(|line| {
            let n: Vec<f32> = line
                .split_ascii_whitespace()
                .map(|s| s.parse().unwrap())
                .collect();

            let (e1x, e1y, e1z) = (n[3] - n[0], n[4] - n[1], n[5] - n[2]);
            let (e2x, e2y, e2z) = (n[6] - n[0], n[7] - n[1], n[8] - n[2]);
            let nx = e1y * e2z - e1z * e2y;
            let ny = e1z * e2x - e1x * e2z;
            let nz = e1x * e2y - e1y * e2x;
            let len = (nx * nx + ny * ny + nz * nz).sqrt();

            Triangle {
                red: n[9],
                green: n[10],
                blue: n[11],
                roughness: n[12],
                metallic: n[13],
                x_norm: nx / len,
                y_norm: ny / len,
                z_norm: nz / len,
            }
        })
        .collect()
}

pub struct BvhNode {
    pub min_x: f32,
    pub min_y: f32,
    pub min_z: f32,
    pub max_x: f32,
    pub max_y: f32,
    pub max_z: f32,
    pub left_first: u32,
    pub tri_count: u32,
    pub parent: u32,
}

pub fn load_bvh_nodes() -> Vec<BvhNode> {
    let text = read_to_string("bvh_nodes.txt")
        .or_else(|_| read_to_string("src/bvh_nodes.txt"))
        .unwrap();

    let mut lines = text.lines();
    lines.next(); // skip header

    let mut nodes: Vec<BvhNode> = lines
        .map(|line| {
            let p: Vec<&str> = line.split_ascii_whitespace().collect();
            BvhNode {
                min_x: p[1].parse().unwrap(),
                min_y: p[2].parse().unwrap(),
                min_z: p[3].parse().unwrap(),
                max_x: p[4].parse().unwrap(),
                max_y: p[5].parse().unwrap(),
                max_z: p[6].parse().unwrap(),
                left_first: p[7].parse().unwrap(),
                tri_count: p[8].parse().unwrap(),
                parent: u32::MAX,
            }
        })
        .collect();

    // BFS from root, filling in parent pointers.
    let mut queue: VecDeque<u32> = VecDeque::new();
    queue.push_back(0);
    nodes[0].parent = 0; // root is its own parent (sentinel)

    while let Some(idx) = queue.pop_front() {
        let n = &nodes[idx as usize];
        if n.tri_count == 0 {
            // branch: children are at left_first and left_first + 1
            let left = n.left_first;
            let right = n.left_first + 1;
            nodes[left as usize].parent = idx;
            nodes[right as usize].parent = idx;
            queue.push_back(left);
            queue.push_back(right);
        }
        // leaf: tri_count > 0, no children to enqueue
    }
    nodes
}

const WELD_EPSILON: f32 = 1e-4;

#[derive(Debug, Clone)]
struct BvhLeaf {
    first_tri: usize,
    tri_count: usize,
}
type TriangleVertices = [f32; 9];

fn walk(
    node_id: usize,
    nodes: &Vec<BvhNode>,
    leaves: &Vec<BvhLeaf>,
    triangles: &[TriangleVertices],
    out: &mut Vec<TriangleVertices>,
) {
    let node = &nodes[node_id];

    if node.tri_count > 0 {
        let leaf_id = node.left_first as usize;
        let leaf = &leaves[leaf_id];
        let tri_id = leaf.first_tri;
        let tri_count = leaf.tri_count;
        out.extend_from_slice(&triangles[tri_id..tri_id + tri_count]);
        return;
    }

    let left = node.left_first;
    let right = node.left_first + 1;
    walk(left as usize, nodes, leaves, triangles, out);
    walk(right as usize, nodes, leaves, triangles, out);
}
// A triangle is three vertices, each with x/y/z → 9 floats.
/// Build an indexed mesh for the subtree rooted at `node_id`.
///
/// - Walks all descendant leaves left-to-right (same order as `walk`).
/// - Dedupes vertices by quantizing to WELD_EPSILON.
/// - Emits 3 indices per triangle in traversal order.
fn indexed_mesh_for_node_partitioner(
    node_id: usize,
    nodes: &[parse_bvh::Node],
    triangles: &[parse_bvh::Triangle],
) -> (Vec<(u32, u16, u16, u16)>, Vec<[f32; 3]>, Vec<(usize, u32)>) {
    // AI: also returns (bvh_leaf_node_index, byte offset of its first record in the index list) for each BVH leaf,
    // and index records now carry the global (bvh_triangles.txt order) triangle id instead of the local position.
    // Walk the subtree, gathering triangles in DFS order and deduping
    // vertices the SAME way the partitioner does.
    let mut vertex_map: HashMap<parse_bvh::QPoint, u16> = HashMap::new();
    let mut vertices: Vec<[f32; 3]> = Vec::new();
    let mut indices: Vec<(u32, u16, u16, u16)> = Vec::new();
    let mut leaf_offsets: Vec<(usize, u32)> = Vec::new();

    fn intern(
        p: parse_bvh::Point,
        map: &mut HashMap<parse_bvh::QPoint, u16>,
        verts: &mut Vec<[f32; 3]>,
    ) -> u16 {
        let key = parse_bvh::snap(p);
        if let Some(&i) = map.get(&key) {
            return i;
        }
        let i: u16 = verts.len().try_into().expect("vertex index exceeds u16");
        verts.push([p.x, p.y, p.z]);
        map.insert(key, i);
        i
    }

    fn walk(
        idx: usize,
        nodes: &[parse_bvh::Node],
        triangles: &[parse_bvh::Triangle],
        vertex_map: &mut HashMap<parse_bvh::QPoint, u16>,
        vertices: &mut Vec<[f32; 3]>,
        indices: &mut Vec<(u32, u16, u16, u16)>,
        leaf_offsets: &mut Vec<(usize, u32)>,
    ) {
        let n = &nodes[idx];
        if n.is_leaf {
            leaf_offsets.push((n.index, (indices.len() * 12) as u32));
            for i in n.first_tri..n.first_tri + n.tri_count {
                let t = &triangles[i];
                let v0 = intern(t.v0, vertex_map, vertices);
                let v1 = intern(t.v1, vertex_map, vertices);
                let v2 = intern(t.v2, vertex_map, vertices);
                indices.push((i as u32, v0, v1, v2));
            }
            return;
        }
        walk(n.left_child, nodes, triangles, vertex_map, vertices, indices, leaf_offsets);
        walk(n.right_child, nodes, triangles, vertex_map, vertices, indices, leaf_offsets);
    }

    walk(node_id, nodes, triangles, &mut vertex_map, &mut vertices, &mut indices, &mut leaf_offsets);

    println!(
        "node {}: tris={} unique_vertices={}",
        node_id, indices.len(), vertices.len()
    );

    (indices, vertices, leaf_offsets)
}

fn walk_direct(
    node_id: usize,
    nodes: &Vec<BvhNode>,
    triangles: &[TriangleVertices],
    out: &mut Vec<TriangleVertices>,
) {
    let node = &nodes[node_id];

    if node.tri_count > 0 {
        // Leaf: left_first is the direct triangle offset.
        let tri_id = node.left_first as usize;
        let tri_count = node.tri_count as usize;
        out.extend_from_slice(&triangles[tri_id..tri_id + tri_count]);
        return;
    }

    let left = node.left_first as usize;
    walk_direct(left, nodes, triangles, out);
    walk_direct(left + 1, nodes, triangles, out);
}
use std::fs;

fn parse_bvh_nodes(path: &str) -> Vec<BvhNode> {
    let content = fs::read_to_string(path).expect("failed to read bvh_nodes.txt");
    let mut nodes = Vec::new();

    for (line_no, line) in content.lines().enumerate() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        // Format (8 fields, position-indexed; node_id is the line index):
        //   min.x min.y min.z  max.x max.y max.z  left_first  tri_count
        //   [0]   [1]   [2]    [3]   [4]   [5]    [6]         [7]
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < 8 {
            panic!(
                "bvh_nodes.txt line {}: expected 8 fields, got {}",
                line_no,
                parts.len()
            );
        }

        nodes.push(BvhNode {
            min_x: parts[1].parse().unwrap(),
            min_y: parts[2].parse().unwrap(),
            min_z: parts[3].parse().unwrap(),
            max_x: parts[4].parse().unwrap(),
            max_y: parts[5].parse().unwrap(),
            max_z: parts[6].parse().unwrap(),
            left_first: parts[7].parse().unwrap(),
            tri_count: parts[8].parse().unwrap(),
            parent: 0, // filled in below
        });
    }

    // ---- Backfill parent pointers ----
    // For every internal node (tri_count == 0), its two children are at
    // left_first and left_first+1. Mark each child's parent as that node.
    // Root's parent stays 0 (or you can use u32::MAX as a sentinel — see note).
    let n = nodes.len();
    for i in 0..n {
        if nodes[i].tri_count == 0 {
            let l = nodes[i].left_first as usize;
            let r = l + 1;
            if l < n {
                nodes[l].parent = i as u32;
            }
            if r < n {
                nodes[r].parent = i as u32;
            }
        }
    }

    nodes
}

fn parse_bvh_leaves(path: &str) -> Vec<BvhLeaf> {
    let content = fs::read_to_string(path).expect("failed to read bvh_leaves.txt");

    // The leaf file is sparse: it has lines like "13 27 5", "15 24 1", etc.
    // The first column is the leaf_id, which can have gaps. We need a Vec
    // indexed by leaf_id, so we size it to (max_id + 1) and fill the rest
    // with zero entries that will never be looked up.
    let mut entries: Vec<(usize, BvhLeaf)> = Vec::new();
    let mut max_id: usize = 0;

    for (line_no, line) in content.lines().enumerate() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        // Format: leaf_id  first_tri  tri_count
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < 3 {
            panic!(
                "bvh_leaves.txt line {}: expected 3 fields, got {}",
                line_no,
                parts.len()
            );
        }
        let leaf_id: usize = parts[0].parse().unwrap();
        let first_tri: usize = parts[1].parse().unwrap();
        let tri_count: usize = parts[2].parse().unwrap();

        if leaf_id > max_id {
            max_id = leaf_id;
        }
        entries.push((
            leaf_id,
            BvhLeaf {
                first_tri,
                tri_count,
            },
        ));
    }

    let mut leaves: Vec<BvhLeaf> = vec![
        BvhLeaf {
            first_tri: 0,
            tri_count: 0
        };
        max_id + 1
    ];
    for (id, leaf) in entries {
        leaves[id] = leaf;
    }
    leaves
}

fn parse_triangles(path: &str) -> Vec<TriangleVertices> {
    let content = fs::read_to_string(path).expect("failed to read bvh_triangles.txt");
    let mut tris = Vec::new();

    for (line_no, line) in content.lines().enumerate() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        // Format: 9 floats (v0.xyz, v1.xyz, v2.xyz). No leading id column —
        // the triangle's index is just its position in the file.
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < 9 {
            panic!(
                "bvh_triangles.txt line {}: expected 9 fields, got {}",
                line_no,
                parts.len()
            );
        }
        let mut vals = [0f32; 9];
        for i in 0..9 {
            vals[i] = parts[i].parse().unwrap();
        }
        tris.push(vals);
    }
    tris
}


fn count_branch_subtree(
    nodes: &[BvhNode],
    start: usize,
    node_id_map: &HashMap<u32, (usize, u32)>
) -> usize {  
    let mut count = 0;
    let mut stack = vec![0];
    while let Some(idx) = stack.pop() {
        count += 1;
        let l = nodes[idx].left_first as usize;
        let r = l + 1;
        let a = node_id_map.get(&(idx as u32));
        if let Some(b) = a{
            if idx == start {
                stack.push(l);
                stack.push(r);
            }
            continue;
        }
        if nodes[idx].tri_count != 0{
            println!("Happened with origin {}", start);
            continue;
        }
        stack.push(l);
        stack.push(r);

    }
    count
}



fn count_leaf_subtree(
    nodes: &[BvhNode],
    start: usize,
    node_id_map: &HashMap<u32, (usize, u32)>
) -> usize {  
    println!("length of hash map: {}", node_id_map.len());
    let mut parent = start;
    loop{
        if let Some(u) = node_id_map.get(&(parent as u32)) {
            if u.1 != 0 {
                break;
            }
        }
        parent = nodes[parent].parent as usize;
    }
    let mut count = 0;
    let mut stack = vec![parent];
    while let Some(idx) = stack.pop() {
        count += 1;
        if nodes[idx].tri_count > 0 {
            continue;
        }
        let l = nodes[idx].left_first as usize;
        let r = l + 1;
        let a = node_id_map.get(&(idx as u32));
        println!("JOHN IDX: {}", l);
        println!("JOHN IDX: {}", r);
        if let Some(b) = a{
            if idx == start || b.1 != 0 {
                stack.push(l);
                stack.push(r);
            }
            continue;
        }
        stack.push(l);
        stack.push(r);

    }
    count
}



fn max_depth(nodes: &[BvhNode], index: usize) -> usize {
    if nodes[index].tri_count != 0 {
        return 1;
    }
    let l = nodes[index].left_first as usize;
    let r = l + 1;
    1 + max_depth(nodes, l).max(max_depth(nodes, r))
}


fn find_depth(nodes: &[BvhNode], index: usize) -> usize {
    let mut id = index;
    let mut height = 0;
    while id != 0{
        id = nodes[id].parent as usize;
        height += 1;
    }
    height
}

fn main() {
    crate::core::LEAF_HIT_PC.store(leaf_pc_of("sw r6, r0, 56") as u32, std::sync::atomic::Ordering::Relaxed); // AI [85]
    crate::core::BRANCH_HIT_PC.store(branch_pc_of("lw r3, TRIANGLE_ARRAY_HIGH") as u32, std::sync::atomic::Ordering::Relaxed);
    for (w, pat) in ["lhu r2, r1, 32              # r2 - tri_index", "lw r13, INDEX_ARRAY_BASE                   # r13 = Vertex * vertices", "beq r8, r12, TRIANGLE_INTERSECT_RETURN, false", "fpstoreacc.32 r5 #t_unscaled"].iter().enumerate() { crate::core::LEAF_WATCH_PC[w].store(leaf_pc_of(pat) as u32, std::sync::atomic::Ordering::Relaxed); } // AI [86]: leaf-node visits, triangle tests, det checks, passed-u
    for (w, pat) in ["sw_d r14, r12, 0                     # consume", "beq r15, r15, dfs_done, true", "2'. REFUSE: I no longer own that node"].iter().enumerate() { crate::core::NOC_WATCH_PC[w].store(branch_pc_of(pat) as u32, std::sync::atomic::Ordering::Relaxed); crate::core::NOC_WATCH_PC[w + 3].store(leaf_pc_of(pat) as u32, std::sync::atomic::Ordering::Relaxed); } // AI [102]: NoC clone attempts / successes / refusals
    { let p = leaf_pc_of("lhu r1, r1, 24                  #r1 = node = left_child OR right_child"); if p != 0 { crate::core::DESCEND_PC.store(p as u32, std::sync::atomic::Ordering::Relaxed); } } // AI [104]: only when the pattern exists (the stackless leaf has no such instruction; PC 0 would misfire)
    println!("HIT_PCS leaf {:04X} branch {:04X}", crate::core::LEAF_HIT_PC.load(std::sync::atomic::Ordering::Relaxed), crate::core::BRANCH_HIT_PC.load(std::sync::atomic::Ordering::Relaxed));
    // assemble_tree("src".to_string());
    // return;

    let mut stacks: Vec<Stack> = assemble_stacks();
    let init_vector = get_init_vector();
    println!(
        "Num program init bytes per core: {}",
        (init_vector[0] + 1) * 4
    );
    for (i, &value) in init_vector.iter().enumerate() {
        stacks[0].dram_stack[i] = value;
    }
    // for i in 0..MAT_A.len()/2{
    //     stacks[0].dram_stack[i + 250] = MAT_A[2 * i] as u32 | ((MAT_A[2 * i + 1] as u32) << 16);
    // }
    // for i in 0..MAT_B.len()/2{
    //     stacks[0].dram_stack[i + 250 + 4096] = MAT_B[2 * i] as u32 | ((MAT_B[2 * i + 1] as u32) << 16);
    // }
    let mut placement_vec_wrapped = read_placements("placement.csv".to_owned());
    if placement_vec_wrapped.is_err() {
        placement_vec_wrapped = read_placements("src/placement.csv".to_owned());
    }

    let triangles = load_triangles();
    let starting_tri_array = 100_000_000 / 4;
    for i in 0..triangles.len() {
        stacks[0].dram_stack[8 * i + starting_tri_array] = triangles[i].red.to_bits();
        stacks[0].dram_stack[8 * i + 1 + starting_tri_array] = triangles[i].green.to_bits();
        stacks[0].dram_stack[8 * i + 2 + starting_tri_array] = triangles[i].blue.to_bits();
        stacks[0].dram_stack[8 * i + 3 + starting_tri_array] = triangles[i].roughness.to_bits();
        stacks[0].dram_stack[8 * i + 4 + starting_tri_array] = triangles[i].metallic.to_bits();
        stacks[0].dram_stack[8 * i + 5 + starting_tri_array] = triangles[i].x_norm.to_bits();
        stacks[0].dram_stack[8 * i + 6 + starting_tri_array] = triangles[i].y_norm.to_bits();
        stacks[0].dram_stack[8 * i + 7 + starting_tri_array] = triangles[i].z_norm.to_bits();
    }

    let node_vec = load_bvh_nodes();
    let node_array_start = 0;
    for i in 0..node_vec.len() {
        stacks[1].dram_stack[12 * i + node_array_start] = node_vec[i].min_x.to_bits();
        stacks[1].dram_stack[12 * i + 1 + node_array_start] = node_vec[i].max_x.to_bits();
        stacks[1].dram_stack[12 * i + 2 + node_array_start] = node_vec[i].min_y.to_bits();
        stacks[1].dram_stack[12 * i + 3 + node_array_start] = node_vec[i].max_y.to_bits();
        stacks[1].dram_stack[12 * i + 4 + node_array_start] = node_vec[i].min_z.to_bits();
        stacks[1].dram_stack[12 * i + 5 + node_array_start] = node_vec[i].max_z.to_bits();
        let tri_count_packed = (node_vec[i].tri_count as u32) | (node_vec[i].left_first << 8);  // byte 31
        stacks[1].dram_stack[12 * i + 6 + node_array_start] = tri_count_packed;  // word 6 = bytes 24-27, full u32
        stacks[1].dram_stack[12 * i + 7 + node_array_start] = node_vec[i].parent;
        stacks[1].dram_stack[12 * i + 9 + node_array_start] = 0xFFFF_FFFF;
        stacks[1].dram_stack[12 * i + 11 + node_array_start] = 0xFFFF_FFFF; // AI fix: node_id = 0xFFFFFFFF for unowned nodes (firmware's "own child" check)
    }

    let mut node_id_vec_wrapped = node_id_lists("placement.csv".to_owned());
    if node_id_vec_wrapped.is_err() {
        node_id_vec_wrapped = node_id_lists("src/placement.csv".to_owned());
    }

    let node_id_vec = node_id_vec_wrapped.unwrap();
    let start_of_dram_queue_mapping = 63_070_000 / 4;
    let mut node_id_hash_map: HashMap<u32, (usize, u32)> = HashMap::new();
    let mut address_ray_queue_hash_map = HashMap::new();

    let mut ray_queue_allocations: Vec<Vec<u32>> = vec![
        vec![1_115_000_000, 252_516_352, 100_000_000, 100_000_000],
        vec![100_000_000, 100_000_000, 100_000_000, 100_000_000],
    ];
    for i in 0..node_id_vec.len() {
        node_id_hash_map.insert(node_id_vec[i].2, (i, node_id_vec[i].3));
        let mut big_address: u64 =
            (node_id_vec[i].0 / 32) as u64 + (node_id_vec[i].1 / 32) as u64 * 4;
        big_address <<= 31;
        big_address += ray_queue_allocations[node_id_vec[i].1 as usize / 32]
            [node_id_vec[i].0 as usize / 32] as u64;
        stacks[0].dram_stack[2 * i + start_of_dram_queue_mapping] = (big_address >> 32) as u32;
        stacks[0].dram_stack[2 * i + start_of_dram_queue_mapping + 1] = (big_address) as u32;
        address_ray_queue_hash_map.insert(i, big_address);
        ray_queue_allocations[node_id_vec[i].1 as usize / 32][node_id_vec[i].0 as usize / 32] +=
            64 * 1024;
    }
    println!("Allocating values next to the dram queues");
    // println!("ALEX SUPPOSEDLY {} --- {}", 8710512896_u64, address_ray_queue_hash_map.get(&node_id_hash_map.get(&1791132).unwrap().0).unwrap());
    let node_vec = parse_bvh_nodes("bvh_nodes.txt");
    println!("MAX DEPTH: {}", max_depth(&node_vec, 0));
    

        // After read_nodes / read_indices / read_triangles and patching first_tri:
    let nodes_p = parse_bvh::read_nodes("bvh_nodes.txt");  // or your subfolder path
    let tris_p = parse_bvh::read_triangles("bvh_triangles.txt");
    let indices_p = parse_bvh::read_indices("bvh_leaves.txt");
    let mut nodes_p = nodes_p;
    // Patch first_tri on each node from the leaves table — copy this from assemble_tree:
    for i in &node_id_vec {
        if i.3 != 0 {
            let num_in_node = count_branch_subtree(&node_vec, i.2 as usize, &node_id_hash_map);
            println!("BRANCH_NODE_ID: {}, NUM NODES: {}", i.2, num_in_node);
        }
    }
    println!("JOHN 977160: {}", count_leaf_subtree(&node_vec, 977160, &node_id_hash_map));
    let mut expanded: Vec<parse_bvh::Indices> = vec![
        parse_bvh::Indices { node_index: 0, first_triangle_index: 0, num_triangles: 0 };
        nodes_p.len().max(2_000_000)
    ];
    for idx in indices_p {
        expanded[idx.node_index] = idx;
    }
    for n in nodes_p.iter_mut() {
        n.first_tri = expanded[n.index].first_triangle_index;
    }

    // AI: bvh_triangles.txt and scene.txt list triangles in different orders (and split some quads along the other
    // diagonal), so a BVH triangle id can't index the shading triangle array directly. Map each BVH triangle to the
    // scene triangle sharing the most vertices (both halves of a quad share material and plane).
    let bvh_to_scene: Vec<u32> = {
        let key = |x: f32, y: f32, z: f32| ((x * 100.0).round() as i64, (y * 100.0).round() as i64, (z * 100.0).round() as i64);
        let text = read_to_string("scene.txt").or_else(|_| read_to_string("src/scene.txt")).unwrap();
        let mut scene_keys: Vec<[(i64, i64, i64); 3]> = Vec::new();
        for line in text.lines().skip(1) {
            let n: Vec<f32> = line.split_ascii_whitespace().take(9).map(|v| v.parse().unwrap()).collect();
            if n.len() < 9 { continue; }
            scene_keys.push([key(n[0], n[1], n[2]), key(n[3], n[4], n[5]), key(n[6], n[7], n[8])]);
        }
        let mut by_vertex: HashMap<(i64, i64, i64), Vec<u32>> = HashMap::new();
        for (i, k) in scene_keys.iter().enumerate() {
            for v in k { by_vertex.entry(*v).or_default().push(i as u32); }
        }
        let mut unmatched = 0usize;
        let map: Vec<u32> = tris_p.iter().map(|t| {
            let ks = [key(t.v0.x, t.v0.y, t.v0.z), key(t.v1.x, t.v1.y, t.v1.z), key(t.v2.x, t.v2.y, t.v2.z)];
            let mut best = (0usize, u32::MAX);
            for k in &ks {
                if let Some(c) = by_vertex.get(k) {
                    for &si in c.iter().take(64) {
                        let shared = scene_keys[si as usize].iter().filter(|v| ks.contains(v)).count();
                        if shared > best.0 { best = (shared, si); }
                    }
                }
            }
            if best.1 == u32::MAX { unmatched += 1; 0 } else { best.1 }
        }).collect();
        println!("BVH->scene triangle map: {} triangles, {} unmatched", map.len(), unmatched);
        map
    };

    // Now use it:
    for (_, _, node_id, is_branch) in &node_id_vec {
        if *is_branch != 0 {
            continue;
        }
        let i = node_id_hash_map.get(node_id).unwrap().0;
        let address = address_ray_queue_hash_map.get(&i).unwrap();
        let (indices, vertices, leaf_offsets) =
            indexed_mesh_for_node_partitioner(*node_id as usize, &nodes_p, &tris_p);
        // AI fix: each BVH leaf's byte offset into this leaf core's index list, read by the leaf firmware from node byte 32
        for (leaf_node, off) in &leaf_offsets {
            assert!(*off < 65536, "index list offset exceeds u16");
            dram_store_half(&mut stacks[1].dram_stack, 4 * (12 * *leaf_node + node_array_start) + 32, *off);
        }
        let stack_num = address >> 31;
        let intra_stack_addr = address & 0x7FFF_FFFF;
        let mut address_inc = 8 + 32612;
        dram_store_word(
            &mut stacks[stack_num as usize].dram_stack,
            intra_stack_addr as usize + address_inc - 8,
            ((indices.len() as u32 * 12) << 8) | find_depth(&node_vec, *node_id as usize) as u32,
        );
        dram_store_word(
            &mut stacks[stack_num as usize].dram_stack,
            intra_stack_addr as usize + address_inc - 4,
            vertices.len() as u32 * 12,
        );
        println!("STORING AT ADDRESS {} FOR NODE_ID {}: {}", address, node_id, vertices.len() as u32 * 12);
        for index_set in indices {
            dram_store_word(
                &mut stacks[stack_num as usize].dram_stack,
                intra_stack_addr as usize + address_inc,
                bvh_to_scene[index_set.0 as usize], // AI fix: scene triangle id for shading (was local position)
            );
            dram_store_half(
                &mut stacks[stack_num as usize].dram_stack,
                intra_stack_addr as usize + address_inc + 4,
                index_set.1 as u32 * 12, // AI fix: vertex byte offset (firmware adds it to VERTEX_ARRAY_BASE)
            );
            dram_store_half(
                &mut stacks[stack_num as usize].dram_stack,
                intra_stack_addr as usize + address_inc + 6,
                index_set.2 as u32 * 12, // AI fix: vertex byte offset (firmware adds it to VERTEX_ARRAY_BASE)
            );
            dram_store_half(
                &mut stacks[stack_num as usize].dram_stack,
                intra_stack_addr as usize + address_inc + 8,
                index_set.3 as u32 * 12, // AI fix: vertex byte offset (firmware adds it to VERTEX_ARRAY_BASE)
            );

            address_inc += 12;
        }
        for vertex in vertices {
            for float in vertex {
                dram_store_word(
                    &mut stacks[stack_num as usize].dram_stack,
                    intra_stack_addr as usize + address_inc,
                    float.to_bits(),
                );
                address_inc += 4;
            }
        }
    }
    // AI [B1]: spine triangles. BVH leaves reachable from the root through unowned nodes (subtrees absorbed into the shared
    //   spine, e.g. node 2 with its children 4 and 5) are tested by every branch core. One indexed mesh for all of them,
    //   same records as a leaf core's list (u32 scene tri id, 3 x u16 vertex byte offsets, pad), at 66_000_000 in stack 0:
    //   {index bytes, vertex bytes, index records, vertices}, padded to 16 bytes (the branch copies 4 words per pass).
    //   Each spine leaf's DRAM node +32 = byte offset of its first record (the branch DFS copies it to SRAM +32).
    {
        let mut vmap: HashMap<parse_bvh::QPoint, u16> = HashMap::new();
        let mut verts: Vec<[f32; 3]> = Vec::new();
        let mut recs: Vec<(u32, u16, u16, u16)> = Vec::new();
        let mut spine_leaves = 0usize;
        let mut stack = vec![0usize];
        while let Some(idx) = stack.pop() {
            if node_id_hash_map.contains_key(&(idx as u32)) { continue; } // owned: a stub, someone else's geometry
            let n = &nodes_p[idx];
            if n.is_leaf {
                let off = (recs.len() * 12) as u32;
                assert!(off < 65536, "spine index list offset exceeds u16");
                dram_store_half(&mut stacks[1].dram_stack, 4 * (12 * n.index + node_array_start) + 32, off);
                for i in n.first_tri..n.first_tri + n.tri_count {
                    let t = &tris_p[i];
                    let mut vid = |p: parse_bvh::Point| -> u16 {
                        let key = parse_bvh::snap(p);
                        if let Some(&k) = vmap.get(&key) { return k; }
                        let k: u16 = verts.len().try_into().expect("spine vertex index exceeds u16");
                        verts.push([p.x, p.y, p.z]); vmap.insert(key, k); k
                    };
                    let (a, b, c) = (vid(t.v0), vid(t.v1), vid(t.v2));
                    recs.push((bvh_to_scene[i], a, b, c));
                }
                spine_leaves += 1;
                continue;
            }
            stack.push(n.right_child);
            stack.push(n.left_child);
        }
        let base = 66_000_000usize;
        let ib = recs.len() * 12;
        let vb = verts.len() * 12;
        dram_store_word(&mut stacks[0].dram_stack, base, ib as u32);
        dram_store_word(&mut stacks[0].dram_stack, base + 4, vb as u32);
        let mut a = base + 8;
        for r in &recs {
            dram_store_word(&mut stacks[0].dram_stack, a, r.0);
            dram_store_half(&mut stacks[0].dram_stack, a + 4, r.1 as u32 * 12);
            dram_store_half(&mut stacks[0].dram_stack, a + 6, r.2 as u32 * 12);
            dram_store_half(&mut stacks[0].dram_stack, a + 8, r.3 as u32 * 12);
            a += 12;
        }
        for v in &verts { for f in v { dram_store_word(&mut stacks[0].dram_stack, a, f.to_bits()); a += 4; } }
        println!("SPINE_GEO leaves {} tris {} vertices {} bytes {} (padded {}) at stack 0 {}", spine_leaves, recs.len(), verts.len(), ib + vb, (ib + vb + 15) & !15, base);
    }
    println!("Finished allocating values next to the dram queues");
    let start_of_node_init_table = 20_000 / 4;

    let placement_vec = placement_vec_wrapped.unwrap();
    for i in 0..8192 {
        let (x, y, node_id) = placement_vec[i];
        let index = y * 128 + x;
        stacks[0].dram_stack[2 * index as usize + start_of_node_init_table] =
            node_id_hash_map.get(&node_id).unwrap().0 as u32;
        stacks[0].dram_stack[2 * index as usize + start_of_node_init_table + 1] =
            (node_id_hash_map.get(&node_id).unwrap().1 << 31) | node_id;
        if i == 2135 {
            println!("Node id: ANDREW {}", node_id);
        }
    }

    for i in 0..node_id_vec.len() {
        let (x, y, node_id, is_branch) = node_id_vec[i];
        let queue_index = &node_id_hash_map.get(&node_id).unwrap().0;
        let address = address_ray_queue_hash_map.get(queue_index).unwrap();
        // AI [95]: boot template per queue for emergency occupation (63_600_000 + q*8, stack 0), same format as the boot table
        let tq = *queue_index as usize;
        stacks[0].dram_stack[63_600_000 / 4 + 2 * tq] = tq as u32;
        stacks[0].dram_stack[63_600_000 / 4 + 2 * tq + 1] = (node_id_hash_map.get(&node_id).unwrap().1 << 31) | node_id;
        stacks[1].dram_stack[12 * node_id as usize + 8 + node_array_start] = is_branch;
        stacks[1].dram_stack[12 * node_id as usize + 9 + node_array_start] = *address as u32;
        dram_store_half(
            &mut stacks[1].dram_stack,
            4 * (12 * node_id as usize + node_array_start) + 40,
            (*address >> 32) as u32,
        );
        dram_store_half(
            &mut stacks[1].dram_stack,
            4 * (12 * node_id as usize + node_array_start) + 42,
            is_branch,
        );
        // AI fix: node_id field = queue index (matches ROOT_NODE_ID from the init table); was .1 = is_branch
        stacks[1].dram_stack[12 * node_id as usize + 11 + node_array_start] =
            node_id_hash_map.get(&node_id).unwrap().0 as u32;
        println!("NODE ADDRESS: {}, NODE ARRAY INDEX: {}, NODE_ID: {}, IS_BRANCH: {}, CORE_X: {}, CORE_Y: {}", address, node_id, queue_index, is_branch != 0, x, y);
    }

    let start_of_random_table = 60_000_004 / 4;
    let mut rng = StdRng::seed_from_u64(67);

    for i in 0..(1 << 16) {
        let x: u32 = rng.random();
        stacks[0].dram_stack[i + start_of_random_table] = x;
    }
    println!("Finished getting random numbers");
    let start_of_inv_sqrt = 100_000 / 4;

    for i in 0..(32768 / 4) {
        let i_u32 = i as u32;
        let exp_lsb = (i_u32 >> 12) & 1;
        let mant_idx = i_u32 & 0xFFF;

        // Midpoint of the mantissa bin, in [1.0, 2.0)
        let m_mid = 1.0_f64 + (mant_idx as f64 + 0.5) / 4096.0;

        // Even input exp: seed = 1/sqrt(1+m)        ∈ [~0.707, 1.0)
        // Odd input exp:  seed = sqrt(2)/sqrt(1+m)  ∈ [1.0, ~1.414)
        let seed = if exp_lsb != 0 {
            1.0 / m_mid.sqrt()
        } else {
            2.0_f64.sqrt() / m_mid.sqrt()
        };

        // Store mantissa bits only; the asm ORs in the result exponent at runtime
        let value = (seed as f32).to_bits() & 0x007F_FFFF;
        stacks[0].dram_stack[i + start_of_inv_sqrt] = value;
    }
    let start_of_int_to_float_table = 150000 / 4;

    for i in 0..10240 / 4 {
        let fp_val = i as f32;
        stacks[0].dram_stack[start_of_int_to_float_table + i] = fp_val.to_bits();
    }

    /*
     * FRAME_BUF and Random Table shit here
     */

    let start_of_div_table = 61_000_000 / 4;

    for i in 0..8192 / 4 {
        // i is the 11-bit mantissa index (0..2047)
        // reconstruct the float this mantissa represents: 1.mantissa in [1.0, 2.0)
        // exponent = 127 (biased), so the float = 1.0 + i/2048.0
        let x = 1.0_f32 + (i as f32) / 2048.0_f32;
        // reciprocal mantissa: 1/x, but we only store the mantissa bits
        // the exponent is reconstructed at runtime via 254 - exp
        let recip = 1.0_f32 / x;
        // strip the exponent — keep only mantissa bits (bits 0..22)
        let mantissa_only = recip.to_bits() & 0x007F_FFFF;
        stacks[0].dram_stack[start_of_div_table + i] = mantissa_only;
    }

    // AI [152] (Alex): every stack gets its own copy of the read-only math tables, so DIV / INV_SQRT / INT_TO_FLOAT lookups stay
    //   on the core's own stack instead of all crossing to stack 0. Same contents as the stack 0 originals above (kept for
    //   reference). Byte offsets inside each stack; the firmware ORs in bit 31 and sets membits for its own stack at boot.
    //   Nothing else uses stack offsets above ~1.2 GB.
    {
        let copies: [(usize, usize, usize); 3] = [
            (start_of_inv_sqrt, 2_000_000_000 / 4, 32768 / 4),
            (start_of_int_to_float_table, 2_000_100_000 / 4, 10240 / 4),
            (start_of_div_table, 2_000_200_000 / 4, 8192 / 4),
        ];
        for (src, dst, n) in copies {
            let tbl: Vec<u32> = stacks[0].dram_stack[src..src + n].to_vec();
            for st in stacks.iter_mut() {
                st.dram_stack[dst..dst + n].copy_from_slice(&tbl);
            }
        }
        println!("AI [152]: math tables replicated into all {} stacks", stacks.len());
    }

    let tile_queue_start = 62_001_000 / 4; // word index

    // head = 0, tail = num_tiles * 4 (byte offset), count = num_tiles
    let num_tiles_x = 2560 / 16; // 160
    let num_tiles_y = 1440 / 16; // 90
    let num_tiles = num_tiles_x * num_tiles_y; // 14400

    stacks[0].dram_stack[tile_queue_start + 0] = 0; // head = 0
    stacks[0].dram_stack[tile_queue_start + 1] = (num_tiles * 4) as u32; // tail = num_tiles * sizeof(tile_slot)
    stacks[0].dram_stack[tile_queue_start + 2] = num_tiles as u32; // count = num_tiles

    // populate slots - one per tile, in raster order
    let slots_base = tile_queue_start + 3; // +3 words = +12 bytes (past head/tail/count)
    for tile_y in 0..num_tiles_y {
        for tile_x in 0..num_tiles_x {
            let slot_index = tile_y * num_tiles_x + tile_x;
            let tile_index = (tile_y * num_tiles_x + tile_x) as u16;
            // tile_slot: index (u16) | count (u8) | is_valid (u8)
            // count = 0 (no rays spawned yet), is_valid = 1 (slot ready to be grabbed)
            let slot_word = (tile_index as u32)        // bits 0..15 = tile index
                        | (0u32 << 16)               // bits 16..23 = ray count = 0
                        | (1u32 << 24); // bits 24..31 = + = 1
            // each tile_slot is 4 bytes = 1 word, packed into dram_stack word
            stacks[0].dram_stack[slots_base + slot_index] = slot_word;
        }
    }
    println!("Finished tile queues");
    let leaf_core_code_base = 61_010_000 / 4;
    for i in auto_gen_code::get_leaf_core_code().iter().enumerate() {
        stacks[0].dram_stack[leaf_core_code_base + i.0] = *i.1;
    }

    let branch_core_code_base = 400 / 4;
    for i in auto_gen_code::get_branch_core_code().iter().enumerate() {
        stacks[0].dram_stack[branch_core_code_base + i.0] = *i.1;

    }

    // println!("Value at address 6728: {}, line {} in main.rs", dram_read_word(&stacks[0].dram_stack, 6728), line!());

    // if dram_read_word(&stacks[0].dram_stack, 6728) != 0{
    //     return;
    // }

    /*
    typedef struct
    {
        uint16_t core_id;
        uint16_t is_valid;
    } idle_queue_slot;

    typedef struct
    {
        uint32_t head_relative; // 4
        uint32_t tail_relative; // 4 
        uint32_t count; // 4
        uint32_t parent_node_high; // 4
        uint32_t parent_node_low; // 4
        idle_queue_slot slots[8192]; // 4 * 8192 = 32768
    } idle_core_queue_dram; // total size: 32768 + 20 = 32788 bytes
    
    typedef struct
    {
        uint32_t parent_high; 4
        uint32_t parent_low; 4
        uint32_t left_high; 4
        uint32_t left_low; 4
        uint32_t right_high; 4
        uint32_t right_low; 4
        uint16_t is_left; 2
        uint16_t height; 2
    } idle_queue_tree_node; 28 bytes

    */

    // let idle_queue_base = 63_300_000 / 4;
    
    // for i in 0..8 {
    //     stacks[i].dram_stack[idle_queue_base] = 0; // head_relative = 0
    //     stacks[i].dram_stack[idle_queue_base + 1] = 0; // tail_relative = 0
    //     stacks[i].dram_stack[idle_queue_base + 2] = 0; // count = 0
    //     stacks[i].dram_stack[idle_queue_base + 3] = ((i >> 1) as u32) & 3 ; // parent_node_high
    //     stacks[i].dram_stack[idle_queue_base + 4] = (63_400_000 + (((i as u32) & 1) << 31)) / 4; // parent_node_low
    //     for j in 0..8192 {
    //         stacks[i].dram_stack[idle_queue_base + 5 + j] = 0; // mark all slots invalid initially
    //     }
    // }

    // println!("Value at address 6728: {}, line {} in main.rs", dram_read_word(&stacks[0].dram_stack, 6728), line!());

    // if dram_read_word(&stacks[0].dram_stack, 6728) != 0{
    //     return;
    // }

    // let idle_tree_level_1 = 63_400_000 / 4;
    // for i in 0..4 {
    //     stacks[i * 2].dram_stack[idle_tree_level_1] = ((i >> 1) as u32) & 3; // parent_high
    //     stacks[i * 2].dram_stack[idle_tree_level_1 + 1] = (63_400_100 + ((((i >> 1) as u32) & 1) << 31)); // parent_low
    //     stacks[i * 2].dram_stack[idle_tree_level_1 + 2] = (i as u32); // left_high
    //     stacks[i * 2].dram_stack[idle_tree_level_1 + 3] = (63_300_000) / 4; // left_low
    //     stacks[i * 2].dram_stack[idle_tree_level_1 + 4] = (i as u32); // right_high
    //     stacks[i * 2].dram_stack[idle_tree_level_1 + 5] = (63_300_000 | (1 << 31)) / 4; // right_low
    //     stacks[i * 2].dram_stack[idle_tree_level_1 + 6] = 0 | 0; // is_left = 0 for root
    // }
    

    // let idle_tree_level_2 = 63_400_100 / 4;
    // for i in 0..2 {
    //     stacks[i * 4].dram_stack[idle_tree_level_2] = ((i >> 1) as u32) & 3; // parent_high
    //     stacks[i * 4].dram_stack[idle_tree_level_2 + 1] = 63_400_200; // parent_low
    //     stacks[i * 4].dram_stack[idle_tree_level_2 + 2] = (i as u32) * 2; // left_high
    //     stacks[i * 4].dram_stack[idle_tree_level_2 + 3] = (63_400_000) / 4; // left_low
    //     stacks[i * 4].dram_stack[idle_tree_level_2 + 4] = (i as u32) * 2 | 1; // right_high
    //     stacks[i * 4].dram_stack[idle_tree_level_2 + 5] = (63_400_000 | (1 << 31)) / 4; // right_low
    //     stacks[i * 4].dram_stack[idle_tree_level_2 + 6] = 0 | 1; // is_left = 0 for root
    // }

    // let idle_tree_level_3 = 63_400_200 / 4;
    // for i in 0..1 {
    //     stacks[i * 8].dram_stack[idle_tree_level_3] = 0; // parent_high
    //     stacks[i * 8].dram_stack[idle_tree_level_3 + 1] = 0; // parent_low
    //     stacks[i * 4].dram_stack[idle_tree_level_3 + 2] = 0; // left_high
    //     stacks[i * 4].dram_stack[idle_tree_level_3 + 3] = (63_400_100) / 4; // left_low
    //     stacks[i * 4].dram_stack[idle_tree_level_3 + 4] = 1; // right_high
    //     stacks[i * 4].dram_stack[idle_tree_level_3 + 5] = (63_400_100) / 4; // right_low
    //     stacks[i * 4].dram_stack[idle_tree_level_3 + 6] = 0 | 2; // is_left = 0 for root
    // }


    
    

    println!("Val: {}", dram_read_word(&stacks[1].dram_stack, 2151442532 - (1 << 31)));
    println!("Finished copying code");
    let barrier = Arc::new(Barrier::new((CORES_IN_X_STACK * CORES_IN_Y_STACK) as usize));
    let mut handles = Vec::new();
    let done = Arc::new(AtomicBool::new(false));

    print!("Enter cores to watch (0-8191, comma/space separated): ");
    io::stdout().flush().unwrap();
    let mut input = String::new();
    io::stdin().read_line(&mut input).unwrap();

    let cores_to_watch: Vec<u32> = input
        .split(|c: char| c == ',' || c.is_whitespace())
        .filter(|s| !s.is_empty())
        .filter_map(|s| s.parse::<u32>().ok())
        .filter(|&n| n <= 8191)
        .collect();
    io::stdout().flush().unwrap();
    print!("Enter context to inspect (0-15, or Enter to skip): ");
    io::stdout().flush().unwrap();
    input.clear();
    io::stdin().read_line(&mut input).unwrap();
    let context_to_watch = match input.trim() {
        "" => -1,
        s => s
            .parse::<i32>()
            .ok()
            .filter(|&n| (0..=15).contains(&n))
            .unwrap_or(-1),
    };
    println!(
        "Context to watch: {}, cores to watch: {:?}",
        context_to_watch, cores_to_watch
    );
    // AI: (node_id, is_branch, queue address) for the end-of-run queue dump
    let queue_dump_list: Vec<(u32, u32, u64)> = (0..node_id_vec.len())
        .map(|i| (node_id_vec[i].2, node_id_vec[i].3, *address_ray_queue_hash_map.get(&i).unwrap()))
        .collect();
    for (stack_num, mut stack) in stacks.into_iter().enumerate() {
        let queue_dump_list = queue_dump_list.clone(); // AI
        let barrier = barrier.clone();
        let done_per_thread = done.clone();
        let cores_to_monitor = cores_to_watch.clone();
        // AI: run length configurable via DRAEM_CYCLES (default 200000, the original hard-coded stop)
        let max_cycles: u64 = std::env::var("DRAEM_CYCLES").ok().and_then(|v| v.trim().parse().ok()).unwrap_or(200000);
        let handle = thread::spawn(move || -> Option<StackLog> {
            let mut rays_completed_so_far = 0;
            let mut traversals_done_so_far = 0; // AI: progress metric (firmware counter RAYS_COMPLETED at 168_000_000, AI [126])
            let mut last_progress_cycle: u64 = 0; // AI [67]
            let mut far_req_pending: Vec<LongDramRequest> = Vec::new(); // AI [160]
            let mut far_rep_pending: Vec<LongDramOp> = Vec::new(); // AI [160]
            for cycle in 0..1500 * 1000 * 16 {
                let end_cycle = max_cycles.min(STOP_AT.load(std::sync::atomic::Ordering::Relaxed)); // AI [67]
                crate::core::SIM_CYCLE.store(cycle as u64, std::sync::atomic::Ordering::Relaxed); // AI [105]
                let mut local_read = 0;
                let mut local_write = 0;
                for core in stack.cores.iter_mut() {
                    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        core.tick(&mut stack.dram_stack, &mut stack.mem, &cores_to_monitor, &context_to_watch);
                    }));
                    if let Err(e) = result {
                        // AI fix: exit the whole process. A panic here used to leave the other stack threads
                        // blocked forever at the per-cycle barrier, so the simulator hung instead of exiting.
                        println!("Core {} panicked at cycle {}: {:?}", core.get_core_id(), cycle, e);
                        core.debug_dump(); // AI debug [57]
                        let _ = io::stdout().flush();
                        if let Some(m) = crate::core::QCNT_LOG.get() { // AI debug [40]: dump the tally on a crash too
                            if let Ok(m) = m.try_lock() { for ((cid, pc), (sum, n)) in m.iter() { println!("QCNT core {} pc {:04X} n {} sum {}", cid, pc, n, sum); } }
                        }
                        std::process::exit(101);
                    }
                    local_read += core.get_local_read();
                    local_write += core.get_local_write();
                    
                    // if core.get_core_id() == 0 {
                    //     println!("Value of dram at address 6728 is: {}", dram_read_word(&stack.dram_stack, 6728));
                    //     // println!("HEAD: {}, TAIL: {}, CNT: {}, CORE: {}", stack.dram_stack[1163234496/4], stack.dram_stack[1163234496/4 + 1], stack.dram_stack[1163234496/4 + 2], 2944);  
                    // }
                }
                stack.local_read = local_read;
                stack.local_write = local_write;
                // AI [160] (Alex: deterministic simulator): requests and replies from other stacks are collected, and only those sent in an
                //   earlier cycle are applied, in a fixed order (send cycle, then source stack, then that stack's send order). Everything
                //   sent before this cycle is guaranteed to be in the channel (end-of-cycle barrier), so thread timing no longer decides
                //   whether a message is seen this cycle or the next, or in which order same-cycle messages are applied.
                while let Ok(request) = stack.service_other_stack.try_recv() { far_req_pending.push(request); }
                if far_req_pending.iter().any(|r| r.issue_cycle < cycle as u64) {
                    let (mut now_list, keep): (Vec<LongDramRequest>, Vec<LongDramRequest>) = far_req_pending.drain(..).partition(|r| r.issue_cycle < cycle as u64);
                    far_req_pending = keep;
                    now_list.sort_by_key(|r| (r.issue_cycle, r.origin_stack)); // stable: keeps each source's send order
                    for request in now_list {
                        let (read, written) = service_far_dram_request(
                            &mut stack.dram_stack,
                            &mut stack.mem,
                            request,
                            cycle as u64,
                        );
                        stack.foreign_read += read;
                        stack.foreign_write += written;
                    }
                }
                // AI [131]: replies coming back from other stacks go through this stack's incoming link first
                while let Ok(response) = stack.receive_dram_result_from_stack.try_recv() { far_rep_pending.push(response); }
                if far_rep_pending.iter().any(|r| r.sent_cycle < cycle as u64) {
                    let (mut now_list, keep): (Vec<LongDramOp>, Vec<LongDramOp>) = far_rep_pending.drain(..).partition(|r| r.sent_cycle < cycle as u64);
                    far_rep_pending = keep;
                    now_list.sort_by_key(|r| (r.sent_cycle, r.src_stack));
                    for response in now_list {
                        stack.mem.far_reply_in(crate::memory::Done { ready: response.ready_cycle, reply: crate::memory::Reply { origin_stack: stack_num, core_id: response.core_id, register_index: response.register_index, value: response.calculated_val } });
                    }
                }
                if let Some(n) = std::env::var("DRAEM_STATE_HASH").ok().and_then(|v| v.trim().parse::<u64>().ok()) { // AI [160]: determinism check
                    if n > 0 && cycle as u64 % n == 0 {
                        let mut h: u64 = 0xcbf29ce484222325;
                        for core in stack.cores.iter() { h ^= core.state_hash(); h = h.wrapping_mul(0x100000001b3); }
                        h ^= stack.mem.stats.accesses; h = h.wrapping_mul(0x100000001b3);
                        h ^= stack.mem.stats.misses; h = h.wrapping_mul(0x100000001b3);
                        println!("STATEHASH cycle {} stack {} {:016X}", cycle, stack_num, h);
                    }
                }
                // AI [128]: advance this stack's cache/DRAM model, then deliver finished replies (local ones straight to the core,
                //   far ones back to the origin stack with the return link latency added)
                stack.mem.tick(cycle as u64);
                let finished = std::mem::take(&mut stack.mem.out);
                let far_cyc = stack.mem.far_cycles();
                for d in finished {
                    let mut op = LongDramOp { register_index: d.reply.register_index, calculated_val: d.reply.value, core_id: d.reply.core_id, ready_cycle: d.ready, sent_cycle: cycle as u64, src_stack: stack_num }; // AI [160]
                    if d.reply.origin_stack == stack_num {
                        let core_index = stack.core_hash[&op.core_id];
                        assert!(stack.forward_dram_result_to_core[core_index].push(op).is_ok(), "DRAM reply queue full (core {})", d.reply.core_id);
                    } else {
                        op.ready_cycle += far_cyc;
                        let could_send = stack.return_result_to_stack[d.reply.origin_stack].send(op);
                        assert!(could_send.is_ok(), "Failed to send DRAM response");
                    }
                }
                { // AI debug [158]: a receiver flagged a STRAY word; the stack that owns the sender dumps the sending context's history
                    if stack_num == 0 && std::env::var("DRAEM_HS_TEST").ok().and_then(|v| v.trim().parse::<u64>().ok()) == Some(cycle as u64) { // AI debug [159]: self-test of the dump
                        crate::core::DUMP_REQ.store((1u64 << 8) | 0, std::sync::atomic::Ordering::Relaxed);
                    }
                    let req = crate::core::DUMP_REQ.load(std::sync::atomic::Ordering::Relaxed);
                    if req != 0 {
                        let (core_id, ctx) = (((req >> 8) - 1) as u32, (req & 0xFF) as usize);
                        if let Some(&idx) = stack.core_hash.get(&core_id) {
                            if crate::core::DUMP_REQ.compare_exchange(req, 0, std::sync::atomic::Ordering::Relaxed, std::sync::atomic::Ordering::Relaxed).is_ok() {
                                stack.cores[idx].hs_dump(ctx & 15, "STRAY_SENDER");
                            }
                        }
                    }
                }
                if cycle % 500_000 == 0 && cycle > 0 { // AI debug [155] (Alex): periodic NoC contention summary per stack (the per-link
                    //   series are otherwise only dumped to sim_logs at a clean end of run). Window = the last 500K cycles.
                    //   util = flits forwarded per link-cycle (one flit per link per cycle); cong = cycles a flit at the head of a router
                    //   input could not advance because the next link lane was full; mbox = local deliveries stalled on a full mailbox;
                    //   noissue = core-cycles that switched context instead of issuing (unready source register, blocking op, etc.).
                    let e = crate::core::NOC_UTIL_EPOCH_LEN;
                    let (e0, e1) = (((cycle as usize) - 500_000) / e, (cycle as usize) / e);
                    let win = ((e1 - e0) * e) as f64;
                    let (mut links, mut util, mut cong, mut mbox, mut stall, mut rej) = (0u64, 0u64, 0u64, 0u64, 0u64, 0u64);
                    let mut dir_util = [0u64; 4];
                    let mut best = (0u64, 0u32, 0usize);
                    for core in stack.cores.iter() {
                        let (u, c, m, st, mask, r) = core.noc_window(e0, e1);
                        for d in 0..4 { if mask & (1 << d) != 0 { links += 1; util += u[d]; cong += c[d]; dir_util[d] += u[d]; if u[d] > best.0 { best = (u[d], core.get_core_id(), d); } } }
                        mbox += m; stall += st; rej += r;
                    }
                    let n = stack.cores.len() as f64;
                    println!("NOCSTAT cycle {} stack {} links {} util avg {:.1}% max {:.1}% (core {} {}) | dir util R {:.1}% L {:.1}% U {:.1}% D {:.1}% | cong {:.2}% of link-cycles | mbox stalls {} | noissue {:.1}% of core-cycles | auto_rejects total {}",
                        cycle, stack_num, links, 100.0 * util as f64 / (win * links.max(1) as f64), 100.0 * best.0 as f64 / win, best.1, ["R", "L", "U", "D"][best.2],
                        100.0 * dir_util[0] as f64 / (win * n), 100.0 * dir_util[1] as f64 / (win * n), 100.0 * dir_util[2] as f64 / (win * n), 100.0 * dir_util[3] as f64 / (win * n),
                        100.0 * cong as f64 / (win * links.max(1) as f64), mbox, 100.0 * stall as f64 / (win * n), rej);
                }
                if (cycle % 1_000_000 == 0 && cycle > 0) || cycle as u64 == end_cycle {
                    { // AI [144] debug: cumulative histogram of ready worker contexts (0-14 of 15) over this stack's cores, sampled every 16 cycles
                        let mut h = [0u64; 16];
                        for core in stack.cores.iter() { for (i, v) in core.ready_hist().iter().enumerate() { h[i] += v; } }
                        let tot: u64 = h.iter().sum::<u64>().max(1);
                        let avg = h.iter().enumerate().map(|(i, v)| i as u64 * v).sum::<u64>() as f64 / tot as f64;
                        println!("READYCTX cycle {} stack {} avg {:.2} none {:.1}% hist {}", cycle, stack_num, avg, 100.0 * h[0] as f64 / tot as f64, h.iter().map(|v| format!("{:.1}", 100.0 * *v as f64 / tot as f64)).collect::<Vec<_>>().join(" "));
                        if cycle as u64 == end_cycle { // per core at the end: core:avg ready:% samples with none ready
                            let parts: Vec<String> = stack.cores.iter().map(|core| { let h = core.ready_hist(); let t = h.iter().sum::<u64>().max(1);
                                format!("{}:{:.2}:{:.0}", core.get_core_id(), h.iter().enumerate().map(|(i, v)| i as u64 * v).sum::<u64>() as f64 / t as f64, 100.0 * h[0] as f64 / t as f64) }).collect();
                            println!("READYCORE stack {} : {}", stack_num, parts.join(" "));
                        }
                    }
                    crate::core::PC_EXEC_HIST.with(|h| { // AI [132] debug: cumulative execution count of every PC, this stack's cores
                        let h = h.borrow();
                        let parts: Vec<String> = h.iter().enumerate().filter(|(_, n)| **n > 0).map(|(i, n)| format!("{}{:X}={}", if i >= 4096 { "b" } else { "l" }, (i % 4096) * 4, n)).collect();
                        println!("PCEXEC cycle {} stack {} : {}", cycle, stack_num, parts.join(" "));
                    });
                }
                if (cycle % 200_000 == 0 && cycle > 0) || cycle as u64 == end_cycle {
                    println!("{}", stack.mem.summary(cycle as u64)); // AI [128]
                    crate::core::DRAM_PC_HIST.with(|h| { // AI [129] debug: top DRAM-issuing PCs of this stack's cores (cumulative)
                        let h = h.borrow();
                        let mut v: Vec<(u64, usize)> = h.iter().enumerate().filter(|(_, n)| **n > 0).map(|(i, n)| (*n, i)).collect();
                        v.sort_unstable_by(|a, b| b.0.cmp(&a.0));
                        for (n, i) in v.iter().take(25) {
                            let (isb, pcw, tgt) = (i / (4096 * 8), (i / 8) % 4096, i % 8);
                            println!("DRAMPC cycle {} stack {} {} pc {:04X} -> stack {} n {} ({:.2}/cyc)", cycle, stack_num, if isb == 1 { "branch" } else { "leaf" }, pcw * 4, tgt, n, *n as f64 / cycle.max(1) as f64);
                        }
                    });
                }
                // AI: end-of-run dump of every non-empty DRAM ray queue in this stack (count/head/tail, plus the branch receiver queue at +32612)
                // AI debug [65]: where every context sits at the end of the run, and cores still holding getowner
                if cycle as u64 == end_cycle {
                    let mut hist: std::collections::HashMap<(u32, u16), u32> = std::collections::HashMap::new();
                    for core in stack.cores.iter() {
                        let (own, pcs, run, isb) = core.debug_state();
                        if own >= 0 { println!("OWNER_HELD core {} owner_ctx {} pcs {:?} runnable {:?} branch {}", core.get_core_id(), own, pcs, run, isb);
                            // AI [88]: owner context registers and the SRAM header words (0x30 RAY_QUEUE_HIGH .. 0x40 NODE_INDEX_OF_ROOT) and the clone flag (49136)
                            let regs: Vec<String> = (0..16).map(|r| format!("{:X}", core.debug_reg(own as usize, r))).collect();
                            println!("OWNER_REGS core {} r[{}] hdr {:X} {:X} {:X} {:X} {:X} clone {}", core.get_core_id(), regs.join(" "), core.read_sram_word(&0x30u16), core.read_sram_word(&0x34u16), core.read_sram_word(&0x38u16), core.read_sram_word(&0x3Cu16), core.read_sram_word(&0x40u16), core.read_sram_word(&65520u16)); }
                        for p in pcs.iter() { *hist.entry((isb, *p)).or_insert(0) += 1; }
                    }
                    let mut v: Vec<_> = hist.into_iter().collect();
                    v.sort_by(|a, b| b.1.cmp(&a.1));
                    for ((isb, p), n) in v.iter().take(25) { println!("PCHIST stack {} {} pc {:04X} contexts {}", stack_num, if *isb == 1 { "branch" } else { "leaf" }, p, n); }
                }
                // AI debug [68]: primary-ray supply at the end of the run. Branch tile state: GRAB_FROM_TILE_ATOMADDER,
                //   TILE_DATA_COUNT, TILE_IS_ACTIVE, RAYS_SPAWNED_FROM_TILE, RAYS_FORWARDED_OUT_FROM_TILE (SRAM addresses looked up at dump time, [74]). Tile queue at 62_001_000 (stack 0), spawned pool at 2_250_000_000 (stack 1).
                if cycle as u64 == end_cycle {
                    let (ga, ca, aa, sa, fa) = (branch_label_addr("GRAB_FROM_TILE_ATOMADDER"), branch_label_addr("TILE_DATA_COUNT"), branch_label_addr("TILE_IS_ACTIVE"), branch_label_addr("RAYS_SPAWNED_FROM_TILE"), branch_label_addr("RAYS_FORWARDED_OUT_FROM_TILE")); // AI [74]: read from branch_core_code.txt, so they follow the image
                    println!("TILE_ADDRS {:04X} {:04X} {:04X} {:04X} {:04X}", ga, ca, aa, sa, fa);
                    let (mut gated, mut active, mut tiles_open, mut nb) = (0u32, 0u32, 0u32, 0u32);
                    for core in stack.cores.iter() {
                        if core.read_sram_word(&0x38u16) == 0 { continue; }
                        nb += 1;
                        let g = core.read_sram_word(&ga); let cnt = core.read_sram_word(&ca); let act = core.read_sram_word(&aa);
                        if g != 0 { gated += 1; } if act != 0 { active += 1; } if act != 0 && cnt <= 255 { tiles_open += 1; }
                        if act != 0 && cnt <= 255 { println!("TILE_CORE core {} gate {} count {} active {} spawned {} forwarded {}", core.get_core_id(), g, cnt, act, core.read_sram_word(&sa), core.read_sram_word(&fa)); }
                    }
                    println!("TILE_SUMMARY stack {} branch_cores {} gate_taken {} tile_active {} tile_unfinished {}", stack_num, nb, gated, active, tiles_open);
                    if stack_num == 0 { let tq = 62_001_000usize; println!("TILE_QUEUE head {} tail {} count {}", dram_read_word(&stack.dram_stack, tq), dram_read_word(&stack.dram_stack, tq + 4), dram_read_word(&stack.dram_stack, tq + 8) as i32); }
                    if stack_num == 1 { let sp = (2_250_000_000u64 & 0x7FFF_FFFF) as usize; println!("SPAWNED_POOL head {} tail {} count {}", dram_read_word(&stack.dram_stack, sp), dram_read_word(&stack.dram_stack, sp + 4), dram_read_word(&stack.dram_stack, sp + 8) as i32); }
                }
                if stack_num == 2 && cycle % 50000 == 49999 { crate::core::ENTERED_SNAP.store(dram_read_word(&stack.dram_stack, 50_000_016), std::sync::atomic::Ordering::Relaxed); } // AI [B4]
                // AI debug [147]: branch local-queue audit every 250K cycles and at the end. Per branch core and queue (even at
                //   LOCAL_RAY_QUEUE, receiver at +1036): head(+0) tail(+4) count(+8) used(+2072) and filled slots (byte 63 of the 16
                //   slots at +12). Invariants: 0 <= count <= used <= 16, filled <= used, (tail - head) / 64 = count. Prints per-stack sums,
                //   how many cores break each one, and up to 6 offending cores with their context PCs. Spawned pool header every 250K.
                if cycle % 250_000 == 0 || cycle as u64 == end_cycle {
                    let (bra, blq) = (branch_label_addr("RAY_ARRAY"), branch_label_addr("LOCAL_RAY_QUEUE"));
                    let (mut nb, mut held) = (0i64, 0i64);
                    let mut sc = [0i64; 2]; let mut su = [0i64; 2]; let mut sf = [0i64; 2]; let mut sd = [0i64; 2];
                    let (mut c_big, mut c_neg, mut u_bad, mut c_gt_u, mut d_ne_c, mut f_gt_u) = (0, 0, 0, 0, 0, 0);
                    let mut shown = 0;
                    for core in stack.cores.iter() {
                        if core.read_sram_word(&0x38u16) == 0 { continue; }
                        nb += 1;
                        for k in 0..16u16 { if core.read_sram_byte_unsigned(&(bra + 64 * k + 63)) != 0 { held += 1; } }
                        let mut v = [(0i64, 0i64, 0i64, 0i64, 0i64); 2];
                        for qi in 0..2usize {
                            let q = blq + 1036 * qi as u16;
                            let h = core.read_sram_word(&q) as i32 as i64; let t = core.read_sram_word(&(q + 4)) as i32 as i64;
                            let c = core.read_sram_word(&(q + 8)) as i32 as i64; let u = core.read_sram_word(&(q + 2072)) as i32 as i64;
                            let mut f = 0i64; for k in 0..16u16 { if core.read_sram_byte_unsigned(&(q + 12 + 64 * k + 63)) != 0 { f += 1; } }
                            sc[qi] += c; su[qi] += u; sf[qi] += f; sd[qi] += (t - h) / 64;
                            v[qi] = (h, t, c, u, f);
                        }
                        let bad = v.iter().any(|&(h, t, c, u, f)| c > 16 || c < 0 || u > 16 || u < 0 || c > u || (t - h) / 64 != c || f > u);
                        for &(h, t, c, u, f) in v.iter() {
                            if c > 16 { c_big += 1; } if c < 0 { c_neg += 1; } if u > 16 || u < 0 { u_bad += 1; } if c > u { c_gt_u += 1; }
                            if (t - h) / 64 != c { d_ne_c += 1; } if f > u { f_gt_u += 1; }
                        }
                        if bad && shown < 6 {
                            shown += 1;
                            let (_, pcs, _, _) = core.debug_state();
                            println!("LQBAD cycle {} core {} even h {} t {} c {} u {} f {} | recv h {} t {} c {} u {} f {} | pcs {}", cycle, core.get_core_id(), v[0].0, v[0].1, v[0].2, v[0].3, v[0].4, v[1].0, v[1].1, v[1].2, v[1].3, v[1].4, pcs.iter().map(|p| format!("{:04X}", p)).collect::<Vec<_>>().join(","));
                        }
                    }
                    { // AI [B1]: branch SRAM high-water: nodes + spine geometry end (BR_GEO_END); vectors start at 0xFF00
                        let ge = branch_label_addr("BR_GEO_END");
                        let mut mx = 0u32; let mut mxc = 0u32;
                        for core in stack.cores.iter() { if core.read_sram_word(&0x38u16) == 0 { continue; } let e = core.read_sram_word(&ge); if e > mx { mx = e; mxc = core.get_core_id(); } }
                        println!("BRSRAM cycle {} stack {} max_geo_end {} (core {}) limit 65280{}", cycle, stack_num, mx, mxc, if mx > 65280 { " OVERFLOW" } else { "" });
                    }
                    println!("LQAUDIT cycle {} stack {} branch_cores {} held {} even c {} u {} filled {} tail-head {} | recv c {} u {} filled {} tail-head {} | queues: c>16 {} c<0 {} u_bad {} c>u {} (t-h)!=c {} f>u {}", cycle, stack_num, nb, held, sc[0], su[0], sf[0], sd[0], sc[1], su[1], sf[1], sd[1], c_big, c_neg, u_bad, c_gt_u, d_ne_c, f_gt_u);
                    if stack_num == 1 && cycle as u64 != end_cycle { let sp = (2_250_000_000u64 & 0x7FFF_FFFF) as usize; println!("SPAWNED_POOL cycle {} head {} tail {} count {}", cycle, dram_read_word(&stack.dram_stack, sp), dram_read_word(&stack.dram_stack, sp + 4), dram_read_word(&stack.dram_stack, sp + 8) as i32); }
                }
                // AI debug [75]: where in-flight rays sit inside cores: contexts holding an active ray (RAY_ARRAY byte 63 x16),
                //   branch local SRAM queues (even +8, receiver +1044), leaf local queue (RAY_QUEUE_CNT). Sums per stack.
                if cycle as u64 == end_cycle {
                    let (bra, blq, lra, lrq) = (branch_label_addr("RAY_ARRAY"), branch_label_addr("LOCAL_RAY_QUEUE"), label_addr("leaf_core_code.txt", "RAY_ARRAY"), label_addr("leaf_core_code.txt", "RAY_QUEUE_CNT"));
                    let (mut held_b, mut held_l, mut even, mut odd, mut leafq) = (0i64, 0i64, 0i64, 0i64, 0i64);
                    for core in stack.cores.iter() {
                        let isb = core.read_sram_word(&0x38u16) != 0;
                        let ra = if isb { bra } else { lra };
                        let mut h = 0; for k in 0..16u16 { if core.read_sram_byte_unsigned(&(ra + 64 * k + 63)) != 0 { h += 1; } }
                        if isb { held_b += h; even += core.read_sram_word(&(blq + 8)) as i32 as i64; odd += core.read_sram_word(&(blq + 1044)) as i32 as i64; }
                        else { held_l += h; leafq += core.read_sram_word(&lrq) as i32 as i64; }
                    }
                    println!("RAYS_IN_CORES stack {} held_branch {} held_leaf {} branch_local_even {} branch_local_recv {} leaf_local {} (addrs {:04X} {:04X} {:04X} {:04X})", stack_num, held_b, held_l, even, odd, leafq, bra, blq, lra, lrq);
                }
                // AI debug [79]: spawned-pool hang. Branch contexts sitting in ENSURE_RAY_POOL_SLOT_READY: print r2 (slot address), r14 and the
                //   context's PC; stack 1 (pool owner) lists slots whose ready byte (+43 from pool base + head offset) is still 1.
                if cycle as u64 == end_cycle {
                    let p0 = branch_pc_of("lbu_d r3, r2, 43"); // first instruction of ENSURE_RAY_POOL_SLOT_READY
                    let mut shown = 0;
                    for core in stack.cores.iter() {
                        if core.read_sram_word(&0x38u16) == 0 { continue; }
                        let (_, pcs, _, _) = core.debug_state();
                        for (c, pc) in pcs.iter().enumerate() { if p0 != 0 && *pc >= p0.wrapping_sub(4) && *pc <= p0 + 8 && shown < 40 { shown += 1; println!("POOL_WAIT core {} ctx {} pc {:04X} r2 {} r3 {} r14 {}", core.get_core_id(), c, pc, core.debug_reg(c, 2), core.debug_reg(c, 3), core.debug_reg(c, 14)); } }
                    }
                    if stack_num == 1 {
                        let base = (2_250_000_000u64 & 0x7FFF_FFFF) as usize; let tail = dram_read_word(&stack.dram_stack, base + 4) as usize;
                        let ready: Vec<String> = (0..(tail / 32).min(20000)).filter(|k| (dram_read_word(&stack.dram_stack, base + 12 + 32 * k + 28) >> 24) & 0xFF != 0).map(|k| format!("{}", 32 * k)).collect();
                        println!("POOL_READY_SLOTS {} [{}]", ready.len(), ready.iter().take(60).cloned().collect::<Vec<_>>().join(" "));
                    }
                }
                // AI debug [82]: leaf contexts that hold a ray (byte 63 of the ray at r0) but are not in the idle loops: count, plus
                //   up to 8 per stack with their ray words and last 48 PCs, to see whether long leaf traversals loop forever.
                if cycle as u64 == end_cycle {
                    let (mut busy, mut shown) = (0, 0);
                    for core in stack.cores.iter() {
                        if core.read_sram_word(&0x38u16) != 0 { continue; }
                        for c in 0..16usize {
                            let r0 = core.debug_reg(c, 0) as u16;
                            if r0 as usize + 64 > 16384 || r0 & 3 != 0 { continue; }
                            if core.read_sram_byte_unsigned(&(r0 + 63)) == 0 { continue; }
                            busy += 1;
                            if shown < 8 { shown += 1;
                                let w: Vec<String> = (0..16u16).map(|k| format!("{:08X}", core.read_sram_word(&(r0 + 4 * k)))).collect();
                                println!("LEAF_BUSY core {} ctx {} r0 {:04X} r1 {:04X} ray [{}]", core.get_core_id(), c, r0, core.debug_reg(c, 1), w.join(" "));
                                println!("LEAF_BUSY_HIST core {} ctx {} {}", core.get_core_id(), c, core.debug_hist(c, 48)); }
                        }
                    }
                    println!("LEAF_BUSY_COUNT stack {} {}", stack_num, busy);
                }
                // AI debug [91]: contexts spinning in ENSURE_SPACE_IN_QUEUE (blocked DRAM pushes): (own queue, target queue = r9 - 8) histogram
                if cycle as u64 == end_cycle {
                    let bp = branch_pc_of("peek the count first (test-and-test-and-set)"); let lp = leaf_pc_of("peek the count first (test-and-test-and-set)");
                    let mut h: std::collections::BTreeMap<(u32, u32, u32), u32> = std::collections::BTreeMap::new();
                    for core in stack.cores.iter() {
                        let isb = core.read_sram_word(&0x38u16); let p0 = if isb != 0 { bp } else { lp };
                        let (_, pcs, _, _) = core.debug_state();
                        for (c, pc) in pcs.iter().enumerate() { if *pc == p0 || *pc == p0 + 4 { *h.entry((isb, core.read_sram_word(&0x34u16), core.debug_reg(c, 9).wrapping_sub(8))).or_insert(0) += 1; println!("PUSHCTX core {} ctx {} own {} target {}", core.get_core_id(), c, ((core.read_sram_word(&0x30u16) as u64) << 32) | core.read_sram_word(&0x34u16) as u64, ((core.debug_membits(c) as u64) << 32) | core.debug_reg(c, 9).wrapping_sub(8) as u64); { let own64 = ((core.read_sram_word(&0x30u16) as u64) << 32) | core.read_sram_word(&0x34u16) as u64; let tg64 = ((core.debug_membits(c) as u64) << 32) | core.debug_reg(c, 9).wrapping_sub(8) as u64; if isb != 0 && (((tg64 == 1115000000 || tg64 == 1115032612) && own64 != 1115000000) || (own64 == 1115000000 && tg64 == 8723751168 && core.get_core_id() % 16 == 0)) { let r0 = core.debug_reg(c, 0) as u16; let r1 = core.debug_reg(c, 1) as u16; let ray: Vec<String> = (0..16u16).map(|k| format!("{:08X}", core.read_sram_word(&(r0.wrapping_add(4 * k) & 0xFFFC)))).collect(); let node: Vec<String> = (0..12u16).map(|k| format!("{:08X}", core.read_sram_word(&(r1.wrapping_add(4 * k) & 0xFFFC)))).collect(); println!("BACKRAY core {} ctx {} own {} target {} r0 {:04X} r1 {:04X} ray [{}] node [{}] hist {}", core.get_core_id(), c, own64, tg64, r0, r1, ray.join(" "), node.join(" "), core.debug_hist(c, 64)); } } } }
                    }
                    let mut v: Vec<_> = h.into_iter().collect(); v.sort_by(|a, b| b.1.cmp(&a.1));
                    for ((isb, from, to), n) in v.iter().take(30) { println!("PUSHWAIT stack {} {} from_q {} to_q {} contexts {}", stack_num, if *isb != 0 { "branch" } else { "leaf" }, from, to, n); }
                }
                // AI [127] (Alex): every 200K cycles, the owner count (cores serving the node) of every node queue in this stack, from
                //   the queue header (+24). Queue address -> node: the NODE ADDRESS lines at startup. Format: NODEOWN cycle C stack S
                //   n N total T : addr=owners ... (queues with 0 owners are left out; N counts the printed queues).
                if cycle % 200_000 == 0 && stack_num < 8 {
                    let bases: [usize; 8] = [1_115_000_000, 252_516_352, 100_000_000, 100_000_000, 100_000_000, 100_000_000, 100_000_000, 100_000_000];
                    let words = stack.dram_stack.len() * 4;
                    let (mut n, mut total) = (0u32, 0i64);
                    let mut parts: Vec<String> = Vec::new();
                    for k in 0..4000usize {
                        let q = bases[stack_num] + k * 65536; if q + 65536 > words { break; }
                        let own = dram_read_word(&stack.dram_stack, q + 24) as i32;
                        if own > 0 && own < 9000 { n += 1; total += own as i64; parts.push(format!("{}={}", ((stack_num as u64) << 31) + q as u64, own)); }
                    }
                    println!("NODEOWN cycle {} stack {} n {} total {} : {}", cycle, stack_num, n, total, parts.join(" "));
                }
                // AI debug [119]: contexts waiting for a queue's writer lock (ENSURE_NO_WRITERS peek, lock address = r9 - 20), and the header of
                //   every busy queue in this stack: main header count +8, lock +20, owners +24; receiver (+32612) count +8. Queues are 64KB apart.
                if cycle as u64 == end_cycle {
                    let bl = branch_pc_of("AI fix [66]: peek first") as u32; let ll = leaf_pc_of("AI fix [66]: peek first") as u32;
                    let mut lw: std::collections::BTreeMap<(u32, u64), u32> = std::collections::BTreeMap::new();
                    for core in stack.cores.iter() {
                        let isb = core.read_sram_word(&0x38u16); let p0 = if isb != 0 { bl } else { ll };
                        let (_, pcs, _, _) = core.debug_state();
                        for (c, pc) in pcs.iter().enumerate() { let pc = *pc as u32; if p0 != 0 && pc + 4 >= p0 && pc <= p0 + 4 {
                            let a = ((core.debug_membits(c) as u64) << 32) | core.debug_reg(c, 9).wrapping_sub(20) as u64; *lw.entry((isb, a)).or_insert(0) += 1; } }
                    }
                    for ((isb, a), n) in lw.iter() { if *n >= 3 { println!("LOCKWAIT stack {} {} queue {} contexts {}", stack_num, if *isb != 0 { "branch" } else { "leaf" }, a, n); } }
                    let bases: [usize; 8] = [1_115_000_000, 252_516_352, 100_000_000, 100_000_000, 100_000_000, 100_000_000, 100_000_000, 100_000_000];
                    if stack_num < 8 {
                        let words = stack.dram_stack.len() * 4;
                        for k in 0..4000usize {
                            let q = bases[stack_num] + k * 65536; if q + 65536 > words { break; }
                            let (cnt, lock, own) = (dram_read_word(&stack.dram_stack, q + 8) as i32, dram_read_word(&stack.dram_stack, q + 20) as i32, dram_read_word(&stack.dram_stack, q + 24) as i32);
                            let rc = if q + 32612 + 12 <= words && (q + 32612) % 4 == 0 { dram_read_word(&stack.dram_stack, q + 32612 + 8) as i32 } else { 0 };
                            if cnt >= 128 || lock != 0 || rc >= 128 { println!("QHDR stack {} queue {} count {} lock {} owners {} recv_count {}", stack_num, ((stack_num as u64) << 31) + q as u64, cnt, lock, own, rc); }
                        }
                    }
                }
                // AI debug [92]: own queue (full 64-bit) and all 16 context PCs of every core, joined with PUSHCTX offline
                if cycle as u64 == end_cycle {
                    { // AI [111]: contexts waiting in the direct-send handshake (SEND_RAY_LOOP / send_ray_loop): who they wait on
                        let (b0, b1) = (branch_pc_of("sendflit r12, r6, 32") as u32, branch_pc_of("bgt r11, r14, RAY_SEND_LOOP") as u32);
                        let (l0, l1) = (leaf_pc_of("sendflit r6, r11") as u32, leaf_pc_of("sendflit r7, r9") as u32);
                        for core in stack.cores.iter() { let (_, pcs, _, _) = core.debug_state(); let isb = core.read_sram_word(&0x38u16) != 0;
                            for (c, p) in pcs.iter().enumerate() { let p = *p as u32;
                                let waiting = if isb { p >= b0 && p < b1 } else { p >= l0 && p < l1 };
                                if waiting { let tgt = if isb { core.debug_reg(c, 6) } else { core.debug_reg(c, 9) } & 0xFFFF; let n = core.debug_reg(c, 1) as u16;
                                    println!("SENDWAIT core {} ctx {} pc {:04X} branch {} target {} node_id {} node_queue {:X}", core.get_core_id(), c, p, isb as u8, tgt, core.read_sram_word(&n.wrapping_add(44)), core.read_sram_word(&n.wrapping_add(36))); } } } }
                    for core in stack.cores.iter() { let (_, pcs, _, _) = core.debug_state(); println!("CORESTATE {} {} {} {}", core.get_core_id(), core.read_sram_word(&0x38u16), ((core.read_sram_word(&0x30u16) as u64) << 32) | core.read_sram_word(&0x34u16) as u64, pcs.iter().map(|p| format!("{:X}", p)).collect::<Vec<_>>().join(",")); }
                }
                // AI debug [72]: boot-table entries of cores that rebooted as clones (bit 30 of word 1), stack 0 only
                if cycle as u64 == end_cycle && stack_num == 0 {
                    let mut v = Vec::new();
                    for c in 0..8192usize { let w1 = dram_read_word(&stack.dram_stack, 20_000 + 8 * c + 4); if (w1 >> 30) & 1 == 1 { v.push(format!("{}:{}/{}{}", c, dram_read_word(&stack.dram_stack, 20_000 + 8 * c), w1 & 0x3FFF_FFFF, if w1 >> 31 == 1 { "B" } else { "L" })); } }
                    println!("CLONE_ENTRIES {} {}", v.len(), v.join(" "));
                }
                // AI debug [70]: which queue each core points at (SRAM RAY_QUEUE_LOW 0x34), one line per stack, to find orphaned queues
                if cycle as u64 == end_cycle {
                    let mut qm: std::collections::BTreeMap<u32, u32> = std::collections::BTreeMap::new();
                    for core in stack.cores.iter() { *qm.entry(core.read_sram_word(&0x34u16)).or_insert(0) += 1; }
                    println!("QOWN stack {} {}", stack_num, qm.iter().map(|(a, n)| format!("{}:{}", a, n)).collect::<Vec<_>>().join(" "));
                }
                // AI debug [54]: cloning state at the end of the run (idle pool + REASSIGN table live in stack 1)
                if cycle as u64 == end_cycle && stack_num == 1 {
                    let pool = (2_500_000_000u64 & 0x7FFF_FFFF) as usize;
                    println!("CLONE_POOL head {} tail {} count {}", dram_read_word(&stack.dram_stack, pool), dram_read_word(&stack.dram_stack, pool + 4), dram_read_word(&stack.dram_stack, pool + 8) as i32);
                    let req = (2_500_100_000u64 & 0x7FFF_FFFF) as usize;
                    let pending: Vec<String> = (0..8192usize).filter(|c| dram_read_word(&stack.dram_stack, req + 4 * c) != 0).map(|c| format!("{}<-{}", c, dram_read_word(&stack.dram_stack, req + 4 * c) - 1)).collect();
                    println!("CLONE_PENDING_REQUESTS {} [{}]", pending.len(), pending.iter().take(40).cloned().collect::<Vec<_>>().join(" "));
                }
                if cycle as u64 == end_cycle {
                    for (nid, is_branch, addr) in &queue_dump_list {
                        if (*addr >> 31) as usize != stack_num { continue; }
                        let base = (*addr & 0x7FFF_FFFF) as usize;
                        let (h, t, c) = (dram_read_word(&stack.dram_stack, base), dram_read_word(&stack.dram_stack, base + 4), dram_read_word(&stack.dram_stack, base + 8) as i32);
                        let rc = if *is_branch != 0 { dram_read_word(&stack.dram_stack, base + 32612 + 8) as i32 } else { 0 };
                        if c != 0 || h != t || rc != 0 {
                            println!("QDUMP node {} addr {} branch {} count {} head {} tail {} recv_count {} owners {} lock {} ticket {} serving {}", nid, addr, is_branch, c, h, t, rc, dram_read_word(&stack.dram_stack, base + 24) as i32, dram_read_word(&stack.dram_stack, base + 20) as i32, dram_read_word(&stack.dram_stack, base + 12), dram_read_word(&stack.dram_stack, base + 16)); // AI [70]: + owner list state
                        }
                    }
                }
                if stack.cores[0].get_core_id() == 0 && cycle % 10000 == 0 {
                    println!("Finished Cycle {}", cycle);
                }

                // if cycle == 999999 {
                //     println!("SIM TOOK TOO LONG");
                //     std::process::exit(1);
                // }
                if stack_num == 0 {
                    // if dram_read_word(&stack.dram_stack, 168_000_004) == 2560 * 1440 * 16 {
                    //     println!("WE RENDERED THE SCENE!!!");
                    //     println!(
                    //         "Local Read: {}, Local write: {}, foreign read: {}, foreign write: {}",
                    //         stack.local_read,
                    //         stack.local_write,
                    //         stack.foreign_read,
                    //         stack.foreign_write
                    //     );
                    //     done_per_thread.store(true, Ordering::Release);
                    // }
                    if cycle as u64 == end_cycle {
                        println!("FINAL RAYS_COMPLETED: {} of MAX_RAYS 58982400", dram_read_word(&stack.dram_stack, 168_000_000)); // AI [126]: single completion counter
                        if let Some(m) = crate::core::QCNT_LOG.get() { // AI debug [40]
                            for ((cid, pc), (sum, n)) in m.lock().unwrap().iter() {
                                println!("QCNT core {} pc {:04X} n {} sum {}", cid, pc, n, sum);
                            }
                        }
                        done_per_thread.store(true, Ordering::Release);
                    }
                    if dram_read_word(&stack.dram_stack, 168_000_000) != traversals_done_so_far { // AI [126]: was 168_000_008 (TRAVERSALS_DONE, removed)
                        traversals_done_so_far = dram_read_word(&stack.dram_stack, 168_000_000);
                        last_progress_cycle = cycle as u64; // AI [67]
                        if traversals_done_so_far % 10 == 0 || traversals_done_so_far < 10 {
                            println!("TRAVERSALS DONE: {} (cycle {})", traversals_done_so_far, cycle);
                        }
                    }
                    // AI [67]: no traversal for 200K cycles (after warm-up; AI [130]: armed only after the first completed ray or 10M cycles ([133]), since boot is now modeled and can take ~1.4M cycles): stop everyone 1000 cycles from now and dump
                    if cycle as u64 > 300_000 && (traversals_done_so_far > 0 || cycle as u64 > 10_000_000) && cycle as u64 - last_progress_cycle > 200_000 && STOP_AT.load(std::sync::atomic::Ordering::Relaxed) == u64::MAX {
                        println!("STALL DETECTED at cycle {}: no traversal since cycle {}; dumping and stopping", cycle, last_progress_cycle);
                        STOP_AT.store(cycle as u64 + 1000, std::sync::atomic::Ordering::Relaxed);
                    }
                    // AI [74]: rays in flight (RAYS_ENTERED 168_000_016 - RAYS_COMPLETED 168_000_000, AI [126]) every 50K cycles
                    if cycle % 50000 == 0 { let e = crate::core::ENTERED_SNAP.load(std::sync::atomic::Ordering::Relaxed); /* AI [B4]: RAYS_ENTERED lives on stack 2 (50_000_016); stack 2 publishes it one cycle earlier */  let r = dram_read_word(&stack.dram_stack, 168_000_000); println!("INFLIGHT cycle {} entered {} retired {} inflight {} leaf_hits {} branch_hits {} leaf_watch {:?} emerg_q {} emerg_flags {} noc_b {:?} noc_l {:?}", cycle, e, r, e as i64 - r as i64, crate::core::LEAF_HITS.load(std::sync::atomic::Ordering::Relaxed), crate::core::BRANCH_HITS.load(std::sync::atomic::Ordering::Relaxed), (0..4).map(|w| crate::core::LEAF_WATCH_N[w].load(std::sync::atomic::Ordering::Relaxed)).collect::<Vec<_>>(), dram_read_word(&stack.dram_stack, 62_000_008) as i32, (0..16384usize).filter(|q| dram_read_word(&stack.dram_stack, 63_500_000 + 4 * q) != 0).count(), (0..3).map(|w| crate::core::NOC_WATCH_N[w].load(std::sync::atomic::Ordering::Relaxed)).collect::<Vec<_>>(), (3..6).map(|w| crate::core::NOC_WATCH_N[w].load(std::sync::atomic::Ordering::Relaxed)).collect::<Vec<_>>()); }
                    // AI [71]: stop_run.flag in the working directory = stop everyone 1000 cycles from now and dump (lets Claude end a run without the screen)
                    if cycle % 10000 == 0 && STOP_AT.load(std::sync::atomic::Ordering::Relaxed) == u64::MAX && std::path::Path::new("stop_run.flag").exists() {
                        println!("STOP FLAG at cycle {}; dumping and stopping", cycle);
                        STOP_AT.store(cycle as u64 + 1000, std::sync::atomic::Ordering::Relaxed);
                    }
                    if dram_read_word(&stack.dram_stack, 168_000_000) != rays_completed_so_far {
                        rays_completed_so_far = dram_read_word(&stack.dram_stack, 168_000_000);
                        println!("RAYS COMPLETED_SO_FAR: {}", rays_completed_so_far);
                    }

                }
                barrier.wait();
                if done_per_thread.load(Ordering::Acquire) {
                    let mut stack_log = StackLog {
                        local_read: stack.local_read,
                        local_write: stack.local_write,
                        foreign_read: stack.foreign_read,
                        foreign_write: stack.foreign_write,
                        core_logs: vec![vec![None; CORES_IN_X as usize]; CORES_IN_Y as usize],
                        stack_id: stack_num,
                    };
                    for core in stack.cores {
                        let new_core_log = core.get_log();
                        stack_log.core_logs[core.get_y_index() % CORES_IN_Y as usize]
                            [core.get_x_index() % CORES_IN_X as usize] = Some(new_core_log);
                    }
                    return Some(stack_log);
                }
            }
            println!("FINISHED!");
            None
        });
        handles.push(handle);
    }
    let mut log_vec = vec![];
    for handle in handles {
        let log = handle
            .join()
            .expect("Thread panicked!")
            .expect("Thread Took the long way out???");
        log_vec.push(log);
    }
    if !PRINT_STATS {
        return;
    }
    println!("DUMPING LOGS");
    dump_logs_for_viz(
        &log_vec,
        "sim_logs",
        CORES_IN_X as usize,
        CORES_IN_Y as usize,
        CORES_IN_X_STACK as usize,
        CORES_IN_Y_STACK as usize,
    )
    .expect("failed to dump logs");
}
