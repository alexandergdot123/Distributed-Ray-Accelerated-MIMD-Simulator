.org IDK //TODO

    lw r2, ROOT_NODE_ID         # r2 = node
START_SEARCHING:
    yield r8                    # clobber r8
    # uint32_t left_bitfield_check = ray->check_left & (1 << ray->ray_depth) | node->left_child == 0;
    lbu r5, r0, 62                  # r5 = ray->ray_depth
    and r4, r4, 0
    add r4, r4, 1                   # r4 = 1
    sll r4, r4, r5                  # r4 = 1 << ray->ray_depth
    and r4, r4, r2                  # r4 = ray->check_left & (1 << ray->ray_depth)
    lhu r6, r1, 24                  # r6 = node->left_child
    and r7, r7, 0
    add r7, r7, 0xFFFF              # r7 = 0xFFFF (null sentinel)
    beq r6, r7, LEFT_CHILD_NULL, true
    and r6, r6, 0                   # left_child != null => contribute 0
    beq r15, r15, LEFT_BITFIELD_DONE, true
LEFT_CHILD_NULL:
    add r6, r6, 1                   # left_child == null => contribute 1 (forces visited)
LEFT_BITFIELD_DONE:
    or r4, r4, r6                   # r4 = left_bitfield_check

    # uint32_t right_bitfield_check = ray->check_right & (1 << ray->ray_depth) | node->right_child == 0;
    lbu r5, r0, 62                  # r5 = ray->ray_depth
    and r9, r9, 0
    add r9, r9, 1
    sll r9, r9, r5                  # r9 = 1 << ray->ray_depth
    and r9, r9, r3                  # r9 = ray->check_right & (1 << ray->ray_depth)
    lhu r6, r1, 26                  # r6 = node->right_child (uint16 at offset 25)
    beq r6, r7, RIGHT_CHILD_NULL, true
    and r6, r6, 0
    beq r15, r15, RIGHT_BITFIELD_DONE, true
RIGHT_CHILD_NULL:
    add r6, r6, 1                   # right_child == null => contribute 1 (forces visited)
RIGHT_BITFIELD_DONE:
    or r9, r9, r6                   # r9 = right_bitfield_check    

    # if (left_bitfield_check != 0 && right_bitfield_check != 0) { ... }
    and r6, r4, r9                  # r6 = left_bitfield_check & right_bitfield_check (nonzero if both set)
    and r7, r7, 0                   # r7 = 0
    beq r6, r7, CHECK_BOTH_ZERO, true   # if r6 == 0, neither both set - check other cases

    # uint32_t bitfield = *(ray.check_left + node->is_right * 4);
    lbu r6, r1, 32                  # r6 = node->is_right
    sll r6, r6, 2                   # r6 = node->is_right * 4
    add r6, r0, r6                  # r6 = &ray.check_left + is_right*4
    lw r8, r6, 44                    # r8 = bitfield


    # uint32_t or_value = 1 << (ray->ray_depth - 1);
    lbu r5, r0, 62                  # r5 = ray->ray_depth
    add r5, r5, -1                  # r5 = ray_depth - 1
    and r10, r10, 0
    add r10, r10, 1
    sll r10, r10, r5                # r10 = or_value

    # bitfield |= or_value;
    or r8, r8, r10
    sw r8, r6, 0                    # *(ray.check_left + is_right*4) = bitfield

    # ray->ray_depth--;
    lbu r5, r0, 62
    add r5, r5, -1
    sb r5, r0, 62

    # if (node->parent == 0) goto send_ray_up;
    lhu r6, r1, 28                  # r6 = node->parent
    beq r6, r7, send_ray_up, true  # r7 = 0

    # node = node->parent;
    and r1, r1, 0
    add r1, r1, r6                  # r1 = node->parent (SRAM pointer)
    beq r15, r15, START_SEARCHING, true
    
CHECK_BOTH_ZERO:
    # else if (left_bitfield_check == 0 && right_bitfield_check == 0)
    or r6, r4, r9                   # r6 = left | right
    bne r6, r7, TRAVERSE_LEFT_OR_RIGHT, false       # both zero -> do AABB test

    jmp r8, AABB_INTERSECT 
AABB_INTERSECT_RETURN:
    # if (hit)
    beq r11, r7, AABB_MISS, true

    # if (node->tri_count == 0) <- ASSUME RAY -> TRI_INDEX
    lbu r6, r1, 31                  # TODO confirm offset
    bne r6, r7, IS_LEAF_NODE, true

IS_INTERNAL_NODE:
    # ray->ray_depth++
    lbu r5, r0, 62
    add r5, r5, 1
    sb r5, r0, 62

    # if (node->core_owner != 0xFFFF)
    lhu r6, r1, 30                  # r6 = node->core_owner (uint16 offset 32) TODO confirm offset
    and r7, r7, 0
    add r7, r7, 0xFFFF
    beq r6, r7, TRAVERSE_OWN_CHILD, true   # owner == 0xFFFF means we own it
