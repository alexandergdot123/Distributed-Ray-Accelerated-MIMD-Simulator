.org 0x2C //TODO



    beq r15, r15, download_bvh_tree, true

    RAY_QUEUE_HIGH: 
    .data -1
    RAY_QUEUE_LOW: 
    .data -1
    IS_BRANCH_CORE: 
    .data -1
    ROOT_NODE_ID:           
    .data -1
    NODE_INDEX_OF_ROOT:
    .data -1
    beq r15, r15, download_bvh_tree, true
SWITCH_DRAM_QUEUE:
    lw r12, NODE_ID_TABLE_HIGH
    setmembits r12
    lw r12, NODE_ID_TABLE_LOW
    sll r11, r11, 2
    add r12, r12, r11
    lw_d r9, r12, 0
    lw_d r10, r12, 4
    lw r2, RAY_QUEUE_HIGH   # r2 = q_high #assume high in r2, low in
    lw r3, RAY_QUEUE_LOW    # r3 = q_low
    sw r9, RAY_QUEUE_HIGH
    sw r10, RAY_QUEUE_LOW
    and r14, r14, 0
    add r9, r14, LOCAL_QUEUE_FLUSHING
    atomadd r15, r9, 1
    add r10, r14, 16 
WAIT_FOR_FLUSH_READY_SWITCH_DRAM_QUEUE:
    lw r9, LOCAL_QUEUE_FLUSHING
    switchctx
    beq r10, r9, WAIT_FOR_FLUSH_READY_SWITCH_DRAM_QUEUE, true
    # ;     set_address_bits(q_high);

    setmembits r2
# ;     uint32_t my_ticket = atomic_add_dram(q_low + 12, 1);
    add r4, r3, 12
    atomadd_d r5, r4, 1
REMOVE_TICKET_WAIT_EMERGENCY:
    lw_d r4, r3, 16
    bne r4, r5, REMOVE_TICKET_WAIT_EMERGENCY, true
    add r4, r3, 20
    and r5, r5, 0
    add r5, r5, -8192
    atomadd_d r15, r4, r5
LOCKING_BULLSHIT_EMERGENCY:
    lw_d r9, r4, 0
    bne r5, r9, LOCKING_BULLSHIT_EMERGENCY, true
    add r6, r3, 28 
    and r8, r8, 0
    srl r9, r15, 4
    lw_d r4, r4, 4
find_our_slot_remove_emergency:
    add r10, r14, 256
    beq r4, r10, RELEASE_INSERT_LOCK, false
    sll r10, r8, 1              # r10 = i * 2
    add r10, r10, r6            # r10 = slots_base + i * 2
    lhu_d r11, r10, 0           # r11 = slot_val
    beq r11, r9, found_our_slot_remove_emergency, true
    add r8, r8, 1
    beq r15, r15, find_our_slot_remove_emergency, true

found_our_slot_remove_emergency:
    # last_slot_addr = slots_base + (owner_count - 1) * 2
    add r11, r4, -1             # r11 = owner_count - 1
    sll r11, r11, 1             # r11 = (owner_count - 1) * 2
    add r11, r11, r6            # r11 = last_slot_addr
    # last_val = load_dram_half(last_slot_addr)
    lhu_d r12, r11, 0           # r12 = last_val
    # store_dram_half(slots_base + i * 2, last_val)
    # r10 still = slots_base + i * 2
    sh_d r12, r10, 0            # slots[i] = last_val
    # store_dram_half(last_slot_addr, 0)
    and r12, r12, 0
    sh_d r12, r11, 0            # last slot = 0
    # atomic_add_dram(q_low + 24, -1)
    add r10, r3, 24             # r10 = &core_owner_count
    atomadd_d r12, r10, -1     # core_owner_count--
release_remove_emergency:
    # atomic_add_dram(q_low + 20, LOCK_DECREMENT)
    # rebuild LOCK_DECREMENT = 0x7FFFFFFF
    add r10, r3, 20             # r10 = &lock
    atomadd_d r12, r10, 8192     # release lock
    # atomic_add_dram(q_low + 16, 1)
    add r10, r3, 16             # r10 = &now_serving
    and r5, r5, 0
    add r5, r5, 1
    atomadd_d r12, r10, r5     # advance now_serving
# ;     set_address_bits(q_high);
    lw r2, RAY_QUEUE_HIGH   # ASSUME: r2 = q_high
    lw r3, RAY_QUEUE_LOW    # r3 = q_low
    setmembits r2
# ;     uint32_t my_ticket = atomic_add_dram(q_low + 12, 1);
    add r4, r3, 12
    atomadd_d r5, r4, 1
ADD_TICKET_WAIT_EMERGENCY:
# ;     uint32_t now_serving = load_dram_word(q_low + 16)
# ;     if (now_serving != my_ticket) <- should be while
# ;     {
# ;         now_serving = load_dram_word(q_low + 16)
# ;     }
    lw_d r4, r3, 16
    bne r4, r5, ADD_TICKET_WAIT_EMERGENCY, true

# ;     int32_t lock_val = atomic_add_dram(q_low + 20, -LOCK_DECREMENT);
# ;     while (lock_val != -LOCK_DECREMENT)
# ;     {
# ;         lock_val = load_dram_word(q_low + 20);
# ;     }
    add r4, r3, 20
    and r5, r5, 0
    add r5, r5, -8192
    atomadd_d r15, r4, r5
LOCKING_BULLSHIT_INSERT_EMERGENCY:
    lw_d r9, r4, 0
    bne r5, r9, LOCKING_BULLSHIT_INSERT_EMERGENCY, true
    # uint32_t slots_base = q_low + 28
    add r6, r3, 28              # r6 = slots_base

    # uint32_t i = 0
    and r8, r8, 0               # r8 = i = 0

    # core_id = r15 >> 4
    srl r9, r15, 4              # r9 = core_id
    lw_d r4, r4, 4    # r4 = owner_count

    sll r4, r4, 1
    add r6, r6, r4
    srl r12, r15, 4
    # last_val = load_dram_half(last_slot_addr)
    sh_d r12, r6, 0           # r12 = last_val

    # atomic_add_dram(q_low + 24, -1)
    add r10, r3, 24             # r10 = &core_owner_count
    atomadd_d r12, r10, 1     # core_owner_count--
    # atomic_add_dram(q_low + 20, LOCK_DECREMENT)
    # rebuild LOCK_DECREMENT = 0x7FFFFFFF
    add r10, r3, 20             # r10 = &lock
    atomadd_d r12, r10, 8192     # release lock

    # atomic_add_dram(q_low + 16, 1)
    add r10, r3, 16             # r10 = &now_serving
    and r5, r5, 0
    add r5, r5, 1
    atomadd_d r12, r10, r5     # advance now_serving

    beq r15, r15, download_bvh_tree, true




REMOVE_FROM_RAY_QUEUE_DRAM:
# ;     set_address_bits(q_high);
    lw r2, RAY_QUEUE_HIGH   # r2 = q_high #assume high in r2, low in
    lw r3, RAY_QUEUE_LOW    # r3 = q_low
    setmembits r2
# ;     uint32_t my_ticket = atomic_add_dram(q_low + 12, 1);
    add r4, r3, 12
    atomadd_d r5, r4, 1
REMOVE_TICKET_WAIT:
# ;     uint32_t now_serving = load_dram_word(q_low + 16)
# ;     if (now_serving != my_ticket) <- should be while
# ;     {
# ;         now_serving = load_dram_word(q_low + 16)
# ;     }
    lw_d r4, r3, 16
    bne r4, r5, REMOVE_TICKET_WAIT, true

# ;     int32_t lock_val = atomic_add_dram(q_low + 20, -LOCK_DECREMENT);
# ;     while (lock_val != -LOCK_DECREMENT)
# ;     {
# ;         lock_val = load_dram_word(q_low + 20);
# ;     }
    add r4, r3, 20
    and r5, r5, 0
    add r5, r5, -8192
    atomadd_d r15, r4, r5
LOCKING_BULLSHIT:
    lw_d r9, r4, 0
    bne r5, r9, LOCKING_BULLSHIT, true
    # r4 = owner_count
    # uint32_t slots_base = q_low + 28
    add r6, r3, 28              # r6 = slots_base

    # uint32_t i = 0
    and r8, r8, 0               # r8 = i = 0

    # core_id = r15 >> 4
    srl r9, r15, 4              # r9 = core_id
    lw_d r4, r4, 4
find_our_slot_remove:
    add r10, r14, 256
    beq r4, r10, RELEASE_INSERT_LOCK, false
    # slot_val = load_dram_half(slots_base + i * 2)
    sll r10, r8, 1              # r10 = i * 2
    add r10, r10, r6            # r10 = slots_base + i * 2
    lhu_d r11, r10, 0           # r11 = slot_val

    # if (slot_val == core_id) goto found_our_slot_remove
    beq r11, r9, found_our_slot_remove, true

    # i++
    add r8, r8, 1
    beq r15, r15, find_our_slot_remove, true

found_our_slot_remove:
    # last_slot_addr = slots_base + (owner_count - 1) * 2
    add r11, r4, -1             # r11 = owner_count - 1
    sll r11, r11, 1             # r11 = (owner_count - 1) * 2
    add r11, r11, r6            # r11 = last_slot_addr

    # last_val = load_dram_half(last_slot_addr)
    lhu_d r12, r11, 0           # r12 = last_val

    # store_dram_half(slots_base + i * 2, last_val)
    # r10 still = slots_base + i * 2
    sh_d r12, r10, 0            # slots[i] = last_val

    # store_dram_half(last_slot_addr, 0)
    and r12, r12, 0
    sh_d r12, r11, 0            # last slot = 0

    # atomic_add_dram(q_low + 24, -1)
    add r10, r3, 24             # r10 = &core_owner_count
    atomadd_d r12, r10, -1     # core_owner_count--
release_remove:
    # atomic_add_dram(q_low + 20, LOCK_DECREMENT)
    # rebuild LOCK_DECREMENT = 0x7FFFFFFF
    add r10, r3, 20             # r10 = &lock
    atomadd_d r12, r10, 8192     # release lock

    # atomic_add_dram(q_low + 16, 1)
    add r10, r3, 16             # r10 = &now_serving
    and r5, r5, 0
    add r5, r5, 1
    atomadd_d r12, r10, r5     # advance now_serving

    beq r15, r15, RETURN_FROM_CORE_DRAM_QUEUE, true
    

ADD_TO_RAY_QUEUE_DRAM:
# ;     set_address_bits(q_high);
    lw r2, RAY_QUEUE_HIGH   # ASSUME: r2 = q_high
    lw r3, RAY_QUEUE_LOW    # r3 = q_low
    setmembits r2
# ;     uint32_t my_ticket = atomic_add_dram(q_low + 12, 1);
    add r4, r3, 12
    atomadd_d r5, r4, 1
ADD_TICKET_WAIT:
# ;     uint32_t now_serving = load_dram_word(q_low + 16)
# ;     if (now_serving != my_ticket) <- should be while
# ;     {
# ;         now_serving = load_dram_word(q_low + 16)
# ;     }
    lw_d r4, r3, 16
    bne r4, r5, ADD_TICKET_WAIT, true

# ;     int32_t lock_val = atomic_add_dram(q_low + 20, -LOCK_DECREMENT);
# ;     while (lock_val != -LOCK_DECREMENT)
# ;     {
# ;         lock_val = load_dram_word(q_low + 20);
# ;     }
    add r4, r3, 20
    and r5, r5, 0
    add r5, r5, -8192
    atomadd_d r15, r4, r5
LOCKING_BULLSHIT_INSERT:
    lw_d r9, r4, 0
    bne r5, r9, LOCKING_BULLSHIT_INSERT, true
    # uint32_t slots_base = q_low + 28
    add r6, r3, 28              # r6 = slots_base

    # uint32_t i = 0
    and r8, r8, 0               # r8 = i = 0

    # core_id = r15 >> 4
    srl r9, r15, 4              # r9 = core_id
    lw_d r4, r4, 4    # r4 = owner_count

    sll r4, r4, 1
    add r6, r6, r4
    srl r12, r15, 4
    # last_val = load_dram_half(last_slot_addr)
    sh_d r12, r6, 0           # r12 = last_val

    # atomic_add_dram(q_low + 24, -1)
    add r10, r3, 24             # r10 = &core_owner_count
    atomadd_d r12, r10, 1     # core_owner_count--
    # atomic_add_dram(q_low + 20, LOCK_DECREMENT)
    # rebuild LOCK_DECREMENT = 0x7FFFFFFF
RELEASE_INSERT_LOCK:
    add r10, r3, 20             # r10 = &lock
    atomadd_d r12, r10, 8192     # release lock

    # atomic_add_dram(q_low + 16, 1)
    add r10, r3, 16             # r10 = &now_serving
    and r5, r5, 0
    add r5, r5, 1
    atomadd_d r12, r10, r5     # advance now_serving

    beq r15, r15, RETURN_FROM_INSERT_DRAM_QUEUE, true


