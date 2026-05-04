g// #[derive(Debug, Copy, Clone, PartialEq)]
// pub struct Point {
//     pub x: f32,
//     pub y: f32,
//     pub z: f32,
// }

// #[derive(Hash, Eq, PartialEq, Copy, Clone, Debug)]
// pub struct QPoint {
//     x: i64,
//     y: i64,
//     z: i64,
// }

// pub(crate) fn snap(point: Point) -> QPoint {
//     QPoint {
//         x: (point.x * 10000.0) as i64,
//         y: (point.y * 10000.0) as i64,
//         z: (point.z * 10000.0) as i64,
//     }
// }

// impl Point {
//     pub fn new(x: f32, y: f32, z: f32) -> Self {
//         Self { x, y, z }
//     }
// }

// #[derive(Debug, Copy, Clone, PartialEq)]
// pub struct Node {
//     pub(crate) index: usize,
//     min: Point,
//     max: Point,
//     pub(crate) left_child: usize,
//     pub(crate) is_leaf: bool,
//     pub(crate) right_child: usize,
//     pub(crate) tri_count: usize,
//     pub(crate) first_tri: usize,
// }

// #[derive(Debug, Copy, Clone, PartialEq)]
// pub struct Indices {
//     pub node_index: usize,
//     pub first_triangle_index: usize,
//     pub num_triangles: usize,
// }

// #[derive(Debug, Copy, Clone)]
// pub struct Triangle {
//     pub index: usize,
//     pub v0: Point,
//     pub v1: Point,
//     pub v2: Point,
// }

// use hashbrown::HashMap;
// use std::collections::HashSet;
// use std::fs::File;
// use std::io::{BufRead, BufReader, Write};

// // ---------------------------------------------------------------------------
// // Constants
// // ---------------------------------------------------------------------------

// const INDEX_SIZE: usize = 2;
// const POINT_SIZE: usize = 12;
// const NODE_SIZE: usize = 48;
// const MATERIAL_POINTER_SIZE: usize = 6;
// const MAX_ALLOC: usize = 32 * 1024;

// /// Phase 1: leaf cores use 65% of SRAM for owned geometry.
// const LEAF_OWNED_PCT: usize = 79;
// const LEAF_OWNED_BUDGET: usize = MAX_ALLOC * LEAF_OWNED_PCT / 100;

// /// Phase 2: branch treelets (above leaf cores) use the remaining 35%.
// const LEAF_OVERHEAD_BUDGET: usize = MAX_ALLOC - LEAF_OWNED_BUDGET;

// /// Phase 3: spine budget now equals the leaf owned budget.
// const SPINE_BUDGET: usize = LEAF_OWNED_BUDGET;

// /// Phase 4: absorb small branch cores into the spine.
// /// Set to false to disable.
// const ENABLE_SPINE_ABSORPTION: bool = false;

// // ---------------------------------------------------------------------------
// // File readers (unchanged)
// // ---------------------------------------------------------------------------

// pub fn read_nodes(path: &str) -> Vec<Node> {
//     let reader = BufReader::new(File::open(path).expect("failed to open node file"));
//     let mut nodes = Vec::new();

//     for (line_index, line) in reader.lines().enumerate() {
//         let line = line.expect("failed to read line");
//         let line = line.trim();
//         if line.is_empty() || line.starts_with('#') {
//             continue;
//         }

//         let parts: Vec<&str> = line.split_whitespace().collect();
//         assert!(
//             parts.len() == 8 || parts.len() == 9,
//             "expected 8 or 9 fields, got {}: {}",
//             parts.len(),
//             line
//         );

//         let offset = if parts.len() == 9 { 1 } else { 0 };
//         let index: usize = if offset == 1 {
//             parts[0].trim_matches('`').parse().unwrap()
//         } else {
//             nodes.len()
//         };

//         let min = Point::new(
//             parts[offset + 0].parse().unwrap(),
//             parts[offset + 1].parse().unwrap(),
//             parts[offset + 2].parse().unwrap(),
//         );
//         let max = Point::new(
//             parts[offset + 3].parse().unwrap(),
//             parts[offset + 4].parse().unwrap(),
//             parts[offset + 5].parse().unwrap(),
//         );

//         let left_first: usize = parts[offset + 6].parse().unwrap();
//         let tri_count: usize = parts[offset + 7].parse().unwrap();

//         if index != 0 && left_first == 0 && tri_count == 0 {
//             nodes.push(Node {
//                 index,
//                 min,
//                 max,
//                 is_leaf: false,
//                 left_child: 0,
//                 right_child: 0,
//                 tri_count: 0,
//                 first_tri: 0,
//             });
//             continue;
//         }

//         let (left_child, right_child) = if tri_count == 0 {
//             (left_first, left_first + 1)
//         } else {
//             (0, 0)
//         };

//         nodes.push(Node {
//             index,
//             min,
//             max,
//             is_leaf: tri_count != 0,
//             left_child,
//             right_child,
//             tri_count,
//             first_tri: 0,
//         });
//     }
//     nodes
// }

// pub fn read_indices(path: &str) -> Vec<Indices> {
//     let reader = BufReader::new(File::open(path).expect("failed to open indices file"));
//     let mut indices = Vec::new();

//     for line in reader.lines() {
//         let line = line.expect("failed to read line");
//         let line = line.trim();
//         if line.is_empty() || line.starts_with('#') {
//             continue;
//         }

//         let parts: Vec<&str> = line.split_whitespace().collect();
//         assert!(
//             parts.len() == 3,
//             "expected 3 fields, got {}: {}",
//             parts.len(),
//             line
//         );

//         indices.push(Indices {
//             node_index: parts[0].parse().unwrap(),
//             first_triangle_index: parts[1].parse().unwrap(),
//             num_triangles: parts[2].parse().unwrap(),
//         });
//     }
//     indices
// }

// pub fn read_triangles(path: &str) -> Vec<Triangle> {
//     let reader = BufReader::new(File::open(path).expect("failed to open triangle file"));
//     let mut tris = Vec::new();

//     for line in reader.lines() {
//         let line = line.expect("failed to read line");
//         let line = line.trim();
//         if line.is_empty() || line.starts_with('#') {
//             continue;
//         }

//         let parts: Vec<&str> = line.split_whitespace().collect();
//         assert!(
//             parts.len() == 9 || parts.len() == 10,
//             "expected 9 or 10 fields, got {}: {}",
//             parts.len(),
//             line
//         );

//         let offset = if parts.len() == 10 { 1 } else { 0 };
//         let index = if offset == 1 {
//             parts[0].parse().unwrap()
//         } else {
//             tris.len()
//         };

//         let v0 = Point::new(
//             parts[offset + 0].parse().unwrap(),
//             parts[offset + 1].parse().unwrap(),
//             parts[offset + 2].parse().unwrap(),
//         );
//         let v1 = Point::new(
//             parts[offset + 3].parse().unwrap(),
//             parts[offset + 4].parse().unwrap(),
//             parts[offset + 5].parse().unwrap(),
//         );
//         let v2 = Point::new(
//             parts[offset + 6].parse().unwrap(),
//             parts[offset + 7].parse().unwrap(),
//             parts[offset + 8].parse().unwrap(),
//         );

//         tris.push(Triangle { index, v0, v1, v2 });
//     }
//     tris
// }

// // ---------------------------------------------------------------------------
// // Parent map
// // ---------------------------------------------------------------------------

// fn build_parent_map(nodes: &[Node]) -> Vec<Option<usize>> {
//     let mut parents = vec![None; nodes.len()];
//     for node in nodes {
//         if !node.is_leaf && !(node.left_child == 0 && node.right_child == 0) {
//             if node.left_child < nodes.len() {
//                 parents[node.left_child] = Some(node.index);
//             }
//             if node.right_child < nodes.len() {
//                 parents[node.right_child] = Some(node.index);
//             }
//         }
//     }
//     parents
// }

// // ---------------------------------------------------------------------------
// // Size computation helpers
// // ---------------------------------------------------------------------------

// /// Compute the SRAM cost of a leaf subtree rooted at `index`.
// /// Counts: NODE_SIZE per internal/leaf node, plus geometry at leaves
// /// (deduplicated vertex points + index/material overhead per triangle).
// /// Stops (inclusive) at nodes in `boundary` — they count as NODE_SIZE stubs.
// pub fn subtree_leaf_size(
//     index: usize,
//     nodes: &[Node],
//     triangles: &[Triangle],
//     boundary: &HashSet<usize>,
//     points: &mut HashMap<QPoint, ()>,
// ) -> (usize, usize) {
//     let node = &nodes[index];

//     if node.is_leaf {
//         let mut size = NODE_SIZE;
//         for i in node.first_tri..node.first_tri + node.tri_count {
//             size += INDEX_SIZE * 3 + MATERIAL_POINTER_SIZE;
//             points.insert(snap(triangles[i].v0), ());
//             points.insert(snap(triangles[i].v1), ());
//             points.insert(snap(triangles[i].v2), ());
//         }
//         return (size, node.tri_count);
//     }

//     let mut size = NODE_SIZE;
//     let mut tris = 0;

//     if boundary.contains(&node.left_child) {
//         size += NODE_SIZE;
//     } else {
//         let (s, t) = subtree_leaf_size(node.left_child, nodes, triangles, boundary, points);
//         size += s;
//         tris += t;
//     }

//     if boundary.contains(&node.right_child) {
//         size += NODE_SIZE;
//     } else {
//         let (s, t) = subtree_leaf_size(node.right_child, nodes, triangles, boundary, points);
//         size += s;
//         tris += t;
//     }

//     (size, tris)
// }

// fn leaf_treelet_cost(
//     index: usize,
//     nodes: &[Node],
//     triangles: &[Triangle],
//     boundary: &HashSet<usize>,
// ) -> usize {
//     let mut points: HashMap<QPoint, ()> = HashMap::new();
//     let (node_bytes, tri_count) = subtree_leaf_size(index, nodes, triangles, boundary, &mut points);
//     println!(
//         "LEAF {}: tris={} unique_vertices={}",
//         index, tri_count, points.len()
//     );
//     node_bytes + points.len() * POINT_SIZE
// }

// /// Size of a branch treelet: traverse from `index` down, stopping
// /// (inclusive as NODE_SIZE stubs) at nodes in `leaf_roots`.
// fn branch_treelet_size(index: usize, nodes: &[Node], leaf_roots: &HashSet<usize>) -> usize {
//     if leaf_roots.contains(&index) {
//         return NODE_SIZE; // stub for leaf core root
//     }
//     let node = &nodes[index];
//     if node.is_leaf {
//         // Shouldn't normally happen — a BVH leaf not claimed by any leaf core
//         return NODE_SIZE;
//     }
//     NODE_SIZE
//         + branch_treelet_size(node.left_child, nodes, leaf_roots)
//         + branch_treelet_size(node.right_child, nodes, leaf_roots)
// }

// /// Size of the spine: traverse from root down, stopping (inclusive as
// /// NODE_SIZE stubs) at branch core roots.
// fn spine_size(index: usize, nodes: &[Node], branch_roots: &HashSet<usize>) -> usize {
//     if branch_roots.contains(&index) {
//         return NODE_SIZE; // stub
//     }
//     let node = &nodes[index];
//     if node.is_leaf {
//         return NODE_SIZE;
//     }
//     NODE_SIZE
//         + spine_size(node.left_child, nodes, branch_roots)
//         + spine_size(node.right_child, nodes, branch_roots)
// }

// /// Compute the full SRAM cost of an entire subtree rooted at `index`,
// /// traversing all the way down to BVH leaves (no boundary).
// /// Accumulates vertices into the provided shared `points` map for
// /// cross-subtree deduplication.
// /// Returns the non-vertex bytes (nodes + index/material overhead).
// fn full_subtree_node_bytes(
//     index: usize,
//     nodes: &[Node],
//     triangles: &[Triangle],
//     points: &mut HashMap<QPoint, ()>,
// ) -> usize {
//     let node = &nodes[index];
//     if node.is_leaf {
//         let mut size = NODE_SIZE;
//         for i in node.first_tri..node.first_tri + node.tri_count {
//             size += INDEX_SIZE * 3 + MATERIAL_POINTER_SIZE;
//             points.insert(snap(triangles[i].v0), ());
//             points.insert(snap(triangles[i].v1), ());
//             points.insert(snap(triangles[i].v2), ());
//         }
//         return size;
//     }
//     NODE_SIZE
//         + full_subtree_node_bytes(node.left_child, nodes, triangles, points)
//         + full_subtree_node_bytes(node.right_child, nodes, triangles, points)
// }