SEND_RAY_UP:
    # uint16_t ray_send_pending_addr = self.ray_send_pending_addr;
    lhu r8, RAY_SEND_PENDING_ADDR    # r8 = self.ray_send_pending_addr

    # atomic_add(ray_send_pending_addr, 1)
    atomadd r9, r8, 1               # r9 = clobber


    and r10, r15, 0xF               # r10 = thread_id

    and r4, r4, 0                   # r4 = 0
    add r4, r4, -1                  # r4 = 0xFFFFFFFF = slot
    # uint32_t sent = 0;
    and r3, r3, 0                   # r3 = sent = 0

    # uint32_t request_word = (node->node_id << 17) | self.thread_id;
    lw r12, r1, 44                  # r12 = node->node_id TODO confirm offset
    sll r12, r12, 17
    or r12, r12, r10                # r12 = request_word

    # send_packet(request_word, node->core_owner, 32);
    lhu r6, r1, 30                  # r6 = node->core_owner
    sendflit r6, r12, 32            # TODO confirm notation w/ Alex

SEND_RAY_LOOP:
    # uint32_t msg_available = nb_recv(self.thread_id + 16);
    and r7, r7, 0
    and r10, r15, 0xF               # r10 = thread_id
    add r11, r10, 16                # r11 = thread_id + 16
    nonblock r12, r11               # r12 = msg_available
    beq r12, r7, CHECK_DATA_MAILBOX, true   # r7=0, nothing on shallow mailbox

    # uint32_t msg = blocking_receive(self.thread_id + 16);
    block r12, r11                  # r12 = msg

    # uint32_t header = msg >> 24;
    srl r13, r12, 24                # r13 = header

    # if (header == ack_ray)  -- ack_ray = 5
    and r11, r11, 0
    add r11, r11, 5                 # r11 = 5 (ack_ray)
    bne r13, r11, REJECT_PATH, true

    # ACK path: for (i = 0; i < 16; i++) send_packet(ray[i], core_owner, mailbox)
    lhu r6, r1, 30                  # r6 = node->core_owner
    and r11, r12, 0xF               # r11 = dest mailbox from ack msg low nibble
    add r13, r0, 0                  # r13 = ray base ptr
    and r14, r14, 0                 # r14 = i = 0
RAY_SEND_LOOP:
    lw r9, r13, 0                   # r9 = ray word i
    and r11, r12, 0xF               # r11 = dest mailbox from ack msg low nibble
    sendflit r6, r9, r11            # r6 = clobber; send word to core_owner on mailbox
    add r13, r13, 4                 # r13 += 4 (next word)
    add r14, r14, 1                 # i++
    and r11, r11, 0
    add r11, r11, 16                # r11 = 16
    bgt r11, r14, RAY_SEND_LOOP, true   # loop while i < 16
    sb r7, r0, 63                   # ray->active_ray = 0  (r7=0)
    and r3, r3, 0
    add r3, r3, 1                   # r3 = sent = 1
    beq r15, r15, CHECK_DATA_MAILBOX, true

REJECT_PATH:
    # push ray to DRAM queue
    lhu r8, r1, 40                  # r8 = node->queue_high_bit_addr
    setmembits r8                   # set address bits to reach node's DRAM stack
    lw r9, r1, 36                   # r9 = node->queue_low_bit_addr

ENSURE_SPACE_IN_QUEUE:
    lw_d r10, r9, -12               # r10 = cur_ray_count (count field is -12 from here)
    and r11, r11, 0
    add r11, r11, 255               # r11 = 255
    bgt r10, r11, ENSURE_SPACE_IN_QUEUE, true   # spin while count > 255

    add r9, r9, -16                 # r9 = queue base (tail field)
    atomadd_d r10, r9, 64           # r10 = old tail, advance tail by 64 bytes
    and r10, r10, 0x3FFF            # r10 = tail & 0x3FFF (ring mask)
    add r11, r9, 536                # r11 = queue base + 536 (start of ray slots)
    add r11, r11, r10               # r11 = write_addr = slot base + tail offset

WAIT_FOR_SLOT_TO_OPEN:
    lbu_d r10, r11, 63              # r10 = slot[63] (valid byte)
    bne r10, r7, WAIT_FOR_SLOT_TO_OPEN, true   # spin while slot occupied (r7=0)

    add r13, r0, 0                  # r13 = ray base ptr
    and r14, r14, 0                 # r14 = i = 0
RAY_DRAM_WRITE_LOOP:
    lw r10, r13, 0                  # r10 = ray word i
    sw_d r10, r11, 0                # write to DRAM slot
    add r13, r13, 4                 # r13 += 4
    add r11, r11, 4                 # r11 write_addr += 4
    add r14, r14, 1                 # i++
    and r12, r12, 0
    add r12, r12, 16                # r12 = 16
    bgt r12, r14, RAY_DRAM_WRITE_LOOP, true   # loop while i < 16

    lw r9, r1, 36                   # r9 = queue_low_bit_addr (reload)
    add r9, r9, 20                  # r9 = &lock field (offset 20 from queue base)

ENSURE_NO_WRITERS:
    atomadd_d r10, r9, 1            # r10 = old lock value, increment
    and r11, r11, 0                 # r11 = 0
    beq r11, r10, SKIP_UNDO_LOCK, true   # old val >= 0 means no writer held it
    atomadd_d r11, r9, -1           # undo our increment