SWITCH_ROLES_INTERRUPT:
    add r4, r8, 0                           # r4 = return address (saved from r8 by caller convention)
    intdis 34                               # disable_interrupts(34)
    nonblock r7, 34                             # is_value = r7 = nb_recv(channel) (0 if no message waiting)
    and r14, r14, 0                         # r14 = 0 (zero register)
    bne r14, r7, CONTINUE_WITH_SWITCH_ROLES_INTERRUPT, true  # if message waiting goto CONTINUE_WITH_SWITCH_ROLES_INTERRUPT
    intena 34                               # enable_interrupts(channel) (nothing to do)
    jmp r15, r4                             # return
CONTINUE_WITH_SWITCH_ROLES_INTERRUPT:
    block r7, 34                                # switch_core_request = r7 = blocking_recv(channel) (full flit value)
    # if (self.core_handled->previously_idle == 0)
    lw r9, PREVIOUSLY_IDLE                  # r9 = self.previously_idle
    bne r9, r14, UNHANDLED_CORE, false # if previously_idle == 0 goto SWITCH_ROLES_INTERRUPT_DONE
    #     send_flit(REJECT_CHANGE << 24, switch_core_request >> 4, switch_core_request & 0xF + 16);
REJECT_CHANGE:
    add r10, r7, 0                      # r10 = switch_core_request
    add r11, r14, 14                    # r11 = REJECT_CHANGE = 14
    sll r11, r11, 24                     # r11 = REJECT_CHANGE << 24
    and r12, r10, 0xF                   # r12 = thread_id = switch_core_request & 0xF
    add r12, r12, 16                     # r12 = thread_id + 16 (send channel)
    and r10, r10, 0xFFF0                  # r10 = core_id high nibble
    sll r10, r10, 8                     
    srl r10, r10, 6
    or r10, r10, r12                    # r10 = destination flit
    sendflit r11, r10                   # send_flit(REJECT_CHANGE << 24, dest) (reject: target core not idle)
    # enable_interrupts(34);
    # return;
    intena 34                               # enable_interrupts(channel)
    jmp r15, r4                             # return
UNHANDLED_CORE:
    # send_flit(ACCEPT_CHANGE << 24 | self.is_branch_core, switch_core_request >> 4, switch_core_request & 0xF + 16);
    lw r9, IS_BRANCH_CORE
    and r14, r14, 0
    beq r9, r14, LEGAL_TO_SWITCH, true
    lw r9, RAY_QUEUE_HIGH
    setmembits r9
    lw r9, RAY_QUEUE_LOW
    add r9, r9, 20
GET_READER_LOCK_CORE_CNT:
    atomadd_d r10, r9, 1
    blte r14, r10, HAVE_READER_LOCK_CORE_CNT, true
    atomadd_d r10, r9, -1
    beq r15, r15, GET_READER_LOCK_CORE_CNT, true
HAVE_READER_LOCK_CORE_CNT:
    lw_d r9, r9, 4
    add r10, r14, 1
    beq r9, r10, REJECT_CHANGE, false
LEGAL_TO_SWITCH:
    add r9, r14, LOCAL_QUEUE_FLUSHING
    atomadd r15, r9, 1
    add r10, r14, 16 
WAIT_FOR_FLUSH_READY:
    lw r9, LOCAL_QUEUE_FLUSHING
    switchctx
    beq r10, r9, WAIT_FOR_FLUSH_READY, true
    add r10, r7, 0                      # r10 = switch_core_request
    add r11, r14, 13                    # r11 = ACCEPT_CHANGE = 13
    sll r11, r11, 24                     # r11 = ACCEPT_CHANGE << 24
    and r12, r10, 0xF                   # r12 = thread_id = switch_core_request & 0xF
    add r12, r12, 16                     # r12 = thread_id + 16 (send channel)
    and r10, r10, 0xFFF0                  # r10 = core_id high nibble
    sll r10, r10, 8                     # r10 = core_id high nibble shifted to channel position
    srl r10, r10, 6
    or r10, r10, r12                    # r10 = destination flit
    sendflit r11, r10                   # send_flit(ACCEPT_CHANGE << 24 | self.is_branch_core, dest) (accept: target core idle)
    getowner                  # TODO ALex tf is this?
    # uint32_t type_of_core = blocking_recv(0);
    beq r15, r15, REMOVE_FROM_RAY_QUEUE_DRAM, true ; # if t0 == t1 then target
    
                                # REMOVE CURRENT CORE FROM DRAM QUEUE
RETURN_FROM_CORE_DRAM_QUEUE:
    block r10, r14                           # r10 = type_of_core = blocking_recv(0)
    # if (type_of_core != self.is_branch_core)
    lw r11, IS_BRANCH_CORE             # r11 = self.is_branch_core
    beq r10, r11, CORE_TYPE_BRANCH, false # if type_of_core != self.is_branch_core goto SWITCH_ROLES_INTERRUPT_DONE
    #     uint32_t starting_address = (type_of_core == 1) ? branch_start_of_code : leaf_start_of_code;
    add r11, r14, 1
    beq r10, r11, DO_BRANCH_START_OF_CODE, true
    lw r11, leaf_start_of_code             # r11 = leaf_start_of_code    
    beq r15, r15, DONE_LOADING_CODE, true
DO_BRANCH_START_OF_CODE:
    lw r11, BRANCH_START_OF_CODE   
    # r11 = starting_address
DONE_LOADING_CODE:
    and r12, r12, 0
    add r12, r12, 17284                     # num_instructions
    #    for (int i = 0; i < num_instructions; i += 4)
    and r14, r14, 0             # 0
    and r9, r9, 0               # i
FOR_NUM_INSTRUCTIONS:
    #         uint32_t instruction_to_recv = blocking_recv(0);
    block r13, r14                           # r13 = instruction_to_recv = blocking_recv(0)
    #           *(starting_address + i) = instruction_to_recv;
    sw r13, r11, 0                         # *(starting_address + i) = instruction_to_recv
    add r11, r11, 4
    add r9, r9, 4                           # i += 4
    bgt r12, r9, FOR_NUM_INSTRUCTIONS, true # if i < num_instructions goto FOR_NUM_INSTRUCTIONS
CORE_TYPE_BRANCH:
    # uint32_t starting_address = (type_of_core == 1) ? branch_start_of_geometry : leaf_start_of_geometry;
    add r11, r14, 1
    and r12, r12, 0
    bne r10, r11, DONE_LOADING_GEO, true
    lw r11, LEAF_START_OF_GEO              # r11 = leaf_start_of_geometry
    add r12, r12, 5678
    beq r15, r15, DONE_LOADING_GEO, true
    lw r11, BRANCH_START_OF_GEO             # r11 = branch_start_of_geometry
    add r12, r12, 8765
DONE_LOADING_GEO:
    # for (int i = 0; i < size_of_geo; i += 4)
    and r14, r14, 0             # 0
    and r9, r9, 0               # i
FOR_SIZE_OF_GEO:
    #     uint32_t word_to_transfer_of_geo = blocking_recv(0);
    #     *(starting_address + i) = word_to_transfer_of_geo;
    block r13, r14                           # r13 = word_to_transfer_of_geo = blocking_recv(0)
    sw r13, r11, 0                         # *(starting_address + i) = word_to_transfer_of_geo
    add r9, r9, 4                           # i += 4
    add r11, r11, 4
    bgt r12, r9, FOR_SIZE_OF_GEO, true     # if i < size_of_geo goto FOR_SIZE_OF_GEO
    # self.is_branch_core = type_of_core;
    sw r10, IS_BRANCH_CORE             # self.is_branch_core = type_of_core
    beq r15, r15, ADD_TO_RAY_QUEUE_DRAM, true
RETURN_FROM_INSERT_DRAM_QUEUE:
    relinquish true
    lw r10, IS_BRANCH_CORE
    and r14, r14, 0
    add r11, r14, 1
    beq r10, r11, 1234, true # if type_of_core == 1 (branch core) goto SWITCH_ROLES_INTERRUPT_DONE
    beq r15, r15, 4321, true




START_RAY_TRAVERSAL:
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
    lhu r1, r1, 28                  # r6 = node->parent
    beq r6, r7, SEND_RAY_UP, true  # r7 = 0
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
    lw r6, r1, 44                  # r6 = node->node_id 
    or r9, r9, 0xFFFF
    beq r6, r9, TRAVERSE_OWN_CHILD, true   # owner == 0xFFFF means we own it
#TODO NEED TO ADDRESS WHEN CORE ID == 0xFFFF!!!
    # uint16_t ray_send_pending_addr = self.ray_send_pending_addr;
SEND_RAY_UP:
    add r8, r7, RAY_SEND_PENDING_ADDR    # r8 = self.ray_send_pending_addr

    # atomic_add(ray_send_pending_addr, 1)
    atomadd r15, r8, 1               # r9 = clobber

    # standalone slot sentinel init
    # slot = 0xFFFFFFFF  //NEEDS FIX HERE! confirm r4 vs r13 as slot register
    or r4, r4, 0xFFFF
    # uint32_t sent = 0;
    and r3, r3, 0                   # r3 = sent = 0

    # disable_interrupts(32)  -- leaf core uses only mailbox 32 for interrupts
    intdis 32
    lhu r11, r1, 28
    add r10, r7, 32
    or r13, r13, 0xFFFF
    bne r11, r13, SKIP_ADDING_ONE_TO_BRANCH_CORE_MAILBOX, true
    # uint32_t request_word = (node->node_id << 17) | self.thread_id;
    add r10, r10, 1
SKIP_ADDING_ONE_TO_BRANCH_CORE_MAILBOX:
    sll r6, r6, 17
    or r6, r6, r15                # r12 = request_word

    # send_packet(request_word, node->core_owner, 32);
    lhu r9, r1, 30                  # r6 = node->core_owner
    sll r9, r9, 6
    add r9, r9, r10
    sendflit r6, r9            # TODO confirm notation w/ Alex
send_ray_loop:
    # uint32_t msg_available = nb_recv(self.thread_id + 16);
    and r10, r15, 0xF               # r10 = thread_id
    add r11, r10, 16                # r11 = thread_id + 16 (shallow mailbox)
    nonblock r12, r11               # r12 = msg_available
    beq r12, r7, CHECK_DATA_MAILBOX, true   # r7=0, nothing on shallow mailbox

    # uint32_t msg = blocking_receive(self.thread_id + 16);
    block r12, r11                  # r12 = msg

    # uint32_t header = msg >> 24;
    srl r13, r12, 24                # r13 = header

    # if (header == ack_ray)  -- ack_ray = 5
    add r11, r7, 5                 # r11 = 5 (ack_ray)
    bne r13, r11, REJECT_PATH, true

    # ACK path: for (i = 0; i < 16; i++) send_packet(ray[i], core_owner, mailbox)
    srl r9, r12, 4
    sll r9, r9, 19
    srl r9, r9, 13    
    and r11, r12, 0xF               # r11 = dest mailbox from ack msg low nibble
    or r9, r9, r11                  # r13 = ray base ptr

    lw r7, r0, 0
    sendflit r7, r9
    lw r7, r0, 4
    sendflit r7, r9
    lw r7, r0, 8
    sendflit r7, r9
    lw r7, r0, 12
    sendflit r7, r9
    lw r7, r0, 16
    sendflit r7, r9
    lw r7, r0, 20
    sendflit r7, r9
    lw r7, r0, 24
    sendflit r7, r9
    lw r7, r0, 28
    sendflit r7, r9
    lw r7, r0, 32
    sendflit r7, r9
    lw r7, r0, 36
    sendflit r7, r9
    lw r7, LEAF_CORE_INDEX_FOR_BRANCH
    sendflit r7, r9
    lw r7, r0, 44
    sendflit r7, r9
    lw r7, r0, 48
    sendflit r7, r9
    lw r7, r0, 52
    sendflit r7, r9
    lw r7, r0, 56
    sendflit r7, r9
    lw r7, r0, 60   
    sendflit r7, r9


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
    add r9, r9, 8
    atomadd_d r10, r9, 1               # r10 = cur_ray_count (count field is -12 from here)
    add r11, r7, 255               # r11 = 255
    bgt r10, r11, THERE_EXISTS_SPACE_IN_DRAM_RAY_QUEUE, true   # spin while count > 255
    atomadd_d r15, r9, -1
    beq r15, r15, ENSURE_SPACE_IN_QUEUE, true
THERE_EXISTS_SPACE_IN_DRAM_RAY_QUEUE:
    add r9, r9, -4                 # r9 = queue base (tail field)
    atomadd_d r10, r9, 64           # r10 = old tail, advance tail by 64 bytes
    and r10, r10, 0x3FFF            # r10 = tail & 0x3FFF (ring mask)
    add r9, r9, 16228                # r11 = queue base + 540 (start of ray slots)
    add r9, r9, r10               # r11 = write_addr = slot base + tail offset

