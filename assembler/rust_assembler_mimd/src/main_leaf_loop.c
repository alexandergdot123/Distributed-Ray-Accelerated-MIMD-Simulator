// DRÆM Leaf Core - Complete Pseudocode
// Leaf cores own 9 local levels of BVH nodes (with triangles) + cache 6 levels above for leaf-leaf forwarding.
// All thread contexts are identical (no send/receive split like branch cores).
// Leaf cores do NOT spawn rays (no tile/camera/spawn pool work).
// Leaf cores terminate shadow rays on triangle hit and write occlusion to DRAM.
// Primary/bounce rays traverse the local 9-level subtree, then continue up through 6 cached parent levels for forwarding.
// always do pre-order traversal
typedef struct
{ // 48 Bytes
    float x_min;
    float x_max;
    float y_min;
    float y_max;
    float z_min;
    float z_max;
    uint16_t *left_child;         // 2 bytes - 0 if leaf
    uint16_t *right_child;        // 2 bytes - 0 if leaf
    uint16_t *parent;             // 2 bytes
    uint8_t is_right;             // 1 byte
    uint8_t tri_count;            // 1 byte
    uint16_t tri_start;           // 2 bytes -
    uint16_t core_owner;          // 2 bytes - the core that is currently responsible for this node (0xFFFF if no owner)
    uint32_t queue_low_bit_addr;  // 4 bytes - the address of the low bits of the ray queue for this node, used for sending rays to the owning core
    uint16_t queue_high_bit_addr; // 2 bytes - the address of the high bits of the ray queue for this node, used for sending rays to the owning core
    uint16_t prev_index;          // 2 bytes - select a different index each time for the core owner
    uint32_t node_id;
} AABB_Node;

typedef struct
{                                 // 64 Bytes, 16 packets
    float ox, oy, oz;             // 12 bytes - origin
    float dx, dy, dz;             // 12 bytes - direction
    float inv_dx, inv_dy, inv_dz; // 12 bytes - precomputed 1/direction
    float t_max;                  // 4 bytes  - valid interval
    uint32_t leaf_node_starting_point;
    uint32_t check_left;  // used for backtracking
    uint32_t check_right; // used for backtracking
    uint16_t pix_x;
    uint16_t pix_y;
    uint32_t tri_index; // index of the triangle hit, 0xFFFF_FFFF if no hit
    uint8_t bounce_count;
    uint8_t light_id; // 0 for not a shadow, 1, 2, 3 for lights
    uint8_t ray_depth;
    uint8_t active_ray;
} Ray; // 64 Bytes, 16 packets

typedef struct
{
    uint32_t data_mailbox[16]; // deep
    uint32_t message[16];
    uint32_t interrupt_mailbox[16];
} mailbox_system;

typedef struct
{                           // 16924 Bytes
    uint32_t head_relative; // relative to the start of the queue in DRAM
    uint32_t tail_relative; // relative to the start of the queue in DRAM
    uint32_t count;
    uint32_t next_ticket; // atomically incremented
    uint32_t now_serving; // spin on when this value equals your ticket, then increment when done
    uint32_t lock;
    uint32_t core_owner_count;
    uint16_t core_slots[256];
    struct Ray[256] rays; // 256 * 64 bytes for the rays
    uint32_t on_emergency_idle_queue;
} ray_queue_dram;

typedef struct
{                           // 16924 Bytes
    uint32_t head_relative; // relative to the start of the queue
    uint32_t tail_relative; // relative to the start of the queue
    uint32_t count;
    struct Ray[32] rays; // 32 * 64 bytes for the rays
} ray_queue_sram;

typedef struct
{                     // 32 Bytes, 8 packets
    float ox, oy, oz; // 12 bytes - origin
    float dx, dy, dz; // 12 bytes - direction
    uint16_t pix_x;   // 2 bytes
    uint16_t pix_y;   // 2 bytes
    uint8_t bounce_count;
    uint8_t light_id;
    uint8_t padding;
    uint8_t open_slot;
} RaySpawn; // 32 Bytes, 8 packets

typedef struct
{
    uint32_t head; // bytes relative to start of RaySpawns
    uint32_t tail; // bytes relative to start of RaySpawns
    uint32_t count;
    struct RaySpawn newRays[262144]; // num_cores (8192) * num_threads (16) * max_rays_per_pix (16) / num_stacks (1 per stack) (8)
} SpawnedRayPool;                    // 67MB across DRAM total for each stack

// Single ray result after traversal + shading
// Stored in fp16, accumulated in fp32 during final pass
typedef struct
{ // 16 bytes
    float r, g, b;
    union
    {
        float len_sq;
        uint32_t tri_index;
    };
} RayResult;

typedef struct
{ // 256 bytes
    // results[depth * 4 + 0] = bounce
    // results[depth * 4 + 1] = shadow light 0
    // results[depth * 4 + 2] = shadow light 1
    // results[depth * 4 + 3] = shadow light 2
    RayResult results[16];
} PixelResults;

typedef struct
{
    float red, green, blue;
    float roughness, metallic;
    float x_norm, y_norm, z_norm;
} Triangle;
// Full framebuffer of ray results for 4K
// Address: base + (y * 3840 + x) * 256
// Total: 3840 * 2160 * 256 = ~2.03 GB
typedef struct
{
    PixelResults pixels[2560 * 1440];
} FrameResults;

// Final pixel color output
typedef struct
{ // 4 bytes
    uint8_t r, g, b, a;
} Pixel;

// Final framebuffer
typedef struct
{
    Pixel pixels[2560 * 1440];
} Framebuffer;

typedef struct
{
    float r, g, b;
    float x, y, z;
} light;

typedef struct
{
    light[3];
} light_array;

typedef struct
{
    uint32_t head;
    uint32_t tail;
    uint32_t count;
    node_slot slots[64];
} emergency_node_queue;

const ray_ack = 5;
const reject_ray = 7;
const wrong_core = 8;

// ============================================================================
// LEAF CORE MAIN LOOP
// ============================================================================

// start_ray_traversal:
node = self.local_root; // always start at the leaf core's own 9-level subtree root
// start_searching:
yield();

uint32_t left_bitfield_check = ray->check_left & (1 << ray->ray_depth) | node->left_child == 0;
uint32_t right_bitfield_check = ray->check_right & (1 << ray->ray_depth) | node->right_child == 0;