// /// Total SRAM cost of a full subtree (nodes + deduplicated vertices).
// fn full_subtree_cost(index: usize, nodes: &[Node], triangles: &[Triangle]) -> usize {
//     let mut points: HashMap<QPoint, ()> = HashMap::new();
//     let node_bytes = full_subtree_node_bytes(index, nodes, triangles, &mut points);
//     node_bytes + points.len() * POINT_SIZE
// }

// /// Compute the total spine cost, where:
// ///   - branch_roots that are NOT in `absorbed` are stubs (NODE_SIZE).
// ///   - branch_roots that ARE in `absorbed` are fully expanded with geometry.
// ///   - Vertices are deduplicated across ALL absorbed subtrees + spine nodes.
// /// Returns total bytes.
// fn spine_cost_with_absorbed(
//     nodes: &[Node],
//     triangles: &[Triangle],
//     branch_roots: &HashSet<usize>,
//     absorbed: &HashSet<usize>,
// ) -> usize {
//     let mut points: HashMap<QPoint, ()> = HashMap::new();
//     let node_bytes =
//         spine_node_bytes_recursive(0, nodes, triangles, branch_roots, absorbed, &mut points);
//     node_bytes + points.len() * POINT_SIZE
// }

// /// Recursive helper for spine_cost_with_absorbed.
// fn spine_node_bytes_recursive(
//     index: usize,
//     nodes: &[Node],
//     triangles: &[Triangle],
//     branch_roots: &HashSet<usize>,
//     absorbed: &HashSet<usize>,
//     points: &mut HashMap<QPoint, ()>,
// ) -> usize {
//     if branch_roots.contains(&index) {
//         if absorbed.contains(&index) {
//             // Fully expand this subtree with geometry
//             return full_subtree_node_bytes(index, nodes, triangles, points);
//         } else {
//             return NODE_SIZE; // stub
//         }
//     }
//     let node = &nodes[index];
//     if node.is_leaf {
//         // A BVH leaf in the spine (unusual but handle it)
//         let mut size = NODE_SIZE;
//         for i in node.first_tri..node.first_tri + node.tri_count {
//             size += INDEX_SIZE * 3 + MATERIAL_POINTER_SIZE;
//             points.insert(snap(triangles[i].v0), ());
//             points.insert(snap(triangles[i].v1), ());
//             points.insert(snap(triangles[i].v2), ());
//         }
//         return size;
//     }
//     NODE_SIZE
//         + spine_node_bytes_recursive(
//             node.left_child,
//             nodes,
//             triangles,
//             branch_roots,
//             absorbed,
//             points,
//         )
//         + spine_node_bytes_recursive(
//             node.right_child,
//             nodes,
//             triangles,
//             branch_roots,
//             absorbed,
//             points,
//         )
// }

// /// Count total descendant nodes (all the way down, no boundary).
// fn count_total_descendants(index: usize, nodes: &[Node]) -> usize {
//     let node = &nodes[index];
//     if node.is_leaf {
//         return 1;
//     }
//     1 + count_total_descendants(node.left_child, nodes)
//         + count_total_descendants(node.right_child, nodes)
// }

// // ---------------------------------------------------------------------------
// // Phase 1: Bottom-up greedy leaf treelet growth
// // ---------------------------------------------------------------------------

// /// Collect all BVH leaf node indices.
// fn collect_bvh_leaves(nodes: &[Node]) -> Vec<usize> {
//     nodes
//         .iter()
//         .filter(|n| n.is_leaf)
//         .map(|n| n.index)
//         .collect()
// }

// /// Phase 1: Starting from each unclaimed BVH leaf, greedily grow upward.
// ///
// /// At each step we try to move from the current root to its parent,
// /// which would absorb the parent node and the sibling's entire subtree.
// /// We re-evaluate the full cost of the new subtree (with deduplication).
// /// If it fits in LEAF_OWNED_BUDGET, we absorb it: mark all newly-claimed
// /// BVH leaves as covered and continue climbing.
// ///
// /// Returns the set of leaf core roots.
// fn phase1_leaf_partition(
//     nodes: &[Node],
//     triangles: &[Triangle],
//     parents: &[Option<usize>],
// ) -> Vec<usize> {
//     let mut unclaimed: HashSet<usize> = collect_bvh_leaves(nodes).into_iter().collect();

//     let mut leaf_core_roots: Vec<usize> = Vec::new();

//     // Process leaves smallest-first for better packing.
//     // We'll iterate until unclaimed is empty.
//     while !unclaimed.is_empty() {
//         // Pick an arbitrary unclaimed BVH leaf to seed a new treelet.
//         let seed = *unclaimed.iter().next().unwrap();
//         let mut current_root = seed;

//         // The set of BVH leaves currently inside this treelet.
//         let mut owned_leaves: HashSet<usize> = HashSet::new();
//         owned_leaves.insert(seed);
//         unclaimed.remove(&seed);

//         // Try to grow upward.
//         loop {
//             let parent = match parents[current_root] {
//                 Some(p) => p,
//                 None => break, // reached BVH root
//             };

//             // The sibling is the other child of parent.
//             let parent_node = &nodes[parent];
//             let sibling = if parent_node.left_child == current_root {
//                 parent_node.right_child
//             } else {
//                 parent_node.left_child
//             };

//             // Compute cost if we expand to `parent` as new root.
//             // The boundary is empty — we own everything below `parent`.
//             let cost = leaf_treelet_cost(parent, nodes, triangles, &HashSet::new());

//             if cost > LEAF_OWNED_BUDGET {
//                 break; // can't grow further
//             }

//             // Absorb: collect all BVH leaves under sibling and mark them claimed.
//             let sibling_leaves = collect_leaves_under(sibling, nodes);
//             for &sl in &sibling_leaves {
//                 unclaimed.remove(&sl);
//                 owned_leaves.insert(sl);
//             }

//             current_root = parent;
//         }

//         leaf_core_roots.push(current_root);
//     }

//     leaf_core_roots
// }

// /// Collect all BVH leaf indices under a given subtree root.
// fn collect_leaves_under(index: usize, nodes: &[Node]) -> Vec<usize> {
//     let node = &nodes[index];
//     if node.is_leaf {
//         return vec![index];
//     }
//     let mut result = collect_leaves_under(node.left_child, nodes);
//     result.extend(collect_leaves_under(node.right_child, nodes));
//     result
// }

// // ---------------------------------------------------------------------------
// // Phase 2: Branch treelet growth from leaf core roots
// // ---------------------------------------------------------------------------

// /// Phase 2: Starting from each unclaimed leaf core root, greedily grow
// /// upward, building branch treelets.
// ///
// /// A branch treelet's cost = all interior nodes from its root down to
// /// (inclusive) leaf core roots, which appear as NODE_SIZE stubs.
// ///
// /// We use the remaining 35% of SRAM (LEAF_OVERHEAD_BUDGET).
// ///
// /// At each step, move from current root to its parent. Re-evaluate the
// /// branch treelet cost from the parent down to all leaf core root stubs.
// /// If it fits, absorb (mark all newly-claimed leaf core roots). If not,
// /// emit the previous root as a branch core root.
// ///
// /// Returns the set of branch core roots.
// fn phase2_branch_partition(
//     nodes: &[Node],
//     leaf_core_roots: &HashSet<usize>,
//     parents: &[Option<usize>],
// ) -> Vec<usize> {
//     let mut unclaimed: HashSet<usize> = leaf_core_roots.clone();
//     let mut branch_core_roots: Vec<usize> = Vec::new();

//     while !unclaimed.is_empty() {
//         let seed = *unclaimed.iter().next().unwrap();
//         let mut current_root = seed;

//         // Leaf core roots owned by this branch treelet so far.
//         let mut owned_lcrs: HashSet<usize> = HashSet::new();
//         owned_lcrs.insert(seed);
//         unclaimed.remove(&seed);

//         // The initial cost is just one stub: NODE_SIZE.
//         // But we need to start climbing to actually form a branch treelet.
//         // A single leaf core root by itself isn't a branch treelet —
//         // we need to go up at least to the parent to get interior nodes.

//         loop {
//             let parent = match parents[current_root] {
//                 Some(p) => p,
//                 None => break, // reached BVH root
//             };

//             // Cost of branch treelet rooted at `parent`, with all leaf
//             // core roots as stubs.
//             let cost = branch_treelet_size(parent, nodes, leaf_core_roots);

//             if cost > LEAF_OVERHEAD_BUDGET {
//                 break; // can't grow further
//             }

//             // Absorb: collect all leaf core roots under sibling.
//             let parent_node = &nodes[parent];
//             let sibling = if parent_node.left_child == current_root {
//                 parent_node.right_child
//             } else {
//                 parent_node.left_child
//             };

//             let sibling_lcrs = collect_lcrs_under(sibling, nodes, leaf_core_roots);
//             for &sl in &sibling_lcrs {
//                 unclaimed.remove(&sl);
//                 owned_lcrs.insert(sl);
//             }

//             current_root = parent;
//         }

//         branch_core_roots.push(current_root);
//     }

//     branch_core_roots
// }

// /// Collect all leaf core roots that exist under a given subtree.
// fn collect_lcrs_under(
//     index: usize,
//     nodes: &[Node],
//     leaf_core_roots: &HashSet<usize>,
// ) -> Vec<usize> {
//     if leaf_core_roots.contains(&index) {
//         return vec![index];
//     }
//     let node = &nodes[index];
//     if node.is_leaf {
//         return vec![];
//     }
//     let mut result = collect_lcrs_under(node.left_child, nodes, leaf_core_roots);
//     result.extend(collect_lcrs_under(node.right_child, nodes, leaf_core_roots));
//     result
// }

// // ---------------------------------------------------------------------------
// // Utilities
// // ---------------------------------------------------------------------------

// fn count_subtree_nodes(index: usize, nodes: &[Node]) -> (usize, usize) {
//     let node = &nodes[index];
//     if node.is_leaf {
//         return (node.tri_count, 1);
//     }
//     let (a, b) = count_subtree_nodes(node.left_child, nodes);
//     let (c, d) = count_subtree_nodes(node.right_child, nodes);
//     (a + c, 1 + b + d)
// }

// fn count_subtree_tris_bounded(index: usize, nodes: &[Node], boundary: &HashSet<usize>) -> usize {
//     if boundary.contains(&index) {
//         return 0; // stub — no tris
//     }
//     let node = &nodes[index];
//     if node.is_leaf {
//         return node.tri_count;
//     }
//     count_subtree_tris_bounded(node.left_child, nodes, boundary)
//         + count_subtree_tris_bounded(node.right_child, nodes, boundary)
// }

// fn count_subtree_nodes_bounded(index: usize, nodes: &[Node], boundary: &HashSet<usize>) -> usize {
//     if boundary.contains(&index) {
//         return 1; // stub
//     }
//     let node = &nodes[index];
//     if node.is_leaf {
//         return 1;
//     }
//     1 + count_subtree_nodes_bounded(node.left_child, nodes, boundary)
//         + count_subtree_nodes_bounded(node.right_child, nodes, boundary)
// }

// /// Map each leaf core root to the branch core root that owns it.
// fn map_lcrs_to_branches(
//     branch_roots: &[usize],
//     leaf_core_roots: &HashSet<usize>,
//     nodes: &[Node],
// ) -> HashMap<usize, usize> {
//     let mut result = HashMap::new();
//     for &br in branch_roots {
//         assign_lcrs(br, br, nodes, leaf_core_roots, &mut result);
//     }
//     result
// }

// fn assign_lcrs(
//     index: usize,
//     branch_root: usize,
//     nodes: &[Node],
//     leaf_core_roots: &HashSet<usize>,
//     result: &mut HashMap<usize, usize>,
// ) {
//     if leaf_core_roots.contains(&index) {
//         result.insert(index, branch_root);
//         return;
//     }
//     let node = &nodes[index];
//     if node.is_leaf {
//         return;
//     }
//     assign_lcrs(node.left_child, branch_root, nodes, leaf_core_roots, result);
//     assign_lcrs(
//         node.right_child,
//         branch_root,
//         nodes,
//         leaf_core_roots,
//         result,
//     );
// }

// // ---------------------------------------------------------------------------
// // Skew score: measures how balanced a subtree is.
// //   depth_skew = max_depth - min_depth (of leaves under the root).
// //   0 = perfectly balanced; higher = more skewed.
// // ---------------------------------------------------------------------------