WAIT_FOR_SLOT_TO_OPEN:
    lbu_d r10, r9, 63              # r10 = slot[63] (valid byte)
    bne r10, r7, WAIT_FOR_SLOT_TO_OPEN, true   # spin while slot occupied (r7=0)
RAY_DRAM_WRITE_LOOP:
    lw r10, r0, 0                  # r10 = ray word i
    sw_d r10, r9, 0                # write to DRAM slot
    lw r10, r0, 4                  # r10 = ray word i
    sw_d r10, r9, 4                # write to DRAM slot
    lw r10, r0, 8                  # r10 = ray word i
    sw_d r10, r9, 8                # write to DRAM slot
    lw r10, r0, 12                  # r10 = ray word i
    sw_d r10, r9, 12                # write to DRAM slot
    lw r10, r0, 16                  # r10 = ray word i
    sw_d r10, r9, 16                # write to DRAM slot
    lw r10, r0, 20                  # r10 = ray word i
    sw_d r10, r9, 20                # write to DRAM slot
    lw r10, r0, 24                  # r10 = ray word i
    sw_d r10, r9, 24                # write to DRAM slot
    lw r10, r0, 28                  # r10 = ray word i
    sw_d r10, r9, 28                # write to DRAM slot
    lw r10, r0, 32                  # r10 = ray word i
    sw_d r10, r9, 32                # write to DRAM slot
    lw r10, r0, 36                  # r10 = ray word i
    sw_d r10, r9, 36                # write to DRAM slot
    lw r10, r0, 40                  # r10 = ray word i
    sw_d r10, r9, 40                # write to DRAM slot
    lw r10, r0, 44                  # r10 = ray word i
    sw_d r10, r9, 44                # write to DRAM slot
    lw r10, r0, 48                  # r10 = ray word i
    sw_d r10, r9, 48                # write to DRAM slot
    lw r10, r0, 52                  # r10 = ray word i
    sw_d r10, r9, 52                # write to DRAM slot
    lw r10, r0, 56                  # r10 = ray word i
    sw_d r10, r9, 56                # write to DRAM slot
    lw r10, r0, 60                  # r10 = ray word i
    sw_d r10, r9, 60                # write to DRAM slot
    and r14, r14, 0
    sb r14, r0, 63

    lw r9, r1, 36                   # r9 = queue_low_bit_addr (reload)
    add r9, r9, 20                  # r9 = &lock field (offset 20 from queue base)

ENSURE_NO_WRITERS:
    atomadd_d r10, r9, 1            # r10 = old lock value, increment
    beq r7, r10, SKIP_UNDO_LOCK, true   # old val >= 0 means no writer held it
    atomadd_d r11, r9, -1           # undo our increment
    beq r15, r15, ENSURE_NO_WRITERS, true        # retry claim

SKIP_UNDO_LOCK:
    lw_d r10, r9, 4                 # r10 = core_owner_count
    beq r10, r7, NO_OWNER, true     # r7=0, no owners

    # pick owner round-robin: idx = (core_id ^ clock) % core_owner_count
    getclk r11                      # r11 = clock
    srl r12, r15, 4                 # r12 = core_id
    xor r12, r12, r11               # r12 = core_id ^ clock = raw idx
    lhu r13, r1, 38                 # r13 = node->prev_index
    bne r12, r13, SKIP_BUMP, true    # if idx == prev_idx, bump to avoid repeat
BUMP_IDX:
    add r12, r12, 1                 # r12 = idx + 1
SKIP_BUMP:
    mod r12, r12, r10               # r12 = idx % core_owner_count
    sh r12, r1, 38                  # node->prev_index = idx
    sll r12, r12, 1                 # r12 = idx * 2 (uint16 slots)
    add r9, r9, r12                 # r9 = &core_slots[idx]
    lh_d r10, r9, 8                # r10 = core_to_cache (core_slots at +28 from lock field)
    sh r10, r1, 34                  # node->core_owner = core_to_cache
    beq r15, r15, SKIP_EMERGENCY_ENQUEUE, true

NO_OWNER:
    # node->core_owner = 0xFFFF
    and r11, r11, 0
    add r11, r11, 0xFFFF            # r11 = 0xFFFF
    sh r11, r1, 32                  # node->core_owner = 0xFFFF

    # if (cur_ray_count > 200) -> emergency queue insertion
    lw r9, r1, 36                   # r9 = queue_low_bit_addr (reload)
    lw_d r10, r9, 8               # r10 = cur_ray_count
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
    add r11, r7, 1                 # r11 = 1
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
    nonblock r12, r10               # r12 = nb_recv(thread_id) -- data mailbox
    and r7, r7, 0
    beq r12, r7, CHECK_INTERRUPT_MAILBOX, true   # r7=0, nothing available.
    block r11, r10
    sw r11, r4, 0
    block r11, r10
    sw r11, r4, 4
    block r11, r10
    sw r11, r4, 8
    block r11, r10
    sw r11, r4, 12
    block r11, r10
    sw r11, r4, 16
    block r11, r10
    sw r11, r4, 20
    block r11, r10
    sw r11, r4, 24
    block r11, r10
    sw r11, r4, 28
    block r11, r10
    sw r11, r4, 32
    block r11, r10
    sw r11, r4, 36
    block r11, r10
    sw r11, r4, 40
    block r11, r10
    sw r11, r4, 44
    block r11, r10
    sw r11, r4, 48
    block r11, r10
    sw r11, r4, 52
    block r11, r10
    sw r11, r4, 56
    block r11, r10
    sw r11, r4, 60
    add r11, r7, 1
    sb r11, r4, 63
    lw r1, ROOT_NODE_ADDRESS
CHECK_INTERRUPT_MAILBOX:
    nonblock r11, 32
    beq r11, r7, SKIP_INTERRUPT_MAILBOX, true
    block r11, 32
    srl r12, r11, 17
    lw r6, ROOT_NODE_ID
    beq r12, r6, CORRECT_NODE_ID, true
SEND_REJECT_RAY_MSG:
    add r12, r7, 8
    srl r13, r11, 4
    sll r13, r13, 19
    srl r13, r13, 13
    and r11, r11, 0xF
    or r13, r13, r11
    sendflit r12, r13
    beq r15, r15, SKIP_INTERRUPT_MAILBOX, true
CORRECT_NODE_ID:
    lbu r10, r0, 63
    bne r10, r7, NO_ROOM_IN_RAY_SLOT, true
    add r4, r0, 0
    beq r15, r15, SEND_ACK_PACKET, true
NO_ROOM_IN_RAY_SLOT:
    add r10, r7, RAY_QUEUE_CNT
    atomadd r5, r10, 1
    add r6, r7, 31
    blte r6, r5, SPACE_IN_QUEUE_RAY_SEND, true
    atomadd r15, r10, -1
    beq r15, r15, SEND_REJECT_RAY_MSG, true
SPACE_IN_QUEUE_RAY_SEND:
    add r10, r10, -4
    atomadd r6, r10, 64
    and r6, r6, 0x7FF
    add r10, r10, r6
    add r4, r10, 8
SEND_ACK_PACKET:
    add r12, r7, 5
    srl r13, r11, 4
    sll r13, r13, 19
    srl r13, r13, 13
    and r11, r11, 0xF
    or r13, r13, r11
    or r12, r12, r15
    sendflit r12, r13
SKIP_INTERRUPT_MAILBOX:
    or r12, r12, 0xFFFF
    bne r12, r4, send_ray_loop, false
    beq r3, r7, send_ray_loop, false
    intena 32
    add r3, r7, RAY_SEND_PENDING 
    atomadd r15, r3, -1
    beq r15, r15, ray_done, true
TRAVERSE_OWN_CHILD:
    # node = node->left_child
    lhu r1, r1, 24                  # r1 = node->left_child
    beq r15, r15, START_SEARCHING, true
IS_LEAF_NODE:
    and r7, r7, 0
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
    lhu r2, r1, 32              # r2 - tri_index
    lbu r3, r1, 31              # r3 = tri_count
TRIANGLE_INTERSECT_LOOP:
    beq r15, r15, triangle_intersect, true
TRIANGLE_INTERSECT_RETURN:
    add r2, r2, 6
    lbu r5, r0, 61
    and r4, r4, 0
    lw r6, r0, 56
    beq r4, r5, SHADOW_RAY_NOT_OCCLUDED, true
    and r5, r5, 0
    add r5, r5, -1
    beq r5, r6, SHADOW_RAY_NOT_OCCLUDED, true
    beq r15, r15, SHADOW_RAY_OCCLUDED, true
SHADOW_RAY_NOT_OCCLUDED:
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

SHADOW_RAY_OCCLUDED:
    and r7, r7, 0
    # BIG TODO; Alex explain the math for ray_result_addr stuff

    # uint32_t finished_ray_high = self.ray_result_addr_high;
    lw r10, RAY_RESULT_HIGH # r10 = finished_ray_high TODO Alex tf is this

    # set_address_bits(finished_ray_high);
    setmembits r10

    # uint32_t result_addr_low = self.ray_result_addr_low;
    lw r11, RAY_RESULT_LOW # r11 = result_addr_low

    # atomic_add_dram(result_addr_low, 1); // increment finished ray counter
    atomadd_d r12, r11, 1           # r12 = old finished ray count, increment

    # uint32_t pix_index = ray->pix_y;
    lhu r13, r0, 54         # r13 = pix_index

    # pix_index *= 2560;
    sll r13, r13, 9         # r13 = pix_index * 512
    add r12, r13, 0         # r12 = pix_index * 512
    sll r13, r13, 2         # r13 = pix_index * 2048
    add r12, r13, r12        # r12 = pix_index * 2560

    # pix_index += ray->pix_x;
    lhu r13, r0, 52         # r13 = ray -> pix_x 
    add r12, r13, r12        # pix_index += pix_x

    # pix_index <<= 8;
    sll r12, r12, 8         # pix_index <<= 8

    # result_addr_low += pix_index;
    add r11, r12, r11        # result_addr_low += pix_index

    # uint32_t bounce = ray->bounce_count;
    lbu r10, r0, 60         # r10 = bounce_count

    # bounce <<= 6;
    sll r10, r10, 6         # bounce <<= 6

    # result_addr_low += bounce;
    add r11, r10, r11        # result_addr_low += bounce

    # uint32_t shadow = ray->light_id;
    lbu r10, r0, 61         # r10 = shadow

    # result_addr_low += shadow << 4;
    sll r10, r10, 4         # shadow <<= 4
    add r11, r10, r11        # result_addr_low += shadow

    # Write 1.0 to len_sq slot to mark as occluded (blocked)
    # uint32_t one = 0x3F800000;
    lw r10, ONE

    # store_dram_word(result_addr_low + 12, one);
    add r11, r11, 12         # r11 = result_addr_low + 12
    sw_d r10, r11, 0         # store 1.0 to len_sq slot

    # ray->active_ray = 0;
    sb r7, r0, 63           # ray->active_ray = 0 (r7=0)

    # goto ray_done;
    # redunant

ray_done:
    # ; if (ray->active_ray == 1) { goto start_ray_traversal; }
    and r7, r7, 0
    lb r8, r0, 63
    bne r8, r7, START_RAY_TRAVERSAL, true

    # yield();
    yield r8

    # Check local SRAM ray queue
    # uint32_t local_queue_addr = self.local_ray_queue;
    add r8, r7, RAY_QUEUE_HEAD # r8 = local_queue_addr

    # uint32_t local_ray_count = *(local_queue_addr + 8);
    add r8, r8, 8           # r8 = local_queue_addr + 8
    lw r9, r8, 0           # r9 = local_ray_count

    # if (local_ray_count > 0) { ... }
    and r7, r7, 0
    blte r9, r7, NEGATIVE_RAY_COUNT, false
    
    # uint32_t old_count = atomic_add(local_queue_addr + 8, -1);
    atomadd r10, r8, -1          # r10 = old_count, decrement local_ray_count
    bgt r10, r7, CHECK_SRAM_HEAD, true
    atomadd r10, r8, 1          # r10 = old_count, decrement local_ray_count
    beq r15, r15, CHECK_DRAM_QUEUE, true
CHECK_SRAM_HEAD:
    # uint32_t head = atomic_add(local_queue_addr, 64);
    and r7, r7, 0
    add r7, r7, 64
    lw r8, RAY_QUEUE_HEAD
    atomadd r10, r8, r7          # r10 = head, advance head by 64 bytes
    and r7, r7, 0
    # head = head & 0x000007FF; // 32 slots * 64 bytes = 1024
    and r10, r10, 0x7FF          # r10 = head & 0x7FF (ring buffer mask)
    # uint32_t ray_src = local_queue_addr + 12 + head;
    add r10, r10, 12             # r10 = local_queue_addr + 12 + head (ray slot address)
    add r10, r10, r8
    # int ray_index = ray;
    add r11, r0, 0
    and r7, r7, 0
    add r6, r7, 16