if (left_bitfield_check != 0 && right_bitfield_check != 0)
{
    // Both subtrees visited at this depth — backtrack
    uint32_t bitfield = *(ray.check_left + node->is_right * 4);
    uint32_t or_value = 1 << (ray->ray_depth - 1);
    bitfield |= or_value;
    *(ray.check_left + node->is_right * 4) = bitfield;
    ray->ray_depth--;
    if (node->parent == 0)
    {
        goto send_ray_up;
    }
    node = node->parent;
}
else if (left_bitfield_check == 0 && right_bitfield_check == 0)
{
    int hit = AABB_Intersect(node, ray);
    if (hit)
    {
        if (node->tri_count == 0)
        {
            // Internal node
            ray->ray_depth++;
            if (node->core_owner != 0xFFFF)
            {
                // send_ray_up:
                uint16_t ray_send_pending_addr = self.ray_send_pending_addr;
                atomic_add(ray_send_pending_addr, 1);
                /*
                send_ray_to_core(ray, dest):
                    rays_incoming = 0
                    send request to dest's interrupt mailbox
                    sent = false
                    loop:
                        if nb_recv(data_mailbox) >= 1:
                            for i in 0..16:
                                blocking_recv(data_mailbox)
                            enqueue(new_ray) //this enqueue MUST allow for
                            rays_incoming--
                        if nb_recv(shallow_mailbox) >= 1:
                            msg = recv(shallow_mailbox)
                            sent = true
                            if msg == ACK:
                                for i in 0..16:
                                    send(dest, ray[i])
                            if msg == REJECT:
                                push to dram queue
                        if nb_recv(interrupt_mailbox) >= 1:
                            req = recv(interrupt_mailbox)
                            if space_in_queue - rays_incoming > 0:
                                send_ack(req.src)
                                rays_incoming++
                            else:
                                send_reject(req.src)
                        if sent and rays_incoming == 0:
                            break
                */

                uint32_t slot = 0xFFFFFFFF;
                uint32_t sent = 0;
                uint32_t request_word = (node->node_id << 17) | self.thread_id;
                send_packet(request_word, node->core_owner, 32);

                // send_ray_loop:
                uint32_t msg_available = nb_recv(self.thread_id + 16);
                if (msg_available == 1)
                {
                    uint32_t msg = blocking_receive(self.thread_id + 16);
                    uint32_t header = msg >> 24;

                    if (header == ack_ray)
                    {
                        for (int i = 0; i < 16; i++)
                        {
                            send_packet(((uint32_t *)ray)[i], node->core_owner, msg & 0xF);
                        }
                        ray->active_ray = 0;
                        sent = 1;
                    }
                    else
                    {
                        int queue_address_high = node->queue_high_bit_addr;
                        set_address_bits(queue_address_high);
                        int queue_address_low = node->queue_low_bit_addr;

                        // ensure_space_in_queue:
                        int cur_ray_count = load_dram_word(queue_address_low - 12);
                        if (cur_ray_count > 255)
                        {
                            goto ensure_space_in_queue;
                        }
                        queue_address_low -= 16;
                        int tail = atomic_add_dram(queue_address_low, 64);
                        tail &= 0x00003FFF;
                        int write_addr = queue_address_low + 536;
                        write_addr += tail;
                        // wait_for_slot_to_open:
                        int cur_ray_count = load_dram_byte(write_addr + 63);
                        if (cur_ray_count != 0)
                        {
                            goto wait_for_slot_to_open;
                        }
                        uint32_t ray_index = ray;
                        for (int i = 0; i < 16; i++)
                        {
                            uint32_t ray_word = load_word(ray_index);
                            store_dram_word(write_addr, ray_word);
                            write_addr = write_addr + 4;
                            ray_index = ray_index + 4;
                        }
                        queue_address_low = node->queue_low_bit_addr;
                        queue_address_low += 20;
                        // ensure_no_writers:
                        int is_there_a_writer = atomic_add_dram(queue_address_low, 1);
                        if (is_there_a_writer < 0)
                        {
                            atomic_add_dram(queue_address_low, -1);
                            // ensure_no_writers_loop:
                            is_there_a_writer = load_word_dram(queue_address_low);
                            if (is_there_a_writer < 0)
                            {
                                goto ensure_no_writers_loop;
                            }
                            else
                            {
                                goto ensure_no_writers;
                            }
                        }
                        uint32_t core_owner_count = load_dram_word(queue_address_low + 4);
                        if (core_owner_count == 0)
                        {
                            node->core_owner = 0xFFFFFFFF;
                            if (cur_ray_count > 200)
                            {
                                // need to throw the node_id into a queue for someone to pick up the geometry.
                                uint32_t queue_address_high = node->queue_high_bit_addr;
                                set_address_bits(queue_address_high);
                                uint32_t queue_address_low = node->queue_low_bit_addr;
                                queue_address_low += 16924;
                                uint32_t is_first_to_enqueue_queue = atomic_add_dram(queue_address_low, 1);
                                if (is_first_to_enqueue_queue != 0)
                                {
                                    goto skip_adding_queue_to_emergency_queue;
                                }
                                uint32_t emergency_queue_high = self.emergency_queue_high;
                                set_address_bits(emergency_queue_high);
                                uint32_t emergency_queue_low = self.emergency_queue_low;
                                emergency_queue_low += 8;
                                // loop_emergency_queue_insertion:
                                uint32_t old_cnt = atomic_add_dram(emergency_queue_low, 1);
                                if (old_cnt >= 64)
                                {
                                    atomic_add_dram(emergency_queue_low, -1);
                                    goto loop_emergency_queue_insertion;
                                }
                                emergency_queue_low -= 4;
                                uint32_t byte_index = atomic_add_dram(emergency_queue_low, 4);
                                byte_index &= 0x000000FF;
                                emergency_queue_low += byte_index;
                                emergency_queue_low += 8;
                                // ensure_emergency_slot_ready:
                                uint16_t is_ready = load_dram_byte(emergency_queue_low + 2);
                                if (is_ready == 1)
                                {
                                    goto ensure_emergency_slot_ready;
                                }
                                store_dram_half(emergency_queue_low, node->node_id);
                                store_dram_byte(emergency_queue_low + 2, 1);
                            }
                        }
                        else
                        {
                            uint32_t clock = get_clock();
                            uint16_t idx = self.core_id ^ clock;
                            uint16_t prev_idx = node->prev_index;
                            if (idx == prev_idx)
                            {
                                idx += 1;
                            }
                            idx %= core_owner_count;
                            node->prev_index = idx;
                            idx <<= 1;
                            queue_address_low += idx;
                            uint32_t core_to_cache = load_dram_word(queue_address_low + 28);
                            node->core_owner = core_to_cache;
                        }
                        // skip_adding_queue_to_emergency_queue:
                        queue_address_low = node->queue_low_bit_addr;
                        queue_address_low += 20;
                        atomic_add_dram(queue_address_low, -1);
                        ray->active_ray = 0;
                        sent = 1;
                    }
                }
                uint32_t data_available = nb_recv(self.thread_id);
                if (data_available == 1)
                {
                    for (int i = 0; i < 16; i++)
                    {
                        uint32_t ray_word = blocking_receive(self.thread_id);
                        *slot = ray_word;
                        slot = slot + 4;
                    }
                    slot = 0xFFFFFFFF;
                }               
                uint32_t interrupt_available = nb_recv(32);
                if (interrupt_available != 0)
                {
                    // typedef struct { //16924 Bytes
                    //     uint32_t head_relative; //relative to the start of the queue
                    //     uint32_t tail_relative; //relative to the start of the queue
                    //     uint32_t count;
                    //     struct Ray[16] rays; //16 * 64 bytes for the rays
                    // } ray_queue_sram;
                    // the below should occur on an interrupt which is accepted.

                    uint32_t message = blocking_receive(32);
                    uint32_t my_node_id = *self.root_node_id;
                    uint32_t supposed_node_id = (message >> 17);
                    if (supposed_node_id != my_node_id)
                    {
                        uint32_t wrong_core_msg = wrong_core << 24;
                        send_packet(wrong_core_msg, (message >> 4) * 0x1FFF, message & 0xF + 16);
                        goto done_with_interrupt;
                    }

                    uint32_t local_queue = self.local_queue + 8; // skip head and tail
                    uint32_t old_count = atomic_add(&local_queue.count, 1);
                    if (old_count > 32)
                    {
                        atomic_add(&local_queue.count, -1);
                        uint32_t reject_ray_msg = reject_ray << 24;
                        send_packet(reject_ray_msg, (message >> 4) * 0x1FFF, message & 0xF + 16);
                        goto done_with_interrupt;
                    }
                    local_queue -= 4;
                    uint32_t tail_relative = atomic_add(&local_queue, 64);
                    tail_relative = tail_relative & 0x000007FF;
                    local_queue += 8;
                    local_queue += tail_relative;
                    slot = local_queue;
                    uint32_t ray_ack_msg = ray_ack << 24 | self.thread_id;
                    send_packet(ray_ack_msg, (message >> 4) * 0x1FFF, message & 0xF + 16);
                }
                // done_with_interrupt:
                if (sent == 1 && slot == 0xFFFFFFFF)
                {
                    uint16_t ray_send_pending_addr = self.ray_send_pending_addr;
                    atomic_add(ray_send_pending_addr, -1);
                    goto ray_done;
                }
                goto send_ray_loop;
            }
            else
            {
                node = node->left_child; // Traverse left child first
            }
        }
        else
        {
            // traverse own child
            // Leaf node — check triangles
            uint32_t bitfield = *(ray.check_left + node->is_right * 4);
            uint32_t or_value = 1 << (ray->ray_depth - 1);
            bitfield |= or_value;
            *(ray.check_left + node->is_right * 4) = bitfield;

            uint16_t tri_index = node->tri_start;
            for (int i = 0; i < node->tri_count; i++)
            {
                Triangle_Intersect(tri_index, ray);
                tri_index = tri_index + 6;

                // Shadow ray early termination: if we hit anything, we're done
                if (ray->light_id != 0 && ray->tri_index != 0xFFFFFFFF)
                {
                    goto shadow_ray_occluded;
                }
            }
            ray->ray_depth--;
            node = node->parent;
        }
    }
    else
    {
        // No intersection with AABB — backtrack
        uint32_t right_bitfield = *(ray.check_left + node->is_right * 4);
        uint32_t or_value = 1 << (ray->ray_depth - 1);
        right_bitfield |= or_value;
        *(ray.check_left + node->is_right * 4) = right_bitfield;
        ray->ray_depth--;
        node = node->parent;
    }
}
else
{
    // One subtree not yet visited — descend into it
    uint32_t zero_out_subtree = ~(0xFFFFFFFF << ray->ray_depth + 1);
    ray->check_left &= zero_out_subtree;
    ray->check_right &= zero_out_subtree;
    node = *(node.left_child + ((left_bitfield_check != 0) * 2));
    ray->ray_depth++;
}
goto start_searching;