ENSURE_NO_WRITERS_LOOP:
    lw_d r10, r9, 0                 # r10 = current lock value
    bgt r11, r10, ENSURE_NO_WRITERS_LOOP, true   # spin while lock < 0 (writer active)
    beq r15, r15, ENSURE_NO_WRITERS, true        # retry claim

SKIP_UNDO_LOCK:
    lw_d r10, r9, 4                 # r10 = core_owner_count
    beq r10, r7, NO_OWNER, true     # r7=0, no owners

    # pick owner round-robin: idx = (core_id ^ clock) % core_owner_count
    getclk r11                      # r11 = clock
    srl r12, r15, 4                 # r12 = core_id
    xor r12, r12, r11               # r12 = core_id ^ clock = raw idx
    lhu r13, r1, 38                 # r13 = node->prev_index
    beq r12, r13, BUMP_IDX, true    # if idx == prev_idx, bump to avoid repeat
    beq r15, r15, SKIP_BUMP, true
BUMP_IDX:
    add r12, r12, 1                 # r12 = idx + 1
SKIP_BUMP:
    mod r12, r12, r10               # r12 = idx % core_owner_count
    sh r12, r1, 38                  # node->prev_index = idx
    sll r12, r12, 1                 # r12 = idx * 2 (uint16 slots)
    add r9, r9, r12                 # r9 = &core_slots[idx]
    lw_d r10, r9, 28                # r10 = core_to_cache (core_slots at +28 from lock field)
    sh r10, r1, 32                  # node->core_owner = core_to_cache
    beq r15, r15, SKIP_EMERGENCY_ENQUEUE, true

NO_OWNER:
    # node->core_owner = 0xFFFF
    and r11, r11, 0
    add r11, r11, 0xFFFF            # r11 = 0xFFFF
    sh r11, r1, 32                  # node->core_owner = 0xFFFF

    # if (cur_ray_count > 200) -> emergency queue insertion
    # cur_ray_count still valid from ENSURE_SPACE_IN_QUEUE in r10? No — reload
    lw r9, r1, 36                   # r9 = queue_low_bit_addr (reload)
    lw_d r10, r9, -12               # r10 = cur_ray_count
    and r11, r11, 0
    add r11, r11, 200               # r11 = 200
    blte r10, r11, SKIP_EMERGENCY_ENQUEUE, true   # if count <= 200 skip emergency

    # atomic_add(queue_address_low + 16924, 1) to check if first to enqueue
    add r9, r9, 16924               # r9 = &on_emergency_idle_queue flag
    atomadd_d r10, r9, 1            # r10 = old value
    bne r10, r7, SKIP_EMERGENCY_ENQUEUE, true   # r7=0; if old != 0 someone else did it

    # load emergency queue address
    lw r9, EMERGENCY_QUEUE_HIGH     # r9 = emergency_queue_high
    setmembits r9                   # set address bits
    lw r9, EMERGENCY_QUEUE_LOW      # r9 = emergency_queue_low
    add r9, r9, 8                   # r9 = &count field

LOOP_EMERGENCY_QUEUE_INSERTION:
    atomadd_d r10, r9, 1            # r10 = old count, increment
    and r11, r11, 0
    add r11, r11, 64                # r11 = 64 (max slots)
    bgt r10, r11, EMERGENCY_UNDO_AND_SPIN, true   # if old >= 64 queue full
    beq r15, r15, EMERGENCY_CLAIM_SLOT, true

EMERGENCY_UNDO_AND_SPIN:
    atomadd_d r11, r9, -1           # undo increment
    beq r15, r15, LOOP_EMERGENCY_QUEUE_INSERTION, true  # retry

EMERGENCY_CLAIM_SLOT:
    add r9, r9, -4                  # r9 = &tail field
    atomadd_d r10, r9, 4            # r10 = old tail, advance by 4 bytes per slot
    and r10, r10, 0xFF              # r10 = tail & 0xFF (ring mask for 64 slots)
    add r9, r9, r10                 # r9 = &slots[tail]
    add r9, r9, 8                   # r9 = slot base (skip head+tail fields)

ENSURE_EMERGENCY_SLOT_READY:
    lbu_d r11, r9, 2                # r11 = slot->is_valid
    bne r11, r7, ENSURE_EMERGENCY_SLOT_READY, true  # spin while slot occupied (r7=0)

    # write node_id into slot and mark valid
    lw r11, r1, 44                  # r11 = node->node_id
    sh_d r11, r9, 0                 # slot->node_id = node_id (uint16)
    and r11, r11, 0
    add r11, r11, 1                 # r11 = 1
    sb_d r11, r9, 2                 # slot->is_valid = 1

SKIP_EMERGENCY_ENQUEUE:
    lw r9, r1, 36                   # r9 = queue_low_bit_addr
    add r9, r9, 20                  # r9 = &lock field
    atomadd_d r11, r9, -1           # release lock (decrement back)
    sb r7, r0, 63                   # ray->active_ray = 0  (r7=0)
    and r3, r3, 0
    add r3, r3, 1                   # r3 = sent = 1

CHECK_DATA_MAILBOX:
    and r10, r15, 0xF               # r10 = thread_id
    nonblock r12, r10               # r12 = nb_recv(thread_id) -- data_available
    beq r12, r7, CHECK_INTERRUPT_MAILBOX, true   # r7=0, nothing available

    and r13, r0, 0                 # r13 = slot ptr (starts at 0 = invalid sentinel)
    and r14, r14, 0                 # r14 = i = 0