// /// Returns (min_leaf_depth, max_leaf_depth) for the subtree rooted at
// /// `index`, stopping at `boundary` nodes (treated as leaves at that depth).
// fn subtree_depth_range(
//     index: usize,
//     nodes: &[Node],
//     boundary: &HashSet<usize>,
//     depth: usize,
// ) -> (usize, usize) {
//     if boundary.contains(&index) {
//         return (depth, depth);
//     }
//     let node = &nodes[index];
//     if node.is_leaf {
//         return (depth, depth);
//     }
//     let (lmin, lmax) = subtree_depth_range(node.left_child, nodes, boundary, depth + 1);
//     let (rmin, rmax) = subtree_depth_range(node.right_child, nodes, boundary, depth + 1);
//     (lmin.min(rmin), lmax.max(rmax))
// }

// /// Skew score = max_leaf_depth - min_leaf_depth for the owned subtree.
// fn skew_score(root: usize, nodes: &[Node], boundary: &HashSet<usize>) -> usize {
//     let (min_d, max_d) = subtree_depth_range(root, nodes, boundary, 0);
//     max_d - min_d
// }

// // ---------------------------------------------------------------------------
// // Statistics helpers
// // ---------------------------------------------------------------------------

// fn stats_summary(values: &[f64]) -> (f64, f64, f64, f64, f64) {
//     // Returns (min, max, mean, median, std)
//     if values.is_empty() {
//         return (0.0, 0.0, 0.0, 0.0, 0.0);
//     }
//     let mut sorted = values.to_vec();
//     sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
//     let n = sorted.len();
//     let min = sorted[0];
//     let max = sorted[n - 1];
//     let mean = sorted.iter().sum::<f64>() / n as f64;
//     let median = if n % 2 == 0 {
//         (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
//     } else {
//         sorted[n / 2]
//     };
//     let variance = sorted.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / n as f64;
//     let std = variance.sqrt();
//     (min, max, mean, median, std)
// }

// fn print_stats(label: &str, values: &[f64]) {
//     let (min, max, mean, median, std) = stats_summary(values);
//     println!(
//         "  {}: min={:.1} max={:.1} mean={:.1} median={:.1} std={:.1}",
//         label, min, max, mean, median, std
//     );
// }

// /// Count triangles owned by a branch treelet (interior nodes between
// /// branch root and leaf core root stubs — stubs contribute 0 tris).
// fn branch_owned_tris(index: usize, nodes: &[Node], leaf_core_roots: &HashSet<usize>) -> usize {
//     if leaf_core_roots.contains(&index) {
//         return 0; // stub — leaf core owns these tris
//     }
//     let node = &nodes[index];
//     if node.is_leaf {
//         return node.tri_count;
//     }
//     branch_owned_tris(node.left_child, nodes, leaf_core_roots)
//         + branch_owned_tris(node.right_child, nodes, leaf_core_roots)
// }

// /// Count nodes owned by a branch treelet (including stubs).
// fn branch_owned_nodes(index: usize, nodes: &[Node], leaf_core_roots: &HashSet<usize>) -> usize {
//     if leaf_core_roots.contains(&index) {
//         return 1; // stub node
//     }
//     let node = &nodes[index];
//     if node.is_leaf {
//         return 1;
//     }
//     1 + branch_owned_nodes(node.left_child, nodes, leaf_core_roots)
//         + branch_owned_nodes(node.right_child, nodes, leaf_core_roots)
// }

// // ---------------------------------------------------------------------------
// // Main entry point
// // ---------------------------------------------------------------------------
// /// Count nodes from a branch core root down, treating each leaf core root
// /// as a single stub EXCEPT for `target_lcr` whose full subtree is expanded.
// fn count_leaf_plus_branch_path(
//     branch_root: usize,
//     target_lcr: usize,
//     nodes: &[Node],
//     leaf_core_roots: &HashSet<usize>,
// ) -> usize {
//     fn recurse(
//         index: usize,
//         target: usize,
//         nodes: &[Node],
//         lcrs: &HashSet<usize>,
//     ) -> usize {
//         if index == target {
//             // Expand the target leaf core's full subtree
//             return count_total_descendants(index, nodes);
//         }
//         if lcrs.contains(&index) {
//             return 1; // other leaf cores are stubs
//         }
//         let node = &nodes[index];
//         if node.is_leaf {
//             return 1;
//         }
//         1 + recurse(node.left_child, target, nodes, lcrs)
//           + recurse(node.right_child, target, nodes, lcrs)
//     }
//     recurse(branch_root, target_lcr, nodes, leaf_core_roots)
// }

// /// Returns (node_bytes, index_bytes, vertex_bytes) for a leaf treelet.
// fn leaf_treelet_cost_breakdown(
//     index: usize,
//     nodes: &[Node],
//     triangles: &[Triangle],
//     boundary: &HashSet<usize>,
// ) -> (usize, usize, usize) {
//     let mut points: HashMap<QPoint, ()> = HashMap::new();
//     let mut node_bytes = 0;
//     let mut index_bytes = 0;
//     accumulate_leaf_breakdown(
//         index,
//         nodes,
//         triangles,
//         boundary,
//         &mut points,
//         &mut node_bytes,
//         &mut index_bytes,
//     );
//     let vertex_bytes = points.len() * POINT_SIZE;
//     (node_bytes, index_bytes, vertex_bytes)
// }

// fn accumulate_leaf_breakdown(
//     index: usize,
//     nodes: &[Node],
//     triangles: &[Triangle],
//     boundary: &HashSet<usize>,
//     points: &mut HashMap<QPoint, ()>,
//     node_bytes: &mut usize,
//     index_bytes: &mut usize,
// ) {
//     let node = &nodes[index];
//     if node.is_leaf {
//         *node_bytes += NODE_SIZE;
//         for i in node.first_tri..node.first_tri + node.tri_count {
//             *index_bytes += INDEX_SIZE * 3 + MATERIAL_POINTER_SIZE;
//             points.insert(snap(triangles[i].v0), ());
//             points.insert(snap(triangles[i].v1), ());
//             points.insert(snap(triangles[i].v2), ());
//         }
//         return;
//     }
//     *node_bytes += NODE_SIZE;
//     if boundary.contains(&node.left_child) {
//         *node_bytes += NODE_SIZE;
//     } else {
//         accumulate_leaf_breakdown(node.left_child, nodes, triangles, boundary, points, node_bytes, index_bytes);
//     }
//     if boundary.contains(&node.right_child) {
//         *node_bytes += NODE_SIZE;
//     } else {
//         accumulate_leaf_breakdown(node.right_child, nodes, triangles, boundary, points, node_bytes, index_bytes);
//     }
// }


// pub fn assemble_tree(subfolder: String) {
//     let bvh_leaves_path = format!("bvh_leaves.txt");
//     let bvh_nodes_path = format!("bvh_nodes.txt");
//     let bvh_triangles_path = format!("bvh_triangles.txt");

//     let triangles = read_triangles(&bvh_triangles_path);
//     let indices = read_indices(&bvh_leaves_path);
//     let mut nodes = read_nodes(&bvh_nodes_path);

//     let mut expanded: Vec<Indices> = vec![
//         Indices {
//             node_index: 0,
//             first_triangle_index: 0,
//             num_triangles: 0
//         };
//         nodes.len().max(2_000_000)
//     ];
//     for idx in indices {
//         expanded[idx.node_index] = idx;
//     }
//     for node in nodes.iter_mut() {
//         node.first_tri = expanded[node.index].first_triangle_index;
//     }

//     println!(
//         "Loaded {} nodes, {} triangles",
//         nodes.len(),
//         triangles.len()
//     );
//     println!(
//         "Budgets: leaf_owned={}B ({:.1}KB) [{}%], leaf_overhead={}B ({:.1}KB) [{}%], spine={}B ({:.1}KB) [=leaf_owned]",
//         LEAF_OWNED_BUDGET,
//         LEAF_OWNED_BUDGET as f32 / 1024.0,
//         LEAF_OWNED_PCT,
//         LEAF_OVERHEAD_BUDGET,
//         LEAF_OVERHEAD_BUDGET as f32 / 1024.0,
//         100 - LEAF_OWNED_PCT,
//         SPINE_BUDGET,
//         SPINE_BUDGET as f32 / 1024.0,
//     );

//     // ── Build parent map ────────────────────────────────────────────────────
//     println!("\nBuilding parent map...");
//     let parents = build_parent_map(&nodes);

//     // ── Phase 1: Leaf treelet partitioning ──────────────────────────────────
//     println!(
//         "Phase 1: growing leaf treelets bottom-up (budget = {}B)...",
//         LEAF_OWNED_BUDGET
//     );
//     let leaf_core_roots_vec = phase1_leaf_partition(&nodes, &triangles, &parents);
//     let leaf_core_roots: HashSet<usize> = leaf_core_roots_vec.iter().cloned().collect();
//     println!("  → {} leaf core roots", leaf_core_roots.len());

//     // ── Phase 2: Branch treelet partitioning ────────────────────────────────
//     println!(
//         "Phase 2: growing branch treelets bottom-up from leaf core roots (budget = {}B)...",
//         LEAF_OVERHEAD_BUDGET
//     );
//     let mut branch_core_roots_vec = phase2_branch_partition(&nodes, &leaf_core_roots, &parents);
//     let mut branch_core_roots: HashSet<usize> = branch_core_roots_vec.iter().cloned().collect();
//     println!("  → {} branch core roots", branch_core_roots_vec.len());

//     // ── Phase 3: Spine validation ───────────────────────────────────────────
//     println!("Phase 3: validating spine (budget = {}B)...", SPINE_BUDGET);
//     let spine_total = spine_size(0, &nodes, &branch_core_roots);
//     let spine_fits = spine_total <= SPINE_BUDGET;
//     println!(
//         "  Spine: {}B ({:.1}KB) / {}B budget ({:.1}%) — {}",
//         spine_total,
//         spine_total as f32 / 1024.0,
//         SPINE_BUDGET,
//         100.0 * spine_total as f32 / SPINE_BUDGET as f32,
//         if spine_fits {
//             "OK"
//         } else {
//             "FAILURE — spine exceeds budget"
//         },
//     );

//     // ── Phase 4: Absorb small branch cores into the spine ───────────────────
//     let mut absorbed: HashSet<usize> = HashSet::new();
//     if ENABLE_SPINE_ABSORPTION && spine_fits {
//         println!(
//             "Phase 4: absorbing small branch cores into spine (remaining = {}B)...",
//             SPINE_BUDGET - spine_total
//         );

//         // Sort branch cores by total descendant count (ascending = smallest first).
//         let mut candidates: Vec<(usize, usize)> = branch_core_roots_vec
//             .iter()
//             .map(|&br| (br, count_total_descendants(br, &nodes)))
//             .collect();
//         candidates.sort_by_key(|&(_, desc)| desc);

//         let mut absorbed_count = 0usize;
//         let mut absorbed_tris = 0usize;

//         for (br, desc_count) in &candidates {
//             // Tentatively absorb this branch core.
//             let mut test_absorbed = absorbed.clone();
//             test_absorbed.insert(*br);

//             let new_spine_cost =
//                 spine_cost_with_absorbed(&nodes, &triangles, &branch_core_roots, &test_absorbed);

//             if new_spine_cost <= SPINE_BUDGET {
//                 let tris = count_subtree_nodes(*br, &nodes).0;
//                 absorbed.insert(*br);
//                 absorbed_count += 1;
//                 absorbed_tris += tris;
//                 println!(
//                     "  Absorbed branch {:>8}: {:>6} descendants, {:>6} tris | \
//                      spine now {}B ({:.1}KB) / {}B ({:.1}%)",
//                     br,
//                     desc_count,
//                     tris,
//                     new_spine_cost,
//                     new_spine_cost as f32 / 1024.0,
//                     SPINE_BUDGET,
//                     100.0 * new_spine_cost as f32 / SPINE_BUDGET as f32,
//                 );
//             }
//         }

//         // Remove absorbed branch cores from the active sets.
//         branch_core_roots_vec.retain(|br| !absorbed.contains(br));
//         branch_core_roots = branch_core_roots_vec.iter().cloned().collect();

//         let final_spine_cost = spine_cost_with_absorbed(
//             &nodes,
//             &triangles,
//             // We need the *original* branch roots to know where stubs were.
//             // But absorbed ones are now expanded. The remaining branch_core_roots
//             // are the stubs. We need to pass the union as "branch roots" and
//             // absorbed as "which to expand".
//             // Actually — now that we've removed absorbed from branch_core_roots,
//             // the spine just traverses through them naturally. Recompute cleanly.
//             &branch_core_roots,
//             &HashSet::new(), // no more absorbed — they're just part of the spine now
//         );