// ============================================================================
// SHADOW RAY OCCLUDED — write result to DRAM and terminate
// ============================================================================
// shadow_ray_occluded:
uint32_t finished_ray_high = self.ray_result_addr_high;
set_address_bits(finished_ray_high);
uint32_t result_addr_low = self.ray_result_addr_low;
atomic_add_dram(result_addr_low, 1); // increment finished ray counter

uint32_t pix_index = ray->pix_y;
pix_index *= 2560;
pix_index += ray->pix_x;
pix_index <<= 8;
result_addr_low += pix_index;

uint32_t bounce = ray->bounce_count;
bounce <<= 6;
result_addr_low += bounce;

uint32_t shadow = ray->light_id;
result_addr_low += shadow << 4;

// Write 1.0 to len_sq slot to mark as occluded (blocked)
uint32_t one = 0x3F800000;
store_dram_word(result_addr_low + 12, one);

ray->active_ray = 0;
goto ray_done;

// ============================================================================
// RAY DONE — check for more work
// ============================================================================
// ray_done:
if (ray->active_ray == 1)
{
    goto start_ray_traversal;
}
yield();

// Check local SRAM ray queue
uint32_t local_queue_addr = self.local_ray_queue;
uint32_t local_ray_count = *(local_queue_addr + 8);
if (local_ray_count > 0)
{
    uint32_t old_count = atomic_add(local_queue_addr + 8, -1);
    if (old_count <= 0)
    {
        atomic_add(local_queue_addr + 8, 1);
        goto check_dram_queue;
    }
    // CHECK_SRAM_HEAD:
    uint32_t head = atomic_add(local_queue_addr, 64);
    head = head & 0x000007FF; // 32 slots * 64 bytes = 1024
    uint32_t ray_src = local_queue_addr + 12 + head;

    int ray_index = ray;
    // RAY_UPDATE_LOOP:
    for (int i = 0; i < 16; i++)
    {
        uint32_t ray_word = *(ray_src);
        *(ray_index) = ray_word;
        ray_src = ray_src + 4;
        ray_index = ray_index + 4;
    }
    // Clear the slot's ready byte
    *(ray_src - 1) = 0;

    ray->leaf_node_starting_point = self.branch_local_leaf_index;
    ray->active_ray = 1;
    goto start_ray_traversal;
}
// NO_DRAM_RAYS:
uint8_t flushing_queue = *(self.local_queue_flushing);
if (flushing_queue != 0)
{
    goto inf_loop;
}
// check_dram_queue:
yield();
int queue_address_low = self.ray_queue_address_low;
int queue_address_high = self.ray_queue_address_high;
set_address_bits(queue_address_high);
int cur_ray_count = load_dram_word(queue_address_low + 8);
if (cur_ray_count > 0)
{
    if (cur_ray_count >= 256)
    {
        uint32_t pulled_from_full_queue_address = self.pulled_from_full_queue_address;
        uint32_t num_times_pulled_from_full_queue = atomic_add(pulled_from_full_queue_address, 1);
        if (num_times_pulled_from_full_queue > LEAF_BUSY_THRESHOLD)
        {
            leaf_core_ask_for_help();
        }
        else
        {
            *(self->pulled_from_full_queue_address) = 0;
        }
    }
    // CHECK_CUR_RAY_COUNT:
    int cur_ray_count_check = atomic_add_dram(queue_address_low + 8, -1);
    if (cur_ray_count_check <= 0)
    {
        atomic_add_dram(queue_address_low + 8, 1);
        goto ray_done;
    }
    int head = atomic_add_dram(queue_address_low, 64);
    queue_address_low = queue_address_low + 536; // skip header + core_slots to ray data
    head = head & 0x00003FFF;
    queue_address_low += head;

    // wait_for_write:
    int ready = load_dram_byte(queue_address_low + 63);
    if (ready == 0)
    {
        goto wait_for_write;
    }
    int ray_index = ray;
    for (int i = 0; i < 16; i++)
    {
        *(ray_index) = load_dram_word(queue_address_low);
        queue_address_low = queue_address_low + 4;
        ray_index = ray_index + 4;
    }
    write_dram_byte(queue_address_low - 1, 0); // mark consumed
    ray->leaf_node_starting_point = self.branch_local_leaf_index;
    goto start_ray_traversal;
}
// NO_DRAM_RAY:
uint32_t emergency_queue_high = self.emergency_queue_high;
set_address_bits(emergency_queue_high);
uint32_t emergency_queue_low = self.emergency_queue_low;
uint32_t count = load_dram_word(emergency_queue_low + 8);
if (count <= 0)
{
    goto check_done;
}
emergency_queue_low += 8;
uint32_t old_cnt = atomic_add_dram(emergency_queue_low, 1);
if (old_cnt <= 0)
{
    atomic_add_dram(emergency_queue_low, -1);
    goto check_done;
}
emergency_queue_low -= 8;
uint32_t byte_index = atomic_add_dram(emergency_queue_low, 4);
byte_index &= 0x000000FF;
emergency_queue_low += byte_index;
emergency_queue_low += 12;
// ensure_emergency_slot_ready:
uint16_t is_ready = load_dram_byte(emergency_queue_low + 2);
if (is_ready == 1)
{
    goto ensure_emergency_slot_ready;
}
uint32_t new_node_id = load_dram_half(emergency_queue_low);
store_dram_byte(emergency_queue_low + 2, 0);
*(self.local_queue_flushing) = 1;
*(self.local_queue_flushing + 4) = new_node_id;
goto switch_dram_queue;