DATA_RECV_LOOP:
    block r9, r10                   # r9 = ray_word from data mailbox
    sw r9, r13, 0                   # *slot = ray_word
    add r13, r13, 4                 # slot += 4
    add r14, r14, 1                 # i++
    and r11, r11, 0
    add r11, r11, 16                # r11 = 16
    bgt r11, r14, DATA_RECV_LOOP, true   # loop while i < 16


    and r4, r4, 0
    add r4, r4, -1            # r13 = slot = 0xFFFF sentinel (low 16; full 32 not possible in imm)

CHECK_INTERRUPT_MAILBOX:        # TODO continue form here
    and r11, r11, 0                 # r11 = thread_id & 1
    add r11, r11, 32                # r11 = interrupt mailbox index
    nonblock r12, r11               # r12 = nb_recv(interrupt mailbox)
    beq r12, r7, DONE_WITH_INTERRUPT, true   # r7=0, nothing available
    block r12, r11                  # r12 = message

    srl r8, r12, 17                 # r8 = supposed_node_id (message >> 17)
    lw r9, ROOT_NODE_ID             # r9 = self.root_node_id
    bne r8, r9, WRONG_CORE_SEND, true   # node mismatch -> wrong core

    lw r8, LOCAL_QUEUE              # r8 = self.local_queue
    add r8, r8, 8                   # r8 = skip head and tail
    and r9, r10, 1                  # r9 = thread_id & 1
    and r11, r11, 0
    add r11, r11, 1036              # r11 = 1036
    mul r9, r9, r11                 # r9 = odd_thread * 1036
    add r8, r8, r9                  # r8 = &local_queue for this thread parity
    atomadd r9, r8, 1               # r9 = old_count
    lw r11, LOCAL_QUEUE_FLUSHING   # r11 = flushing flag
    and r14, r14, 0
    add r14, r14, 16                # r14 = 16 (max queue)
    bgt r9, r14, REJECT_INTERRUPT, true     # if old_count > 16 reject
    beq r11, r7, NO_FLUSH, true     # r7=0; if not flushing proceed
REJECT_INTERRUPT:
    atomadd r9, r8, -1              # undo count increment
    and r9, r9, 0
    add r9, r9, 7                   # r9 = reject_ray = 7
    sll r9, r9, 24                  # r9 = reject_ray << 24
    srl r11, r12, 4                 # r11 = dest core (message >> 4 & 0x1FFF)
    and r11, r11, 0x1FFF
    and r14, r12, 0xF               # r14 = dest mailbox (message & 0xF + 16)
    add r14, r14, 16
    sll r11, r11, 6
    or r11, r11, r14
    sendflit r9, r11                # send reject
    beq r15, r15, DONE_WITH_INTERRUPT, true

NO_FLUSH:
    add r8, r8, -4                  # r8 = &tail_relative field
    atomadd r9, r8, 64              # r9 = old tail, advance by 64
    and r9, r9, 0x3FF               # r9 = tail & 0x3FF (ring mask)
    add r8, r8, 8                   # r8 = back to queue data base
    add r8, r8, r9                  # r8 = slot = queue_base + tail_relative
    # slot is now r8 -- send ack with our thread_id
    and r14, r14, 0
    add r14, r14, 5                 # r14 = ray_ack = 5
    sll r14, r14, 24                # r14 = ray_ack << 24
    and r10, r15, 0xF               # r10 = thread_id
    or r14, r14, r10                # r14 = ray_ack << 24 | thread_id
    srl r11, r12, 4                 # r11 = dest core
    and r11, r11, 0x1FFF
    and r9, r12, 0xF                # r9 = dest mailbox + 16
    add r9, r9, 16
    sll r11, r11, 6
    or r11, r11, r14
    sendflit r9, r11                # send reject
    beq r15, r15, DONE_WITH_INTERRUPT, true

WRONG_CORE_SEND:
    and r9, r9, 0
    add r9, r9, 8                   # r9 = wrong_core = 8
    sll r9, r9, 24                  # r9 = wrong_core << 24
    srl r11, r12, 4                 # r11 = dest core
    and r11, r11, 0x1FFF
    and r14, r12, 0xF               # r14 = dest mailbox + 16
    add r14, r14, 16
    sll r11, r11, 6
    or r11, r11, r14
    sendflit r9, r11                # send reject

DONE_WITH_INTERRUPT:
    # if (sent == 1 && slot == 0xFFFFFFFF) goto ray_done
    # r3 = sent, check if sent == 1
    and r11, r11, 0
    add r11, r11, 1                 # r11 = 1
    bne r3, r11, SEND_RAY_LOOP, true    # if sent != 1 keep looping
    # check slot == 0xFFFFFFFF sentinel (r13 == 0xFFFF as 16-bit stand-in)
    and r11, r11, 0
    add r11, r11, 0xFFFF            # r11 = sentinel value
    bne r13, r11, SEND_RAY_LOOP, true   # if slot not sentinel keep looping
    beq r15, r15, DECREMENT_PENDING, true