RAY_UPDATE_LOOP:
    beq r7, r6, RAY_UPDATE_LOOP_DONE, true
    # uint32_t ray_word = *(ray_src);
    lw r12, r10, 0
    # *(ray_index) = ray_word;
    sw r12, r11, 0
    # ray_src = ray_src + 4;
    add r10, r10, 4
    # ray_index = ray_index + 4;
    add r11, r11, 4
    add r7, r7, 1
    beq r15, r15, RAY_UPDATE_LOOP, true
RAY_UPDATE_LOOP_DONE:
    and r7, r7, 0
    # *(ray_src - 1) = 0;
    add r10, r10, -4 # <- I think??
    # ray->leaf_node_starting_point = self.branch_local_leaf_index;
    lw r8, BRANCH_LOCAL_LEAF_INDEX # TODO Alex what
    # ray->active_ray = 1;
    add r7, r7, 1
    sb r7, r0, 63           # ray->active_ray = 1 (r7=0)
    lw r1, ROOT_NODE_ADDRESS
    add r1, r1, 0
    # goto start_ray_traversal;
    beq r15, r15, START_RAY_TRAVERSAL, true
NEGATIVE_RAY_COUNT:
    # uint8_t flushing_queue = *(self.local_queue_flushing);
    lw r8, LOCAL_QUEUE_FLUSHING # r8 = &local_queue_flushing
    lbu r8, r8, 0
    # if (flushing_queue != 0){ goto inf_loop; }
    and r7, r7, 0
    bne r8, r7, INF_LOOP, true
CHECK_DRAM_QUEUE:
    # yield();
    yield r8
    # int queue_address_low = self.ray_queue_address_low;
    lw r9, RAY_QUEUE_LOW # TODO Alex what is this
    # int queue_address_high = self.ray_queue_address_high;
    lw r10, RAY_QUEUE_HIGH
    # set_address_bits(queue_address_high);
    setmembits r10
    # int cur_ray_count = load_dram_word(queue_address_low + 8);
    add r9, r9, 8           # r9 = queue_address_low + 8
    lw_d r11, r9, 0       # r11 = cur_ray_count

    # if (cur_ray_count > 0) { ... }
    and r7, r7, 0
    blte r11, r7, NO_DRAM_RAYS, false

    #     if (cur_ray_count >= 256) { ... }
    and r7, r7, 0
    add r7, r7, 256
    blte r11, r7, DONT_ASK_FOR_HELP, true
    # uint32_t num_times_pulled_from_full_queue = atomic_add(pulled_from_full_queue_address, 1);
    and r9, r9, 0
    add r9, r9, PULLED_FROM_FULL_QUEUE_CNT
    atomadd r9, r9, 1           # r9 = old count, increment
    # if (num_times_pulled_from_full_queue > BRANCH_BUSY_THRESHOLD)
    and r7, r7, 0
    add r7, r7, 200
    blte r9, r7, CHECK_CUR_RAY_COUNT, true
    jmp r15, SEARCH_FOR_IDLE_CORES 
DONT_ASK_FOR_HELP:
    # *(self->pulled_from_full_queue_address) = 0;
    and r7, r7, 0
    sw r7, PULLED_FROM_FULL_QUEUE_CNT
CHECK_CUR_RAY_COUNT:
    # int cur_ray_count_check = atomic_add_dram(queue_address_low + 8, -1);
    lw r9, RAY_QUEUE_LOW # TODO Alex what is this
    add r9, r9, 8           # r9 = queue_address_low + 8
    atomadd_d r11, r9, -1       # r11 = cur_ray_count_check, decrement    
    #if (cur_ray_count_check <= 0)
    # {
    #     atomic_add_dram(queue_address_low + 8, 1);
    #     goto ray_done;
    # }
    and r7, r7, 0
    bgt r11, r7, PROCEED_TO_READ_RAY, true

    atomadd_d r11, r9, 1
    beq r15, r15, ray_done, true
PROCEED_TO_READ_RAY:
    # int head = atomic_add_dram(queue_address_low, 64);
    lw r9, RAY_QUEUE_LOW # TODO Alex what is this
    and r7, r7, 0
    add r7, r7, 64
    atomadd_d r10, r9, r7       # r10 = head, advance head by 64 bytes

    # queue_address_low = queue_address_low + 536; // skip header + core_slots to ray data
    add r9, r9, 16228                 # r9 = queue_address_low + 536 (start of ray slots)
    # head = head & 0x00003FFF;
    and r10, r10, 0x3FFF            # r10 = head & 0x3FFF (ring buffer mask for 16KB queue) TODO ALEX THE "AND" ALSO THE OFFSET 
    # queue_address_low += head;
    add r9, r9, r10               # r9 = queue_address_low + 536 + head (ray slot address)

WAIT_FOR_WRITE:
    # int ready = load_dram_byte(queue_address_low + 63);
    add r10, r9, 63              # r10 = queue_address_low + 63
    lbu_d r10, r10, 0              # r10 = ready byte
    # if (ready == 0)
    # {
    #    goto wait_for_write;
    # }
    and r7, r7, 0
    beq r10, r7, WAIT_FOR_WRITE, true   # r7=0, spin while not ready

    # int ray_index = ray;
    add r11, r0, 0
    and r7, r7, 0
    add r6, r7, 16
WRITE_TO_RAY_IDX_LOOP:
    # for (int i = 0; i < 16; i++)
    # {
    #     *(ray_index) = load_dram_word(queue_address_low);
    #     queue_address_low = queue_address_low + 4;
    #     ray_index = ray_index + 4;
    # }
    beq r7, r6, WRITE_TO_RAY_IDX_LOOP_DONE, true

    lw_d r12, r9, 0           # r12 = load_dram_word(queue_address_low)
    sw r12, r11, 0         # *(ray_index) = ray_word
    add r9, r9, 4           # queue_address_low = queue_address_low + 4
    add r11, r11, 4         # ray_index = ray_index + 4
    add r7, r7, 1
    beq r15, r15, WRITE_TO_RAY_IDX_LOOP, true
WRITE_TO_RAY_IDX_LOOP_DONE:
    lw r1, ROOT_NODE_ADDRESS
    # write_dram_byte(queue_address_low - 1, 0); // mark consumed
    add r9, r9, -1          # r9 = queue_address_low - 1
    sb_d r7, r9, 0           # write 0 to ready byte to mark consumed
    add r9, r9, 1           # restore r9 to point to start of ray slot
    # ray->leaf_node_starting_point = self.branch_local_leaf_index;
    lw r8, BRANCH_LOCAL_LEAF_INDEX
    sw r8, r0, 40          # ray->leaf_node_starting_point = branch_local_leaf_index
    # goto start_ray_traversal;   
    beq r15, r15, START_RAY_TRAVERSAL, true 
NO_DRAM_RAYS:
    # uint32_t emergency_queue_high = self.emergency_queue_high;
    lw r10, EMERGENCY_QUEUE_HIGH # r10 = emergency_queue_high
    # set_address_bits(emergency_queue_high);
    setmembits r10
    # uint32_t emergency_queue_low = self.emergency_queue_low;
    lw r9, EMERGENCY_QUEUE_LOW # r9 = emergency_queue_low
    # uint32_t count = load_dram_word(emergency_queue_low + 8);
    add r9, r9, 8           # r9 = &count field
    lw_d r11, r9, 0       # r11 = count
    add r9, r9, -8
    # if (count <= 0)
    # {
    #     goto check_done;
    # }
    and r7, r7, 0
    blte r11, r7, CHECK_DONE, true
    # emergency_queue_low += 8;
    add r9, r9, 8
    # uint32_t old_cnt = atomic_add_dram(emergency_queue_low, 1);
    atomadd_d r11, r9, 1       # r11 = old_cnt, increment count
    # if (old_cnt <= 0)
    # {
    #     atomic_add_dram(emergency_queue_low, -1);
    #     goto check_done;
    # }
    and r7, r7, 0
    bgt r11, r7, EMERGANCY_QUEUE_CONTINUE, true
    atomadd_d r11, r9, -1      # undo increment
    beq r15, r15, CHECK_DONE, true
EMERGANCY_QUEUE_CONTINUE:
    # emergency_queue_low -= 8;
    add r9, r9, -8
    # uint32_t byte_index = atomic_add_dram(emergency_queue_low, 4);
    atomadd_d r10, r9, 4 
    # byte_index &= 0x000000FF;
    and r10, r10, 0xFF
    # emergency_queue_low += byte_index;
    add r9, r9, r10
    # emergency_queue_low += 12;
    add r9, r9, 12
    # ensure_emergency_slot_ready:
ENSURE_EMERGENCY_SLOT_READY_TWO:
    # uint16_t is_ready = load_dram_byte(emergency_queue_low + 2);
    add r10, r9, 2           # r10 = emergency_queue_low + 2
    lbu_d r10, r10, 0          # r10 = is_ready
    # if (is_ready == 1)
    # {
    #     goto ensure_emergency_slot_ready_TWO;
    # }
    and r7, r7, 0
    add r7, r7, 1
    beq r10, r7, ENSURE_EMERGENCY_SLOT_READY_TWO, true
    # uint32_t new_node_id = load_dram_half(emergency_queue_low);
    lw_d r11, r9, 0           # r11 = new_node_id (uint32 loaded from slot)
    # store_dram_byte(emergency_queue_low + 2, 0);
    add r10, r9, 2           # r10 = emergency_queue_low + 2
    and r7, r7, 0
    sb_d r7, r10, 0          # mark slot as empty by writing 0 to is_ready
    # goto switch_dram_queue;
    #TODO
    beq r15, r15, SWITCH_DRAM_QUEUE, true

    # yield();
    yield r8
CHECK_DONE:
    # is_idle_leaf();
    jmp r2, is_idle_leaf# r2 is return address @ ALEX LOOK AT THIS
    yield r8                             # yield()
    lw r2, RAYS_COMPLETED_HIGH           # uint32_t finished_ray_high = self.ray_result_addr_high  -- differs: pseudocode uses ray_result_addr, asm uses RAYS_COMPLETED
    setmembits r2                        # set_address_bits(finished_ray_high)
    lw r2, RAYS_COMPLETED_LOW            # uint32_t finished_ray_low = self.ray_result_addr_low
    lw_d r2, r2, 0                       # uint32_t rays_finished = load_dram_word(finished_ray_low)
    lw r3, MAX_RAYS                      # uint32_t max_rays = 1440 * 2560 * 4
    bne r2, r3, ray_done, true           # if (rays_finished != max_rays) goto ray_done
    yield r8                             # yield()

# below is the final pass of the main loop, calculating the color of the final image
    getowner                             # get_thread_ownership()
    setctx 14                            # set_ctx(14)  -- differs: pseudocode uses 15
    relinquish true                         # relinquish_ownership(1)
    yield r15                            # yield()
    lw r0, RAY_RESULT_HIGH           # uint32_t pixel_addr_high = self.ray_result_addr_high
    setmembits r0                        # set_address_bits(pixel_addr_high)
    lw r0, RAY_RESULT_LOW            # uint32_t pixel_addr_low = self.ray_result_addr_low
    srl r1, r15, 4                       # uint32_t pix_index = self.core_id >> 4
    and r2, r15, 0xF                     # uint32_t thread_index = self.core_id & 0xF
    mul r1, r1, 15                       # pix_index *= 15
    srl r1, r1, 8                        # pix_index >>= 8  -- r1 = pix_increment  -- differs: pseudocode adds 15 then shifts
    add r0, r0, r1                       # pixel_addr_low += pix_increment
    and r14, r14, 0                      # r14 = 0
    and r1, r1, 0                        # r1 = 0 (reset pixel loop counter)

LOOP_PIXEL:
    add r2, r14, 2                       # uint32_t bounce = NUM_BOUNCES - 1  (NUM_BOUNCES=3, so bounce=2)
    add r4, r14, RAY_ARRAY               # r4 = &RAY_ARRAY (scratch area for register pressure)
    and r5, r15, 0xF                     # r5 = thread_index
    sll r5, r5, 6                        # r5 <<= 6 (64 bytes per thread scratch slot)
    add r4, r4, r5                       # r4 = thread-local scratch base
    sw r14, r4, 0                        # carried_r = 0.0f
    sw r14, r4, 4                        # carried_g = 0.0f
    sw r14, r4, 8                        # carried_b = 0.0f
BOUNCE_LOOP:
    sll r5, r2, 6                        # uint32_t bounce_addr = bounce << 6 (64 bytes per bounce slot)
    add r5, r0, r5                       # bounce_addr += pixel_addr_low
    lw_d r6, r5, 0                       # float sr = load_dram_word(bounce_addr)
    lw_d r7, r5, 4                       # float sg = load_dram_word(bounce_addr + 4)
    lw_d r8, r5, 8                       # float sb = load_dram_word(bounce_addr + 8)
    lw_d r9, r5, 12                      # float metallic = load_dram_word(bounce_addr + 12)
    sw r6, r4, 12                        # scratch->sr = sr
    sw r7, r4, 16                        # scratch->sg = sg
    sw r8, r4, 20                        # scratch->sb = sb
    sw r9, r4, 24                        # scratch->metallic = metallic
    sw r14, r4, 28                       # acc_r = 0.0f
    sw r14, r4, 32                       # acc_g = 0.0f
    sw r14, r4, 36                       # acc_b = 0.0f
    add r5, r5, 16                       # shadow_addr = bounce_addr + 16 (skip sr/sg/sb/metallic)
    and r6, r6, 0                        # uint32_t light = 0