yield();
// check_done
is_idle_leaf();
uint32_t finished_ray_high = self.ray_result_addr_high;
set_address_bits(finished_ray_high);
uint32_t finished_ray_low = self.ray_result_addr_low;
uint32_t rays_finished = load_dram_word(finished_ray_low);
uint32_t max_rays = 1440 * 2560 * 4;
if (rays_finished != max_rays)
{
    goto ray_done;
}

// pixel_color subroutine
// NUM_BOUNCES is a compile-time constant
get_thread_ownership();
set_ctx(15);
relinquish_ownership();
yield();
uint32_t pixel_addr_high = self.ray_result_addr_high;
set_address_bits(pixel_addr_high);
uint32_t pixel_addr_low = self.ray_result_addr_low;
uint32_t pix_index = self.core_id >> 4;
uint32_t thread_index = self.core_id & 0xF;
pix_index *= 15;
pix_index += 15;
pix_index <<= 8;
uint32_t pix_increment = pix_index;
// loop_pixel:
uint32_t pixel_addr_low = self.ray_result_addr_low;
pixel_addr_low += pix_increment;

float carried_r = 0.0f;
float carried_g = 0.0f;
float carried_b = 0.0f;

uint32_t bounce = NUM_BOUNCES - 1;
// bounce_loop:
uint32_t bounce_addr = bounce;
bounce_addr <<= 6;
bounce_addr += pixel_addr_low;

float sr = load_dram_word(bounce_addr);
float sg = load_dram_word(bounce_addr + 4);
float sb = load_dram_word(bounce_addr + 8);
float metallic = load_dram_word(bounce_addr + 12);

float acc_r = 0.0f;
float acc_g = 0.0f;
float acc_b = 0.0f;

uint32_t shadow_addr = bounce_addr + 16;
uint32_t light = 0;
// shadow_loop:
uint32_t len_sq = load_dram_word(shadow_addr + 12);
if (len_sq != 0xFFFFFFFF)
    goto shadow_skip;
float lr = load_dram_word(shadow_addr);
float lg = load_dram_word(shadow_addr + 4);
float lb = load_dram_word(shadow_addr + 8);
float atten = reciprocal(len_sq);
lr *= atten;
lg *= atten;
lb *= atten;
acc_r += lr;
acc_g += lg;
acc_b += lb;
shadow_skip : shadow_addr += 16;
light += 1;
if (light < NUM_LIGHTS)
    goto shadow_loop;

float diffuse_r = acc_r * sr;
float diffuse_g = acc_g * sg;
float diffuse_b = acc_b * sb;

carried_r *= sr;
carried_g *= sg;
carried_b *= sb;

float one = 1.0f;
float inv_metallic = one - metallic;
diffuse_r *= inv_metallic;
diffuse_g *= inv_metallic;
diffuse_b *= inv_metallic;
carried_r *= metallic;
carried_g *= metallic;
carried_b *= metallic;
carried_r += diffuse_r;
carried_g += diffuse_g;
carried_b += diffuse_b;

if (bounce == 0)
    goto bounce_done;
bounce -= 1;
goto bounce_loop;

// bounce_done:
// carried_r/g/b is final pixel color
float one = 1.0f;
carried_r += one;
carried_g += one;
carried_b += one;
carried_r >>= 14; // using 9 bits to reduce aliasing
carried_g >>= 14;
carried_b >>= 14;
carried_r &= 0x1FF;
carried_g &= 0x1FF;
carried_b &= 0x1FF;
red_byte = *(self.table_mappings + carried_r);
green_byte = *(self.table_mappings + carried_g);
blue_byte = *(self.table_mappings + carried_b);

uint32_t pixel_addr_high = self.frame_buffer_high;
set_address_bits(pixel_addr_high);
uint32_t pixel_addr_low = self.frame_buffer_low;
uint32_t pix_offset = pix_increment >> 6; // each pixel is 4 bytes
pixel_addr_low += pix_offset;
store_dram_byte(red_byte, pixel_addr_low);
pixel_addr_low += 1;
store_dram_byte(green_byte, pixel_addr_low);
pixel_addr_low += 1;
store_dram_byte(blue_byte, pixel_addr_low);
pix_increment += pix_index;
uint32_t max_rez = 2560 * 1440;
max_rez <<= 8;
// need some atomic to increment up till 2560 * 1440;
uint32_t finished_pixel_high = self.finished_pixel_high;
set_address_bits(finished_pixel_high)
    uint32_t finished_pixel_low = self.finished_pixel_low;