DECREMENT_PENDING:
    and r10, r15, 0xF               # r10 = thread_id
    and r11, r10, 1                 # r11 = thread_id & 1
    add r11, r11, 32                # r11 = interrupt mailbox index
    intdis r11                      # disable interrupts
    lw r8, RAY_SEND_PENDING_ADDR    # r8 = &ray_send_pending
    atomadd r9, r8, -1              # decrement pending count
    beq r15, r15, ray_done, true

TRAVERSE_OWN_CHILD:
    # node = node->left_child
    lhu r1, r1, 24                  # r1 = node->left_child
    beq r15, r15, start_ray_traversal, true
IS_LEAF_NODE:
    lbu r10, r1, 30
    sll r10, r10, 2
    add r10, r10, r0
    lw r11, r10, 44
    lbu r12, r0, 62
    add r13, r7, 1
    add r12, r12, -1
    sw r12, r0, 62
    sll r13, r13, r12
    or r11, r13, r11
    sw r11, r10, 44
    lhu r2, r0, 32
    lbu r3, r0, 31
TRIANGLE_INTERSECT_LOOP:
    beq r15, r15, triangle_intersect, true
TRIANGLE_INTERSECT_RETURN:
    lbu r5, r0, 61
    and r4, r4, 0
    lw r6, r0, 56
    beq r4, r5, SHADOW_RAY_NOT_OCCLUDED, true
    or r5, r5, 0xFFFF
    beq r5, r6, SHADOW_RAY_NOT_OCCLUDED, true
    beq r15, r15, SHADOW_RAY_OCCLUDED, true
SHADOW_RAY_NOT_OCCLUDED:
    add r2, r2, 12
    add r3, r3, -1
    bne r4, r3, TRIANGLE_INTERSECT_LOOP, true
    lhu r1, r1, 28
    beq r15, r15, START_SEARCHING, true
AABB_MISS:
    lbu r10, r1, 30
    sll r10, r10, 2
    add r10, r10, r0
    lw r11, r10, 44
    lbu r12, r0, 62
    add r13, r7, 1
    add r12, r12, -1
    sw r12, r0, 62
    sll r13, r13, r12
    or r11, r13, r11
    sw r11, r10, 44
    lhu r1, r1, 28
    beq r15, r15, START_SEARCHING, true
TRAVERSE_LEFT_OR_RIGHT:
    or r10, r10, 0xFFFF
    lbu r12, r0, 62
    add r12, r12, 1
    sll r10, r10, r12
    xor r10, r10, 0xFFFF
    lw r9, r0, 44
    lw r13, r0, 48
    and r9, r9, r10
    and r13, r13, r10
    sw r9, r0, 44
    sw r13, r0, 48
    and r12, r12, 0
    beq r4, r12, SKIP_LEFT_BITFIELD_INCREMENT, false
    add r12, r12, 2
SKIP_LEFT_BITFIELD_INCREMENT:
    add r1, r1, r12
    lhu r1, r1, 24
    lbu r10, r0, 62
    add r10, r10, 1
    sb r10, r0, 62
    beq r15, r15, START_SEARCHING, true


triangle_intersect: 
    #void Triangle_Intersect(Triangle *tri, Ray *ray, Vertex *vertices)
    # tri in r2 = index ptr, ray is in r0, i won't touch r3 or r2 or r1. 
    lw r13, VERTEX_ARRAY_BASE                   # r13 = Vertex * vertices
    and r14, r14, 0
    add r4, r14, RAY_TRIANGLE_REG_SPILL
    and r5, r15, 0xF
    sll r5, r5, 6
    add r4, r4, r5
    add r8, r2, r13
    lhu r5, r8, 4
    lhu r6, r8, 6
    lhu r7, r8, 8
    lw r8, TRIANGLE_ARRAY_BASE
    add r5, r5, r8 #v0
    add r6, r6, r8 #V1
    add r7, r7, r8 #V2
    lw r12, r5, 0 #v0x
    lw r9, r6, 0
    fpsub.32 r8, r9, r12 #e1x
    lw r9, r6, 4
    lw r13, r5, 4 #v0y
    fpsub.32 r9, r9, r13 #e1y
    lw r10, r6, 8 
    lw r14, r5, 8 #v0z
    fpsub.32 r10, r10, r14 #e1z
    sw r8, r4, 0
    sw r9, r4, 4
    sw r10, r4, 8
    lw r8, r7, 0
    lw r9, r7, 4
    lw r10, r7, 8
    fpsub.32 r8, r8, r12 #e2x
    fpsub.32 r9, r9, r13 #e2y
    fpsub.32 r10, r10, r14 #e2z i have 11-14 now i think
    sw r8, r4, 12
    sw r9, r4, 16
    sw r10, r4, 20
    lw r11, r0, 16 #dy
    fpmul.32 r11, r11, r10 # ray->dy * e2z
    lw r12, r0, 20 #dz
    fpmul.32 r13, r9, r12 #ray->dz * e2y I now have  r14, r10 available
    fpsub.32 r11, r11, r13 #px, now available registers are r13, r14, r10
    fpmul.32 r12, r12, r8 # ray->dz * e2x 
    lw r14, r0, 12 #dx
    fpmul.32 r13, r14, r10 #ray->dx * e2z
    fpsub.32 r13, r12, r13 #py i now have r12, r10
    fpmul.32 r14, r14, r9  #ray->dx * e2y
    lw r12, r0, 16 #dy
    fpmul.32 r12, r12, r8 #ray->dy * e2x
    fpsub.32 r14, r14, r12 #pz
    and r12, r12, 0
    fpsetaccum.32 r12
    lw r8, r4, 0
    lw r9, r4, 4
    lw r10, r4, 8
    fpmac.32 r8, r11
    fpmac.32 r9, r13
    fpmac.32 r10, r14
    fpstoreaccum.32 r8
    beq r8, r12, TRIANGLE_INTERSECT_RETURN, false #I have 9, 10, and 12 available
    lw r6, r0, 0
    lw r7, r5, 0
    fpsub.32 r6, r6, r7
    lw r7, r0, 4
    lw r9, r5, 4
    fpsub.32 r7, r7, r9
    lw r9, r0, 8
    lw r10, r5, 8
    fpsub.32 r9, r9, r10
    and r10, r10, 0
    fpsetaccum.32 r10
    fpmac.32 r6, r11 
    fpmac.32 r7, r13
    fpmac.32 r9, r14
    fpstoreaccum.32 r12
    sw r6, r4, 32
    sw r7, r4, 36
    sw r9, r4, 40
    fplt r6, r10, r8
    bne r6, r10, TRIANGLE_INTERSECT_ELSE_BLOCK_1, false
    fplt r6, r12, r10
    fplt r7, r8, r12
    or r6, r6, r7
    bne r6, r10, TRIANGLE_INTERSECT_RETURN, true
    beq r15, r15, TRIANGLE_INTERSECT_END_IF_BLOCK_1, true