SHADOW_LOOP:
    lw_d r9, r5, 12                      # uint32_t len_sq = load_dram_word(shadow_addr + 12)
    or r8, r8, 0xFFFF                # r8 = 0xFFFFFFFF (sentinel for blocked/no light)
    beq r9, r8, SHADOW_SKIP, false             # if (len_sq == 0xFFFFFFFF) goto shadow_skip  -- differs: pseudocode has inverted condition
    #TODO EVERY TIME I DO A JUMP I NEED TO RESET MEMBITS
    jmp r10, RECIPROCAL                  # float atten = reciprocal(len_sq)  -- result in r9
    lw_d r7, r5, 0                       # float lr = load_dram_word(shadow_addr)
    lw_d r8, r5, 4                       # float lg = load_dram_word(shadow_addr + 4)
    lw_d r10, r5, 8                      # float lb = load_dram_word(shadow_addr + 8)
    fpmul.32 r7, r7, r9                   # lr *= atten
    fpmul.32 r8, r8, r9                   # lg *= atten
    fpmul.32 r10, r10, r9                 # lb *= atten
    lw r11, r4, 28                       # r11 = acc_r
    lw r12, r4, 32                       # r12 = acc_g
    lw r13, r4, 36                       # r13 = acc_b
    fpadd.32 r11, r11, r7                 # acc_r += lr 
    fpadd.32 r12, r12, r8                 # acc_g += lg
    fpadd.32 r13, r13, r10               # acc_b += lb
    sw r11, r4, 28                       # store acc_r
    sw r12, r4, 32                       # store acc_g
    sw r13, r4, 36                       # store acc_b
SHADOW_SKIP:
    add r5, r5, 16                       # shadow_addr += 16 (next light slot)
    add r6, r6, 1                        # light += 1
    add r7, r14, 3                       # r7 = NUM_LIGHTS (3)
    bgt r7, r6, SHADOW_LOOP, true        # if (light < NUM_LIGHTS) goto shadow_loop

    lw r6, r4, 28                        # r6 = acc_r
    lw r7, r4, 32                        # r7 = acc_g
    lw r8, r4, 36                        # r8 = acc_b
    lw r9, r4, 12                        # r9 = sr
    lw r10, r4, 16                       # r10 = sg
    lw r11, r4, 20                       # r11 = sb
    lw r12, r4, 24                       # r12 = metallic
    lw r13, ONE                          # r13 = 1.0f
    fpsub.32 r13, r13, r12                   # float inv_metallic = 1.0f - metallic
    fpmul.32 r6, r6, r9                   # float diffuse_r = acc_r * sr
    fpmul.32 r7, r7, r10                  # float diffuse_g = acc_g * sg
    fpmul.32 r8, r8, r11                  # float diffuse_b = acc_b * sb
    fpmul.32 r6, r6, r13                  # diffuse_r *= inv_metallic
    fpmul.32 r7, r7, r13                  # diffuse_g *= inv_metallic
    fpmul.32 r8, r8, r13                  # diffuse_b *= inv_metallic
    lw r13, r4, 0                        # r13 = carried_r
    fpmul.32 r13, r13, r9                 # carried_r *= sr
    fpmul.32 r13, r13, r12               # carried_r *= metallic
    fpadd.32 r6, r6, r13                  # diffuse_r *= (carried_r * metallic)  -- differs: pseudocode does carried_r += diffuse_r at end
    sw r6, r4, 0                         # store new carried_r
    lw r13, r4, 4                        # r13 = carried_g
    fpmul.32 r13, r13, r10               # carried_g *= sg
    fpmul.32 r13, r13, r12               # carried_g *= metallic
    fpadd.32 r7, r7, r13                  # diffuse_g *= (carried_g * metallic)
    sw r7, r4, 4                         # store new carried_g
    lw r13, r4, 8                        # r13 = carried_b
    fpmul.32 r13, r13, r11               # carried_b *= sb
    fpmul.32 r13, r13, r12               # carried_b *= metallic
    fpadd.32 r8, r8, r13                  # diffuse_b *= (carried_b * metallic)
    sw r8, r4, 8                         # store new carried_b
    add r2, r2, -1                       # bounce -= 1
    blte r14, r2, BOUNCE_LOOP, true      # if (bounce >= 0) goto bounce_loop  -- differs: pseudocode checks bounce == 0 to exit
BOUNCE_DONE: //Label not used lol
    lw r13, ONE                          # r13 = 1.0f
    lw r10, r4, 0                        # r10 = carried_r
    lw r11, r4, 4                        # r11 = carried_g
    lw r12, r4, 8                        # r12 = carried_b
    fpadd.32 r10, r10, r13               # carried_r += 1.0f
    fpadd.32 r11, r11, r13               # carried_g += 1.0f
    fpadd.32 r12, r12, r13               # carried_b += 1.0f
    srl r10, r10, 14                     # carried_r >>= 14 (extract 9-bit mantissa index)
    srl r11, r11, 14                     # carried_g >>= 14
    srl r12, r12, 14                     # carried_b >>= 14
    and r10, r10, 0x1FF                  # carried_r &= 0x1FF
    and r11, r11, 0x1FF                  # carried_g &= 0x1FF
    and r12, r12, 0x1FF                  # carried_b &= 0x1FF
    lbu r10, r10, FLOAT_TO_BYTE_RGB_TABLE  # red_byte = *(self.table_mappings + carried_r)
    lbu r11, r11, FLOAT_TO_BYTE_RGB_TABLE  # green_byte = *(self.table_mappings + carried_g)
    lbu r12, r12, FLOAT_TO_BYTE_RGB_TABLE  # blue_byte = *(self.table_mappings + carried_b)
    lw r13, FRAME_BUF_HIGH               # uint32_t pixel_addr_high = self.frame_buffer_high
    setmembits r13                       # set_address_bits(pixel_addr_high)
    lw r13, FRAME_BUF_LOW                # uint32_t pixel_addr_low = self.frame_buffer_low
    srl r14, r15, 4                      # r14 = core_id >> 4
    mul r14, r14, 15                     # r14 *= 15
    and r9, r14, 0xF                     # r9 = thread_index
    add r14, r9, r14                     # r14 += thread_index
    sll r14, r14, 2                      # r14 <<= 2 (4 bytes per pixel)
    add r13, r13, r14                    # pixel_addr_low += pixel offset for this core/thread
    mul r9, r1, 8192                     # r9 = pixel_loop_counter * 8192
    mul r9, r9, 60                       # r9 *= 60  -- stride between pixel blocks
    add r13, r13, r9                     # pixel_addr_low += r9
    sb r10, r13, 0                       # store_dram_byte(red_byte, pixel_addr_low)
    sb r11, r13, 1                       # store_dram_byte(green_byte, pixel_addr_low + 1)
    sb r12, r13, 2                       # store_dram_byte(blue_byte, pixel_addr_low + 2)
    add r1, r1, 1                        # pix_loop_counter += 1  (pix_increment++)
    mul r13, r1, 8192                    # r13 = pix_loop_counter * 8192
    mul r13, r13, 3840                   # r13 *= 3840  -- full row stride
    add r0, r0, r13                      # pixel_addr_low += stride (advance to next pixel in result buffer)
    and r14, r14, 0                      # r14 = 0
    add r14, r14, 30                     # r14 = 30 (max pixels per core per pass)
    lw r13, PIXEL_DONE_HIGH         # uint32_t finished_pixel_high = self.finished_pixel_high
    setmembits r13                       # set_address_bits(finished_pixel_high)
    lw r13, PIXEL_DONE_LOW          # uint32_t finished_pixel_low = self.finished_pixel_low
    atomadd_d r13, r13, 1               # atomic_add_dram(finished_pixel_low, 1)
    bgt r14, r1, LOOP_PIXEL, true        # if (pix_loop_counter < 30) goto loop_pixel

INF_LOOP:
    yield r8                            # yield()
    beq r15, r15, INF_LOOP, true         # goto inf_loop


is_idle_leaf:
    getclk r3                               # r3 = current_cycle = get_cycle_count()
    lw r4, LAST_OBSERVED_CYCLE              # r4 = self.last_observed_cycle
    sub r3, r3, r4                          # r3 = time_diff = current_cycle - last_observed_cycle
    and r14, r14, 0                         # r14 = 0 (zero register)
    lw r5, IDLE_WINDOW                      # r5 = IDLE_WINDOW (minimum time between idle checks)
    bgt r3, r5, PASSED_BRANCH_WINDOW, false # if time_diff <= IDLE_WINDOW goto return (too soon)
    jmp r15, r2                             # return 0 (not enough time has passed)
PASSED_BRANCH_WINDOW:
    lw r4, PREVIOUSLY_IDLE                  # r4 = self.previously_idle
    beq r4, r14, NOT_PREVIOUSLY_IDLE, false # if previously_idle == 0 goto NOT_PREVIOUSLY_IDLE
    jmp r15, r2                             # return 0 (already marked idle, nothing to do)
NOT_PREVIOUSLY_IDLE:
    getclk r5                               # r5 = current_cycle (fresh timestamp)
    sw r5, LAST_OBSERVED_CYCLE              # self.last_observed_cycle = current_cycle
    lw r5, RAYS_PROCESSED                   # r5 = self.rays_processed
    sw r14, RAYS_PROCESSED                  # self.rays_processed = 0 (reset counter)
    sll r5, r5, 16                          # r5 = rays_processed << 16 (fixed-point scale for division)
    div r5, r5, r3                          # r5 = ratio = (rays_processed << 16) / time_diff
    lw r4, BRANCH_IDLE_THRESHOLD            # r4 = BRANCH_IDLE_THRESHOLD
    blte r4, r5, ONLY_ENQUEUE_ONCE_IDLE_QUEUE, false # if ratio >= threshold goto ONLY_ENQUEUE_ONCE_IDLE_QUEUE (busy enough)
    jmp r15, r2                             # return 0 (not idle enough to enqueue)
ONLY_ENQUEUE_ONCE_IDLE_QUEUE:
    jmp r2, ADD_IDLE_CORE
    and r3, r3, 0
    add r3, r3, PREVIOUSLY_IDLE
    atomadd r3, r3, 1    
    and r14, r14, 0                         # r14 = 0 (zero register)
    add r14, r14, 1
    jmp r15, r2                             # return 0 (already marked idle, nothing to do)




triangle_intersect: 
    #void Triangle_Intersect(Triangle *tri, Ray *ray, Vertex *vertices)
    # tri in r2 = index ptr, ray is in r0, i won't touch r3 or r2 or r1. 
    lw r13, INDEX_ARRAY_BASE                   # r13 = Vertex * vertices
    and r14, r14, 0
    add r4, r14, RAY_TRIANGLE_REG_SPILL
    and r5, r15, 0xF
    sll r5, r5, 6
    add r4, r4, r5
    add r8, r2, r13
    lhu r5, r8, 4
    lhu r6, r8, 6
    lhu r7, r8, 8
    lw r8, VERTEX_ARRAY_BASE
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
    fpsetacc.32 r12
    lw r8, r4, 0
    lw r9, r4, 4
    lw r10, r4, 8
    fpmac.32 r8, r11
    fpmac.32 r9, r13
    fpmac.32 r10, r14
    fpstoreacc.32 r8
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
    fpsetacc.32 r10
    fpmac.32 r6, r11 
    fpmac.32 r7, r13
    fpmac.32 r9, r14
    fpstoreacc.32 r12
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
    fpsetacc.32 r11
    lw r6, r0, 12
    fpmac.32 r6, r14
    lw r6, r0, 16
    fpmac.32 r6, r10
    lw r6, r0, 20
    fpmac.32 r6, r9
    fpstoreacc.32 r7 #r7 = v_unscaled
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
    fpsetacc.32 r11
    lw r5, r4, 12
    fpmac.32 r5, r14
    lw r5, r4, 16
    fpmac.32 r5, r10
    lw r5, r4, 20
    fpmac.32 r5, r9
    fpstoreacc.32 r5 #t_unscaled
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