atomic_add_dram(finished_pixel_low, 1);
if (max_rez > pix_increment)
{
    goto loop_pixel;
}
// inf_loop:
goto inf_loop;

// ============================================================================
// SUBROUTINES
// ============================================================================

int AABB_Intersect(AABB_Node *node, Ray *ray)
{
    float tx1 = (node->x_min - ray->ox) * ray->inv_dx;
    float tx2 = (node->x_max - ray->ox) * ray->inv_dx;

    float tmin = min(tx1, tx2);
    float tmax = max(tx1, tx2);

    float epsilon = 0x38D1B717; // ~1e-4
    tmin = max(tmin, epsilon);
    tmax = min(tmax, ray->t_max);

    if (tmin > tmax || tmax <= 0.0)
        return 0;

    float ty1 = (node->y_min - ray->oy) * ray->inv_dy;
    float ty2 = (node->y_max - ray->oy) * ray->inv_dy;

    tmin = max(tmin, min(ty1, ty2));
    tmax = min(tmax, max(ty1, ty2));

    if (tmin > tmax || tmax <= 0.0)
        return 0;

    float tz1 = (node->z_min - ray->oz) * ray->inv_dz;
    float tz2 = (node->z_max - ray->oz) * ray->inv_dz;

    tmin = max(tmin, min(tz1, tz2));
    tmax = min(tmax, max(tz1, tz2));

    return (tmin <= tmax) & (0.0 < tmax);
}

void Triangle_Intersect(Index *idx, Ray *ray, Vertex *vertices)
{
    Vertex *v0 = &vertices[idx];
    Vertex *v1 = &vertices[idx->v0[1]];
    Vertex *v2 = &vertices[idx->v0[2]];

    float e1x = v1->x - v0->x;
    float e1y = v1->y - v0->y;
    float e1z = v1->z - v0->z;

    float e2x = v2->x - v0->x;
    float e2y = v2->y - v0->y;
    float e2z = v2->z - v0->z;

    float px = ray->dy * e2z - ray->dz * e2y;
    float py = ray->dz * e2x - ray->dx * e2z;
    float pz = ray->dx * e2y - ray->dy * e2x;

    set_accumulator(0.0);
    fmac(e1x, px);
    fmac(e1y, py);
    fmac(e1z, pz);
    float det = store_accumulator();

    if (det == 0.0)
        return;

    float tx = ray->ox - v0->x;
    float ty = ray->oy - v0->y;
    float tz = ray->oz - v0->z;

    set_accumulator(0.0);
    fmac(tx, px);
    fmac(ty, py);
    fmac(tz, pz);
    float u_unscaled = store_accumulator();

    if (det > 0.0)
    {
        if (u_unscaled < 0.0 || u_unscaled > det)
            return;
    }
    else
    {
        if (u_unscaled > 0.0 || u_unscaled < det)
            return;
    }

    float qx = ty * e1z - tz * e1y;
    float qy = tz * e1x - tx * e1z;
    float qz = tx * e1y - ty * e1x;

    set_accumulator(0.0);
    fmac(ray->dx, qx);
    fmac(ray->dy, qy);
    fmac(ray->dz, qz);
    float v_unscaled = store_accumulator();

    float uv_sum = u_unscaled + v_unscaled;
    if (det > 0.0)
    {
        if (v_unscaled < 0.0 || uv_sum > det)
            return;
    }
    else
    {
        if (v_unscaled > 0.0 || uv_sum < det)
            return;
    }

    set_accumulator(0.0);
    fmac(e2x, qx);
    fmac(e2y, qy);
    fmac(e2z, qz);
    float t_unscaled = store_accumulator();

    float epsilon = 0x38D1B717; // ~1e-4
    float tmin_scaled = epsilon * det;
    float tmax_scaled = ray->t_max * det;
    if (det > 0.0)
    {
        if (t_unscaled < tmin_scaled || t_unscaled > tmax_scaled)
            return;
    }
    else
    {
        if (t_unscaled > tmin_scaled || t_unscaled < tmax_scaled)
            return;
    }

    float t = t_unscaled * reciprocal(det);
    ray->t_max = t;
    ray->tri_index = tri->tri_index;
}

// reciprocal subroutine
uint32_t neg_max = 0x80000000;
uint32_t sign = x & neg_max;
neg_max ^= 0xFFFFFFFF;
x &= neg_max;
uint32_t original_magnitude = x;

uint32_t exp = x >> 23;
uint32_t new_exp = 254 - exp;

uint32_t index = x >> 12;
index &= 0x7FF;
index <<= 2;
uint32_t table_addr = self.div_table_high;
set_address_bits(table_addr);
table_addr = self.div_table_low;
table_addr += index;
uint32_t reciprocal_lookup = load_dram_word(table_addr);

new_exp <<= 23;
reciprocal_lookup |= new_exp;

// NR: r1 = r0 * (2 - x * r0)
float xf = original_magnitude;
float r0 = reciprocal_lookup;
float t = xf * r0;
float two = 2.0f;
t = two - t;
r0 = r0 * t;
r0 |= sign;
// r0 is returned

// Eat_Ray_Interrupt:
disable_interrupts(32);
uint32_t is_value = nb_recv(32);
if (is_value == 0)
{
    return;
}
uint32_t value = blocking_recv(32);
uint32_t node_id = value >> 17;
uint32_t core_id = value & 0x0001FFFF;
if (node_id != self.node_id)
{
    uint32_t value_to_send = wrong_core << 24;
    value_to_send |= self.thread_id;
    send_packet(value_to_send, core_id);
    enable_interrupts(32);
    return;
}
uint8_t flushing_queue = *(self.local_queue_flushing);
if (flushing_queue == 1)
{
    goto reject_ray_interrupt;
}
uint32_t is_slot_empty = *(ray + 63);
if (is_slot_empty == 0)
{
    uint32_t local_queue = ray;
    goto receive_ray_data;
}
uint32_t local_queue = self.local_queue + 8; // skip head and tail
uint32_t old_count = atomic_add(&local_queue.count, 1);
if (old_count > 32)
{
    atomic_add(&local_queue.count, -1);
    // reject_ray_interrupt:
    uint32_t reject_ray_msg = reject_ray << 24;
    reject_ray_msg |= self.thread_id;
    send_packet(reject_ray_msg, core_id);
    enable_interrupts(32);
    return;
}
local_queue -= 4;
uint32_t tail_relative = atomic_add(&local_queue, 64);
tail_relative = tail_relative & 0x000007FF;
local_queue += 8;
local_queue += tail_relative;
// receive_ray_data:
uint32_t ray_ack_msg = ray_ack << 24 | self.thread_id;
send_packet(ray_ack_msg, core_id);
for (int i = 0; i < 16; i++)
{
    uint32_t ray_data = blocking_recv(self.thread_id);
    *local_queue = ray_data;
    local_queue += 4;
}
enable_interrupts(32);
return;