TRIANGLE_INTERSECT_ELSE_BLOCK_1:
    fplt r6, r10, r12
    fplt r7, r12, r8
    or r6, r6, r7
    bne r6, r10, TRIANGLE_INTERSECT_RETURN, true
TRIANGLE_INTERSECT_END_IF_BLOCK_1:
    sw r11, r4, 44
    sw r13, r4, 48
    sw r14, r4, 52
    lw r6, r4, 40
    lw r7, r4, 0
    lw r9, r4, 4 #e1y
    fpmul.32 r10, r6, r7 #tz * e1x
    fpmul.32 r6, r6, r9  #tz * e1y
    lw r11, r4, 36 #ty
    fpmul.32 r13, r11, r7 #ty * e1x
    lw r7, r4, 8 #e1z
    fpmul.32 r14, r7, r11 #ty * e1z
    fpsub.32 r14, r14, r6 #qx
    lw r6, r4, 32 #tx
    fpmul.32 r7, r6, r7 #tx * e1z
    fpsub.32 r10, r10, r7 #qy
    fpmul.32 r9, r9, r6 #tx * e1y
    fpsub.32 r9, r9, r13 #qz
    and r11, r11, 0
    fpsetaccum.32 r11
    lw r6, r0, 12
    fpmac.32 r6, r14
    lw r6, r0, 16
    fpmac.32 r6, r10
    lw r6, r0, 20
    fpmac.32 r6, r9
    fpstoreaccum.32 r7 #r7 = v_unscaled
    fpadd.32 r12, r7, r12 #r12 = uv_sum
    fplt.32 r13, r11, r8 #r8 = det
    beq r13, r11, TRIANGLE_INTERSECT_ELSE_BLOCK_2, false
    fplt.32 r5, r7, r11
    fplt.32 r6, r8, r12
    or r5, r5, r6
    bne r5, r11, TRIANGLE_INTERSECT_END_IF_BLOCK_2, true
    beq r15, r15, TRIANGLE_INTERSECT_RETURN, true
TRIANGLE_INTERSECT_ELSE_BLOCK_2:
    fplt.32 r5, r11, r7
    fplt.32 r6, r12, r8
    or r5, r5, r6
    bne r5, r11, TRIANGLE_INTERSECT_END_IF_BLOCK_2, true
    beq r15, r15, TRIANGLE_INTERSECT_RETURN, true
TRIANGLE_INTERSECT_END_IF_BLOCK_2:
    fpsetaccum.32 r11
    lw r5, r4, 12
    fpmac.32 r5, r14
    lw r5, r4, 16
    fpmac.32 r5, r10
    lw r5, r4, 20
    fpmac.32 r5, r9
    fpstoreaccum.32 r5 #t_unscaled
    lw r6, EPSILON
    fpmul.32 r6, r6, r8 #tmin_scaled
    lw r7, r0, 36
    fpmul.32 r7, r7, r8 #tmax_scaled
    fplt.32 r9, r11, r8
    beq r9, r11, TRIANGLE_INTERSECT_ELSE_BLOCK_3, false
    fplt.32 r6, r5, r6
    fplt.32 r7, r7, r5
    or r6, r6, r7
    beq r11, r6, TRIANGLE_INTERSECT_END_IF_BLOCK_3, false
    beq r15, r15, TRIANGLE_INTERSECT_RETURN, true
TRIANGLE_INTERSECT_ELSE_BLOCK_3:
    fplt.32 r6, r6, r5
    fplt.32 r7, r5, r7
    or r6, r6, r7
    beq r11, r6, TRIANGLE_INTERSECT_END_IF_BLOCK_3, false
    beq r15, r15, TRIANGLE_INTERSECT_RETURN, true