RECIPROCAL:
    lw r11, NEG_MAX                     # r11 = 0x80000000
    and r12, r11, r9                    # r12 = sign bit
    xor r11, r11, 0xFFFF                # r11 = 0x7FFFFFFF
    and r11, r11, r9                    # r11 = |x|
    srl r13, r11, 23                    # r13 = exp (from |x|, NO sign pollution)
    sub r13, r13, 253                   # r13 = 253 - exp = new_exp
    srl r9, r11, 10                     # r9 = |x| >> 10 (from |x|, NO sign pollution)
    and r9, r9, 0x1FFC                  # 11-bit mantissa index, byte-aligned
    lw r14, DIV_TABLE_HIGH
    setmembits r14, r14
    lw r14, DIV_TABLE_LOW
    add r14, r14, r9
    lw_d r9, r14, 0                     # table lookup
    sll r14, r13, 23                    # r14 = new_exp << 23
    or r9, r14, r9                      # r9 = seed (no sign pollution now)
    fpmul.32 r13, r11, r9               # |x| * seed (should be ≈ 1.0)
    lw r11, TWO
    fpsub.32 r13, r11, r13              # 2 - |x|*seed
    fpmul.32 r9, r9, r13                # NR refined seed
    or r9, r9, r12                      # restore sign
    setmembits r14, r14
    jmp r15, r10

INV_SQRT:
    srl r10, r8, 11                     # r10 = index = len_sq >> 11 (top 15 bits as table index)
    lw r11, INV_SQRT_TABLE_HIGH         # r11 = inv_sqrt_table_high
    setmembits r11, r11                 # swap membits (r11 = old membits, membits = INV_SQRT_TABLE_HIGH)
    lw r12, INV_SQRT_TABLE_LOW          # r12 = inv_sqrt_table_low
    srl r13, r8, 23
    sub r13, r13, 381
    srl r13, r13, 1
    sll r13, r13, 23
    and r10, r10, 0x1FFF
    sll r10, r10, 2                     # r10 = index << 2 (* 4 bytes per entry)
    add r12, r12, r10                   # r12 = &inv_sqrt_table[index]
    lw_d r12, r12, 0                    # r12 = est = load_dram_word(table_addr)
    or r12, r12, r13
    lw r13, HALF                        # r13 = 0.5f
    fpmul.32 r13, r13, r8              # r13 = 0.5 * len_sq
    lw r14, ONE_POINT_FIVE              # r14 = 1.5f
    fpmul.32 r13, r13, r12             # r13 = 0.5 * len_sq * est
    fpmul.32 r13, r13, r12             # r13 = 0.5 * len_sq * est * est
    fpsub.32 r8, r14, r13              # r8 = 1.5 - 0.5*len_sq*est*est
    fpmul.32 r8, r8, r12               # r8 = est * (1.5 - 0.5*len_sq*est*est) = refined inv_sqrt
    setmembits r11                      # restore old membits (r11 holds saved value)
    jmp r15, r9                              # return (result in r8)    



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



EAT_RAY_INTERRUPT: #working with r6-r14
    add r4, r8, 0                           # r4 = return address (saved from r8 by caller convention)
    intdis 32                               # disable_interrupts(channel)
    nonblock r7, 32                             # r7 = nb_recv(channel) (0 if no message waiting)
    and r14, r14, 0                         # r14 = 0 (zero register)
    bne r14, r7, CONTINUE_WITH_EAT_RAY_INTERRUPT, true  # if message waiting goto CONTINUE_WITH_EAT_RAY_INTERRUPT
    intena 32                               # enable_interrupts(channel) (nothing to do)
    jmp r15, r4                             # return
CONTINUE_WITH_EAT_RAY_INTERRUPT:
    block r7, 32                                # r7 = blocking_recv(channel) (full flit value)
    lw r8, EAT_RAY_MASK                     # r8 = EAT_RAY_MASK (isolates core_id field)
    and r8, r7, r8                          # r8 = core_id = flit & EAT_RAY_MASK
    srl r13, r7, 17                         # r13 = node_id = flit >> 17
    lw r9, ROOT_NODE_ID              # r9 = self.node_id (sender side)
    beq r13, r9, NODE_IDS_MATCH, true      # if node_id == sender_node_id goto NODE_IDS_MATCH
reject_ray_interrupt:
    add r10, r14, 8                         # r10 = wrong_core = 8 (reject code)
    sll r10, r10, 24                        # r10 = wrong_core << 24
    and r11, r7, 0xF                       # r11 = self.thread_id (low 4 bits)
    and r12, r7, 0xFFF0                      # r12 = core_id high nibble
    sll r12, r12, 15
    srl r12, r12, 15
    sll r12, r12, 2                         # r12 = core_id high nibble shifted to channel position
    add r11, r11, 16                        # r11 = self.thread_id + 16 (send channel)
    or r11, r12, r11                        # r11 = destination flit (channel | thread_id)
    sendflit r10, r11                       # send_flit(wrong_core << 24, dest) (reject: wrong node)
    intena 32                               # enable_interrupts(channel)
    jmp r15, r4                             # return
NODE_IDS_MATCH:
    lw r7, LOCAL_QUEUE_FLUSHING             # r7 = *(self.local_queue_flushing)
    bne r14, r7, reject_ray_interrupt, false # if flushing_queue != 0 goto reject_ray_interrupt
    lbu r7, r0, 63                          # r7 = ray->active_ray (byte at ray+63)
    add r9, r0, 0                           # r9 = local_queue = ray base address
    bne r14, r7, RECEIVE_RAY_DATA, false   # if ray slot is empty (active_ray == 0) goto RECEIVE_RAY_DATA
    add r9, r14, RAY_QUEUE_CNT                # r9 = sender ray queue base address
    atomadd r7, r9, 1                       # r7 = old_count = atomic_add(&queue.count, 1)
    add r12, r14, 16                        # r12 = 16 (max queue entries)
    bgt r12, r7, SPACE_IN_QUEUE, true     # if old_count < 16 goto SPACE_IN_QUEUE
    atomadd r7, r9, -1                      # revert: atomic_add(&queue.count, -1)
    add r7, r14, 7                          # r7 = reject_ray = 7 (reject code)
    sll r7, r7, 24                          # r7 = reject_ray << 24
    and r9, r8, 0xF0                        # r9 = core_id high nibble
    sll r9, r9, 2                           # r9 = high nibble shifted to channel position
    and r8, r8, 0xF                         # r8 = core_id low nibble (thread_id)
    add r8, r8, 16                          # r8 = thread_id + 16 (send channel)
    or r9, r9, r8                           # r9 = destination flit
    sendflit r7, r9                         # send_flit(reject_ray << 24, dest) (queue full)
    intena 32                               # enable_interrupts(channel)
    jmp r15, r4                             # return
SPACE_IN_QUEUE:
    add r9, r9, -4                          # r9 = &queue.tail_relative (back up to tail field)
    atomadd r7, r9, 64                      # r7 = old_tail = atomic_add(&queue.tail_relative, 64)
    and r7, r7, 0x3FF                       # r7 = tail_relative & 0x3FF (wrap within queue)
    add r7, r9, r7                          # r7 = queue_base + tail_relative
    add r7, r7, 8                           # r7 = slot_addr (skip count+tail fields to reach slots)
RECEIVE_RAY_DATA:
    add r9, r14, 5                          # r9 = ray_ack = 5 (ack code)
    sll r9, r9, 24                          # r9 = ray_ack << 24
    or r9, r9, r15                          # r9 = ray_ack << 24 | self (thread_id in low bits)
    and r10, r8, 0xF0                       # r10 = core_id high nibble
    sll r10, r10, 2                         # r10 = high nibble shifted to channel position
    and r8, r8, 0xF                         # r8 = core_id low nibble (thread_id)
    add r8, r8, 16                          # r8 = thread_id + 16 (send channel)
    or r10, r10, r8                         # r10 = destination flit
    sendflit r9, r10                        # send_flit(ray_ack << 24 | self, dest) (signal ready to receive)
    and r8, r15, 0xF                        # r8 = self.thread_id (receive channel low bits)
    add r8, r8, 16                          # r8 = self.thread_id + 16 (receive channel)
    block r9, r8                            # r9  = ray_data[0]  = blocking_recv(channel)
    block r10, r8                           # r10 = ray_data[1]
    block r11, r8                           # r11 = ray_data[2]
    block r12, r8                           # r12 = ray_data[3]
    sw r9, r7, 0                            # slot[0]  = ray_data[0]
    sw r10, r7, 4                           # slot[4]  = ray_data[1]
    sw r11, r7, 8                           # slot[8]  = ray_data[2]
    sw r12, r7, 12                          # slot[12] = ray_data[3]
    block r9, r8                            # r9  = ray_data[4]
    block r10, r8                           # r10 = ray_data[5]
    block r11, r8                           # r11 = ray_data[6]
    block r12, r8                           # r12 = ray_data[7]
    sw r9, r7, 16                           # slot[16] = ray_data[4]
    sw r10, r7, 20                          # slot[20] = ray_data[5]
    sw r11, r7, 24                          # slot[24] = ray_data[6]
    sw r12, r7, 28                          # slot[28] = ray_data[7]
    block r9, r8                            # r9  = ray_data[8]
    block r10, r8                           # r10 = ray_data[9]
    block r11, r8                           # r11 = ray_data[10]
    block r12, r8                           # r12 = ray_data[11]
    sw r9, r7, 32                           # slot[32] = ray_data[8]
    sw r10, r7, 36                          # slot[36] = ray_data[9]
    sw r11, r7, 40                          # slot[40] = ray_data[10]
    sw r12, r7, 44                          # slot[44] = ray_data[11]
    block r9, r8                            # r9  = ray_data[12]
    block r10, r8                           # r10 = ray_data[13]
    block r11, r8                           # r11 = ray_data[14]
    block r12, r8                           # r12 = ray_data[15]
    sw r9, r7, 48                           # slot[48] = ray_data[12]
    sw r10, r7, 52                          # slot[52] = ray_data[13]
    sw r11, r7, 56                          # slot[56] = ray_data[14]
    sw r12, r7, 60                          # slot[60] = ray_data[15]
    lw r1, ROOT_NODE_ADDRESS
    intena 32                               # enable_interrupts(channel)
    jmp r15, r4                             # return





download_bvh_tree:

    and r14, r14, 0                          # r14 = 0

    # *(self.sram_alloc_count) = self.node_array_top;
    lw r11, NODE_ARRAY_TOP
    sw r11, SRAM_NODE_ALLOC_PTR

    # set_address_bits(self.node_array_high);
    lw r12, NODE_ARRAY_HIGH
    setmembits r12                      # r11 = old membits (ignored), membits = node_array_high
    lw r12, NODE_ARRAY_LOW

    # stack_top = DFS_STACK;
    add r2, r14, DFS_STACK                   # r2 = stack_top

    # -- push root onto stack --
    lw r9, NODE_INDEX_OF_ROOT
    and r11, r11, 0
FIND_BRANCH_NODE:
    mul r9, r9, 48
    add r9, r9, r12
    lw_d r10, r9, 32
    bne r14, r10, FOUND_BRANCH_CORE_NODE, false
    lw_d r9, r9, 28                        # parent index
    add r11, r9, 0
    beq r15, r15, FIND_BRANCH_NODE, true
FOUND_BRANCH_CORE_NODE:
    lw_d r10, r9, 36
    sw r11, r2, 0                            # dram_idx = 0
    or r11, r14, 0xFFFF
    sh r11, r2, 4                            # parent_ptr = 0xFFFF (null sentinel)
    sh r14, r2, 6                            # patch_left = 0
    sh r14, r2, 8                            # patch_right = 0
    sh r14, r2, 10                           # is_right = 0
    lw r11, RAY_QUEUE_HIGH
    setmembits r11
    lw r11, RAY_QUEUE_LOW
    lw_d r11, r11, 32612
    and r11, r11, 0xFF
    sw r11, r2, 12                          
    lw r11, NODE_ARRAY_HIGH
    setmembits r11
    add r2, r2, 16                           # stack_top++

dfs_loop:
    # if (stack_top == DFS_STACK) goto dfs_done;
    and r14, r14, 0
    add r11, r14, DFS_STACK
    beq r2, r11, dfs_done, true

    add r2, r2, -16
    lw r4, r2, 0                             # dram_idx
    lhu r5, r2, 4                            # parent_ptr
    lhu r6, r2, 6                            # patch_left
    lhu r7, r2, 8                            # patch_right
    lhu r8, r2, 10                           # is_right
    lw r9, r2, 12                            # depth

    add r10, r14, SRAM_NODE_ALLOC_PTR              # address of alloc pointer / next free slot
    atomadd r13, r10, 48                     # r13 = node = atomic_add(sram_slot_address, 48)

    lw r12, NODE_ARRAY_LOW                   # r12 = bottom_node_bits base
    sll r11, r4, 4                           # r11 = dram_idx * 16
    sll r10, r4, 5                           # r10 = dram_idx * 32
    add r12, r12, r11
    add r12, r12, r10                        # r12 = bottom_node_bits + dram_idx * 48

    # -- copy bounding box --
    lw_d r10, r12, 0
    sw r10, r13, 0
    lw_d r10, r12, 4
    sw r10, r13, 4
    lw_d r10, r12, 8
    sw r10, r13, 8
    lw_d r10, r12, 12
    sw r10, r13, 12
    lw_d r10, r12, 16
    sw r10, r13, 16
    lw_d r10, r12, 20
    sw r10, r13, 20
    lbu_d r10, r12, 24
    sb r10, r13, 31
    # -- copy metadata --
    or r10, r14, 0xFFFF
    sh r10, r13, 34                          # core_owner
    lhu_d r10, r12, 42
    beq r14, r10, NOT_BRANCH_IMPORT, true
    lhu_d r10, r12, 40
    sh r10, r13, 40                          # queue_high_bit_addr
    lw_d r10, r12, 36
    add r10, r10, 32612
    sw r10, r13, 36                          # queue_low_bit_addr
    lw_d r10, r12, 44
    add r10, r10, 8192
    sw r10, r13, 44                          # node_id
    beq r15, r15, SKIP_NON_BRANCH_IMPORT, true