//         if absorbed_count > 0 {
//             println!(
//                 "  → Absorbed {} branch cores ({} tris) into spine",
//                 absorbed_count, absorbed_tris,
//             );
//             println!(
//                 "  → Final spine: {}B ({:.1}KB) / {}B ({:.1}%)",
//                 final_spine_cost,
//                 final_spine_cost as f32 / 1024.0,
//                 SPINE_BUDGET,
//                 100.0 * final_spine_cost as f32 / SPINE_BUDGET as f32,
//             );
//             println!(
//                 "  → Remaining branch cores: {}",
//                 branch_core_roots_vec.len(),
//             );
//         } else {
//             println!("  No branch cores small enough to absorb.");
//         }
//     } else if !ENABLE_SPINE_ABSORPTION {
//         println!("Phase 4: spine absorption disabled.");
//     } else {
//         println!("Phase 4: skipped — spine already over budget.");
//     }

//     // ── Validate leaf treelet sizes ─────────────────────────────────────────
//     println!("\nValidating leaf treelet sizes...");
//     let mut leaf_violations = 0usize;
//     let mut leaf_sizes: Vec<(usize, usize)> = Vec::new();
//     for &lr in &leaf_core_roots_vec {
//         let cost = leaf_treelet_cost(lr, &nodes, &triangles, &HashSet::new());
//         leaf_sizes.push((lr, cost));
//         if cost > LEAF_OWNED_BUDGET {
//             leaf_violations += 1;
//             println!(
//                 "  VIOLATION: leaf root {:>8}: {}B > {}B budget",
//                 lr, cost, LEAF_OWNED_BUDGET
//             );
//         }
//     }
//     if leaf_violations == 0 {
//         println!(
//             "  All {} leaf treelets fit within budget.",
//             leaf_core_roots.len()
//         );
//     }

//     // ── Validate branch treelet sizes ───────────────────────────────────────
//     println!("\nValidating branch treelet sizes...");
//     let mut branch_violations = 0usize;
//     for &br in &branch_core_roots_vec {
//         let cost = branch_treelet_size(br, &nodes, &leaf_core_roots);
//         if cost > LEAF_OVERHEAD_BUDGET {
//             branch_violations += 1;
//             println!(
//                 "  VIOLATION: branch root {:>8}: {}B > {}B budget",
//                 br, cost, LEAF_OVERHEAD_BUDGET
//             );
//         }
//     }
//     if branch_violations == 0 {
//         println!(
//             "  All {} branch treelets fit within budget.",
//             branch_core_roots_vec.len()
//         );
//     }

//     // ── Final report ────────────────────────────────────────────────────────
//     // Recompute spine cost post-absorption (geometry-aware).
//     let final_spine_size =
//         spine_cost_with_absorbed(&nodes, &triangles, &branch_core_roots, &HashSet::new());
//     let final_spine_fits = final_spine_size <= SPINE_BUDGET;

//     println!("\n── Final partition ──────────────────────────────────────────────");
//     println!("  Leaf cores:      {}", leaf_core_roots.len());
//     println!("  Branch cores:    {}", branch_core_roots_vec.len());
//     println!("  Absorbed into spine: {}", absorbed.len());
//     println!(
//         "  Total cores:     {} (+ 1 spine)",
//         leaf_core_roots.len() + branch_core_roots_vec.len()
//     );
//     println!(
//         "  Spine size:      {}B ({:.1}KB) / {}B ({:.1}%) — {}",
//         final_spine_size,
//         final_spine_size as f32 / 1024.0,
//         SPINE_BUDGET,
//         100.0 * final_spine_size as f32 / SPINE_BUDGET as f32,
//         if final_spine_fits { "OK" } else { "FAIL" },
//     );

//     // ── Detailed statistics ─────────────────────────────────────────────────
//     let lcr_to_branch = map_lcrs_to_branches(&branch_core_roots_vec, &leaf_core_roots, &nodes);
//     let empty_boundary: HashSet<usize> = HashSet::new();

//     // -- Leaf core stats --
//     let leaf_tri_counts: Vec<f64> = leaf_core_roots_vec
//         .iter()
//         .map(|&lr| count_subtree_nodes(lr, &nodes).0 as f64)
//         .collect();
//     let leaf_node_counts: Vec<f64> = leaf_core_roots_vec
//         .iter()
//         .map(|&lr| count_subtree_nodes(lr, &nodes).1 as f64)
//         .collect();
//     let leaf_skew_scores: Vec<f64> = leaf_core_roots_vec
//         .iter()
//         .map(|&lr| skew_score(lr, &nodes, &empty_boundary) as f64)
//         .collect();
//     let leaf_sz_values: Vec<f64> = leaf_sizes.iter().map(|(_, s)| *s as f64).collect();

//     println!("\n── Leaf core statistics ─────────────────────────────────────────");
//     print_stats("Triangles per leaf core ", &leaf_tri_counts);
//     print_stats("Nodes per leaf core     ", &leaf_node_counts);
//     print_stats("SRAM bytes per leaf core", &leaf_sz_values);
//     print_stats("Skew score (leaf cores) ", &leaf_skew_scores);

//     // -- Branch core stats --
//     let branch_tri_counts: Vec<f64> = branch_core_roots_vec
//         .iter()
//         .map(|&br| count_subtree_nodes(br, &nodes).0 as f64)
//         .collect();
//     let branch_node_counts: Vec<f64> = branch_core_roots_vec
//         .iter()
//         .map(|&br| branch_owned_nodes(br, &nodes, &leaf_core_roots) as f64)
//         .collect();
//     let branch_skew_scores: Vec<f64> = branch_core_roots_vec
//         .iter()
//         .map(|&br| skew_score(br, &nodes, &leaf_core_roots) as f64)
//         .collect();
//     let branch_sz_values: Vec<f64> = branch_core_roots_vec
//         .iter()
//         .map(|&br| branch_treelet_size(br, &nodes, &leaf_core_roots) as f64)
//         .collect();

//     println!("\n── Branch core statistics ───────────────────────────────────────");
//     print_stats("Tris under branch core     ", &branch_tri_counts);
//     print_stats("Nodes owned by branch core ", &branch_node_counts);
//     print_stats("SRAM bytes per branch core ", &branch_sz_values);
//     print_stats("Skew score (branch cores)  ", &branch_skew_scores);

//     // -- Per-branch detail listing --
//     println!("\nBranch core details:");
//     let mut branch_info: Vec<(usize, usize, usize, usize)> = branch_core_roots_vec
//         .iter()
//         .map(|&br| {
//             let lcr_count = lcr_to_branch.iter().filter(|(_, b)| **b == br).count();
//             let treelet_sz = branch_treelet_size(br, &nodes, &leaf_core_roots);
//             let owned_n = branch_owned_nodes(br, &nodes, &leaf_core_roots);
//             (br, lcr_count, treelet_sz, owned_n)
//         })
//         .collect();
//     branch_info.sort_by_key(|&(_, c, _, _)| std::cmp::Reverse(c));

//     for (br, lcr_count, treelet_sz, owned_n) in &branch_info {
//         let sk = skew_score(*br, &nodes, &leaf_core_roots);
//         println!(
//             "  Branch {:>8}: {:>5} leaf cores, {:>6} nodes | \
//              treelet {}B ({:.1}KB) / {}B  skew={}",
//             br,
//             lcr_count,
//             owned_n,
//             treelet_sz,
//             *treelet_sz as f32 / 1024.0,
//             LEAF_OVERHEAD_BUDGET,
//             sk,
//         );
//     }

//     // ── Write output files ──────────────────────────────────────────────────
//     let leaf_out_path = format!("leaf_core_roots_{}pct.txt", LEAF_OWNED_PCT);
//     let branch_out_path = format!("branch_core_roots_{}pct.txt", LEAF_OWNED_PCT);

//     {
//         let mut f = File::create(&leaf_out_path).expect("failed to create leaf core roots file");
//         writeln!(f, "# Leaf core root node indices (LEAF_OWNED_PCT={}%)", LEAF_OWNED_PCT).unwrap();
//         writeln!(f, "# {} leaf cores total", leaf_core_roots_vec.len()).unwrap();
//         writeln!(f, "# format: lcr_index own_subtree_nodes connecting_nodes total_nodes branch_root index_bytes vertex_bytes geom_total_bytes").unwrap();
//         let mut sorted_lcrs = leaf_core_roots_vec.clone();
//         sorted_lcrs.sort();
//         for lr in &sorted_lcrs {
//             let branch = lcr_to_branch.get(lr).copied().unwrap_or(*lr);
//             let own = count_total_descendants(*lr, &nodes);
//             let total = count_leaf_plus_branch_path(branch, *lr, &nodes, &leaf_core_roots);
//             let connecting = total - own;
//             let (_node_b, idx_b, vert_b) = leaf_treelet_cost_breakdown(*lr, &nodes, &triangles, &HashSet::new());
//             let geom_total = idx_b + vert_b;
//             writeln!(f, "{} {} {} {} {} {} {} {}", lr, own, connecting, total, branch, idx_b, vert_b, geom_total).unwrap();
//         }
//         println!("\nWrote leaf core roots to:   {}", leaf_out_path);
//     }

//     {
//         let mut f =
//             File::create(&branch_out_path).expect("failed to create branch core roots file");
//         writeln!(
//             f,
//             "# Branch core root node indices (LEAF_OWNED_PCT={}%)",
//             LEAF_OWNED_PCT
//         )
//         .unwrap();
//         writeln!(f, "# {} branch cores total", branch_core_roots_vec.len()).unwrap();
//         let mut sorted_brs = branch_core_roots_vec.clone();
//         sorted_brs.sort();
//         for br in &sorted_brs {
//             writeln!(f, "{}", br).unwrap();
//         }
//         println!("Wrote branch core roots to: {}", branch_out_path);
//     }