TRIANGLE_INTERSECT_END_IF_BLOCK_3:
    add r9, r8, 0
    jmp r10, RECIPROCAL
    fpmul.32 r5, r5, r9
    sw r5, r0, 36
    lw r6, r2, 0
    sw r6, r0, 56
    beq r15, r15, TRIANGLE_INTERSECT_RETURN, true



AABB_INTERSECT: #do not use r4, r9. r0 = ray, r1 = node, r7 = 0
    lw r2, r1, 0                        
    lw r3, r0, 0
    fpsub.32 r2, r2, r3                   # float t1 = (node->min_x - ray->ox) * ray->inv_dx
    lw r5, r0, 24
    fpmul.32 r2, r2, r5                   # t1 *= ray->inv_dx
    lw r6, r1, 4
    fpsub.32 r3, r6, r3                   # float t2 = (node->max_x - ray->ox) * ray->inv_dx
    fpmul.32 r3, r3, r5                   # t2 *= ray->inv_dx
    fpminmax.32 r12, r2, r3, false         # float tmin = min(t1, t2)
    fpminmax.32 r3, r2, r3, true          # float tmax = max(t1, t2)
    lw r2, r0, 36
    fpminmax.32 r13, r2, r3, false          # tmax = min(tmax, ray->t_max)
    fplt.32 r6, r12, r13                  # r6 = tmin < tmax
    lw r10, EPSILON                 # float epsilon = self.epsilon
    fplt.32 r8, r10, r13                # r8 = epsilon < tmax
    and r11, r6, r8                     # r11 = (tmax >= tmin) && (tmax > epsilon)
    blte r7, r11, AABB_INTERSECT_RETURN, false  # if (tmax < EPSILON) return false
    #doing y now
    lw r2, r1, 8
    lw r3, r0, 4
    fpsub.32 r2, r2, r3                   # float t1 = (node->min_x - ray->ox) * ray->inv_dx
    lw r5, r0, 28
    fpmul.32 r2, r2, r5                   # t1 *= ray->inv_dx
    lw r6, r1, 12
    fpsub.32 r3, r6, r3                   # float t2 = (node->max_x - ray->ox) * ray->inv_dx
    fpmul.32 r3, r3, r5                   # t2 *= ray->inv_dx
    fpminmax.32 r5, r2, r3, false         # float tmin = min(t1, t2)
    fpminmax.32 r3, r2, r3, true          # float tmax = max(t1, t2)
    fpminmax.32 r13, r13, r3, false          # tmax = min(tmax, ray->t_max)
    fpminmax.32 r12, r12, r5, true          # tmin = max(tmin, t1)
    fplt.32 r6, r12, r13                  # r6 = tmin < tmax
    fplt.32 r8, r10, r13                # r8 = epsilon < tmax
    and r11, r6, r8                     # r11 = (tmax >= tmin) && (tmax > epsilon)
    blte r7, r11, AABB_INTERSECT_RETURN, false  # if (tmax < EPSILON) return false
    #doing z now
    lw r2, r1, 16                           # r2 = node->z_min
    lw r3, r0, 8                            # r3 = ray->oz
    fpsub.32 r2, r2, r3                     # r2 = node->z_min - ray->oz
    lw r5, r0, 32                           # r5 = ray->inv_dz
    fpmul.32 r2, r2, r5                     # tz1 = (node->z_min - ray->oz) * ray->inv_dz
    lw r6, r1, 20                           # r6 = node->z_max
    fpsub.32 r3, r6, r3                     # r3 = node->z_max - ray->oz
    fpmul.32 r3, r3, r5                     # tz2 = (node->z_max - ray->oz) * ray->inv_dz
    fpminmax.32 r5, r2, r3, false           # r5 = min(tz1, tz2)
    fpminmax.32 r3, r2, r3, true            # r3 = max(tz1, tz2)
    fpminmax.32 r13, r13, r3, false         # tmax = min(tmax, max(tz1, tz2))
    fpminmax.32 r12, r12, r5, true          # tmin = max(tmin, min(tz1, tz2))
    fplt.32 r6, r12, r13                    # r6 = tmin < tmax
    fplt.32 r8, r10, r13                     # r8 = epsilon < tmax
    and r11, r6, r8                         # r11 = (tmin <= tmax) && (0.0 < tmax)
    beq r15, r15, AABB_INTERSECT_RETURN, true # return r11



