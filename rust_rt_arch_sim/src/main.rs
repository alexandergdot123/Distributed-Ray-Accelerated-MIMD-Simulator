use crate::auto_gen_code::get_init_vector;
use crate::core::{
    BidirectionalNoc, CORES_IN_X, CORES_IN_Y, Core, DEBUG, DRAM_LATENCY_FAR, DRAM_STACK_SIZE,
    Feeder, LongDramOp, LongDramRequest, NOC_FIFO_LATENCY, NOC_FIFO_SIZE, Operation, SpscQueue,
};
use crate::matrices::{MAT_A, MAT_B, MAT_C};
use crate::parse_bvh::{QPoint, assemble_tree, read_indices, read_nodes, read_triangles, subtree_leaf_size};
pub mod auto_gen_code;
pub mod core;
pub mod matrices;
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
            let rightwards = SpscQueue::new(NOC_FIFO_SIZE);
            let leftwards = SpscQueue::new(NOC_FIFO_SIZE);
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
            let upwards = SpscQueue::new(NOC_FIFO_SIZE);
            let downwards = SpscQueue::new(NOC_FIFO_SIZE);
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
            let (feeder, eater) = SpscQueue::new(DRAM_LATENCY_FAR as usize).split();
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
    request: LongDramRequest,
    forward_dram_result_to_stack: &mut Vec<Sender<LongDramOp>>,
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
    if response_load.is_some() {
        let loaded_value = response_load.unwrap();
        let response = LongDramOp {
            core_id: request.core_id,
            register_index: request.register_index,
            calculated_val: loaded_value,
        };
        let could_send = forward_dram_result_to_stack[request.origin_stack].send(response);
        if let Err(e) = could_send {
            println!("Failed to send DRAM response: {:?}", e);
        }
    }
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
) -> (Vec<(u32, u16, u16, u16)>, Vec<[f32; 3]>) {
    // Walk the subtree, gathering triangles in DFS order and deduping
    // vertices the SAME way the partitioner does.
    let mut vertex_map: HashMap<parse_bvh::QPoint, u16> = HashMap::new();
    let mut vertices: Vec<[f32; 3]> = Vec::new();
    let mut indices: Vec<(u32, u16, u16, u16)> = Vec::new();

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
    ) {
        let n = &nodes[idx];
        if n.is_leaf {
            for i in n.first_tri..n.first_tri + n.tri_count {
                let t = &triangles[i];
                let v0 = intern(t.v0, vertex_map, vertices);
                let v1 = intern(t.v1, vertex_map, vertices);
                let v2 = intern(t.v2, vertex_map, vertices);
                indices.push((indices.len() as u32, v0, v1, v2));
            }
            return;
        }
        walk(n.left_child, nodes, triangles, vertex_map, vertices, indices);
        walk(n.right_child, nodes, triangles, vertex_map, vertices, indices);
    }

    walk(node_id, nodes, triangles, &mut vertex_map, &mut vertices, &mut indices);

    println!(
        "node {}: tris={} unique_vertices={}",
        node_id, indices.len(), vertices.len()
    );

    (indices, vertices)
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

    // Now use it:
    for (_, _, node_id, is_branch) in &node_id_vec {
        if *is_branch != 0 {
            continue;
        }
        let i = node_id_hash_map.get(node_id).unwrap().0;
        let address = address_ray_queue_hash_map.get(&i).unwrap();
        let (indices, vertices) =
            indexed_mesh_for_node_partitioner(*node_id as usize, &nodes_p, &tris_p);
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
                index_set.0,
            );
            dram_store_half(
                &mut stacks[stack_num as usize].dram_stack,
                intra_stack_addr as usize + address_inc + 4,
                index_set.1 as u32,
            );
            dram_store_half(
                &mut stacks[stack_num as usize].dram_stack,
                intra_stack_addr as usize + address_inc + 6,
                index_set.2 as u32,
            );
            dram_store_half(
                &mut stacks[stack_num as usize].dram_stack,
                intra_stack_addr as usize + address_inc + 8,
                index_set.3 as u32,
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
        stacks[1].dram_stack[12 * node_id as usize + 11 + node_array_start] =
            node_id_hash_map.get(&node_id).unwrap().1;
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

    let idle_queue_base = 63_300_000 / 4;
    
    for i in 0..8 {
        stacks[i].dram_stack[idle_queue_base] = 0; // head_relative = 0
        stacks[i].dram_stack[idle_queue_base + 1] = 0; // tail_relative = 0
        stacks[i].dram_stack[idle_queue_base + 2] = 0; // count = 0
        stacks[i].dram_stack[idle_queue_base + 3] = ((i >> 1) as u32) & 3 ; // parent_node_high
        stacks[i].dram_stack[idle_queue_base + 4] = (63_400_000 + (((i as u32) & 1) << 31)) / 4; // parent_node_low
        for j in 0..8192 {
            stacks[i].dram_stack[idle_queue_base + 5 + j] = 0; // mark all slots invalid initially
        }
    }

    let idle_tree_level_1 = 63_400_000 / 4;
    for i in 0..4 {
        stacks[i * 2].dram_stack[idle_tree_level_1] = ((i >> 1) as u32) & 3; // parent_high
        stacks[i * 2].dram_stack[idle_tree_level_1 + 1] = (63_400_100 + ((((i >> 1) as u32) & 1) << 31)); // parent_low
        stacks[i * 2].dram_stack[idle_tree_level_1 + 2] = (i as u32); // left_high
        stacks[i * 2].dram_stack[idle_tree_level_1 + 3] = (63_300_000) / 4; // left_low
        stacks[i * 2].dram_stack[idle_tree_level_1 + 4] = (i as u32); // right_high
        stacks[i * 2].dram_stack[idle_tree_level_1 + 5] = (63_300_000 | (1 << 31)) / 4; // right_low
        stacks[i * 2].dram_stack[idle_tree_level_1 + 6] = 0 | 0; // is_left = 0 for root
    }

    let idle_tree_level_2 = 63_400_100 / 4;
    for i in 0..2 {
        stacks[i * 4].dram_stack[idle_tree_level_2] = ((i >> 1) as u32) & 3; // parent_high
        stacks[i * 4].dram_stack[idle_tree_level_2 + 1] = 63_400_200; // parent_low
        stacks[i * 4].dram_stack[idle_tree_level_2 + 2] = (i as u32) * 2; // left_high
        stacks[i * 4].dram_stack[idle_tree_level_2 + 3] = (63_400_000) / 4; // left_low
        stacks[i * 4].dram_stack[idle_tree_level_2 + 4] = (i as u32) * 2 | 1; // right_high
        stacks[i * 4].dram_stack[idle_tree_level_2 + 5] = (63_400_000 | (1 << 31)) / 4; // right_low
        stacks[i * 4].dram_stack[idle_tree_level_2 + 6] = 0 | 1; // is_left = 0 for root
    }

    let idle_tree_level_3 = 63_400_200 / 4;
    for i in 0..1 {
        stacks[i * 8].dram_stack[idle_tree_level_3] = 0; // parent_high
        stacks[i * 8].dram_stack[idle_tree_level_3 + 1] = 0; // parent_low
        stacks[i * 4].dram_stack[idle_tree_level_3 + 2] = 0; // left_high
        stacks[i * 4].dram_stack[idle_tree_level_3 + 3] = (63_400_100) / 4; // left_low
        stacks[i * 4].dram_stack[idle_tree_level_3 + 4] = 1; // right_high
        stacks[i * 4].dram_stack[idle_tree_level_3 + 5] = (63_400_100) / 4; // right_low
        stacks[i * 4].dram_stack[idle_tree_level_3 + 6] = 0 | 2; // is_left = 0 for root
    }

    

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
    for (stack_num, mut stack) in stacks.into_iter().enumerate() {
        let barrier = barrier.clone();
        let done_per_thread = done.clone();
        let cores_to_monitor = cores_to_watch.clone();
        let handle = thread::spawn(move || -> Option<StackLog> {
            let mut rays_completed_so_far = 0;
            for cycle in 0..1500 * 1000 * 16 {
                let mut local_read = 0;
                let mut local_write = 0;
                for core in stack.cores.iter_mut() {
                    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        core.tick(&mut stack.dram_stack, &cores_to_monitor, &context_to_watch);
                    }));
                    if let Err(e) = result {
                        panic!("Core {} panicked: {:?}", core.get_core_id(), e);
                    }
                    local_read += core.get_local_read();
                    local_write += core.get_local_write();
                }
                stack.local_read = local_read;
                stack.local_write = local_write;
                while let Ok(request) = stack.service_other_stack.try_recv() {
                    let (read, written) = service_far_dram_request(
                        &mut stack.dram_stack,
                        request,
                        &mut stack.return_result_to_stack,
                    );
                    stack.foreign_read += read;
                    stack.foreign_write += written;
                }
                while let Ok(response) = stack.receive_dram_result_from_stack.try_recv() {
                    let core_index = stack.core_hash[&response.core_id];
                    let _could_send = stack.forward_dram_result_to_core[core_index].push(response);
                }
                if stack.cores[0].get_core_id() == 0 && cycle % 10000 == 0 {
                    println!("Finished Cycle {}", cycle);
                }

                // if cycle == 999999 {
                //     println!("SIM TOOK TOO LONG");
                //     std::process::exit(1);
                // }
                if stack_num == 0 {
                    if dram_read_word(&stack.dram_stack, 168_000_004) == 2560 * 1440 * 16 {
                        println!("WE RENDERED THE SCENE!!!");
                        println!(
                            "Local Read: {}, Local write: {}, foreign read: {}, foreign write: {}",
                            stack.local_read,
                            stack.local_write,
                            stack.foreign_read,
                            stack.foreign_write
                        );
                        done_per_thread.store(true, Ordering::Release);
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