uint32_t ACCEPT_CHANGE = 13;
uint32_t REJECT_CHANGE = 14;

// search_for_idle_cores:
//  ============================================================
//  bottom_up_idle_core_search
//  ============================================================
//  Searches the idle_queue_tree starting at a known leaf queue,
//  ascending and searching sibling subtrees until an idle core
//  is found or the full tree is exhausted.
//
//  Inputs:
//    self->idle_queue_address_high : high bits of current leaf idle_queue_tree_node
//    self->idle_queue_address_low  : low bits of current leaf idle_queue_tree_node
//
//  Outputs:
//    self->found_core_id : core_id of dequeued idle core, or 0xFFFF if none found
//  ============================================================

typedef struct
{
    uint32_t high;
    uint32_t low;
    uint16_t height;
    uint16_t _pad;
} DFS_Entry;

// 5-level tree: max 2*height entries live at once, height <= 5, 12 bytes each
DFS_Entry dfs_stack[12];
uint32_t dfs_top = 0;

uint32_t idle_queue_address_high = self.idle_queue_address_high;
set_address_bits(idle_queue_address_high);
uint32_t current = self.idle_queue_address_low;
int32_t found_core_id = 0xFFFF;

// ascend:
uint16_t is_left = load_dram_half(current + offsetof(idle_queue_tree_node, is_left));
uint16_t height = load_dram_half(current + offsetof(idle_queue_tree_node, height));

uint32_t parent_high = load_dram_word(current + offsetof(idle_queue_tree_node, parent_high));
uint32_t parent_low = load_dram_word(current + offsetof(idle_queue_tree_node, parent_low));
if (parent_high == 0xFFFFFFFF)
    goto search_done;

set_address_bits(parent_high);
uint32_t parent = parent_low;

parent += 8;
uint32_t sibling_high = load_dram_word(parent + offsetof(idle_queue_tree_node, left_high));
uint32_t sibling_low = load_dram_word(parent + offsetof(idle_queue_tree_node, left_low));

// push_sibling:
dfs_stack[dfs_top].high = sibling_high;
dfs_stack[dfs_top].low = sibling_low;
dfs_stack[dfs_top].height = height; // sibling is at same height as us
dfs_top++;

// dfs_loop:
if (dfs_top == 0)
    goto sibling_exhausted;
dfs_top--;

uint32_t dfs_node_high = dfs_stack[dfs_top].high;
uint32_t dfs_node_low = dfs_stack[dfs_top].low;
uint16_t dfs_node_height = dfs_stack[dfs_top].height;

set_address_bits(dfs_node_high);
uint32_t dfs_node = dfs_node_low;

if (dfs_node_height == 0)
    goto try_dequeue;

uint16_t child_height = dfs_node_height - 1;

uint32_t right_high = load_dram_word(dfs_node + offsetof(idle_queue_tree_node, right_high));
uint32_t right_low = load_dram_word(dfs_node + offsetof(idle_queue_tree_node, right_low));
dfs_stack[dfs_top].high = right_high;
dfs_stack[dfs_top].low = right_low;
dfs_stack[dfs_top].height = child_height;
dfs_top++;

uint32_t left_high = load_dram_word(dfs_node + offsetof(idle_queue_tree_node, left_high));
uint32_t left_low = load_dram_word(dfs_node + offsetof(idle_queue_tree_node, left_low));
dfs_stack[dfs_top].high = left_high;
dfs_stack[dfs_top].low = left_low;
dfs_stack[dfs_top].height = child_height;
dfs_top++;

goto dfs_loop;

// try_dequeue:
uint32_t count_addr = dfs_node + offsetof(idle_core_queue_dram, count);
uint32_t count = load_dram_word(count_addr);
if (count == 0)
    goto dfs_loop;

int32_t old_count = atomic_add_dram(count_addr, -1);
if (old_count <= 0)
    goto revert_count;
goto claim_slot;

// revert_count:
atomic_add_dram(count_addr, 1);
goto dfs_loop;

// claim_slot:
uint32_t head_addr = dfs_node + offsetof(idle_core_queue_dram, head_relative);
uint32_t head_relative = atomic_add_dram(head_addr, 4);
head_relative = head_relative & 0x3FF;
uint32_t slot_addr = dfs_node + offsetof(idle_core_queue_dram, slots) + head_relative;
uint32_t valid_addr = slot_addr + offsetof(idle_queue_slot, is_valid);
uint32_t coreid_addr = slot_addr + offsetof(idle_queue_slot, core_id);

// spinlock_valid:
uint16_t is_valid = load_dram_half(valid_addr);
if (is_valid == 0)
    goto spinlock_valid;

uint16_t found_core = load_dram_half(coreid_addr);
store_dram_half(0, valid_addr);
found_core_id = found_core;
goto search_done;

// sibling_exhausted:
set_address_bits(parent_high);
current = parent_low;
uint16_t parent_is_left = load_dram_half(current + offsetof(idle_queue_tree_node, is_left));
is_left = parent_is_left;
goto ascend;

// search_done:
if (found_core_id != 0xFFFF)
{
    send_flit(self.thread_id, found_core_id, 34);
    uint32_t will_accept_change = blocking_recv(16 + self.thread_id);
    if ((will_accept_change >> 24) == REJECT_CHANGE)
    {
        goto ray_done;
    }
    send_flit(1, found_core_id, 0);
    if ((will_accept_change & 1) != self.is_branch_core)
    {
        uint32_t starting_address = branch_start_of_code;
        uint32_t num_instructions = 1234 * 4;
        for (int i = 0; i < num_instructions; i += 4)
        {
            uint32_t instruction_to_send = *(starting_address + i);
            send_flit(instruction_to_send, found_core_id, 0);
        }
    }
    uint32_t starting_address = branch_start_of_geometry;
    uint32_t size_of_geo = 5678 * 4;
    for (int i = 0; i < size_of_geo; i += 4)
    {
        uint32_t word_to_transfer_of_geo = *(starting_address + i);
        send_flit(word_to_transfer_of_geo, found_core_id, 0);
    }
}
goto ray_done;