VERTEX_ARRAY_BASE:       .data 0
SRAM_ALLOC_COUNT:       .data 0
SRAM_NODE_ALLOC_PTR:     .data 0
NODE_ARRAY_TOP:         .data 0
ROOT_NODE_ID:           .data 0
BRANCH_START_OF_CODE:    .data -1
BRANCH_NUM_INSTRUCTION_BYTES: .data -1
BRANCH_START_OF_GEO:     .data -1
BRANCH_SIZE_OF_GEO:      .data -1
SAVED_BRANCH_HIGH:       .data -1
SAVED_BRANCH_LOW:        .data -1
SEARCH_FOR_IDLE_CORES_STORAGE: .data -1
BRANCH_IDLE_THRESHOLD:    .data -1
IDLE_WINDOW:             .data 100000
EAT_RAY_MASK:            .data 0x0001FFFF
HALF:                    .data 0x3F000000
TWO:                     .data 0x40000000
RECIPROCAL_STORAGE:      .data -1
NEG_MAX:                 .data 0x80000000
ONE_POINT_FIVE:          .data 0x3FC00000
RANDOM_FLOAT_AND_MASK:    .data 0x3FFFFFFF
RANDOM_TABLE_MASK:       .data 0x0003FFF0
MAX_RAYS_IN_RAY_POOL:    .data 260000
FINISHED_PIXELS_HIGH:   .data -1
FINISHED_PIXELS_LOW:    .data -1
ONE:                    .data 0x3F800000
MAX_RAYS:              .data 58982400
EPSILON:                .data 0x38D1B717
NEG_ONE:                .data 0xBF800000
INFINITY:               .data 0x7F800000
SPAWNED_RAY_POOL_MASK:  .data 0x007FFFFF
RAY_SEND_PENDING_ADDR:  .data 0
LOCAL_QUEUE:            .data 0
LOCAL_QUEUE_FLUSHING:   .data 0
ROOT_NODE_ID_SENDER:    .data -1
ROOT_NODE_ID_RECEIVER:  .data -1
IS_BRANCH_CORE: .data -1
RAY_QUEUE_HIGH: .data -1
RAY_QUEUE_LOW: .data -1
EMERGENCY_QUEUE_HIGH: .data -1
EMERGENCY_QUEUE_LOW: .data -1
SPAWNED_RAY_POOL_HIGH: .data -1
SPAWNED_RAY_POOL_LOW: .data -1
TILE_QUEUE_HIGH: .data -1
TILE_QUEUE_LOW: .data -1
RAY_RESULT_HIGH: .data -1
RAY_RESULT_LOW: .data -1
RAYS_COMPLETED_HIGH: .data -1
RAYS_COMPLETED_LOW: .data -1
FRAME_BUF_HIGH: .data -1
FRAME_BUF_LOW: .data -1
NODE_ARRAY_HIGH: .data -1
NODE_ARRAY_LOW: .data -1
TRIANGLE_ARRAY_HIGH: .data -1
TRIANGLE_ARRAY_LOW: .data -1
INT_TO_FLOAT_TABLE_HIGH: .data -1
INT_TO_FLOAT_TABLE_LOW: .data -1
DIV_TABLE_HIGH: .data -1
DIV_TABLE_LOW: .data -1
INV_SQRT_TABLE_HIGH: .data -1
INV_SQRT_TABLE_LOW: .data -1
IDLE_QUEUE_HIGH: .data -1
IDLE_QUEUE_LOW: .data -1
RANDOM_TABLE_HIGH: .data -1
RANDOM_TABLE_LOW: .data -1
CAM_X: .data -1
CAM_Y: .data -1
CAM_Z: .data -1
CAM_CX: .data -1
CAM_CY: .data -1
CAM_INV_FOCAL: .data -1
RAY_SEND_PENDING: .data -1
PULLED_FROM_FULL_QUEUE_CNT: .data -1
CORE_ID_TO_SWITCH_TO: .data -1
TILE_DATA_COUNT: .data 0 #count
TILE_IS_ACTIVE: .data 0 
TILE_INTER_INDEX: .data 0 #tile_x_index/tile_y_index
TILE_CUR_RAY_SPAWNED:.data 0 #cur_ray_spawned_from_tile[16] in bytes
.data 0 
.data 0 
.data 0
RAYS_SPAWNED_FROM_TILE: .data 0 #rays_spawned_from_tile
RAYS_FORWARDED_OUT_FROM_TILE: .data 0 #rays_forwarded_out_from_tile
RAYS_PROCESSED: .data 0
LAST_OBSERVED_CYCLE: .data 0
PREVIOUSLY_IDLE: .data 0
FLOAT_TO_BYTE_RGB_TABLE: .data(128) 0
LIGHT0_X: .data -1
LIGHT0_Y: .data -1
LIGHT0_Z: .data -1
LIGHT0_R: .data -1
LIGHT0_G: .data -1
LIGHT0_B: .data -1
LIGHT1_X: .data -1
LIGHT1_Y: .data -1
LIGHT1_Z: .data -1
LIGHT1_R: .data -1
LIGHT1_G: .data -1
LIGHT1_B: .data -1
LIGHT2_X: .data -1
LIGHT2_Y: .data -1
LIGHT2_Z: .data -1
LIGHT2_R: .data -1
LIGHT2_G: .data -1
LIGHT2_B: .data -1
ROOT_NODE_ADDRESS: .data 0
//DO NOT INCLUDE LINES BELOW THIS AS PULLED FROM DRAM
RAY_ARRAY: .data(256) 0
LEAF_CORE_LOOKUP_TABLE: .data(64) 0
RAY_QUEUE_HEAD: .data 0
RAY_QUEUE_TAIL: .data 0
RAY_QUEUE_CNT: .data 0
RAY_QUEUE_ENTRIES: .data(515) 0
DFS_STACK: .data(256) 0
RAY_TRIANGLE_REG_SPILL: .data(256) 0