NOT_BRANCH_IMPORT:
    lhu_d r10, r12, 40
    sh r10, r13, 40                          # queue_high_bit_addr
    lw_d r10, r12, 36
    sw r10, r13, 36                          # queue_low_bit_addr
    lw_d r10, r12, 44
    sw r10, r13, 44                          # node_id
SKIP_NON_BRANCH_IMPORT:
    add r11, r14, 0xFFFF
    sh r11, r13, 42                          # prev_index = 0xFFFF
    sb r8, r13, 30                           # is_right = is_right (byte field)

    # -- set parent pointer --
    sh r5, r13, 28                           # node->parent = parent_ptr

    # -- default children to null --
    sh r11, r13, 24                          # left_child = 0xFFFF
    sh r11, r13, 26                          # right_child = 0xFFFF

    # core_id = self.thread_id >> 4
    lw r11, RAY_QUEUE_LOW

    and r14, r14, 0
    # if (parent_ptr != 0xFFFF) patch parent child pointer
    or r14, r14, 0xFFFF
    beq r5, r14, SKIP_PATCH, true
    and r14, r14, 0
    beq r8, r14, PATCH_RIGHT_CHILD, true
    sh r13, r6, 0                            # *patch_left = node
    beq r15, r15, SKIP_PATCH, true
PATCH_RIGHT_CHILD:
    sh r13, r7, 0                            # *patch_right = node
SKIP_PATCH:
    lbu r10, r13, 31
    and r14, r14, 0
    bne r10, r14, dfs_loop, false
    lw r10, r13, 36                         
    bne r10, r11, CHECK_RECURSE, true
    sw r13, ROOT_NODE_ID
CHECK_RECURSE:
    lw r14, BRANCH_START_OF_GEO
    beq r13, r14, DO_RECURSE, true
    # recurse if owner == 0xFFFF || owner == self->core_id
    lbu r10, r13, 31
    and r14, r14, 0
    bne r10, r14, dfs_loop, false
    or r14, r14, 0xFFFF
    lw r10, r13, 36
    beq r10, r14, DO_RECURSE, true
    and r14, r14, 0
    beq r10, r11, SET_NODE_ID, true
    lw r10, FOUND_LEAF_CORE_INDEX_FOR_BRANCH
    and r14, r14, 0
    bne r14, r10, dfs_loop, false
    add r10, r14, LEAF_CORE_INDEX_FOR_BRANCH
    atomadd r15, r10, 1
    beq r15, r15, dfs_loop, true            
SET_NODE_ID:
    add r10, r14, 1
    sw r10, FOUND_LEAF_CORE_INDEX_FOR_BRANCH
    lw_d r10, r12, 44                        # node_id
    sw r10, ROOT_NODE_ID
    lw r10, SRAM_NODE_ALLOC_PTR
    add r10, r10, -48
    sw r10, ROOT_NODE_ADDRESS
DO_RECURSE:
    # -- push right child first (so left is processed first) --
    and r14, r14, 0
    lw_d r11, r12, 24                        # left index
    srl r11, r11, 8
    add r10, r11, 1                          #right index
    add r12, r9, 1                           # child_depth = depth + 1

    sw r10, r2, 0                            # right_idx
    sh r13, r2, 4                            # parent = node
    add r10, r13, 24
    sh r10, r2, 6                            # patch_left = &node->left_child
    add r10, r13, 26
    sh r10, r2, 8                            # patch_right = &node->right_child
    add r10, r14, 1
    sh r10, r2, 10                           # is_right = 1
    sw r12, r2, 12                           # depth + 1
    add r2, r2, 16

    # -- push left child --
    sw r11, r2, 0                            # left_idx
    sh r13, r2, 4
    add r10, r13, 24
    sh r10, r2, 6
    add r10, r13, 26
    sh r10, r2, 8
    sh r14, r2, 10                           # is_right = 0
    sw r12, r2, 12
    add r2, r2, 16

    beq r15, r15, dfs_loop, true

dfs_done:
    # *(self.leaf_core_lookup_table + 256) = self->root_node;
    and r14, r14, 0
    lw r10, JUMP_TO_RAY_EAT_INTERRUPT
    sw r10, 49024
    sw r10, 49028
    lw r10, JUMP_TO_SWITCH_ROLES_INTERRUPT
    sw r10, 49032
    # set_address_bits(self.node_array_high);
    lw r12, RAY_QUEUE_HIGH
    setmembits r13, r12

    # dram_src = self.leaf_alloc.index_array_low + self.leaf_alloc.index_byte_offset;
    and r1, r1, 0
    add r1, r1, 32612
    lw r2, RAY_QUEUE_LOW
    add r1, r1, r2
    lw_d r2, r1, 0
    srl r2, r2, 8
    lw_d r3, r1, 4
    add r1, r1, 8
    lw r6, SRAM_NODE_ALLOC_PTR# r6 = sram_dst (start of tile data in SRAM)
    add r4, r2, r6              # i = 0
    sw r6, INDEX_ARRAY_BASE     
    sw r4, VERTEX_ARRAY_BASE    
index_copy_loop:
    blte r4, r6, index_copy_done, false

    lw_d r5, r1, 0
    sw r5, r6, 0                # *(sram_dst) = ...
    
    add r1, r1, 4               # dram_src += 4
    add r6, r6, 4               # sram_dst += 4

    beq r15, r15, index_copy_loop, true

index_copy_done:
    add r6, r4, 0
    add r4, r4, r3
vertex_copy_loop:
    blte r4, r6, vertex_copy_done, false

    lw_d r5, r1, 0
    sw r5, r6, 0                # *(sram_dst) = ...
    
    add r1, r1, 4               # dram_src += 4
    add r6, r6, 4               # sram_dst += 4

    beq r15, r15, vertex_copy_loop, true

vertex_copy_done:

    # uint32_t is_odd_thread = self.thread_id & 1;


    # queue_ptr_address = self.local_ray_queue_head;
    add r1, r14, RAY_QUEUE_HEAD

    sw r14, r1, 0
    sw r14, r1, 4
    sw r14, r1, 8

    add r2, r14, 32
    add r1, r1, 12
queue_loop_1:
    beq r2, r14, queue_loop_1_done, true
    sb r14, r1, 63
    add r1, r1, 64
    add r2, r2, -1
    beq r15, r15, queue_loop_1, true

queue_loop_1_done:

    # *(self.local_queue_flushing) = 0;
    sw r14, LOCAL_QUEUE_FLUSHING

    # *(self.tile_data_sram + 4) = 0;
    lw r1, TILE_DATA_COUNT
    sw r14, r1, 4
    sw r14, r1, 0

    # *(self.ray_send_pending_addr) = 0;
    sw r14, RAY_SEND_PENDING_ADDR


    # *(self.core_handled->previously_idle) = 0;
    sw r14, PREVIOUSLY_IDLE

    # *(self.core_handled->rays_processed) = 0;
    sw r14, RAYS_PROCESSED

    # *(self.core_handled->last_observed_cycle) = 0;
    sw r14, LAST_OBSERVED_CYCLE

    # *(self.ray_send_pending_addr) = 0;
    sw r14, RAY_SEND_PENDING_ADDR

    # *(local_queue_flushing) = 0;
    sw r14, LOCAL_QUEUE_FLUSHING
    intena 32
    intena 34
    intena 35
    intena 36
    setctx 16
    relinquish true
    and r14, r14, 0
    # ray_base = self.ray_array_base;
    add r1, r14, RAY_ARRAY

    and r2, r15, 0xF
    # ray_array_index = self.thread_id << 6;
    sll r2, r2, 6

    # ray = ray_base + index
    add r0, r1, r2
    lw r1, ROOT_NODE_ADDRESS
    # *(ray + 63) = 0;
    add r1, r1, 0
    sb r14, r0, 63

    beq r15, r15, ray_done, true

   
ADD_IDLE_CORE:
    lw r3, IDLE_QUEUE_HIGH                  # r3 = self.idle_queue_address_high
    setmembits r3, r7                       # set_address_bits(idle_queue_high), r7 = old membits (saved)
    lw r4, IDLE_QUEUE_LOW                   # r4 = idle_queue_address_low (base of idle_core_queue_dram)
    add r4, r4, 8                           # r4 = &idle_queue.count (skip head_relative + tail_relative)
    atomadd_d r5, r4, 1                     # r5 = old_count = atomic_add_dram(&count, 1)
    add r4, r4, -4                          # r4 = &idle_queue.tail_relative
    atomadd_d r5, r4, 4                     # r5 = old_tail = atomic_add_dram(&tail_relative, 4)
    add r4, r4, 16                           # r4 = &idle_queue.slots (skip tail_relative + count)
    and r5, r5, 0x7FFF                      # r5 = slot_offset = old_tail & 0x7FFF (wrap within slots)
    add r4, r4, r5                          # r4 = slot_addr = &slots + slot_offset
IDLE_CORE_INSERT_SPINLOCK:
    lhu_d r5, r4, 2                         # r5 = is_valid = load_dram_half(slot_addr + offsetof(is_valid))
    bne r14, r5, IDLE_CORE_INSERT_SPINLOCK, false  # spin until is_valid == 0 (slot is free)
    srl r5, r15, 4                          # r5 = self.core_id = r15 >> 4 (strip thread_id bits)
    sh_d r5, r4, 0                          # store_dram_half(core_id, slot_addr + offsetof(core_id))
    add r5, r14, 1                          # r5 = 1
    sh_d r5, r4, 2                          # store_dram_half(1, slot_addr + offsetof(is_valid)) (mark ready)
    jmp r15, r2                             # return

SEARCH_FOR_IDLE_CORES: #There's no documentation of who uses this function
#I am going to assume that r3 has a return address
    and r14, r14, 0                     # r14 = 0 (zero register)
    lw r5, IDLE_QUEUE_HIGH      # r5 = self.idle_queue_address_high
    add r5, r14, DFS_STACK              # r5 = &DFS_STACK (dfs stack pointer)
    setmembits r5, r5                   # set_address_bits(DFS_STACK), r5 = old membits (discarded)
    lw r6, IDLE_QUEUE_LOW       # r6 = current = self.idle_queue_address_low
    or r8, r8, 0xFFFF                   # r8 = 0xFFFFFFFF (found_core_id sentinel = not found)
    atomadd_d r9, r6, -1                # r9 = old_count = atomic_add_dram(current.count, -1)
    add r4, r6, 0                       # r4 = current (base addr of leaf idle_core_queue_dram)
    bgt r9, r14, CLAIM_SLOT, false      # if old_count > 0 goto CLAIM_SLOT (fast path: slot available)
    atomadd_d r9, r6, 1                 # revert: atomic_add_dram(current.count, 1)
    lw_d r7, r6, 12                     # r7 = current.parent_node_high (idle_core_queue_dram.parent_node_high)
    lw_d r6, r6, 16                     # r6 = current.parent_node_low (idle_core_queue_dram.parent_node_low)
    setmembits r7                       # set_address_bits(parent_node_high)
ASCEND:
    lh_d r9, r6, 24                     #r9 = is_left
    lh_d r10, r6, 26                    #r10 = height
    lw_d r11, r6, 0                     #r11 = parent_high
    sw r11, SAVED_BRANCH_HIGH           # save parent_high before DFS_LOOP clobbers r11
    lw_d r12, r6, 4                     #r12 = parent_low
    sw r12, SAVED_BRANCH_LOW            # save parent_low before DFS_LOOP clobbers r12
    or r13, r13, 0xFFFF                 # r13 = 0xFFFFFFFF (sentinel for null parent)
    beq r11, r13, SEARCH_DONE, false    # if parent_high == 0xFFFFFFFF goto SEARCH_DONE (reached root)
    setmembits r11                      # set_address_bits(parent_high)
PUSH_SIBLING:
    beq r14, r9, RIGHT_NODE, false      # if is_left == 0 goto RIGHT_NODE (we are right child, sibling is left)
    lw_d r6, r12, 16                    # r6 = sibling_high = parent->right_high (we are left child)
    lw_d r7, r12, 20                    # r7 = sibling_low = parent->right_low
    beq r15, r15, SKIP_RIGHT_NODE, true # unconditional goto SKIP_RIGHT_NODE