// switch_roles_interrupt:
disable_interrupts(34);
uint32_t is_value = nb_recv(34);
if (is_value == 0)
{
    enable_interrupts(34);
    return;
}
uint32_t switch_core_request = blocking_recv(34);
if (self.core_handled->previously_idle == 0)
{
    send_flit(REJECT_CHANGE << 24, switch_core_request >> 4, switch_core_request & 0xF + 16);
    enable_interrupts(34);
    return;
}
send_flit(ACCEPT_CHANGE << 24 | self.is_branch_core, switch_core_request >> 4, switch_core_request & 0xF + 16);
get_ownership();
uint32_t type_of_core = blocking_recv(0);
if (type_of_core != self.is_branch_core)
{
    uint32_t starting_address = (type_of_core == 1) ? branch_start_of_code : leaf_start_of_code;
    uint32_t num_instructions = 4321 * 4;
    for (int i = 0; i < num_instructions; i += 4)
    {
        uint32_t instruction_to_recv = blocking_recv(0);
        *(starting_address + i) = instruction_to_recv;
    }
}
uint32_t starting_address = (type_of_core == 1) ? branch_start_of_geometry : leaf_start_of_geometry;
uint32_t size_of_geo = (type_of_core == 1) ? 5678 * 4 : 8765 * 4;
for (int i = 0; i < size_of_geo; i += 4)
{
    uint32_t word_to_transfer_of_geo = blocking_recv(0);
    *(starting_address + i) = word_to_transfer_of_geo;
}
self.is_branch_core = type_of_core;
if (type_of_core == 1)
{
    goto dfs_done;
}
goto dfs_done_but_leaf;

bool is_idle_leaf()
{
    uint32_t current_cycle = get_cycle_count();
    uint32_t last_observed_cycle = self.core_handled->last_observed_cycle;
    uint32_t time_diff = current_cycle - last_observed_cycle;
    if (time_diff < IDLE_WINDOW)
    {
        return 0;
    }

    if (self.core_handled->previously_idle)
    {
        return 0;
    }

    uint32_t rays_processed = self.core_handled->rays_processed;

    self.core_handled->rays_processed = 0;
    self.core_handled->last_observed_cycle = current_cycle;
    rays_processed <<= 16;
    uint32_t ratio = rays_processed / time_diff;
    if (ratio >= IDLE_THRESHOLD)
    {
        return 0;
    }
    add_idle_core();
    self.core_handled->previously_idle = 1;
    return 1;
}

void add_idle_core()
{
    uint32_t idle_queue_address_high = self.idle_queue_address_high;
    set_address_bits(idle_queue_address_high);
    uint32_t idle_queue_address_low = self.idle_queue_address_low;
    idle_queue_address_low += 8;
idle_core_insert_spinlock:
    uint32_t old_count = atomic_add_dram(idle_queue_address_low, 1);
    if (old_count > 256)
    {
        atomic_add_dram(idle_queue_address_low, -1);
        goto idle_core_insert_spinlock;
    }
    idle_queue_address_low -= 4;
    uint32_t slot_index = atomic_add_dram(idle_queue_address_low, 4);
    slot_index = slot_index & 0x3FF;
    uint32_t slot_address = idle_queue_address_low + slot_index;
wait_for_idle_queue_slot_to_open:
    uint32_t is_open = load_dram_half(slot_address + 10);
    if (is_open != 0)
    {
        goto wait_for_idle_queue_slot_to_open;
    }
    store_dram_half(self.core_id, slot_address + 8);
    store_dram_byte(1, slot_address + 10);
}

#define LOCK_DECREMENT 0x7FFFFFFF // some large value idk

// Return 0 on failure, return 1 on success

uint32_t remove_from_ray_queue_dram(uint32_t q_high, uint32_t q_low)
{

    set_address_bits(q_high);

    uint32_t my_ticket = atomic_add_dram(q_low + 12, 1);

    uint32_t now_serving = load_dram_word(q_low + 16);
    if (now_serving != my_ticket)
    {
        now_serving = load_dram_word(q_low + 16)
    }
    int32_t lock_val = atomic_add_dram(q_low + 20, -LOCK_DECREMENT);
    while (lock_val != -LOCK_DECREMENT)
    {
        lock_val = load_dram_word(q_low + 20);
    }
    uint32_t owner_count = load_dram_word(q_low + 24);
    if (owner_count <= 1)
    {
        atomic_add_dram(q_low + 20, LOCK_DECREMENT);
        atomic_add_dram(q_low + 16, 1);
        return 0;
    }

    uint32_t slots_base = q_low + 28;
    uint32_t i = 0;
find_our_slot_remove:
    if (i >= owner_count)
        goto slot_not_found_remove;
    uint16_t slot_val = load_dram_half(slots_base + i * 2);
    if (slot_val == self.core_id)
        goto found_our_slot_remove;
    i += 1;
    goto find_our_slot_remove;

found_our_slot_remove:
    uint32_t last_slot_addr = slots_base + (owner_count - 1) * 2;
    uint16_t last_val = load_dram_half(last_slot_addr);
    store_dram_half(slots_base + i * 2, last_val);
    store_dram_half(last_slot_addr, 0);
    atomic_add_dram(q_low + 24, -1); // decrement core_owner_count
    goto release_remove;

slot_not_found_remove:
    return 1;
release_remove:
    atomic_add_dram(q_low + 20, LOCK_DECREMENT);
    atomic_add_dram(q_low + 16, 1);
    return 1;
}

// Return 0 on failure, return 1 on success

uint32_t add_to_ray_queue_dram(uint32_t q_high, uint32_t q_low)
{
    set_address_bits(q_high);
    uint32_t my_ticket = atomic_add_dram(q_low + 12, 1);
    uint32_t now_serving = load_dram_word(q_low + 16);
    while (now_serving != my_ticket)
    {
        now_serving = load_dram_word(q_low + 16);
    }
    int32_t lock_val = atomic_add_dram(q_low + 20, -LOCK_DECREMENT);
    while (lock_val != -LOCK_DECREMENT)
    {
        lock_val = load_dram_word(q_low + 20);
    }

    uint32_t owner_count = load_dram_word(q_low + 24);
    if (owner_count >= 32)
    {
        atomic_add_dram(q_low + 20, LOCK_DECREMENT);
        atomic_add_dram(q_low + 16, 1);
        return 0;
    }
    uint32_t new_slot_addr = q_low + 28 + owner_count * 2;
    store_dram_half(() new_slot_addr, self.core_id);
    atomic_add_dram(q_low + 24, 1);
    atomic_add_dram(q_low + 20, LOCK_DECREMENT);
    atomic_add_dram(q_low + 16, 1);
    return 1;
}

// ============================================================
// download_bvh_nodes
// ============================================================
// Pulls BVH nodes from DRAM into SRAM, starting at DRAM index 0.
// Allocates nodes from sram_nodes[] pool using sram_alloc_count.
//
// Inputs:
//   self->core_id          : this core's ID
//   dram_nodes             : base pointer to DRAM node array
//   sram_nodes             : base pointer to SRAM node pool
//   self->sram_alloc_count : next free slot in sram_nodes (initially 0)
//
// Outputs:
//   self->root_node        : pointer to the SRAM node whose core_owner == self->core_id
//   sram_nodes populated with downloaded tree
// ============================================================