//     let mut violations = vec![];
//     // ── Validate: spine traversal should never hit a BVH leaf ───────────────
//     println!("\nValidating spine coverage (no BVH leaves should leak into spine)...");
//     {
//         // Stops are: any branch core root OR any leaf core root.
//         // Absorbed branch cores have already been removed from branch_core_roots,
//         // so they will be traversed through (their leaf cores are still stops).
//         fn check_no_leaks(
//             index: usize,
//             nodes: &[Node],
//             leaf_core_roots: &HashSet<usize>,
//             violations: &mut Vec<usize>,
//             path: &mut Vec<usize>,
//         ) {
//             // Only leaf core roots are stops. Branch core roots are traversed through.
//             if leaf_core_roots.contains(&index) {
//                 return;
//             }
//             let node = &nodes[index];
//             if node.is_leaf || node.tri_count > 0 {
//                 violations.push(index);
//                 println!(
//                     "  VIOLATION: BVH leaf {} (tri_count={}) reached — not owned by any leaf core",
//                     index, node.tri_count
//                 );
//                 println!("    path from root: {:?}", path);
//                 return;
//             }
//             path.push(index);
//             check_no_leaks(node.left_child, nodes, leaf_core_roots, violations, path);
//             check_no_leaks(node.right_child, nodes, leaf_core_roots, violations, path);
//             path.pop();
//         }
//         for &br in &branch_core_roots_vec {
//             let mut path = vec![];
//             check_no_leaks(br, &nodes, &leaf_core_roots, &mut violations, &mut path);
//         }
//     }
//     println!("VIOLATIONS: {}", violations.len());
// }
#[derive(Debug, Copy, Clone, PartialEq)]
pub struct Point {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

#[derive(Hash, Eq, PartialEq, Copy, Clone, Debug)]
pub struct QPoint {
    x: i64,
    y: i64,
    z: i64,
}

pub(crate) fn snap(point: Point) -> QPoint {
    QPoint {
        x: (point.x * 10000.0) as i64,
        y: (point.y * 10000.0) as i64,
        z: (point.z * 10000.0) as i64,
    }
}

impl Point {
    pub fn new(x: f32, y: f32, z: f32) -> Self {
        Self { x, y, z }
    }
}

#[derive(Debug, Copy, Clone, PartialEq)]
pub struct Node {
    pub(crate) index: usize,
    min: Point,
    max: Point,
    pub(crate) left_child: usize,
    pub(crate) is_leaf: bool,
    pub(crate) right_child: usize,
    pub(crate) tri_count: usize,
    pub(crate) first_tri: usize,
}

#[derive(Debug, Copy, Clone, PartialEq)]
pub struct Indices {
    pub node_index: usize,
    pub first_triangle_index: usize,
    pub num_triangles: usize,
}

#[derive(Debug, Copy, Clone)]
pub struct Triangle {
    pub index: usize,
    pub v0: Point,
    pub v1: Point,
    pub v2: Point,
}

use hashbrown::HashMap;
use std::collections::HashSet;
use std::fs::File;
use std::io::{BufRead, BufReader, Write};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const INDEX_SIZE: usize = 2;
const POINT_SIZE: usize = 12;
const NODE_SIZE: usize = 48;
const MATERIAL_POINTER_SIZE: usize = 6;
const MAX_ALLOC: usize = 32 * 1024;

const LEAF_OWNED_PCT: usize = 79;
const LEAF_OWNED_BUDGET: usize = MAX_ALLOC * LEAF_OWNED_PCT / 100;
const LEAF_OVERHEAD_BUDGET: usize = MAX_ALLOC - LEAF_OWNED_BUDGET;
const SPINE_BUDGET: usize = LEAF_OWNED_BUDGET;

// ---------------------------------------------------------------------------
// File readers
// ---------------------------------------------------------------------------

pub fn read_nodes(path: &str) -> Vec<Node> {
    let reader = BufReader::new(File::open(path).expect("failed to open node file"));
    let mut nodes = Vec::new();

    for (_line_index, line) in reader.lines().enumerate() {
        let line = line.expect("failed to read line");
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        let parts: Vec<&str> = line.split_whitespace().collect();
        assert!(
            parts.len() == 8 || parts.len() == 9,
            "expected 8 or 9 fields, got {}: {}",
            parts.len(),
            line
        );

        let offset = if parts.len() == 9 { 1 } else { 0 };
        let index: usize = if offset == 1 {
            parts[0].trim_matches('`').parse().unwrap()
        } else {
            nodes.len()
        };

        let min = Point::new(
            parts[offset + 0].parse().unwrap(),
            parts[offset + 1].parse().unwrap(),
            parts[offset + 2].parse().unwrap(),
        );
        let max = Point::new(
            parts[offset + 3].parse().unwrap(),
            parts[offset + 4].parse().unwrap(),
            parts[offset + 5].parse().unwrap(),
        );

        let left_first: usize = parts[offset + 6].parse().unwrap();
        let tri_count: usize = parts[offset + 7].parse().unwrap();

        if index != 0 && left_first == 0 && tri_count == 0 {
            nodes.push(Node {
                index,
                min,
                max,
                is_leaf: false,
                left_child: 0,
                right_child: 0,
                tri_count: 0,
                first_tri: 0,
            });
            continue;
        }

        let (left_child, right_child) = if tri_count == 0 {
            (left_first, left_first + 1)
        } else {
            (0, 0)
        };

        nodes.push(Node {
            index,
            min,
            max,
            is_leaf: tri_count != 0,
            left_child,
            right_child,
            tri_count,
            first_tri: 0,
        });
    }
    nodes
}

pub fn read_indices(path: &str) -> Vec<Indices> {
    let reader = BufReader::new(File::open(path).expect("failed to open indices file"));
    let mut indices = Vec::new();

    for line in reader.lines() {
        let line = line.expect("failed to read line");
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let parts: Vec<&str> = line.split_whitespace().collect();
        assert!(parts.len() == 3, "expected 3 fields, got {}: {}", parts.len(), line);
        indices.push(Indices {
            node_index: parts[0].parse().unwrap(),
            first_triangle_index: parts[1].parse().unwrap(),
            num_triangles: parts[2].parse().unwrap(),
        });
    }
    indices
}

pub fn read_triangles(path: &str) -> Vec<Triangle> {
    let reader = BufReader::new(File::open(path).expect("failed to open triangle file"));
    let mut tris = Vec::new();

    for line in reader.lines() {
        let line = line.expect("failed to read line");
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let parts: Vec<&str> = line.split_whitespace().collect();
        assert!(
            parts.len() == 9 || parts.len() == 10,
            "expected 9 or 10 fields, got {}: {}",
            parts.len(),
            line
        );
        let offset = if parts.len() == 10 { 1 } else { 0 };
        let index = if offset == 1 {
            parts[0].parse().unwrap()
        } else {
            tris.len()
        };
        let v0 = Point::new(
            parts[offset + 0].parse().unwrap(),
            parts[offset + 1].parse().unwrap(),
            parts[offset + 2].parse().unwrap(),
        );
        let v1 = Point::new(
            parts[offset + 3].parse().unwrap(),
            parts[offset + 4].parse().unwrap(),
            parts[offset + 5].parse().unwrap(),
        );
        let v2 = Point::new(
            parts[offset + 6].parse().unwrap(),
            parts[offset + 7].parse().unwrap(),
            parts[offset + 8].parse().unwrap(),
        );
        tris.push(Triangle { index, v0, v1, v2 });
    }
    tris
}

// ---------------------------------------------------------------------------
// Parent map
// ---------------------------------------------------------------------------

fn build_parent_map(nodes: &[Node]) -> Vec<Option<usize>> {
    let mut parents = vec![None; nodes.len()];
    for node in nodes {
        if !node.is_leaf && !(node.left_child == 0 && node.right_child == 0) {
            if node.left_child < nodes.len() {
                parents[node.left_child] = Some(node.index);
            }
            if node.right_child < nodes.len() {
                parents[node.right_child] = Some(node.index);
            }
        }
    }
    parents
}

// ---------------------------------------------------------------------------
// Cost helpers
// ---------------------------------------------------------------------------

pub fn subtree_leaf_size(
    index: usize,
    nodes: &[Node],
    triangles: &[Triangle],
    boundary: &HashSet<usize>,
    points: &mut HashMap<QPoint, ()>,
) -> (usize, usize) {
    let node = &nodes[index];

    if node.is_leaf {
        let mut size = NODE_SIZE;
        for i in node.first_tri..node.first_tri + node.tri_count {
            size += INDEX_SIZE * 3 + MATERIAL_POINTER_SIZE;
            points.insert(snap(triangles[i].v0), ());
            points.insert(snap(triangles[i].v1), ());
            points.insert(snap(triangles[i].v2), ());
        }
        return (size, node.tri_count);
    }

    let mut size = NODE_SIZE;
    let mut tris = 0;

    if boundary.contains(&node.left_child) {
        size += NODE_SIZE;
    } else {
        let (s, t) = subtree_leaf_size(node.left_child, nodes, triangles, boundary, points);
        size += s;
        tris += t;
    }

    if boundary.contains(&node.right_child) {
        size += NODE_SIZE;
    } else {
        let (s, t) = subtree_leaf_size(node.right_child, nodes, triangles, boundary, points);
        size += s;
        tris += t;
    }

    (size, tris)
}

fn leaf_treelet_cost(
    index: usize,
    nodes: &[Node],
    triangles: &[Triangle],
    boundary: &HashSet<usize>,
) -> usize {
    let mut points: HashMap<QPoint, ()> = HashMap::new();
    let (node_bytes, _) = subtree_leaf_size(index, nodes, triangles, boundary, &mut points);
    node_bytes + points.len() * POINT_SIZE
}

/// Size of a treelet rooted at `index`, stopping (inclusive as NODE_SIZE
/// stubs) at any node in `boundaries`. Used for branch core sizing.
fn treelet_size_with_boundaries(
    index: usize,
    nodes: &[Node],
    boundaries: &HashSet<usize>,
) -> usize {
    if boundaries.contains(&index) {
        return NODE_SIZE;
    }
    let node = &nodes[index];
    if node.is_leaf {
        panic!(
            "treelet_size_with_boundaries: reached BVH leaf {} (tri_count={}) \
             with no boundary above it. The partitioner left a BVH leaf unclaimed.",
            index, node.tri_count
        );
    }
    NODE_SIZE
        + treelet_size_with_boundaries(node.left_child, nodes, boundaries)
        + treelet_size_with_boundaries(node.right_child, nodes, boundaries)
}

fn count_total_descendants(index: usize, nodes: &[Node]) -> usize {
    let node = &nodes[index];
    if node.is_leaf {
        return 1;
    }
    1 + count_total_descendants(node.left_child, nodes)
        + count_total_descendants(node.right_child, nodes)
}

// ---------------------------------------------------------------------------
// Phase 1: bottom-up post-order unification
// ---------------------------------------------------------------------------

fn phase1_leaf_partition(
    nodes: &[Node],
    triangles: &[Triangle],
    parents: &[Option<usize>],
) -> Vec<usize> {
    let mut owns: Vec<bool> = vec![false; nodes.len()];

    let mut stack: Vec<(usize, bool)> = vec![(0, false)];

    while let Some((idx, visited)) = stack.pop() {
        let node = &nodes[idx];

        if node.is_leaf {
            let cost = leaf_treelet_cost(idx, nodes, triangles, &HashSet::new());
            assert!(
                cost <= LEAF_OWNED_BUDGET,
                "BVH leaf {} alone costs {}B which exceeds LEAF_OWNED_BUDGET ({}B). \
                 Rebuild the BVH with smaller leaves.",
                idx, cost, LEAF_OWNED_BUDGET
            );
            owns[idx] = true;
            continue;
        }

        if !visited {
            stack.push((idx, true));
            stack.push((node.right_child, false));
            stack.push((node.left_child, false));
        } else {
            let cost = leaf_treelet_cost(idx, nodes, triangles, &HashSet::new());
            if cost <= LEAF_OWNED_BUDGET {
                owns[idx] = true;
            }
        }
    }

    let mut leaf_core_roots: Vec<usize> = Vec::new();
    for (i, &is_owned) in owns.iter().enumerate() {
        if !is_owned {
            continue;
        }
        let mut topmost = true;
        let mut cur = parents[i];
        while let Some(p) = cur {
            if owns[p] {
                topmost = false;
                break;
            }
            cur = parents[p];
        }
        if topmost {
            leaf_core_roots.push(i);
        }
    }

    leaf_core_roots
}

// ---------------------------------------------------------------------------
// Phase 2: parents-of-LCR + prune-ancestors + split-oversized
// ---------------------------------------------------------------------------

/// Phase 2 (your algorithm):
///
/// 1. Initialize: every LCR's parent becomes a branch-core-root candidate.
/// 2. Prune ancestors ONCE: if branch core A is an ancestor of branch core B,
///    remove B. Only topmost survive after this pass.
/// 3. Iteratively fix oversized branches:
///    - Pick any oversized branch core `b`.
///    - Remove `b` from the branch set.
///    - Promote `b`'s two children:
///        * If a child is currently an LCR: convert that LCR to a branch
///          core, AND demote the LCR by promoting the LCR's two children
///          to be new LCRs (preserving leaf-coverage).
///          If the LCR is itself a BVH leaf (no children), panic.
///        * Otherwise: child becomes a branch core directly.
///    - Revisit the new branches immediately (in case they're also oversized).
///
/// Returns (final branch_core_roots, final leaf_core_roots).
/// The leaf_core_roots may have changed from input due to the demotion rule.
fn phase2_branch_partition(
    nodes: &[Node],
    initial_leaf_core_roots: &HashSet<usize>,
    parents: &[Option<usize>],
) -> (Vec<usize>, HashSet<usize>) {
    let mut leaf_core_roots: HashSet<usize> = initial_leaf_core_roots.clone();

    // Step 1: initialize branches as parents-of-LCR.
    let mut branch_set: HashSet<usize> = HashSet::new();
    for &lcr in initial_leaf_core_roots {
        if let Some(p) = parents[lcr] {
            branch_set.insert(p);
        } else {
            // LCR is the BVH root. With your algorithm, the BVH root
            // stays in the spine, so we don't add a branch for it.
            // But then this LCR has no branch-core-root ancestor, which
            // is a structural issue we'll catch in the audit.
            eprintln!(
                "WARNING: leaf-core root {} is the BVH root; no branch core \
                 candidate to install above it.",
                lcr
            );
        }
    }
    println!(
        "  Step 1 (parents-of-LCR): {} initial branch-core candidates",
        branch_set.len()
    );

    // Step 2: prune ancestors. If A is ancestor of B (both in branch_set),
    // remove B.
    {
        let candidates: Vec<usize> = branch_set.iter().cloned().collect();
        let mut to_remove: HashSet<usize> = HashSet::new();
        for &b in &candidates {
            // walk up; if any ancestor is in branch_set, remove b.
            let mut cur = parents[b];
            while let Some(p) = cur {
                if branch_set.contains(&p) {
                    to_remove.insert(b);
                    break;
                }
                cur = parents[p];
            }
        }
        for r in to_remove {
            branch_set.remove(&r);
        }
    }
    println!(
        "  Step 2 (prune ancestors): {} branch cores remain",
        branch_set.len()
    );

    // Step 3: iteratively fix oversized branches.
    //
    // We use a worklist of branches to (re)check. When we split a branch,
    // we add its replacements to the worklist. We stop when the worklist
    // is empty AND all current branches fit.
    let mut worklist: Vec<usize> = branch_set.iter().cloned().collect();
    let mut splits = 0usize;
    let mut lcr_demotions = 0usize;

    while let Some(b) = worklist.pop() {
        // It's possible `b` was already removed by an earlier split that
        // promoted it into something else. Skip stale entries.
        if !branch_set.contains(&b) {
            continue;
        }

        // Cost: treelet rooted at b, with current LCRs and OTHER branches
        // as boundaries. (Other branches shouldn't be inside b's territory
        // post-pruning, but we include them defensively.)
        let mut boundaries = leaf_core_roots.clone();
        for &other in &branch_set {
            if other != b {
                boundaries.insert(other);
            }
        }
        let cost = treelet_size_with_boundaries(b, nodes, &boundaries);
        if cost <= LEAF_OVERHEAD_BUDGET {
            continue; // fits, leave it alone
        }

        // Oversized — split. Remove b, promote its two children.
        let node = &nodes[b];
        if node.is_leaf {
            panic!(
                "Phase 2: cannot split branch core {} — it is a BVH leaf with \
                 no children. This shouldn't happen since BVH leaves should be \
                 inside leaf cores, not parents of them.",
                b
            );
        }
        let l = node.left_child;
        let r = node.right_child;

        branch_set.remove(&b);
        splits += 1;

        // Promote each child. If a child is an LCR, demote the LCR.
        for &child in &[l, r] {
            if leaf_core_roots.contains(&child) {
                // The child is an LCR. Convert it to a branch core, and
                // promote its own children to be new LCRs.
                let cnode = &nodes[child];
                if cnode.is_leaf {
                    panic!(
                        "Phase 2: branch core {} oversized; tried to demote \
                         child LCR {} but it is a BVH leaf with no children. \
                         Cannot subdivide further.",
                        b, child
                    );
                }
                leaf_core_roots.remove(&child);
                leaf_core_roots.insert(cnode.left_child);
                leaf_core_roots.insert(cnode.right_child);
                branch_set.insert(child);
                worklist.push(child);
                lcr_demotions += 1;
            } else if nodes[child].is_leaf {
                // A BVH leaf that ISN'T an LCR — Phase 1 must have left an
                // orphan leaf, which is a Phase-1 bug. Phase 1's audit
                // should catch this earlier, but defend anyway.
                panic!(
                    "Phase 2: branch core {} oversized; child {} is a raw BVH \
                     leaf (tri_count={}) not claimed by any LCR. Phase 1 left \
                     an orphan.",
                    b, child, nodes[child].tri_count
                );
            } else {
                branch_set.insert(child);
                worklist.push(child);
            }
        }
    }

    println!(
        "  Step 3 (split oversized): {} splits, {} LCR demotions; {} branch cores final",
        splits,
        lcr_demotions,
        branch_set.len()
    );

    let branch_core_roots: Vec<usize> = branch_set.into_iter().collect();
    (branch_core_roots, leaf_core_roots)
}

// ---------------------------------------------------------------------------
// Spine validation
// ---------------------------------------------------------------------------

fn spine_size(index: usize, nodes: &[Node], branch_roots: &HashSet<usize>) -> usize {
    if branch_roots.contains(&index) {
        return NODE_SIZE;
    }
    let node = &nodes[index];
    if node.is_leaf {
        panic!(
            "spine_size: reached BVH leaf {} (tri_count={}) inside the spine \
             with no branch-core-root boundary above it.",
            index, node.tri_count
        );
    }
    NODE_SIZE
        + spine_size(node.left_child, nodes, branch_roots)
        + spine_size(node.right_child, nodes, branch_roots)
}

// ---------------------------------------------------------------------------
// Audit
// ---------------------------------------------------------------------------

#[derive(Debug)]
struct PartitionAudit {
    duplicate_roots: Vec<usize>,
    orphan_leaves_per_branch: HashMap<usize, usize>,
    leaves_with_no_lcr_ancestor: Vec<usize>,
    nested_lcrs: Vec<(usize, usize)>,
    nested_branches: Vec<(usize, usize)>,
    lcrs_with_no_branch_ancestor: Vec<usize>,
}

impl PartitionAudit {
    fn is_clean(&self) -> bool {
        self.duplicate_roots.is_empty()
            && self.orphan_leaves_per_branch.is_empty()
            && self.leaves_with_no_lcr_ancestor.is_empty()
            && self.nested_lcrs.is_empty()
            && self.nested_branches.is_empty()
            && self.lcrs_with_no_branch_ancestor.is_empty()
    }
}

fn count_orphan_leaves(
    idx: usize,
    nodes: &[Node],
    lcrs: &HashSet<usize>,
    other_branches: &HashSet<usize>,
    is_root: bool,
) -> usize {
    if !is_root && (lcrs.contains(&idx) || other_branches.contains(&idx)) {
        return 0;
    }
    let n = &nodes[idx];
    if n.is_leaf {
        return 1;
    }
    count_orphan_leaves(n.left_child, nodes, lcrs, other_branches, false)
        + count_orphan_leaves(n.right_child, nodes, lcrs, other_branches, false)
}

fn is_ancestor(ancestor: usize, index: usize, parents: &[Option<usize>]) -> bool {
    let mut cur = parents[index];
    while let Some(c) = cur {
        if c == ancestor {
            return true;
        }
        cur = parents[c];
    }
    false
}

fn audit_partition(
    nodes: &[Node],
    parents: &[Option<usize>],
    leaf_core_roots: &HashSet<usize>,
    branch_core_roots: &HashSet<usize>,
) -> PartitionAudit {
    let mut audit = PartitionAudit {
        duplicate_roots: Vec::new(),
        orphan_leaves_per_branch: HashMap::new(),
        leaves_with_no_lcr_ancestor: Vec::new(),
        nested_lcrs: Vec::new(),
        nested_branches: Vec::new(),
        lcrs_with_no_branch_ancestor: Vec::new(),
    };

    for &lr in leaf_core_roots {
        if branch_core_roots.contains(&lr) {
            audit.duplicate_roots.push(lr);
        }
    }

    for &br in branch_core_roots {
        let other_branches: HashSet<usize> = branch_core_roots
            .iter()
            .filter(|&&b| b != br)
            .cloned()
            .collect();
        let orphans = count_orphan_leaves(br, nodes, leaf_core_roots, &other_branches, true);
        if orphans > 0 {
            audit.orphan_leaves_per_branch.insert(br, orphans);
        }
    }

    for n in nodes.iter().filter(|n| n.is_leaf) {
        let mut cur = Some(n.index);
        let mut found = false;
        while let Some(c) = cur {
            if leaf_core_roots.contains(&c) {
                found = true;
                break;
            }
            cur = parents[c];
        }
        if !found {
            audit.leaves_with_no_lcr_ancestor.push(n.index);
        }
    }

    for &lcr in leaf_core_roots {
        let mut cur = parents[lcr];
        let mut found = false;
        while let Some(c) = cur {
            if branch_core_roots.contains(&c) {
                found = true;
                break;
            }
            cur = parents[c];
        }
        if !found {
            audit.lcrs_with_no_branch_ancestor.push(lcr);
        }
    }

    let lcr_vec: Vec<usize> = leaf_core_roots.iter().cloned().collect();
    for (i, &a) in lcr_vec.iter().enumerate() {
        for &b in &lcr_vec[i + 1..] {
            if is_ancestor(a, b, parents) {
                audit.nested_lcrs.push((a, b));
            } else if is_ancestor(b, a, parents) {
                audit.nested_lcrs.push((b, a));
            }
        }
    }

    let br_vec: Vec<usize> = branch_core_roots.iter().cloned().collect();
    for (i, &a) in br_vec.iter().enumerate() {
        for &b in &br_vec[i + 1..] {
            if is_ancestor(a, b, parents) {
                audit.nested_branches.push((a, b));
            } else if is_ancestor(b, a, parents) {
                audit.nested_branches.push((b, a));
            }
        }
    }

    audit
}

fn print_audit(audit: &PartitionAudit) {
    println!("\n── Partition audit ──");
    if audit.duplicate_roots.is_empty() {
        println!("  ✓ No node is both a leaf-core and branch-core root.");
    } else {
        println!(
            "  ✗ {} nodes are BOTH leaf-core and branch-core roots: {:?}",
            audit.duplicate_roots.len(),
            &audit.duplicate_roots[..audit.duplicate_roots.len().min(10)]
        );
    }
    if audit.orphan_leaves_per_branch.is_empty() {
        println!("  ✓ No branch core's subtree contains an unclaimed BVH leaf.");
    } else {
        let total: usize = audit.orphan_leaves_per_branch.values().sum();
        println!(
            "  ✗ {} branch cores have orphan BVH leaves (total {})",
            audit.orphan_leaves_per_branch.len(),
            total
        );
    }
    if audit.leaves_with_no_lcr_ancestor.is_empty() {
        println!("  ✓ Every BVH leaf has a leaf-core-root ancestor.");
    } else {
        println!(
            "  ✗ {} BVH leaves have no leaf-core-root ancestor",
            audit.leaves_with_no_lcr_ancestor.len()
        );
    }
    if audit.lcrs_with_no_branch_ancestor.is_empty() {
        println!("  ✓ Every leaf-core root has a branch-core-root ancestor.");
    } else {
        println!(
            "  ✗ {} leaf-core roots have no branch-core ancestor",
            audit.lcrs_with_no_branch_ancestor.len()
        );
    }
    if audit.nested_lcrs.is_empty() {
        println!("  ✓ No leaf core root is an ancestor of another leaf core root.");
    } else {
        println!("  ✗ {} pairs of nested leaf core roots", audit.nested_lcrs.len());
    }
    if audit.nested_branches.is_empty() {
        println!("  ✓ No branch core root is an ancestor of another branch core root.");
    } else {
        println!("  ✗ {} pairs of nested branch core roots", audit.nested_branches.len());
    }
}

// ---------------------------------------------------------------------------
// Stats helpers
// ---------------------------------------------------------------------------

fn count_subtree_nodes(index: usize, nodes: &[Node]) -> (usize, usize) {
    let node = &nodes[index];
    if node.is_leaf {
        return (node.tri_count, 1);
    }
    let (a, b) = count_subtree_nodes(node.left_child, nodes);
    let (c, d) = count_subtree_nodes(node.right_child, nodes);
    (a + c, 1 + b + d)
}

fn count_stubs_under(
    index: usize,
    nodes: &[Node],
    boundaries: &HashSet<usize>,
    is_root: bool,
) -> usize {
    if !is_root && boundaries.contains(&index) {
        return 1;
    }
    let node = &nodes[index];
    if node.is_leaf {
        return 0;
    }
    count_stubs_under(node.left_child, nodes, boundaries, false)
        + count_stubs_under(node.right_child, nodes, boundaries, false)
}

fn count_tris_bounded(index: usize, nodes: &[Node], boundaries: &HashSet<usize>) -> usize {
    if boundaries.contains(&index) {
        return 0;
    }
    let node = &nodes[index];
    if node.is_leaf {
        return node.tri_count;
    }
    count_tris_bounded(node.left_child, nodes, boundaries)
        + count_tris_bounded(node.right_child, nodes, boundaries)
}

fn map_lcrs_to_branches(
    branch_roots: &[usize],
    leaf_core_roots: &HashSet<usize>,
    nodes: &[Node],
) -> HashMap<usize, usize> {
    let mut result = HashMap::new();
    let branch_set: HashSet<usize> = branch_roots.iter().cloned().collect();
    for &br in branch_roots {
        let other_branches: HashSet<usize> = branch_set
            .iter()
            .filter(|&&b| b != br)
            .cloned()
            .collect();
        assign_lcrs(br, br, nodes, leaf_core_roots, &other_branches, &mut result);
    }
    result
}

fn assign_lcrs(
    index: usize,
    branch_root: usize,
    nodes: &[Node],
    leaf_core_roots: &HashSet<usize>,
    other_branches: &HashSet<usize>,
    result: &mut HashMap<usize, usize>,
) {
    if other_branches.contains(&index) {
        return;
    }
    if leaf_core_roots.contains(&index) {
        result.insert(index, branch_root);
        return;
    }
    let node = &nodes[index];
    if node.is_leaf {
        return;
    }
    assign_lcrs(node.left_child, branch_root, nodes, leaf_core_roots, other_branches, result);
    assign_lcrs(node.right_child, branch_root, nodes, leaf_core_roots, other_branches, result);
}

fn subtree_depth_range(
    index: usize,
    nodes: &[Node],
    boundary: &HashSet<usize>,
    depth: usize,
) -> (usize, usize) {
    if boundary.contains(&index) {
        return (depth, depth);
    }
    let node = &nodes[index];
    if node.is_leaf {
        return (depth, depth);
    }
    let (lmin, lmax) = subtree_depth_range(node.left_child, nodes, boundary, depth + 1);
    let (rmin, rmax) = subtree_depth_range(node.right_child, nodes, boundary, depth + 1);
    (lmin.min(rmin), lmax.max(rmax))
}

fn skew_score(root: usize, nodes: &[Node], boundary: &HashSet<usize>) -> usize {
    let (min_d, max_d) = subtree_depth_range(root, nodes, boundary, 0);
    max_d - min_d
}

fn stats_summary(values: &[f64]) -> (f64, f64, f64, f64, f64) {
    if values.is_empty() {
        return (0.0, 0.0, 0.0, 0.0, 0.0);
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = sorted.len();
    let min = sorted[0];
    let max = sorted[n - 1];
    let mean = sorted.iter().sum::<f64>() / n as f64;
    let median = if n % 2 == 0 {
        (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    } else {
        sorted[n / 2]
    };
    let variance = sorted.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / n as f64;
    let std = variance.sqrt();
    (min, max, mean, median, std)
}

fn print_stats(label: &str, values: &[f64]) {
    let (min, max, mean, median, std) = stats_summary(values);
    println!(
        "  {}: min={:.1} max={:.1} mean={:.1} median={:.1} std={:.1}",
        label, min, max, mean, median, std
    );
}

fn count_leaf_plus_branch_path(
    branch_root: usize,
    target_lcr: usize,
    nodes: &[Node],
    leaf_core_roots: &HashSet<usize>,
) -> usize {
    fn recurse(
        index: usize,
        target: usize,
        nodes: &[Node],
        lcrs: &HashSet<usize>,
    ) -> usize {
        if index == target {
            return count_total_descendants(index, nodes);
        }
        if lcrs.contains(&index) {
            return 1;
        }
        let node = &nodes[index];
        if node.is_leaf {
            return 1;
        }
        1 + recurse(node.left_child, target, nodes, lcrs)
          + recurse(node.right_child, target, nodes, lcrs)
    }
    recurse(branch_root, target_lcr, nodes, leaf_core_roots)
}

fn leaf_treelet_cost_breakdown(
    index: usize,
    nodes: &[Node],
    triangles: &[Triangle],
    boundary: &HashSet<usize>,
) -> (usize, usize, usize) {
    let mut points: HashMap<QPoint, ()> = HashMap::new();
    let mut node_bytes = 0;
    let mut index_bytes = 0;
    accumulate_leaf_breakdown(index, nodes, triangles, boundary, &mut points, &mut node_bytes, &mut index_bytes);
    let vertex_bytes = points.len() * POINT_SIZE;
    (node_bytes, index_bytes, vertex_bytes)
}

fn accumulate_leaf_breakdown(
    index: usize,
    nodes: &[Node],
    triangles: &[Triangle],
    boundary: &HashSet<usize>,
    points: &mut HashMap<QPoint, ()>,
    node_bytes: &mut usize,
    index_bytes: &mut usize,
) {
    let node = &nodes[index];
    if node.is_leaf {
        *node_bytes += NODE_SIZE;
        for i in node.first_tri..node.first_tri + node.tri_count {
            *index_bytes += INDEX_SIZE * 3 + MATERIAL_POINTER_SIZE;
            points.insert(snap(triangles[i].v0), ());
            points.insert(snap(triangles[i].v1), ());
            points.insert(snap(triangles[i].v2), ());
        }
        return;
    }
    *node_bytes += NODE_SIZE;
    if boundary.contains(&node.left_child) {
        *node_bytes += NODE_SIZE;
    } else {
        accumulate_leaf_breakdown(node.left_child, nodes, triangles, boundary, points, node_bytes, index_bytes);
    }
    if boundary.contains(&node.right_child) {
        *node_bytes += NODE_SIZE;
    } else {
        accumulate_leaf_breakdown(node.right_child, nodes, triangles, boundary, points, node_bytes, index_bytes);
    }
}

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

pub fn assemble_tree(_subfolder: String) {
    let bvh_leaves_path = format!("bvh_leaves.txt");
    let bvh_nodes_path = format!("bvh_nodes.txt");
    let bvh_triangles_path = format!("bvh_triangles.txt");

    let triangles = read_triangles(&bvh_triangles_path);
    let indices = read_indices(&bvh_leaves_path);
    let mut nodes = read_nodes(&bvh_nodes_path);

    let mut expanded: Vec<Indices> = vec![
        Indices { node_index: 0, first_triangle_index: 0, num_triangles: 0 };
        nodes.len().max(2_000_000)
    ];
    for idx in indices {
        expanded[idx.node_index] = idx;
    }
    for node in nodes.iter_mut() {
        node.first_tri = expanded[node.index].first_triangle_index;
    }

    println!("Loaded {} nodes, {} triangles", nodes.len(), triangles.len());
    println!(
        "Budgets: leaf_owned={}B, leaf_overhead={}B, spine={}B",
        LEAF_OWNED_BUDGET, LEAF_OVERHEAD_BUDGET, SPINE_BUDGET
    );

    let parents = build_parent_map(&nodes);

    println!("\nPhase 1: leaf treelets (post-order unification)...");
    let leaf_core_roots_vec = phase1_leaf_partition(&nodes, &triangles, &parents);
    let initial_lcr_set: HashSet<usize> = leaf_core_roots_vec.iter().cloned().collect();
    println!("  → {} leaf core roots", initial_lcr_set.len());

    println!("Phase 2: parents-of-LCR → prune → split-oversized...");
    let (branch_core_roots_vec, leaf_core_roots) =
        phase2_branch_partition(&nodes, &initial_lcr_set, &parents);
    let branch_core_roots: HashSet<usize> = branch_core_roots_vec.iter().cloned().collect();
    let leaf_core_roots_vec: Vec<usize> = leaf_core_roots.iter().cloned().collect();
    println!("  → {} branch core roots (after splits)", branch_core_roots_vec.len());
    println!("  → {} leaf core roots (after demotions)", leaf_core_roots_vec.len());

    let audit = audit_partition(&nodes, &parents, &leaf_core_roots, &branch_core_roots);
    print_audit(&audit);
    assert!(audit.is_clean(), "Partition is malformed; see audit output above.");

    println!("\nPhase 3: spine validation...");
    let spine_total = spine_size(0, &nodes, &branch_core_roots);
    let spine_fits = spine_total <= SPINE_BUDGET;
    println!(
        "  spine: {}B / {}B ({:.1}%) — {}",
        spine_total,
        SPINE_BUDGET,
        100.0 * spine_total as f32 / SPINE_BUDGET as f32,
        if spine_fits { "OK" } else { "OVER BUDGET" }
    );
    if !spine_fits {
        eprintln!(
            "  WARNING: spine exceeds budget. With this algorithm, all branch \
             cores hang directly off the spine, so the spine cost grows \
             linearly with the branch core count."
        );
    }

    // ── Validate per-treelet sizes ──
    let mut leaf_violations = 0usize;
    let mut leaf_sizes: Vec<(usize, usize)> = Vec::new();
    for &lr in &leaf_core_roots_vec {
        let cost = leaf_treelet_cost(lr, &nodes, &triangles, &HashSet::new());
        leaf_sizes.push((lr, cost));
        if cost > LEAF_OWNED_BUDGET {
            leaf_violations += 1;
            println!("  VIOLATION: leaf root {}: {}B > {}B", lr, cost, LEAF_OWNED_BUDGET);
        }
    }
    println!("Leaf size violations: {}", leaf_violations);

    let mut branch_violations = 0usize;
    for &br in &branch_core_roots_vec {
        let mut boundaries = leaf_core_roots.clone();
        for &other in &branch_core_roots_vec {
            if other != br {
                boundaries.insert(other);
            }
        }
        let cost = treelet_size_with_boundaries(br, &nodes, &boundaries);
        if cost > LEAF_OVERHEAD_BUDGET {
            branch_violations += 1;
            println!("  VIOLATION: branch root {}: {}B > {}B", br, cost, LEAF_OVERHEAD_BUDGET);
        }
    }
    println!("Branch size violations: {}", branch_violations);

    // ── Stats ──
    let lcr_to_branch = map_lcrs_to_branches(&branch_core_roots_vec, &leaf_core_roots, &nodes);
    let empty_boundary: HashSet<usize> = HashSet::new();

    let leaf_tri_counts: Vec<f64> = leaf_core_roots_vec
        .iter()
        .map(|&lr| count_subtree_nodes(lr, &nodes).0 as f64)
        .collect();
    let leaf_node_counts: Vec<f64> = leaf_core_roots_vec
        .iter()
        .map(|&lr| count_subtree_nodes(lr, &nodes).1 as f64)
        .collect();
    let leaf_skew_scores: Vec<f64> = leaf_core_roots_vec
        .iter()
        .map(|&lr| skew_score(lr, &nodes, &empty_boundary) as f64)
        .collect();
    let leaf_sz_values: Vec<f64> = leaf_sizes.iter().map(|(_, s)| *s as f64).collect();

    println!("\n── Leaf core stats ──");
    print_stats("Triangles per leaf core ", &leaf_tri_counts);
    print_stats("Nodes per leaf core     ", &leaf_node_counts);
    print_stats("SRAM bytes per leaf core", &leaf_sz_values);
    print_stats("Skew score              ", &leaf_skew_scores);

    let branch_stub_counts: Vec<f64> = branch_core_roots_vec
        .iter()
        .map(|&br| {
            let mut boundaries = leaf_core_roots.clone();
            for &other in &branch_core_roots_vec {
                if other != br {
                    boundaries.insert(other);
                }
            }
            count_stubs_under(br, &nodes, &boundaries, true) as f64
        })
        .collect();
    let branch_tri_counts: Vec<f64> = branch_core_roots_vec
        .iter()
        .map(|&br| {
            let mut boundaries = leaf_core_roots.clone();
            for &other in &branch_core_roots_vec {
                if other != br {
                    boundaries.insert(other);
                }
            }
            count_tris_bounded(br, &nodes, &boundaries) as f64
        })
        .collect();
    let branch_sz_values: Vec<f64> = branch_core_roots_vec
        .iter()
        .map(|&br| {
            let mut boundaries = leaf_core_roots.clone();
            for &other in &branch_core_roots_vec {
                if other != br {
                    boundaries.insert(other);
                }
            }
            treelet_size_with_boundaries(br, &nodes, &boundaries) as f64
        })
        .collect();

    println!("\n── Branch core stats ──");
    print_stats("Stubs per branch (LCR+children)      ", &branch_stub_counts);
    print_stats("Tris owned directly by branch        ", &branch_tri_counts);
    print_stats("SRAM bytes per branch                ", &branch_sz_values);

    // ── Output files ──
    let leaf_out_path = format!("leaf_core_roots_{}pct.txt", LEAF_OWNED_PCT);
    let branch_out_path = format!("branch_core_roots_{}pct.txt", LEAF_OWNED_PCT);

    {
        let mut f = File::create(&leaf_out_path).expect("failed to create leaf core roots file");
        writeln!(f, "# Leaf core roots (LEAF_OWNED_PCT={}%)", LEAF_OWNED_PCT).unwrap();
        writeln!(f, "# format: lcr own_subtree connecting total branch idx_bytes vert_bytes geom_total").unwrap();
        let mut sorted_lcrs = leaf_core_roots_vec.clone();
        sorted_lcrs.sort();
        for lr in &sorted_lcrs {
            let branch = lcr_to_branch.get(lr).copied().unwrap_or(*lr);
            let own = count_total_descendants(*lr, &nodes);
            let total = count_leaf_plus_branch_path(branch, *lr, &nodes, &leaf_core_roots);
            let connecting = total - own;
            let (_node_b, idx_b, vert_b) =
                leaf_treelet_cost_breakdown(*lr, &nodes, &triangles, &HashSet::new());
            let geom_total = idx_b + vert_b;
            writeln!(f, "{} {} {} {} {} {} {} {}", lr, own, connecting, total, branch, idx_b, vert_b, geom_total).unwrap();
        }
        println!("\nWrote {}", leaf_out_path);
    }

    {
        let mut f = File::create(&branch_out_path).expect("failed to create branch core roots file");
        writeln!(f, "# Branch core roots (LEAF_OWNED_PCT={}%)", LEAF_OWNED_PCT).unwrap();
        let mut sorted_brs = branch_core_roots_vec.clone();
        sorted_brs.sort();
        for br in &sorted_brs {
            writeln!(f, "{}", br).unwrap();
        }
        println!("Wrote {}", branch_out_path);
    }
}


// // ---------------------------------------------------------------------------
// // K-level partition
// // ---------------------------------------------------------------------------

// /// One level's output: the roots identified at this level, and the budget used.
// pub struct LevelResult {
//     pub level: usize,
//     pub budget_pct: usize,
//     pub budget_bytes: usize,
//     pub roots: Vec<usize>,
//     pub spine_size: Option<usize>, // only Some for the final (spine) level
// }

// /// Run a single bottom-up greedy growth pass.
// ///
// /// `seeds` are the nodes we start from (BVH leaves on level 0,
// /// previous level's roots on levels 1+).
// /// `boundary` is the set of nodes that act as stubs (previous roots).
// /// `budget` is the SRAM byte budget for this level's treelets.
// /// `mode` controls whether cost includes geometry (leaf) or just nodes (branch).
// fn grow_level(
//     seeds: &HashSet<usize>,
//     boundary: &HashSet<usize>,
//     nodes: &[Node],
//     triangles: &[Triangle],
//     parents: &[Option<usize>],
//     budget: usize,
//     with_geometry: bool,
// ) -> Vec<usize> {
//     let mut unclaimed: HashSet<usize> = seeds.clone();
//     let mut roots: Vec<usize> = Vec::new();

//     while !unclaimed.is_empty() {
//         let seed = *unclaimed.iter().next().unwrap();
//         let mut current_root = seed;
//         let mut owned: HashSet<usize> = HashSet::new();
//         owned.insert(seed);
//         unclaimed.remove(&seed);

//         loop {
//             let parent = match parents[current_root] {
//                 Some(p) => p,
//                 None => break,
//             };

//             // Cost of treelet rooted at parent, with boundary as stubs.
//             let cost = if with_geometry {
//                 leaf_treelet_cost(parent, nodes, triangles, boundary)
//             } else {
//                 branch_treelet_size(parent, nodes, boundary)
//             };

//             if cost > budget {
//                 break;
//             }

//             // Absorb sibling's seeds.
//             let parent_node = &nodes[parent];
//             let sibling = if parent_node.left_child == current_root {
//                 parent_node.right_child
//             } else {
//                 parent_node.left_child
//             };

//             let sibling_seeds = collect_seeds_under(sibling, nodes, seeds);
//             for &s in &sibling_seeds {
//                 unclaimed.remove(&s);
//                 owned.insert(s);
//             }

//             current_root = parent;
//         }

//         roots.push(current_root);
//     }

//     roots
// }

// /// Collect all nodes in `seeds` that exist under a given subtree,
// /// stopping at seed boundaries.
// fn collect_seeds_under(index: usize, nodes: &[Node], seeds: &HashSet<usize>) -> Vec<usize> {
//     if seeds.contains(&index) {
//         return vec![index];
//     }
//     let node = &nodes[index];
//     if node.is_leaf {
//         return vec![];
//     }
//     let mut result = collect_seeds_under(node.left_child, nodes, seeds);
//     result.extend(collect_seeds_under(node.right_child, nodes, seeds));
//     result
// }

// /// The main k-level partitioner.
// ///
// /// `budget_pcts` is a slice like [50, 25, 13, 12] where:
// ///   - index 0 is the bottommost level (leaf geometry treelets)
// ///   - subsequent indices are interior levels (node-only treelets)  
// ///   - the last index implicitly defines the spine budget
// ///
// /// The percentages must sum to 100.
// pub fn assemble_tree_klevel(subfolder: String, budget_pcts: Vec<usize>) {
//     assert!(
//         budget_pcts.iter().sum::<usize>() == 100,
//         "budget_pcts must sum to 100, got {}",
//         budget_pcts.iter().sum::<usize>()
//     );
//     assert!(
//         budget_pcts.len() >= 2,
//         "need at least 2 levels (leaf + spine)"
//     );

//     // Load data (same as before)
//     let bvh_leaves_path = format!("{}\\bvh_leaves.txt", subfolder);
//     let bvh_nodes_path = format!("{}\\bvh_nodes.txt", subfolder);
//     let bvh_triangles_path = format!("{}\\bvh_triangles.txt", subfolder);

//     let triangles = read_triangles(&bvh_triangles_path);
//     let indices = read_indices(&bvh_leaves_path);
//     let mut nodes = read_nodes(&bvh_nodes_path);

//     let mut expanded: Vec<Indices> = vec![
//         Indices {
//             node_index: 0,
//             first_triangle_index: 0,
//             num_triangles: 0
//         };
//         nodes.len().max(2_000_000)
//     ];
//     for idx in indices {
//         expanded[idx.node_index] = idx;
//     }
//     for node in nodes.iter_mut() {
//         node.first_tri = expanded[node.index].first_triangle_index;
//     }

//     println!(
//         "Loaded {} nodes, {} triangles",
//         nodes.len(),
//         triangles.len()
//     );

//     let budgets_bytes: Vec<usize> = budget_pcts
//         .iter()
//         .map(|&pct| MAX_ALLOC * pct / 100)
//         .collect();

//     print!("K-level budgets: ");
//     for (i, (&pct, &bytes)) in budget_pcts.iter().zip(budgets_bytes.iter()).enumerate() {
//         let label = if i == 0 {
//             "leaf"
//         } else if i == budget_pcts.len() - 1 {
//             "spine"
//         } else {
//             "branch"
//         };
//         print!(
//             "L{}={} ({}B={:.1}KB) ",
//             i,
//             label,
//             bytes,
//             bytes as f32 / 1024.0
//         );
//     }
//     println!();

//     println!("\nBuilding parent map...");
//     let parents = build_parent_map(&nodes);

//     // ── Level 0: leaf treelets (with geometry) ───────────────────────────────
//     let spine_budget = budgets_bytes[budget_pcts.len() - 1];
//     let mut level_roots: Vec<Vec<usize>> = Vec::new();
//     let mut level_root_sets: Vec<HashSet<usize>> = Vec::new();

//     println!(
//         "\nLevel 0 (leaf, geometry): budget={}B ({:.1}KB, {}%)",
//         budgets_bytes[0],
//         budgets_bytes[0] as f32 / 1024.0,
//         budget_pcts[0]
//     );

//     // Seeds for level 0 are BVH leaves; boundary is empty (no stubs).
//     let bvh_leaves: HashSet<usize> = nodes
//         .iter()
//         .filter(|n| n.is_leaf)
//         .map(|n| n.index)
//         .collect();

//     let l0_roots = grow_level(
//         &bvh_leaves,
//         &HashSet::new(), // no boundary — level 0 owns everything below
//         &nodes,
//         &triangles,
//         &parents,
//         budgets_bytes[0],
//         true, // with geometry
//     );
//     println!("  → {} level-0 roots", l0_roots.len());
//     let l0_set: HashSet<usize> = l0_roots.iter().cloned().collect();
//     level_roots.push(l0_roots);
//     level_root_sets.push(l0_set);

//     // ── Levels 1..N-1: interior branch levels (nodes only) ──────────────────
//     // The last budget entry is the spine, so we grow interior levels for
//     // indices 1..len-2, then validate the spine at index len-1.
//     let num_interior = budget_pcts.len() - 2; // excludes level 0 and spine

//     for level in 1..=num_interior {
//         let budget = budgets_bytes[level];
//         let prev_roots = &level_root_sets[level - 1];

//         println!(
//             "\nLevel {} (branch): budget={}B ({:.1}KB, {}%)",
//             level,
//             budget,
//             budget as f32 / 1024.0,
//             budget_pcts[level]
//         );

//         let roots = grow_level(
//             prev_roots, prev_roots, // boundary = previous level's roots (they're stubs)
//             &nodes, &triangles, &parents, budget, false, // nodes only, no geometry
//         );
//         println!("  → {} level-{} roots", roots.len(), level);

//         let root_set: HashSet<usize> = roots.iter().cloned().collect();
//         level_roots.push(roots);
//         level_root_sets.push(root_set);
//     }

//     // ── Spine: validate and optionally absorb ───────────────────────────────
//     let top_roots = level_root_sets.last().unwrap();
//     println!(
//         "\nSpine: budget={}B ({:.1}KB, {}%)",
//         spine_budget,
//         spine_budget as f32 / 1024.0,
//         budget_pcts[budget_pcts.len() - 1]
//     );

//     let spine_total = spine_size(0, &nodes, top_roots);
//     let spine_fits = spine_total <= spine_budget;
//     println!(
//         "  Spine: {}B ({:.1}KB) / {}B ({:.1}%) — {}",
//         spine_total,
//         spine_total as f32 / 1024.0,
//         spine_budget,
//         100.0 * spine_total as f32 / spine_budget as f32,
//         if spine_fits {
//             "OK"
//         } else {
//             "FAILURE — spine exceeds budget"
//         }
//     );

//     // ── Validate all levels ──────────────────────────────────────────────────
//     println!("\n── Validation ───────────────────────────────────────────────────");

//     // Level 0: geometry-aware cost
//     let mut total_violations = 0usize;
//     let mut l0_violations = 0usize;
//     for &lr in &level_roots[0] {
//         let cost = leaf_treelet_cost(lr, &nodes, &triangles, &HashSet::new());
//         if cost > budgets_bytes[0] {
//             l0_violations += 1;
//             println!(
//                 "  L0 VIOLATION: root {:>8}: {}B > {}B",
//                 lr, cost, budgets_bytes[0]
//             );
//         }
//     }
//     println!(
//         "  Level 0: {} roots, {} violations",
//         level_roots[0].len(),
//         l0_violations
//     );
//     total_violations += l0_violations;

//     // Levels 1..N-1: node-only cost
//     for level in 1..=num_interior {
//         let budget = budgets_bytes[level];
//         let boundary = &level_root_sets[level - 1];
//         let mut violations = 0usize;
//         for &br in &level_roots[level] {
//             let cost = branch_treelet_size(br, &nodes, boundary);
//             if cost > budget {
//                 violations += 1;
//                 println!(
//                     "  L{} VIOLATION: root {:>8}: {}B > {}B",
//                     level, br, cost, budget
//                 );
//             }
//         }
//         println!(
//             "  Level {}: {} roots, {} violations",
//             level,
//             level_roots[level].len(),
//             violations
//         );
//         total_violations += violations;
//     }

//     if total_violations == 0 {
//         println!("  All treelets fit within budget.");
//     }

//     // ── Summary ──────────────────────────────────────────────────────────────
//     println!("\n── Final partition ──────────────────────────────────────────────");
//     let total_cores: usize = level_roots.iter().map(|r| r.len()).sum();
//     for (i, roots) in level_roots.iter().enumerate() {
//         let label = if i == 0 { "leaf" } else { "branch" };
//         println!("  Level {} ({}) cores: {}", i, label, roots.len());
//     }
//     println!("  Total cores: {} (+ 1 spine)", total_cores);
//     println!(
//         "  Spine: {}B ({:.1}KB) / {}B ({:.1}%) — {}",
//         spine_total,
//         spine_total as f32 / 1024.0,
//         spine_budget,
//         100.0 * spine_total as f32 / spine_budget as f32,
//         if spine_fits { "OK" } else { "FAIL" }
//     );

//     // ── Write output files ───────────────────────────────────────────────────
//     for (level, roots) in level_roots.iter().enumerate() {
//         let path = format!("{}\\klevel_roots_L{}.txt", subfolder, level);
//         let mut f = File::create(&path).expect("failed to create output file");
//         writeln!(
//             f,
//             "# K-level roots level={} budget={}% ({}B)",
//             level, budget_pcts[level], budgets_bytes[level]
//         )
//         .unwrap();
//         writeln!(f, "# {} roots total", roots.len()).unwrap();
//         let mut sorted = roots.clone();
//         sorted.sort();
//         for r in &sorted {
//             writeln!(f, "{}", r).unwrap();
//         }
//         println!("Wrote level {} roots to: {}", level, path);
//     }
// }