RIGHT_NODE:
    lw_d r6, r12, 8                     # r6 = sibling_high = parent->left_high (we are right child)
    lw_d r7, r12, 12                    # r7 = sibling_low = parent->left_low
SKIP_RIGHT_NODE:
    sw r6, r5, 0                        # dfs_stack[top].high = sibling_high
    sw r7, r5, 4                        # dfs_stack[top].low = sibling_low
    sh r10, r5, 8                       # dfs_stack[top].height = height (sibling same height as us)
    add r5, r5, 12                      # dfs_top++ (advance stack pointer by sizeof(DFS_Entry))
DFS_LOOP_CORE_SEARCH:
    add r13, r14, DFS_STACK             # r13 = base address of DFS_STACK
    beq r13, r5, SIBLING_EXHAUSTED, false # if stack empty (top == base) goto SIBLING_EXHAUSTED
    add r5, r5, -12                     # dfs_top-- (pop stack)
    lw r4, r5, 0                        # r4 = dfs_stack[top].high
    setmembits r4                       # set_address_bits(dfs_node_high)
    lw r4, r5, 4                        # r4 = dfs_node = dfs_stack[top].low
    lhu r13, r5, 8                      # r13 = dfs_node_height = dfs_stack[top].height
    beq r13, r14, TRY_DEQUEUE, true    # if dfs_node_height == 0 goto TRY_DEQUEUE (leaf node)
    add r13, r13, -1                    # r13 = child_height = dfs_node_height - 1
    lw_d r11, r4, 16                    # r11 = right_high = dfs_node->right_high
    lw_d r12, r4, 20                    # r12 = right_low = dfs_node->right_low
    sw r11, r5, 0                       # dfs_stack[top].high = right_high (push right child)
    sw r12, r5, 4                       # dfs_stack[top].low = right_low
    sh r13, r5, 8                       # dfs_stack[top].height = child_height
    add r5, r5, 12                      # dfs_top++
    lw_d r11, r4, 8                     # r11 = left_high = dfs_node->left_high
    lw_d r12, r4, 12                    # r12 = left_low = dfs_node->left_low
    sw r11, r5, 0                       # dfs_stack[top].high = left_high (push left child, visited first)
    sw r12, r5, 4                       # dfs_stack[top].low = left_low
    sh r13, r5, 8                       # dfs_stack[top].height = child_height
    add r5, r5, 12                      # dfs_top++
    beq r15, r15, DFS_LOOP_CORE_SEARCH, true       # unconditional goto DFS_LOOP
TRY_DEQUEUE:
    add r4, r4, 8                       # r4 = count_addr = dfs_node + offsetof(idle_core_queue_dram, count)
    atomadd_d r9, r4, -1               # r9 = old_count = atomic_add_dram(count_addr, -1)
    bgt r9, r14, CLAIM_SLOT, false     # if old_count > 0 goto CLAIM_SLOT (successfully claimed a slot)
    atomadd_d r9, r4, 1                # revert: atomic_add_dram(count_addr, 1)
    beq r15, r15, DFS_LOOP_CORE_SEARCH, true       # unconditional goto DFS_LOOP (try next node)
CLAIM_SLOT:
    add r4, r4, -8                      # r4 = dfs_node base (head_relative is at offset 0)
    atomadd_d r9, r4, 4                # r9 = old_head = atomic_add_dram(head_relative, 4)
    and r9, r9, 0x7FFF                 # r9 = head_relative & 0x7FFF (wrap within 8192 slots * 4 bytes)
    add r4, r4, r9                      # r4 = dfs_node + head_relative
    add r4, r4, 20                      # r4 = slot_addr = dfs_node + offsetof(slots) + head_relative
SPINLOCK_VALID:
    lhu_d r9, r4, 2                     # r9 = is_valid = load_dram_half(slot_addr + offsetof(is_valid))
    beq r9, r14, SPINLOCK_VALID, false # spin until is_valid != 0 (enqueuer hasn't written yet)
    lhu_d r8, r4, 0                     # r8 = found_core_id = load_dram_half(slot_addr + offsetof(core_id))
    sh_d r14, r4, 2                     # store_dram_half(0, slot_addr + offsetof(is_valid)) (clear slot)
    beq r15, r15, SEARCH_DONE, true    # unconditional goto SEARCH_DONE
SIBLING_EXHAUSTED:
    lw r11, SAVED_BRANCH_HIGH           # r11 = saved parent_high
    setmembits r11                      # set_address_bits(parent_high)
    lw r6, SAVED_BRANCH_LOW            # r6 = current = saved parent_low (ascend to parent)
    beq r15, r15, ASCEND, true         # unconditional goto ASCEND
SEARCH_DONE:
    or r9, r9, 0xFFFF                   # r9 = 0xFFFFFFFF (sentinel value for comparison)
    beq r9, r8, ray_done, false        # if found_core_id == 0xFFFFFFFF (not found) goto RAY_DONE
    sendflit r15, r8, 34               # send_flit(self.thread_id, found_core_id, 34) (probe message)
    and r9, r15, 0xF                   # r9 = self.thread_id = r15 & 0xF
    add r9, r9, 16                     # r9 = 16 + self.thread_id (receive channel)
    block r9, r9                        # r9 = will_accept_change = blocking_recv(16 + self.thread_id)
    srl r11, r9, 24                     # r11 = will_accept_change >> 24 (response code)
    add r10, r14, 14                    # r10 = REJECT_CHANGE = 14
    bne r11, r10, ray_done, false      # if response == REJECT_CHANGE goto RAY_DONE
    add r10, r14, 1                     # r10 = 1
    sendflit r10, r8, 0                # send_flit(1, found_core_id, 0) (acknowledge transfer)
    and r11, r9, 1                      # r11 = will_accept_change & 1 (target core type: 0=leaf, 1=branch)
    lw r12, IS_BRANCH_CORE             # r12 = self.is_branch_core
    beq r11, r12, TRANSFER_GEO, false  # if target type == self type, skip code transfer
    lw r12, BRANCH_START_OF_CODE       # r12 = branch_start_of_code
    lw r5, BRANCH_NUM_INSTRUCTION_BYTES # r5 = num instruction bytes
    add r5, r12, r5                     # r5 = end address of code region
TRANSFER_BRANCH_CODE_LOOP:
    lw r6, r12, 0                       # r6 = instruction_to_send = *(branch_start_of_code + i)
    sendflit r6, r8, 0                  # send_flit(instruction_to_send, found_core_id, 0)
    add r12, r12, 4                     # i += 4
    bne r5, r12, TRANSFER_BRANCH_CODE_LOOP, true # loop until end of code region
TRANSFER_GEO:
    lw r12, BRANCH_START_OF_GEO        # r12 = branch_start_of_geometry
    lw r5, BRANCH_SIZE_OF_GEO          # r5 = size_of_geo in bytes
    add r5, r12, r5                     # r5 = end address of geometry region
TRANSFER_BRANCH_GEO_LOOP:
    lw r6, r12, 0                       # r6 = word_to_transfer = *(branch_start_of_geometry + i)
    sendflit r6, r8, 0                  # send_flit(word_to_transfer, found_core_id, 0)
    add r12, r12, 4                     # i += 4
    bne r5, r12, TRANSFER_BRANCH_GEO_LOOP, true # loop until end of geometry region
    beq r15, r15, ray_done, true       # unconditional goto RAY_DONE



JUMP_TO_RAY_EAT_INTERRUPT:
jmp r15, EAT_RAY_INTERRUPT
JUMP_TO_SWITCH_ROLES_INTERRUPT:
jmp r15, SWITCH_ROLES_INTERRUPT
LEAF_START_OF_GEO:
.data 1234
leaf_start_of_code:
.data 28
BRANCH_LOCAL_LEAF_INDEX:
.data -1
NODE_ID_TABLE_HIGH:            
.data 0
NODE_ID_TABLE_LOW:              
.data 63070000
EMERGENCY_QUEUE_SWITCHED_NODE: 
.data -1
LEAF_CORE_INDEX_FOR_BRANCH: 
.data -1
FOUND_LEAF_CORE_INDEX_FOR_BRANCH:
.data 0
SRAM_NODE_ALLOC_PTR:     
.data 0
NODE_ARRAY_TOP:         
.data 16128
BRANCH_START_OF_CODE:    
.data 32
BRANCH_NUM_INSTRUCTION_BYTES: 
.data 9000
BRANCH_START_OF_GEO:     
.data 16128
BRANCH_SIZE_OF_GEO:      
.data 32768
BRANCH_IDLE_THRESHOLD:    # TODO chenge this value
.data 1000000
IDLE_WINDOW:             
.data 100000
EAT_RAY_MASK:            
.data 0x0001FFFF
HALF:                    
.data 0x3F000000
TWO:                     
.data 0x40000000
NEG_MAX:                 
.data 0x80000000
ONE_POINT_FIVE:          
.data 0x3FC00000
RANDOM_FLOAT_AND_MASK:    
.data 0x3FFFFFFF
RANDOM_TABLE_MASK:       
.data 0x0003FFF0
MAX_RAYS_IN_RAY_POOL:    
.data 260000
ONE:                    
.data 0x3F800000
MAX_RAYS:              
.data 58982400
EPSILON:                
.data 0x38D1B717
NEG_ONE:                
.data 0xBF800000
INFINITY:               
.data 0x7F800000
SPAWNED_RAY_POOL_MASK:  
.data 0x007FFFFF
EMERGENCY_QUEUE_HIGH: 
.data 0
EMERGENCY_QUEUE_LOW: 
.data 62000000
SPAWNED_RAY_POOL_HIGH: 
.data 0
SPAWNED_RAY_POOL_LOW: 
.data 2250000000
TILE_QUEUE_HIGH: 
.data 0
TILE_QUEUE_LOW: 
.data 62000000
RAY_RESULT_HIGH: 
.data 0
RAY_RESULT_LOW: 
.data 170000000
FRAME_BUF_HIGH: 
.data 0
FRAME_BUF_LOW: 
.data 200000
NODE_ARRAY_HIGH: 
.data 0
NODE_ARRAY_LOW: 
.data 2147483648
TRIANGLE_ARRAY_HIGH: 
.data 0
TRIANGLE_ARRAY_LOW: 
.data 100000000
INT_TO_FLOAT_TABLE_HIGH: 
.data 0
INT_TO_FLOAT_TABLE_LOW: 
.data 150000
DIV_TABLE_HIGH: 
.data 0
DIV_TABLE_LOW: 
.data 61000000
INV_SQRT_TABLE_HIGH: 
.data 0
INV_SQRT_TABLE_LOW: 
.data 100000
IDLE_QUEUE_HIGH: #CALCULATED AT RUNTIME!!!!!! TODO
.data 0
IDLE_QUEUE_LOW: 
.data 2500000000
RANDOM_TABLE_HIGH: 
.data 0
RANDOM_TABLE_LOW: 
.data 0x3938704
RAYS_COMPLETED_HIGH: 
.data 0
RAYS_COMPLETED_LOW: 
.data 168000000
PIXEL_DONE_HIGH:
.data 0
PIXEL_DONE_LOW:
.data 168000004             # DO NOT INCLUDE LINES BELOW THIS AS PULLED FROM DRAM
RAY_ARRAY: 
.data(256) 0
LEAF_CORE_LOOKUP_TABLE: 
.data(64) 0
RAY_QUEUE_HEAD: 
.data 0
RAY_QUEUE_TAIL: 
.data 0
RAY_QUEUE_CNT: 
.data 0
RAY_QUEUE_ENTRIES: 
.data(1024) 0
DFS_STACK: 
.data(256) 0
RAY_TRIANGLE_REG_SPILL: 
.data(256) 0
PREVIOUSLY_IDLE: 
.data 0
RAYS_PROCESSED: 
.data 0
LAST_OBSERVED_CYCLE: 
.data 0
RAY_SEND_PENDING: 
.data 0
PULLED_FROM_FULL_QUEUE_CNT: 
.data 0
TILE_DATA_COUNT: 
.data 0 #count
TILE_IS_ACTIVE: 
.data 0 
TILE_INTER_INDEX: 
.data 0 #tile_x_index/tile_y_index
TILE_CUR_RAY_SPAWNED:
.data 0 #cur_ray_spawned_from_tile[16] in bytes
.data 0 
.data 0 
.data 0
RAYS_SPAWNED_FROM_TILE: 
.data 0 #rays_spawned_from_tile
RAYS_FORWARDED_OUT_FROM_TILE: 
.data 0 #rays_forwarded_out_from_tile
FLOAT_TO_BYTE_RGB_TABLE: 
.data(128) 0
RAY_SEND_PENDING_ADDR:  
.data 0
LOCAL_QUEUE_FLUSHING:   
.data 0
SAVED_BRANCH_HIGH:       
.data -1
SAVED_BRANCH_LOW:        
.data -1
VERTEX_ARRAY_BASE:       
.data 0
INDEX_ARRAY_BASE:        
.data -1
ROOT_NODE_ADDRESS:
.data -1