typedef struct
{
    uint32_t dram_tri_byte_index;
    uint16_t *parent_ptr;   // absolute SRAM pointer to parent node, 0 for root
    uint16_t *parent_left;  // pointer to parent's left_child field (to patch)
    uint16_t *parent_right; // pointer to parent's right_child field (to patch)
    uint16_t is_right;      // 1 if this node is the right child of parent
    uint32_t depth;
} DFS_Entry;

DFS_Entry dfs_stack[17];
uint32_t stack_top = self.stack_top + 16;
*(self.sram_alloc_count) = self.node_array_top;
uint32_t top_node_bits = self.node_array_high;
set_address_bits(top_node_bits);
// -- push root onto stack --
*(dfs_stack - 16) = 0;
*(dfs_stack - 12) = 0xFFFF; // invalid pointer to indicate root
*(dfs_stack - 10) = 0;
*(dfs_stack - 8) = 0;
*(dfs_stack - 6) = 0;
*(dfs_stack - 4) = 0;
*(dfs_stack - 2) = 0;
uint32_t leaf_node_table_ptr = self.leaf_core_lookup_table;
// dfs_loop:
if (stack_top == self.stack_top)
{
    goto dfs_done;
}
// -- pop --
stack_top -= 16;
uint32_t dram_idx = *(stack_top);
uint16_t *parent_ptr = *(stack_top + 4);
uint16_t *patch_left = *(stack_top + 6);
uint16_t *patch_right = *(stack_top + 8);
uint16_t is_right = *(stack_top + 10);
uint32_t depth = *(stack_top + 12);

// -- allocate SRAM slot --

uint32_t sram_slot_address = self.sram_node_base_address;
uint32_t node = atomic_add(sram_slot_address, 48);
// -- load DRAM node --
AABB_Node_DRAM *dram_node = &dram_nodes[dram_idx];
uint32_t bottom_node_bits = self.node_array_low;
bottom_node_bits += dram_idx * 48;
// THE FOLLOWING DRAM OFFSETS ARE NOT PERFECT - THE NODE STRUCTURE MUST BE BUILT SOON
//  -- copy bounding box --
uint32_t x_min = load_dram_word(bottom_node_bits);
node->x_min = x_min;
uint32_t x_max = load_dram_word(bottom_node_bits + 4);
node->x_max = x_max;
uint32_t y_min = load_dram_word(bottom_node_bits + 8);
node->y_min = y_min;
uint32_t y_max = load_dram_word(bottom_node_bits + 12);
node->y_max = y_max;
uint32_t z_min = load_dram_word(bottom_node_bits + 16);
node->z_min = z_min;
uint32_t z_max = load_dram_word(bottom_node_bits + 20);
node->z_max = z_max;

// -- copy metadata --
uint16_t core_owner = load_dram_half(bottom_node_bits + 30);
node->core_owner = core_owner;
uint16_t queue_high_bit_addr = load_dram_half(bottom_node_bits + 40);
uint32_t queue_low_bit_addr = load_dram_word(bottom_node_bits + 32);
node->queue_low_bit_addr = queue_low_bit_addr;
node->queue_high_bit_addr = queue_high_bit_addr;
uint32_t node_id = load_dram_word(bottom_node_bits + 48);
node->node_id = node_id;
uint16_t all_ones = 0xFFFF;
node->prev_index = all_ones;
node->is_right = is_right;

// -- set parent pointer --
node->parent = parent_ptr;

// -- default children to 0 (leaf / foreign owner) --
node->left_child = all_ones;  // 0xFFFF indicates no child
node->right_child = all_ones; // 0xFFFF indicates no child

if (depth > 12 && core_owner != 0xFFFF)
{
    *leaf_node_table_ptr = node;
    leaf_node_table_ptr += 2;
}

// -- patch parent's child pointer to point to us --
if (parent_ptr != all_ones)
    goto patch_parent;
goto skip_patch;

// patch_parent:
if (is_right == 1)
    goto patch_right_child;
*patch_left = node;
goto skip_patch;

// patch_right_child:
*patch_right = node;

// skip_patch:
//  -- check if this node is our root --
uint16_t owner = dram_node->core_owner;
if (owner != self->core_id)
    goto check_recurse;
self->root_node = node;

// check_recurse:
//  -- decide whether to recurse into children --
//  recurse if: owner == 0xFFFF OR owner == self->core_id
if (owner == all_ones)
{
}
goto do_recurse;
if (owner == self->core_id)
{
    self.node_id = node_id;
    goto do_recurse;
}
// foreign owner: do not recurse, children stay 0
goto dfs_loop;

// do_recurse:
//  -- push right child first (so left is processed first) --
uint32_t right_idx = load_dram_word(bottom_node_bits + 24);
uint32_t left_idx = load_dram_word(bottom_node_bits + 28);
*(stack_top + 0) = right_idx;
*(stack_top + 4) = node;
*(stack_top + 6) = &node->left_child;
*(stack_top + 8) = &node->right_child;
*(stack_top + 10) = 1;
*(stack_top + 12) = depth + 1;

stack_top += 16;

// -- push left child --
*(stack_top + 0) = left_idx;
*(stack_top + 4) = node;
*(stack_top + 6) = &node->left_child;
*(stack_top + 8) = &node->right_child;
*(stack_top + 10) = 0;
*(stack_top + 12) = depth + 1;
stack_top += 16;

goto dfs_loop;

// dfs_done:
*(self.leaf_core_lookup_table + 256) = self->root_node; // offset 128*2 = 256
uint32_t is_odd_thread = self.thread_id & 1;
is_odd_thread += 32;
enable_interrupts(is_odd_thread);
enable_interrupts(34);
enable_interrupts(35);
enable_interrupts(36);
uint16_t queue_ptr_address = self.local_ray_queue_head;
*(queue_ptr_address) = 0;
*(queue_ptr_address + 4) = 0;
*(queue_ptr_address + 8) = 0;
queue_ptr_address += 75;
for (int i = 0; i < 16; i++)
{
    *(queue_ptr_address) = 0;
    queue_ptr_address += 64;
}
*(queue_ptr_address + 1) = 0;
*(queue_ptr_address + 5) = 0;
*(queue_ptr_address + 9) = 0;
queue_ptr_address += 76;
for (int i = 0; i < 16; i++)
{
    *(queue_ptr_address) = 0;
    queue_ptr_address += 64;
}
*(self.local_queue_flushing) = 0;
*(self.tile_data_sram + 4) = 0;
*(self.ray_send_pending_addr) = 0;
relinquish_ownership(1);
uint32_t ray_base = self.ray_array_base;
uint32_t ray_array_index = self.thread_id << 6; // * 64 bytes per ray
ray = ray_array_index + ray_base;
*(ray + 63) = 0; // set ray slot to empty
*(self.core_handled->previously_idle) = 0;
*(self.core_handled->rays_processed) = 0;
*(self.core_handled->last_observed_cycle) = 0;
*(self.ray_send_pending_addr) = 0;
*(local_queue_flushing) = 0;
goto grab_from_tile;