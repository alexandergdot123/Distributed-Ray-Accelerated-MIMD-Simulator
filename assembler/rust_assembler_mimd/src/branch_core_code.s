.org 0x0028 //TODO

# ***RAY is R0, NODE is R1, R15 is reserved for context info and others**
    # initialize_core();
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
WAIT_FOR_FLUSH_READY_TWO:
    lw r9, LOCAL_QUEUE_FLUSHING
    switchctx
    beq r10, r9, WAIT_FOR_FLUSH_READY_TWO, true
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
    beq r10, r11, EAT_BRANCH_START_OF_CODE, true
    lw r11, leaf_start_of_code             # r11 = leaf_start_of_code    
    beq r15, r15, DONE_LOADING_CODE, true
EAT_BRANCH_START_OF_CODE:
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
    bne r10, r11, LEAF_START_OF_GEO, true
    lw r11, LEAF_START_OF_GEO              # r11 = leaf_start_of_geometry
    lw r12, LEAF_SIZE_OF_GEO
    beq r15, r15, DONE_LOADING_GEO, true
    lw r11, BRANCH_START_OF_GEO             # r11 = branch_start_of_geometry
    lw r12, BRANCH_SIZE_OF_GEO
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
















start_ray_traversal:
    # yield();
    yield r8                        # r8 = scratch for yield

    # if (ray->check_left & 1 != 0 && ray->check_right & 1 != 0)
    # {
    #     goto complete_ray;
    # }
    lw r2, r0, 44                   # r2 = ray->check_left
    and r4, r2, 1
    lw r3, r0, 48                   # r3 = ray->check_right
    and r5, r3, 1
    and r4, r4, r5                  # r4 = (check_left & 1) & (check_right & 1)
    and r5, r5, 0
    bne r4, r5, COMPLETE_RAY, true  # if both bits set goto complete_ray

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
    beq r6, r7, CHECK_BOTH_ZERO, true   # if r6 == 0, neither both set — check other cases

    # if (ray->ray_depth == 0) goto complete_ray;
    lbu r5, r0, 62                  # r5 = ray->ray_depth
    beq r5, r7, COMPLETE_RAY, true

    # TODO ASK ALEX ABOUT THIS
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

    # if (node->parent == 0) goto complete_ray;
    lhu r6, r1, 28                  # r6 = node->parent
    beq r6, r7, COMPLETE_RAY, true  # r7 = 0

    # node = node->parent;
    and r1, r1, 0
    add r1, r1, r6                  # r1 = node->parent (SRAM pointer)
    beq r15, r15, start_ray_traversal, true

CHECK_BOTH_ZERO:
    # else if (left_bitfield_check == 0 && right_bitfield_check == 0)
    or r6, r4, r9                   # r6 = left | right
    bne r6, r7, TRAVERSE_LEFT_OR_RIGHT, false       # both zero -> do AABB test

DO_AABB:
    # int hit = AABB_Intersect(node, ray);
    # TODO ask alex abt function call protocl\ol
    jmp r8, AABB_INTERSECT 
AABB_INTERSECT_RETURN:             
    # ASSUME r11 CONTAINS INFO FROM FUNCTION
    # if (hit)
    beq r11, r7, AABB_MISS, true

    # if (node->tri_count == 0) <- ASSUME RAY -> TRI_INDEX
    lbu r6, r0, 56                  # TODO confirm offset
    # ; beq r6, r7, IS_INTERNAL_NODE, true
    # ; beq r15, r15, IS_LEAF_NODE, true

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

    # uint16_t ray_send_pending_addr = self.ray_send_pending_addr;
    lhu r8, RAY_SEND_PENDING_ADDR    # r8 = self.ray_send_pending_addr

    # atomic_add(ray_send_pending_addr, 1)
    atomadd r9, r8, 1               # r9 = clobber

    # uint32_t is_thread_odd = self.thread_id & 1;
    # is_thread_odd += 32;
    # disable_interrupts(is_thread_odd)
    and r10, r15, 0xF               # r10 = thread_id
    and r11, r10, 1                 # r11 = is_thread_odd
    add r11, r11, 32                

    # disable_interrupts(is_thread_odd);
    intdis r11          

    # uint32_t request_word = (node->node_id << 17) | self.thread_id;
    lw r12, r1, 44                  # r12 = node->node_id TODO confirm offset
    sll r12, r12, 17
    and r10, r15, 0xF               # r10 = thread_id
    or r12, r12, r10                # r12 = request_word

    # send_packet(request_word, node->core_owner, 32);
    lhu r6, r1, 30                  # r6 = node->core_owner
    sendflit r6, r12, 32            # TODO confirm notation w/ Alex

# uint32_t sent = 0;
    and r3, r3, 0                   # r3 = sent = 0

SEND_RAY_LOOP:
    # uint32_t msg_available = nb_recv(self.thread_id + 16);
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
    srl r10, r12, 4
    sll r10, r10, 19
    srl r10, r10, 13
    and r11, r12, 0xF               # r11 = dest mailbox from ack msg low nibble
    or r10, r10, r11
    add r13, r0, 0                  # r13 = ray base ptr
    and r14, r14, 0                 # r14 = i = 0
RAY_SEND_LOOP:
    lw r9, r13, 0                   # r9 = ray word i
    sendflit r9, r10            # send word to core_owner on mailbox
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
    add r11, r9, 16224                # r11 = queue base + 536 (start of ray slots)
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
    nonblock r12, r10               # r12 = nb_recv(thread_id) -- data mailbox
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

    # *(slot - 16) = leaf_core_lookup_table->leaf_core_ptrs[leaf_node_index << 1]
    lw r9, r0, 40                   # r9 = ray->leaf_node_starting_point
    sll r9, r9, 1                   # r9 = leaf_node_index * 2 (uint16 array)
    lw r11, LEAF_CORE_LOOKUP_TABLE  # r11 = base address of lookup table in SRAM
    add r11, r11, r9                # r11 = &leaf_core_ptrs[leaf_node_index]
    lhu r9, r11, 0                  # r9 = leaf_core_data_addr
    sw r9, r13, -16                 # *(slot - 16) = leaf_core_data_addr
    and r13, r13, 0
    or r13, r13, 0xFFFF            # r13 = slot = 0xFFFF sentinel (low 16; full 32 not possible in imm)

CHECK_INTERRUPT_MAILBOX:
    and r10, r15, 0xF               # r10 = thread_id
    and r11, r10, 1                 # r11 = thread_id & 1
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

; IS_LEAF_NODE:
;     # bitfield = *(ray.check_left + node->is_right * 4)
;     lbu r6, r1, 26                  # node->is_right
;     sll r6, r6, 2
;     add r6, r0, r6
;     add r6, r6, 18
;     lw r8, r6, 0

;     lbu r5, r0, 62                  # ray->ray_depth
;     add r5, r5, -1
;     and r10, r10, 0
;     add r10, r10, 1
;     sll r10, r10, r5
;     or r8, r8, r10
;     sw r8, r6, 0

;     # tri loop
;     lhu r9, r1, 22                  # tri_start TODO confirm offset
;     lbu r10, r1, 30                 # tri_count
;     and r14, r14, 0
; TRI_LOOP:
;     beq r14, r10, TRI_LOOP_DONE, true
;     # Triangle_Intersect(tri_index=r9, ray=r0) -- call convention TBD
;     beq r15, r15, Triangle_Intersect, true
; TRI_INTERSECT_RETURN:
;     add r9, r9, 12
;     add r14, r14, 1
;     beq r15, r15, TRI_LOOP, true
; TRI_LOOP_DONE:
;     lbu r5, r0, 59
;     add r5, r5, -1
;     sb r5, r0, 59
;     lhu r1, r1, 28                  # node = node->parent
;     beq r15, r15, start_ray_traversal, true

AABB_MISS:
    lbu r5, r0, 59
    beq r5, r7, MISS_AT_ROOT, true
    lbu r6, r1, 31                  # node->is_right
    sll r6, r6, 2
    add r6, r0, r6
    add r6, r6, 18
    lw r8, r6, 0
    add r5, r5, -1
    and r10, r10, 0
    add r10, r10, 1
    sll r10, r10, r5
    or r8, r8, r10
    sw r8, r6, 0
    lbu r5, r0, 59
    add r5, r5, -1
    sb r5, r0, 59
    lhu r1, r1, 28
    beq r15, r15, start_ray_traversal, true

MISS_AT_ROOT:
    and r8, r8, 0
    add r8, r8, 0xFFFF              # 0xFFFF as 32-bit all-ones approx; need two stores
    sw r8, r0, 22                   # ray->check_right = 0xFFFFFFFF
    sw r8, r0, 18                   # ray->check_left  = 0xFFFFFFFF
    beq r15, r15, start_ray_traversal, true

TRAVERSE_LEFT_OR_RIGHT:
    # clear bits below current depth in check_left and check_right
    lbu r5, r0, 59
    add r5, r5, 1
    or r8, r8, 0xFFFF
    sll r8, r8, r5                  # mask = 0xFFFFFFFF << (ray_depth+1)... TODO: need NOT
    # workaround: xor with all-ones to get ~mask
    or r11, r11, 0xFFFF
    xor r8, r8, r11                 # r8 = zero_out_subtree
    lw r2, r0, 18
    and r2, r2, r8
    sw r2, r0, 18
    lw r3, r0, 22
    and r3, r3, r8
    sw r3, r0, 22

    # node = *(node.left_child + (left_bitfield_check != 0) * 2)
    and r6, r6, 0
    beq r4, r7, USE_LEFT, true      # r4=left_bitfield_check, r7=0
    add r6, r6, 2                   # offset by 2 if left already visited -> use right
USE_LEFT:
    add r1, r1, r6
    lhu r1, r1, 24

    lbu r5, r0, 59
    add r5, r5, 1
    sb r5, r0, 59
    beq r15, r15, start_ray_traversal, true

ray_done:
    lbu r9, r0, 63                  # ray->active_ray
    bne r9, r7, start_ray_traversal, true   # r7=0

    yield r8

    # check local ray queue
    and r10, r15, 0xF               # thread_id
    and r11, r10, 1                 # odd_thread
    and r12, r12, 0
    add r12, r12, 1036
    mul r11, r11, r12               # offset = odd_thread * 1036
    add r12, r7, LOCAL_RAY_QUEUE
    add r11, r11, r12               # offset += self.local_ray_queue

    add r12, r12, 8
    atomadd r14, r12, -1            # decrement count
    beq r7, r14, SLOT_AVAILABLE_LOCAL_RAY_QUEUE, true
    atomadd r14, r12, 1
    beq r15, r15, no_rays_available, true
SLOT_AVAILABLE_LOCAL_RAY_QUEUE:
    add r12, r12, -8
    atomadd r13, r12, 64            # slot = atomic_add(head, 64)
    and r13, r13, 0x3FF
    add r12, r12, r13               # queue_head + slot
    add r12, r12, 12

    # copy 16 words from local queue into ray slot r0
    lw r9, r12, 0 
    sw r9, r0, 0
    lw r9, r12, 4
    sw r9, r0, 4
    lw r9, r12, 8
    sw r9, r0, 8
    lw r9, r12, 12
    sw r9, r0, 12
    lw r9, r12, 16
    sw r9, r0, 16
    lw r9, r12, 20
    sw r9, r0, 20
    lw r9, r12, 24
    sw r9, r0, 24
    lw r9, r12, 28
    sw r9, r0, 28
    lw r9, r12, 32
    sw r9, r0, 32
    lw r9, r12, 36
    sw r9, r0, 36
    and r9, r9, 0
    add r9, r9, 128                 # leaf_node_starting_point hardcoded
    sw r9, r0, 40
    lw r9, r12, 44
    sw r9, r0, 44
    lw r9, r12, 48
    sw r9, r0, 48
    lw r9, r12, 52
    sw r9, r0, 52
    lw r9, r12, 56
    sw r9, r0, 56
    lw r9, r12, 60
    sw r9, r0, 60
    and r9, r9, 0
    sb r9, r12, 63                  # clear slot
    lw r1, r0, 40                   # node = ray->leaf_node_starting_point
    #ABOVE, WE ASSUME THE QUEUE HAS BEEN INSERTED WITH THE CORRECT SRAM ADDRESS TODO
    beq r15, r15, start_ray_traversal, true  

CHECK_ODD_FOR_NO_RAYS:
    and r11, r10, 1
    bne r11, r7, ray_done, true     # odd thread loops back

no_rays_available:
    # (continues in rest of main loop file)
    
    lw r3, LOCAL_QUEUE_FLUSHING          # uint8_t flushing_queue = *(self.local_queue_flushing)
    and r14, r3, 0                       # r14 = 0
    beq r3, r14, INF_LOOP, false         
    add r3, r14, LOCAL_QUEUE_FLUSHING
    atomadd r15, r3, 1
    beq r15, r15, INF_LOOP, true
NOT_FLUSHING_CORE:
    yield r8                             # yield()
    lw r3, RAY_QUEUE_HIGH                # int queue_address_high = self.ray_queue_address_high
    setmembits r3                        # set_address_bits(queue_address_high)
    lw r3, RAY_QUEUE_LOW                 # int queue_address_low = self.ray_queue_address_low
    and r14, r15, 1                      # r14 = self.is_branch_core (bit 0 of r15)
    mul r14, r14, 32612                  # r14 *= 16924 (offset to branch queue if branch core)
    add r3, r3, r14                      # queue_address_low += r14 (select correct queue)
    lw_d r4, r3, 8                       # int cur_ray_count = load_dram_word(queue_address_low + 8)
    blte r4, r14, DRAM_RAY_QUEUE_EMPTY, true  # if (cur_ray_count <= 0) goto DRAM_RAY_QUEUE_EMPTY
    add r5, r14, 256                     # r5 = 256
    blte r4, r5, RESET_PULLED_FROM_FULL_QUEUE_CNT, true  # if (cur_ray_count < 256) goto RESET_PULLED_FROM_FULL_QUEUE_CNT
    add r5, r14, PULLED_FROM_FULL_QUEUE_CNT  # r5 = &PULLED_FROM_FULL_QUEUE_CNT
    atomadd r5, r5, 1                    # uint32_t num_times_pulled = atomic_add(pulled_from_full_queue_address, 1)
    add r6, r14, 1                       # r6 = BRANCH_BUSY_THRESHOLD (1)
    blteu r6, r5, PULL_ELEM_FROM_DRAM_QUEUE, false  # if (num_times_pulled <= BRANCH_BUSY_THRESHOLD) goto PULL_ELEM_FROM_DRAM_QUEUE
    jmp r7, SEARCH_FOR_IDLE_CORES    # branch_core_ask_for_help()
RESET_PULLED_FROM_FULL_QUEUE_CNT:
    sw r14, PULLED_FROM_FULL_QUEUE_CNT  # *(self->pulled_from_full_queue_address) = 0
PULL_ELEM_FROM_DRAM_QUEUE:
    add r3, r3, 8                        # queue_address_low += 8 (point to count field)
    atomadd_d r4, r3, -1                 # int cur_ray_count_check = atomic_add_dram(queue_address_low + 8, -1)
    bgt r4, r14, STILL_ELEM_IN_QUEUE, true  # if (cur_ray_count_check > 0) goto STILL_ELEM_IN_QUEUE
    atomadd_d r4, r3, 1                  # atomic_add_dram(queue_address_low + 8, 1) -- undo decrement
    beq r15, r15, ray_done, true         # goto ray_done
STILL_ELEM_IN_QUEUE:
    add r3, r3, -8                       # queue_address_low -= 8 (back to base)
    atomadd_d r4, r3, 64                 # int head = atomic_add_dram(queue_address_low, 64) -- advance head
    add r3, r3, 16228                      # queue_address_low += 540 (skip head/count fields, +16 base + 524 padding? -- differs from pseudocode's +16)
    and r4, r4, 0x3FFF                   # head = head & 0x00003FFF
    add r4, r3, r4                       # queue_address_low = queue_address_low + head
WAIT_FOR_WRITE:
    lbu_d r5, r4, 63                     # int ready = load_dram_byte(queue_address_low + 63)
    beq r5, r14, WAIT_FOR_WRITE, false   # if (ready == 0) goto WAIT_FOR_WRITE  # r14=0
    lw_d r6, r4, 0                       # load ray word [0]
    lw_d r7, r4, 4                       # load ray word [4]
    lw_d r8, r4, 8                       # load ray word [8]
    lw_d r9, r4, 12                      # load ray word [12]
    lw_d r10, r4, 16                     # load ray word [16]
    lw_d r11, r4, 20                     # load ray word [20]
    lw_d r12, r4, 24                     # load ray word [24]
    lw_d r13, r4, 28                     # load ray word [28]
    sw_d r6, r0, 0                       # store to ray SRAM [0]
    sw_d r7, r0, 4                       # store to ray SRAM [4]
    sw_d r8, r0, 8                       # store to ray SRAM [8]
    sw_d r9, r0, 12                      # store to ray SRAM [12]
    sw_d r10, r0, 16                     # store to ray SRAM [16]
    sw_d r11, r0, 20                     # store to ray SRAM [20]
    sw_d r12, r0, 24                     # store to ray SRAM [24]
    sw_d r13, r0, 28                     # store to ray SRAM [28]
    lw_d r6, r4, 32                      # load ray word [32]
    lw_d r7, r4, 36                      # load ray word [36]
    lw_d r8, r4, 40                      # load ray word [40]
    lw_d r9, r4, 44                      # load ray word [44]
    lw_d r10, r4, 48                     # load ray word [48]
    lw_d r11, r4, 52                     # load ray word [52]
    lw_d r12, r4, 56                     # load ray word [56]
    lw_d r13, r4, 60                     # load ray word [60]
    sw_d r6, r0, 32                      # store to ray SRAM [32]
    sw_d r7, r0, 36                      # store to ray SRAM [36]
    sw_d r8, r0, 40                      # store to ray SRAM [40]
    sw_d r9, r0, 44                      # store to ray SRAM [44]
    sw_d r10, r0, 48                     # store to ray SRAM [48]
    sw_d r11, r0, 52                     # store to ray SRAM [52]
    sw_d r12, r0, 56                     # store to ray SRAM [56]
    sw_d r13, r0, 60                     # store to ray SRAM [60]
    sb_d r14, r4, 63                     # write_dram_byte(queue_address_low + 63, 0) -- mark slot as consumed
    add r6, r14, 1                       # r6 = 1
    sb r6, r0, 63                        # ray->active_ray = 1
    lw r1, r0, 40                        # node = ray->leaf_node_starting_point
    sll r1, r1, 1                        # r1 <<= 1 (index into lookup table, 2 bytes per entry)
    lhu r1, r1, LEAF_CORE_LOOKUP_TABLE   # r1 = LEAF_CORE_LOOKUP_TABLE[node] -- get target leaf core
    beq r15, r15, start_ray_traversal, true  # goto start_ray_traversal
DRAM_RAY_QUEUE_EMPTY:
    yield r8                             # yield()
    lw r3, RAY_QUEUE_HIGH                # (reload) queue_address_high
    setmembits r3                        # set_address_bits(queue_address_high)
    lw r3, RAY_QUEUE_LOW                 # (reload) queue_address_low
    lw_d r4, r3, 8                       # count = load_dram_word(emergency_queue_low + 8)
    blte r4, r14, CHECK_SPAWNED_RAY_POOL, true  # if (count <= 0) goto CHECK_SPAWNED_RAY_POOL
    add r3, r3, 8                        # emergency_queue_low += 8
    atomadd_d r4, r3, 1                  # uint32_t old_cnt = atomic_add_dram(emergency_queue_low, 1)
    blte r4, r14, EMERGENCY_SWITCH_BEGIN, false  # if (old_cnt > 0) goto EMERGENCY_SWITCH_BEGIN -- differs: pseudocode checks <= 0 to UNDO
    atomadd_d r4, r3, -1                 # atomic_add_dram(emergency_queue_low, -1) -- undo increment
    beq r15, r15, CHECK_SPAWNED_RAY_POOL, true  # goto CHECK_SPAWNED_RAY_POOL
EMERGENCY_SWITCH_BEGIN:
    add r3, r3, -8                       # emergency_queue_low -= 8 (back to base)
    atomadd_d r4, r3, 4                  # uint32_t byte_index = atomic_add_dram(emergency_queue_low, 4)
    and r4, r4, 0xFF                     # byte_index &= 0x000000FF
    add r3, r3, r4                       # emergency_queue_low += byte_index
    add r3, r3, 12                       # emergency_queue_low += 12
ENSURE_EMERGENCY_SLOT_READY_TWO:
    lhu_d r4, r3, 2                      # uint16_t is_ready = load_dram_byte(emergency_queue_low + 2)
    beq r4, r14, ENSURE_EMERGENCY_SLOT_READY_TWO, false  # if (is_ready == 0) goto ENSURE_EMERGENCY_SLOT_READY
    lhu_d r4, r3, 0                      # uint32_t new_node_id = load_dram_half(emergency_queue_low)
    add r5, r14, 1                       # r5 = 1
    sh_d r5, r3, 0                       # store_dram_byte(emergency_queue_low + 2, 0) -- mark slot consumed; differs: pseudocode writes to +2 but asm writes to +0
    add r5, r14, LOCAL_QUEUE_FLUSHING   
    atomadd r15, r5, 1
    add r6, r14, 16
EMERGENCY_SLOT_FLUSH_LOOP:
    lw r5, LOCAL_QUEUE_FLUSHING
    switchctx
    beq r5, r6, EMERGENCY_SLOT_FLUSH_LOOP, true
    sw r4, CORE_ID_TO_SWITCH_TO         # *(self.local_queue_flushing + 4) = new_node_id
    #TODO
    beq r15, r15, SWITCH_DRAM_QUEUE, true  # goto switch_dram_queue

CHECK_SPAWNED_RAY_POOL:
    jmp r2, IS_IDLE_BRANCH               # is_idle_branch()
    lw r2, SPAWNED_RAY_POOL_HIGH         # uint32_t spawned_ray_pool_high = self.spawned_ray_pool_high
    setmembits r2                        # set_address_bits(spawned_ray_pool_high)
    lw r2, SPAWNED_RAY_POOL_LOW          # uint32_t spawned_ray_pool_low = self.spawned_ray_pool_low
    lw_d r3, r2, 8                       # uint32_t count = load_dram_word(spawned_ray_pool_low + 8)
    blte r3, r14, GRAB_FROM_TILE, true   # if (count <= 0) goto grab_from_tile
    add r2, r2, 8                        # spawned_ray_pool_low += 8
    atomadd_d r3, r2, -1                 # uint32_t old_cnt = atomic_add(spawned_ray_pool_low, -1)
    bgt r3, r14, CONTINUE_REMOVING_FROM_SPAWNED_RAY_POOL, true  # if (old_cnt > 0) goto CONTINUE -- differs: pseudocode checks old_cnt <= 0 to undo
    atomadd_d r3, r2, 1                  # atomic_add(spawned_ray_pool_low, 1) -- undo decrement
    beq r15, r15, GRAB_FROM_TILE, true   # goto grab_from_tile
CONTINUE_REMOVING_FROM_SPAWNED_RAY_POOL:
    add r2, r2, -8                       # spawned_ray_pool_low -= 8 (back to base)
    atomadd_d r3, r2, 32                 # uint32_t head = atomic_add(spawned_ray_pool_low, 32)
    lw r4, SPAWNED_RAY_POOL_MASK         # r4 = 0x007FFFFF
    and r3, r3, r4                       # head &= head_mask
    add r2, r2, r3                       # spawned_ray_pool_low += head
ENSURE_RAY_POOL_SLOT_READY:
    lbu_d r3, r2, 43                     # uint8_t slot_ready = load_dram_byte(spawned_ray_pool_low + 43)
    beq r3, r14, ENSURE_RAY_POOL_SLOT_READY, false  # if (slot_ready == 0) goto ENSURE_RAY_POOL_SLOT_READY
    lw_d r3, r2, 12                      # value_one = load_dram_word(spawned_ray_pool_low + 12)  -- ox
    lw_d r4, r2, 16                      # value_two = load_dram_word(spawned_ray_pool_low + 16)  -- oy
    lw_d r5, r2, 20                      # value_three = load_dram_word(spawned_ray_pool_low + 20) -- oz
    lw_d r6, r2, 24                      # value_four = load_dram_word(spawned_ray_pool_low + 24)  -- dx
    lw_d r7, r2, 28                      # value_five = load_dram_word(spawned_ray_pool_low + 28)  -- dy
    lw_d r8, r2, 32                      # value_six = load_dram_word(spawned_ray_pool_low + 32)   -- dz
    lw_d r9, r2, 36                      # pix_xy = load_dram_word(spawned_ray_pool_low + 36)
    lh_d r10, r2, 40                     # meta = load_dram_word(spawned_ray_pool_low + 40)
    sb_d r14, r2, 43                     # store_dram_byte(spawned_ray_pool_low + 43, 0) -- mark slot consumed
    sw r3, r0, 0                         # ray->ox = value_one
    sw r4, r0, 4                         # ray->oy = value_two
    sw r5, r0, 8                         # ray->oz = value_three
    sw r6, r0, 12                        # ray->dx = value_four
    sw r7, r0, 16                        # ray->dy = value_five
    sw r8, r0, 20                        # ray->dz = value_six
    sw r9, r0, 52                        # ray->pix_xy = pix_xy  -- differs: pseudocode writes to pix_x field, asm writes to offset 52
    and r3, r10, 0xFF                    # ray->bounce_count = meta & 0xFF
    srl r4, r10, 8                       # r4 = meta >> 8
    and r4, r4, 0xFF                     # ray->light_id = (meta >> 8) & 0xFF
    sb r3, r0, 60                        # store ray->bounce_count
    sb r4, r0, 61                        # store ray->light_id
    lw r5, r0, 12                        # r5 = ray->dx
    lw r6, r0, 16                        # r6 = ray->dy
    lw r7, r0, 20                        # r7 = ray->dz
    fpmul.32 r8, r5, r5                  # float len_sq = dx * dx
    fpmul.32 r9, r6, r6                  # tmp = dy * dy
    fpmul.32 r10, r7, r7                 # tmp2 = dz * dz
    fpadd r8, r8, r9                      # len_sq += tmp
    fpadd r8, r8, r10                     # len_sq += tmp2
    jmp r9, INV_SQRT                     # float inv_len = fast_inv_sqrt(len_sq)  -- result in r8
    fpmul.32 r5, r5, r8                   # ray->dx = dx * inv_len
    fpmul.32 r6, r6, r8                   # ray->dy = dy * inv_len
    fpmul.32 r7, r7, r8                   # ray->dz = dz * inv_len
    add r9, r5, 0                        # r9 = ray->dx (move for RECIPROCAL call)
    jmp r10, RECIPROCAL                  # ray->inv_dx = reciprocal(ray->dx)  -- result in r9
    sw r9, r0, 24                        # store ray->inv_dx
    add r9, r6, 0                        # r9 = ray->dy
    jmp r10, RECIPROCAL                  # ray->inv_dy = reciprocal(ray->dy)
    sw r9, r0, 28                        # store ray->inv_dy
    add r9, r7, 0                        # r9 = ray->dz
    jmp r10, RECIPROCAL                  # ray->inv_dz = reciprocal(ray->dz)
    sw r9, r0, 32                        # store ray->inv_dz
    and r14, r14, 0                      # r14 = 0
    blte r14, r4, IS_NOT_SHADOW, false   # if (light_id == 0) goto IS_NOT_SHADOW  -- differs: pseudocode checks is_shadow != 0
    add r9, r8, 0                        # r9 = inv_len (for shadow ray t_max = 1/|d| = distance to light)
    jmp r10, RECIPROCAL                  # ray->t_max = reciprocal(inv_len)
    beq r15, r15, FINISH_SETTING_OTHER_RAY_FIELDS, true  # goto FINISH_SETTING_OTHER_RAY_FIELDS
IS_NOT_SHADOW:
    lw r2, INFINITY                      # r2 = 0x7F800000
    sw r2, r0, 36                        # ray->t_max = INFINITY
FINISH_SETTING_OTHER_RAY_FIELDS:
    and r14, r14, 0                      # r14 = 0
    sw r14, r0, 44                       # ray->check_left = 0
    sw r14, r0, 48                       # ray->check_right = 0
    add r13, r14, -1                     # r13 = 0xFFFFFFFF
    sw r13, r0, 56                       # ray->tri_index = 0xFFFFFFFF
    add r12, r14, 1                      # r12 = 1
    sb r12, r0, 63                       # ray->active_ray = 1
    sb r14, r0, 62                       # ray->ray_depth = 0  -- differs: pseudocode doesn't explicitly set ray_depth here
    lw r1, ROOT_NODE_ADDRESS             # node = self.sram_node_base_address
    beq r15, r15, start_ray_traversal, true  # goto start_ray_traversal
GRAB_FROM_TILE:
    lh r2, TILE_IS_ACTIVE                # uint16_t is_active = *(self.tile_data_sram->is_active)
    and r14, r14, 0                      # r14 = 0
    beq r2, r14, GET_NEW_TILE, false     # if (!is_active) goto get_new_tile
    lw r2, TILE_DATA_COUNT               # uint32_t tile_total_count = *(self.tile_data_sram->count)
    add r3, r14, 255                     # r3 = 255
    bgt r2, r3, SKIP_RETURNING_TILE, true  # if (tile_total_count > 255) goto skip_returning_tile
    lw r2, RAYS_SPAWNED_FROM_TILE        # uint32_t rays_spawned_from_tile = *(self.tile_data_sram->rays_spawned_from_tile)
    add r3, r14, 7                       # r3 = 7  # TODO, Threshold for when to return tile to queue
    bgt r3, r2, SPAWN_FROM_TILE, false   # if (rays_spawned_from_tile < 7) goto spawn_from_tile
    lw r4, RAYS_FORWARDED_OUT_FROM_TILE  # uint32_t rays_forwarded_out_from_tile = *(self.tile_data_sram->rays_forwarded_out_from_tile)
    sll r4, r4, 1                        # rays_forwarded_out_from_tile <<= 1
    bgt r2, r4, SPAWN_FROM_TILE, true    # if (rays_forwarded_out_from_tile < rays_spawned_from_tile) goto spawn_from_tile
GET_NEW_TILE:
    getowner                             # get_ownership()
    and r14, r14, 0                      # r14 = 0
    lw r2, TILE_QUEUE_HIGH               # uint32_t tile_pool_high = self.tile_pool_high
    setmembits r2                        # set_address_bits(tile_pool_high)
    lw r2, TILE_QUEUE_LOW                # uint32_t tile_pool_low = self.tile_pool_low
    lhu r3, TILE_IS_ACTIVE               # uint8_t tile_rays_spawned = *(self.tile_data_sram->is_active)  -- differs: pseudocode checks count not is_active
    bne r3, r14, SKIP_RETURNING_TILE, false  # if (tile_rays_spawned != 0) goto skip_returning_tile  -- differs: pseudocode checks count > 255
    lw r3, RAYS_SPAWNED_FROM_TILE        # r3 = rays_spawned_from_tile
    add r4, r14, 255                     # r4 = 255
    bgt r3, r4, SKIP_RETURNING_TILE, true  # if (rays_spawned_from_tile > 255) goto skip_returning_tile
    # SAI PLEASE WRITE HERE - BETSKI
    # tile_pool_low += 4;
    add r2, r2, 4
    # uint32_t bytes_relative_tail = atomic_add_dram(tile_pool_low, 4);
    atomadd_d r3, r2, 4     # r3 = bytes_relative_tail
    # tile_pool_low += 4;
    add r2, r2, 4
    # atomic_add_dram(tile_pool_low, 1);
    atomadd_d r4, r2, 1
    # bytes_relative_tail &= 0x0000FFFF;
    and r3, r3, 0xFFFF
    # tile_pool_low += bytes_relative_tail;
    add r2, r2, r3
loop_on_putting_tile_back:
    # tile_pool_low += 4;
    add r2, r2, 4
    # uint8_t is_valid = load_dram_byte(tile_pool_low + 3);
    lbu_d r3, r2, 3
    # if (is_valid != 0)
    # {
    #     goto loop_on_putting_tile_back;
    # }
    and r14, r14, 0
    bne r3, r14, loop_on_putting_tile_back, false
    # tile_y_index = self.tile_data_sram->tile_y_index  (offset 7 from struct base)
    lw r3, TILE_INTER_INDEX_Y          # r3 = tile_y_index
    # tile_y_index *= 160
    and r4, r4, 0
    add r4, r4, 160
    mul r3, r3, r4                       # r3 = tile_y_index * 160
    # tile_x_index = self.tile_data_sram->tile_x_index  (offset 6 from struct base)
    lw r4, TILE_INTER_INDEX_X          # r4 = tile_x_index
    # uint16_t tile_index = tile_y_index * 160 + tile_x_index
    add r3, r3, r4                       # r3 = tile_index
    # store_dram_half(tile_pool_low, tile_index)
    # r2 currently points at the slot base (is_valid byte is at +3)
    sh_d r3, r2, 0                       # store tile_index as half at slot base
    # uint8_t tile_rays_spawned = *(self.tile_data_sram->count)
    lbu r3, TILE_DATA_COUNT              # r3 = tile_rays_spawned (count)
    # tile_pool_low += 2
    add r2, r2, 2                        # r2 = slot base + 2
    # store_dram_byte(tile_pool_low, tile_rays_spawned)
    sb_d r3, r2, 0                       # store count byte at slot+2
    # tile_pool_low += 1
    add r2, r2, 1                        # r2 = slot base + 3
    # uint8_t one_small = 1
    # store_dram_byte(tile_pool_low, one_small)
    and r3, r3, 0
    add r3, r3, 1                        # r3 = 1
    sb_d r3, r2, 0                       # store is_valid = 1 at slot+3

SKIP_RETURNING_TILE: 
    
    ; add r2, r2, 8                        # tile_pool_low += 8 (point to count field)
    ; atomadd_d r15, r2, 1                 # atomic_add_dram(tile_pool_low, 1) -- increment tile count
    ; add r2, r2, -4                        # tile_pool_low -= 4 (point to tail field)
    ; atomadd_d r3, r2, 4                  # uint32_t bytes_relative_tail = atomic_add_dram(tile_pool_low, 4)
    ; add r4, r14, 255                     # r4 = 255
    ; sll r4, r4, 8                        # r4 = 255 << 8 = 0xFF00
    ; add r4, r4, 255                      # r4 = 0xFFFF
    ; and r3, r3, r4                       # bytes_relative_tail &= 0x0000FFFF
    ; add r2, r2, r3                       # tile_pool_low += bytes_relative_tail
    ; add r2, r2, 8                        # tile_pool_low += 8 (skip header)

    # uint32_t tile_pool_low = self.tile_pool_low;
    lw r2, TILE_QUEUE_LOW
    # uint32_t count = load_dram_word(tile_pool_low + 8);
    add r2, r2, 8
    lw r3, r2, 0
    add r2, r2, -8
    and r14, r14, 0
    # if (count <= 0) { goto skip_grabbing_tile_rays; }
    blte r3, r14, SKIP_GRABBING_TILE_RAYS, true
    # tile_pool_low += 8;
    add r2, r2, 8
    # uint32_t old_cnt = atomic_add(tile_pool_low, -1);
    atomadd_d r3, r2, -1
    # if (old_cnt <= 0) { atomic_add(tile_pool_low, 1); goto skip_grabbing_tile_rays; }
    bgt r3, r14, DONT_SKIP_GRABBING_TILE, false
    atomadd_d r3, r2, 1
    beq r15, r15, SKIP_GRABBING_TILE_RAYS, true
DONT_SKIP_GRABBING_TILE:
    # tile_pool_low -= 8;
    add r2, r2, -8
    # uint32_t head = atomic_add(tile_pool_low, 4);
    atomadd_d r3, r2, 4
    # uint32_t head_mask = 0x0000FFFF;
    add r4, r14, 0xFFFF
    # head &= head_mask;
    and r3, r3, r4
    # tile_pool_low += head;
    add r2, r2, r3

WAIT_FOR_TILE_SLOT_TO_OPEN:
    # slot_ready = load_dram_byte(tile_pool_low + 15)
    lbu_d r3, r2, 15                     
    # if (slot_ready == 0)
    # {
    #     goto ensure_tile_slot_ready;
    # }
    beq r3, r14, WAIT_FOR_TILE_SLOT_TO_OPEN, false

    # uint16_t tile_index = load_dram_half(tile_pool_low + 12);
    # uint16_t tile_cnt = load_dram_byte(tile_pool_low + 14);
    # tile_pool_low += 15;
    # store_dram_byte(tile_pool_low, 0);
    lhu_d r3, r2, 12                     # r3 = tile_index  (uint16 at +12)
    lbu_d r4, r2, 14                     # r4 = tile_cnt    (uint8  at +14)
    sb_d r14, r2, 15                     # is_valid = 0

    # self.tile_data_sram->count = tile_cnt;
    sw r4, TILE_DATA_COUNT               # store count

    # uint32_t tile_y_index = tile_index / 160;
    # uint32_t tile_x_index = tile_y_index * 160;
    # tile_x_index = tile_index - tile_x_index;
    and r5, r5, 0
    add r5, r5, 160
    div r5, r3, r5                       # r5 = tile_y_index = tile_index / 160
    mul r6, r5, 160                      # r6 = tile_y_index * 160  (temp for subtraction)
    sub r6, r3, r6                       # r6 = tile_x_index = tile_index - tile_y_index*160

    # self.tile_data_sram->tile_x_index = tile_x_index;
    # self.tile_data_sram->tile_y_index = tile_y_index;
    sw r6, TILE_INTER_INDEX_X                         # tile_x_index
    sw r5, TILE_INTER_INDEX_Y                         # tile_y_index

    # uint32_t zero = 0;
    # *(self.tile_data_sram->cur_ray_spawned_from_tile + 0) = zero;
    # *(self.tile_data_sram->cur_ray_spawned_from_tile + 4) = zero;
    # *(self.tile_data_sram->cur_ray_spawned_from_tile + 8) = zero;
    # *(self.tile_data_sram->cur_ray_spawned_from_tile + 12) = zero;
    sw r14, r2, 4
    sw r14, r2, 8
    sw r14, r2, 12
    sw r14, r2, 16

    # *(self.tile_data_sram->cur_ray_spawned_from_tile + self.thread_id) = 1;
    and r3, r15, 0xF                     # r3 = thread_id
    add r3, r3, 4                        # r3 = thread_id + 4 (offset into struct past x/y)
    add r3, r3, r2                       # r3 = &cur_ray_spawned_from_tile[thread_id]
    and r4, r4, 0
    add r4, r4, 1
    sb r4, r3, 0                         # cur_ray_spawned_from_tile[thread_id] = 1


    # self.tile_data_sram->rays_forwarded_out_from_tile = zero;
    # self.tile_data_sram->rays_spawned_from_tile = zero;
    sw r14, RAYS_FORWARDED_OUT_FROM_TILE # rays_forwarded_out_from_tile = 0
    sw r14, RAYS_SPAWNED_FROM_TILE       # rays_spawned_from_tile = 0

    setctx 16                            # set_ctx(16)
    relinquish false                     # relinquish_ownership(0)

    # Bro tf were you cooking below this????

; WAIT_FOR_TILE_SLOT_TO_OPEN:     # Assume this refers to "ensure_tile_slot_ready" in main_branch_loop
;     lbu r3, r2, 3                        # uint8_t is_valid = load_dram_byte(tile_pool_low + 3)
;     beq r3, r14, WAIT_FOR_TILE_SLOT_TO_OPEN, false  # if (is_valid == 0) goto loop_on_putting_tile_back
;     lhu_d r3, r2, 0                      # uint16_t tile_index -- load tile index (2 bytes)
;     lbu_d r4, r2, 2                      # uint16_t tile_cnt -- load tile count (1 byte)
;     sb_d r14, r2, 3                      # store_dram_byte(tile_pool_low, 0) -- mark slot as taken
;     sw r4, TILE_DATA_COUNT               # self.tile_data_sram->count = tile_cnt
;     div r5, r4, 160                      # uint32_t tile_y_index = tile_index / 160
;     mul r6, r5, 160                      # r6 = tile_y_index * 160
;     sub r6, r4, r6                       # uint32_t tile_x_index = tile_index - (tile_y_index * 160)
;     add r2, r14, TILE_INTER_INDEX        # r2 = &TILE_INTER_INDEX
;     sh r6, r2, 0                         # self.tile_data_sram->tile_x_index = tile_x_index
;     sh r5, r2, 2                         # self.tile_data_sram->tile_y_index = tile_y_index
;     sw r14, r2, 4                        # *(self.tile_data_sram->cur_ray_spawned_from_tile + 0) = 0
;     sw r14, r2, 8                        # *(self.tile_data_sram->cur_ray_spawned_from_tile + 4) = 0
;     sw r14, r2, 12                       # *(self.tile_data_sram->cur_ray_spawned_from_tile + 8) = 0
;     sw r14, r2, 16                       # *(self.tile_data_sram->cur_ray_spawned_from_tile + 12) = 0
;     and r3, r15, 0xF                     # r3 = self.thread_id (low 4 bits of r15)
;     add r2, r3, r2                       # r2 = &cur_ray_spawned_from_tile[thread_id]
;     add r4, r14, 1                       # r4 = 1
;     sb r4, r2, 4                         # *(self.tile_data_sram->cur_ray_spawned_from_tile + self.thread_id) = 1
;     sw r14, RAYS_FORWARDED_OUT_FROM_TILE # self.tile_data_sram->rays_forwarded_out_from_tile = 0
;     sw r14, RAYS_SPAWNED_FROM_TILE       # self.tile_data_sram->rays_spawned_from_tile = 0
;     setctx 16                            # set_ctx(16)
;     relinquish false                         # relinquish_ownership(0)
SPAWN_FROM_TILE:
    and r14, r14, 0                      # r14 = 0
    add r2, r14, TILE_DATA_COUNT         # uint16_t tile_data_sram_address = &(self.tile_data_sram->count)
    atomadd r3, r2, 1                    # uint32_t ray_num_from_tile = atomic_add(tile_data_sram_address, 1)
    add r4, r14, 255                     # r4 = 255
    bgt r3, r4, GET_NEW_TILE, false      # if (ray_num_from_tile > 255) goto get_new_tile
    add r2, r2, 40                       # tile_data_sram_address += 28 (point to rays_spawned counter)
    atomadd r15, r2, 1                   # atomic_add(tile_data_sram_address, 1) -- increment rays spawned
    add r2, r2, -40                       # tile_data_sram_address -= 28 
    and r4, r3, 0xF                      # uint32_t intra_tile_x = ray_num_from_tile & 0xF
    srl r5, r3, 4                        # uint32_t intra_tile_y = ray_num_from_tile >> 4
    lw r6, TILE_INTER_INDEX_X                        # uint32_t inter_tile_x = *(self.tile_data_sram->tile_x_index)
    lw r7, TILE_INTER_INDEX_Y                       # uint32_t inter_tile_y = *(self.tile_data_sram->tile_y_index)
    sll r6, r6, 4                        # inter_tile_x <<= 4
    sll r7, r7, 4                        # inter_tile_y <<= 4
    add r6, r6, r4                       # uint32_t pix_x = inter_tile_x + intra_tile_x
    add r7, r7, r5                       # uint32_t pix_y = inter_tile_y + intra_tile_y
    sh r6, r0, 52                        # ray->pix_x = pix_x
    sh r7, r0, 54                        # ray->pix_y = pix_y
    lw r2, INT_TO_FLOAT_TABLE_HIGH       # uint32_t itof_table_high = self.itof_table_high
    setmembits r2                        # set_address_bits(itof_table_high)
    lw r2, INT_TO_FLOAT_TABLE_LOW        # uint32_t itof_table_low = self.itof_table_low
    sll r6, r6, 2                        # uint32_t x_offset = pix_x << 2
    sll r7, r7, 2                        # uint32_t y_offset = pix_y << 2
    add r6, r2, r6                       # r6 = itof_table_low + x_offset
    add r7, r2, r7                       # r7 = itof_table_low + y_offset
    lw_d r3, r6, 0                       # float fpix_x = load_dram_word(itof_table_low + x_offset)
    lw_d r4, r7, 0                       # float fpix_y = load_dram_word(itof_table_low + y_offset)
    lw r5, CAM_X                         # float cam_cx = *(self.cam_x)  -- differs: pseudocode uses cam_cx here, asm uses CAM_X
    sw r5, r0, 0                         # ray->ox = cam_x  -- storing camera origin
    lw r6, CAM_Y                         # float cam_cy = *(self.cam_y)
    sw r6, r0, 4                         # ray->oy = cam_y
    lw r6, CAM_Z                         # float cam_cy = *(self.cam_y)
    sw r6, r0, 8                         # ray->oy = cam_y
    lw r5, CAM_CX        # principal point x for direction calc
    lw r6, CAM_CY        # principal point y
    lw r7, CAM_INV_FOCAL                 # float cam_inv_f = *(self.cam_inv_f)
    fpsub.32 r8, r3, r5                   # float dx = fpix_x - cam_cx
    fpsub.32 r9, r4, r6                   # float dy = fpix_y - cam_cy
    fpmul.32 r2, r8, r7                   # dx = dx * cam_inv_f
    fpmul.32 r3, r9, r7                   # dy = dy * cam_inv_f
    lw r4, NEG_ONE                       # float dz = -1.0f
    fpmul.32 r5, r2, r2                   # float len_sq = dx * dx
    fpmul.32 r6, r3, r3                   # tmp = dy * dy
    fpmul.32 r7, r4, r4                   # tmp2 = dz * dz
    fpadd.32 r5, r5, r6                   # len_sq += tmp
    fpadd.32 r9, r5, r7                   # len_sq += tmp2  (r9 = full len_sq)
    add r6, r8, 0                        # r6 = dx (save for after INV_SQRT clobbers r8)  -- differs: pseudocode doesn't need this save
    add r7, r9, 0                        # r7 = len_sq (save)
    jmp r9, INV_SQRT                     # float inv_len = fast_inv_sqrt(len_sq)  -- result in r8
    fpmul.32 r9, r8, r2                   # inv_dx intermediate: inv_len * dx
    jmp r10, RECIPROCAL                  # ray->inv_dx = reciprocal(inv_len * dx)  -- differs: pseudocode does reciprocal(dx) separately
    sw r9, r0, 24                        # store ray->inv_dx
    fpmul.32 r9, r8, r3                   # inv_dy intermediate
    jmp r10, RECIPROCAL                  # ray->inv_dy = reciprocal(inv_len * dy)
    sw r9, r0, 28                        # store ray->inv_dy
    fpmul.32 r9, r8, r4                   # inv_dz intermediate
    jmp r10, RECIPROCAL                  # ray->inv_dz = reciprocal(inv_len * dz)
    sw r9, r0, 32                        # store ray->inv_dz
    sw r2, r0, 12                        # ray->dx = dx (unnormalized -- differs: pseudocode normalizes before storing)
    sw r3, r0, 16                        # ray->dy = dy
    sw r4, r0, 20                        # ray->dz = dz
    lw r2, INFINITY                      # r2 = 0x7F800000
    sw r2, r0, 36                        # ray->t_max = INFINITY
    and r14, r14, 0                      # r14 = 0
    sw r14, r0, 44                       # ray->check_left = 0
    sw r14, r0, 48                       # ray->check_right = 0
    sw r14, r0, 60                       # ray->bounce_count = 0
    add r13, r14, 1                      # r13 = 1
    add r12, r14, -1                     # r12 = 0xFFFFFFFF
    sw r12, r0, 56                       # ray->tri_index = 0xFFFFFFFF
    sb r13, r0, 63                       # ray->active_ray = 1
    lw r1, ROOT_NODE_ADDRESS             # node = self.sram_node_base_address
    beq r15, r15, start_ray_traversal, true   # goto start_ray_traversal
SKIP_GRABBING_TILE_RAYS:
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

COMPLETE_RAY: #Only register in use is r0. everything else is fair game.
    lhu r1, r0, 54                      # r1 = ray->pix_y
    mul r1, r1, 2560                    # r1 = pix_y * 2560
    lhu r2, r0, 52                      # r2 = ray->pix_x
    add r1, r2, r1                      # r1 = pix_y * 2560 + pix_x = pix_index #I have the pix index in r2
    sll r1, r1, 8                       # r1 = pix_index << 8 (each pixel has 256 bytes of results)
    lw r2, RAY_RESULT_HIGH              # r2 = RAY_RESULT_HIGH
    setmembits r2                        # set_address_bits(result_addr_high)
    lw r2, RAY_RESULT_LOW               # r2 = result_addr_low
    add r1, r2, r1                      # r1 = result_addr_low + pix_index
    lbu r2, r0, 60                      # r2 = ray->bounce_count
    sll r2, r2, 6                       # r2 = bounce_count << 6 (each bounce has 64 bytes)
    add r1, r1, r2                      # r1 = result_addr + pix_index + bounce_offset #I now have the address of the bounce + shadow array (4 16 byte packs)
    lbu r2, r0, 61                      # r2 = ray->light_id
    and r14, r14, 0                     # r14 = 0
    bne r2, r14, SHADOW_RAY, true       # if (ray->light_id != 0) goto shadow_ray
    or r13, r13, 0xFFFF             # r13 = 0xFFFFFFFF
    lw r2, r0, 56                       # r2 = ray->tri_index
    bne r13, r2, RAY_HIT_A_TRI_IN_COMPLETE, true  # if (ray->tri_index != 0xFFFFFFFF) goto RAY_HIT_A_TRI_IN_COMPLETE
    sb r14, r0, 63                      # ray->active_ray = 0
    beq r15, r15, ray_done, true        # goto ray_done

RAY_HIT_A_TRI_IN_COMPLETE: #r0 = ray, r1 = addr, r14 = 0
    lw r3, TRIANGLE_ARRAY_HIGH          # r3 = self.triangle_address_high
    setmembits r3                        # set_address_bits(tri_addr_high)
    lw r3, TRIANGLE_ARRAY_LOW           # r3 = tri_addr_low
    sll r2, r2, 5                       # r2 = tri_index << 5 (* 32 bytes per triangle)
    add r2, r2, r3                      # r2 = tri_addr_low + tri_offset #r2 = tri index
    lw_d r3, r2, 0                      # r3 = tri_red = load_dram_word(tri_addr_low) #tri_red
    lw_d r4, r2, 4                      # r4 = tri_green #tri_green
    lw_d r5, r2, 8                      # r5 = tri_blue #tri_blue
    lw_d r6, r2, 12                     # r6 = tri_roughness #tri_roughness
    sw r6, r0, 40                       # ray->leaf_node_starting_point = roughness (temp storage)
    lw_d r6, r2, 16                     # r6 = tri_metallic
    lw_d r7, r2, 20                     # r7 = norm_x
    lw_d r8, r2, 24                     # r8 = norm_y
    lw_d r9, r2, 28                     # r9 = norm_z
    sw r9, r0, 32                       # ray->inv_dz = norm_z (temp storage)
    lw r10, RAYS_COMPLETED_HIGH         # r10 = RAY_RESULT_HIGH (restore membits to result buffer)
    setmembits r10                       # set_address_bits(result_addr_high)
    sw_d r3, r1, 0                      # store_dram_word(result_addr_low, tri_red)
    sw_d r4, r1, 4                      # store_dram_word(result_addr_low + 4, tri_green)
    sw_d r5, r1, 8                      # store_dram_word(result_addr_low + 8, tri_blue)
    sw_d r6, r1, 16                     # store_dram_word(result_addr_low + 16, tri_metallic) (note: skips offset 12 which is len_sq/tri_index union)
    lw r3, r0, 0                        # r3 = ray->ox //r3 = ox
    lw r4, r0, 12                       # r4 = ray->inv_dx
    lw r5, r0, 36                           # r5 = ray->t_max //r5 = tmax
    fpmul.32 r4, r4, r5                 # r4 = inv_dx * t_max... wait, this should be dx * t_max
    fpadd.32 r4, r4, r3                 # r4 = ox + dx * t_max = hit_x //r4 = hit_x
    lw r6, r0, 4                        # r6 = ray->oy //r6 = oy
    lw r10, r0, 16                      # r10 = ray->inv_dy... should be dy (offset 16)
    fpmul.32 r10, r10, r5               # r10 = dy * t_max
    fpadd.32 r10, r10, r6               # r10 = oy + dy * t_max = hit_y //r10 = hit_y
    lw r11, r0, 8                       # r11 = ray->oz //r11 - oz
    lw r12, r0, 20                      # r12 = ray->dz (offset 20)
    fpmul.32 r12, r5, r12               # r12 = t_max * dz
    fpadd.32 r12, r11, r12              # r12 = oz + dz * t_max = hit_z //r12 = hit_z
    # light 0 -> slot 1: ndotl = norm_x * (lx - hit_x) + norm_y * (ly - hit_y) + norm_z * (lz - hit_z)
    lw r13, LIGHT0_X                    # r13 = light0.x
    fpsub.32 r13, r13, r4               # r13 = lx - hit_x
    fpmul.32 r13, r13, r7               # r13 = (lx - hit_x) * norm_x
    lw r14, LIGHT0_Y                    # r14 = light0.y
    fpsub.32 r14, r14, r10              # r14 = ly - hit_y
    fpmul.32 r14, r14, r8               # r14 = (ly - hit_y) * norm_y
    fpadd.32 r13, r13, r14              # r13 = norm_x*(lx-hit_x) + norm_y*(ly-hit_y)
    lw r14, LIGHT0_Z                    # r14 = light0.z
    fpsub.32 r14, r14, r12              # r14 = lz - hit_z
    fpmul.32 r14, r14, r9               # r14 = (lz - hit_z) * norm_z
    fpadd.32 r13, r14, r13              # r13 = full ndotl for light 0
    and r14, r14, 0                     # r14 = 0 (for max with 0.0)
    fpminmax.32 r13, r13, r14, true     # ndotl = max(ndotl, 0.0)
    sw_d r13, r1, 28                    # store_dram_word(result_addr_low + 28, ndotl) -> slot 1 offset 12
    # light 1 -> slot 2
    lw r13, LIGHT1_X                    # r13 = light1.x
    fpsub.32 r13, r13, r4               # r13 = lx - hit_x
    fpmul.32 r13, r13, r7               # r13 = (lx - hit_x) * norm_x
    lw r14, LIGHT1_Y                    # r14 = light1.y
    fpsub.32 r14, r14, r10              # r14 = ly - hit_y
    fpmul.32 r14, r14, r8               # r14 = (ly - hit_y) * norm_y
    fpadd.32 r13, r13, r14              # r13 = norm_x*(lx-hit_x) + norm_y*(ly-hit_y)
    lw r14, LIGHT1_Z                    # r14 = light1.z
    fpsub.32 r14, r14, r12              # r14 = lz - hit_z
    fpmul.32 r14, r14, r9               # r14 = (lz - hit_z) * norm_z
    fpadd.32 r13, r14, r13              # r13 = full ndotl for light 1
    and r14, r14, 0                     # r14 = 0
    fpminmax.32 r13, r13, r14, true     # ndotl = max(ndotl, 0.0)
    sw_d r13, r1, 44                    # store_dram_word(result_addr_low + 44, ndotl) -> slot 2 offset 12
    # light 2 -> slot 3
    lw r13, LIGHT2_X                    # r13 = light2.x
    fpsub.32 r13, r13, r4               # r13 = lx - hit_x
    fpmul.32 r13, r13, r7               # r13 = (lx - hit_x) * norm_x
    lw r14, LIGHT2_Y                    # r14 = light2.y
    fpsub.32 r14, r14, r10              # r14 = ly - hit_y
    fpmul.32 r14, r14, r8               # r14 = (ly - hit_y) * norm_y
    fpadd.32 r13, r13, r14              # r13 = norm_x*(lx-hit_x) + norm_y*(ly-hit_y)
    lw r14, LIGHT2_Z                    # r14 = light2.z
    fpsub.32 r14, r14, r12              # r14 = lz - hit_z
    fpmul.32 r14, r14, r9               # r14 = (lz - hit_z) * norm_z
    fpadd.32 r13, r14, r13              # r13 = full ndotl for light 2
    and r14, r14, 0                     # r14 = 0
    fpminmax.32 r13, r13, r14, true     # ndotl = max(ndotl, 0.0)
    sw_d r13, r1, 60                    # store_dram_word(result_addr_low + 60, ndotl) -> slot 3 offset 12
    # spawn 3 shadow rays into spawned ray pool
    lw r13, SPAWNED_RAY_POOL_HIGH       # r13 = self.new_ray_pool_high
    setmembits r13                       # set_address_bits(new_ray_pool_high)
    lw r13, SPAWNED_RAY_POOL_LOW        # r13 = new_ray_pool_low
    add r13, r13, 8                     # r13 = new_ray_pool_low + 8 (point to count field)
ENSURE_SPACE_RAY_POOL:
    atomadd_d r11, r13, 3               # r11 = atomic_add_dram(count, 3) - reserve 3 slots
    lw r9, MAX_RAYS_IN_RAY_POOL         # r9 = 260000
    bgt r9, r11, ENOUGH_SPACE_IN_RAY_POOL, true  # if (cur_num_new_rays <= 260000) goto ENOUGH_SPACE
    atomadd_d r15, r13, -3              # undo reservation: atomic_add_dram(count, -3)
    beq r15, r15, ENSURE_SPACE_RAY_POOL, true     # goto ensure_space_ray_pool (spin)
ENOUGH_SPACE_IN_RAY_POOL:
    add r13, r13, -4                    # r13 = new_ray_pool_low + 4 (point to tail field)
    atomadd_d r11, r13, 32             # r11 = atomic_add_dram(tail, 32) - claim first slot
    lw r9, SPAWNED_RAY_POOL_MASK        # r9 = tail_mask
    and r11, r9, r11                    # r11 = tail & mask
    add r13, r11, r13                   # r13 = pool_base + tail_relative
    add r13, r13, 8                     # r13 = slot_base (skip head+tail fields)
    # wait for slot 0 to be free (active_ray byte at offset 31 must be 0)
WAIT_FOR_SLOT_0_TO_OPEN:
    lbu_d r11, r13, 31                  # r11 = load_dram_byte(slot_base + 31) - check if slot empty
    bne r11, r14, WAIT_FOR_SLOT_0_TO_OPEN, false  # while (slot_base[31] != 0) spin
    # store shadow ray 0 (light 0): origin = hit point, direction = light0 - hit
    sw_d r4, r13, 0                     # store_dram_word(slot_base, hit_x)
    sw_d r10, r13, 4                    # store_dram_word(slot_base + 4, hit_y)
    sw_d r12, r13, 8                    # store_dram_word(slot_base + 8, hit_z)
    lw r11, LIGHT0_X                    # r11 = light0.x
    fpsub.32 r11, r11, r4               # r11 = light0.x - hit_x = sdx
    sw_d r11, r13, 12                   # store_dram_word(slot_base + 12, sdx)
    lw r11, LIGHT0_Y                    # r11 = light0.y
    fpsub.32 r11, r11, r10              # r11 = light0.y - hit_y = sdy
    sw_d r11, r13, 16                   # store_dram_word(slot_base + 16, sdy)
    lw r11, LIGHT0_Z                    # r11 = light0.z
    fpsub.32 r11, r11, r12              # r11 = light0.z - hit_z = sdz
    sw_d r11, r13, 20                   # store_dram_word(slot_base + 20, sdz)
    lw r11, r0, 52                      # r11 = pix_x | (pix_y << 16) packed
    sw_d r11, r13, 24                   # store_dram_word(slot_base + 24, pix_xy)
    add r9, r14, 1                      # r9 = 1 (light_id for light 0)
    sb_d r9, r13, 29                    # store_dram_byte(slot_base + 29, light_id=1) (meta >> 8)
    lb r11, r0, 60                      # r11 = ray->bounce_count
    sb_d r11, r13, 28                   # store_dram_byte(slot_base + 28, bounce_count) (meta & 0xFF)
    sb_d r9, r13, 31                    # store_dram_byte(slot_base + 31, 1) - mark slot as ready
    # claim slot 1
    lw r11, SPAWNED_RAY_POOL_LOW        # r11 = pool base
    add r11, r11, 4                     # r11 = pool + 4 (tail field)
    atomadd_d r9, r11, 32              # r9 = atomic_add_dram(tail, 32) - claim slot 1
    add r11, r11, 8                     # r11 = pool + 12 (data start)
    lw r13, SPAWNED_RAY_POOL_MASK       # r13 = mask
    and r9, r9, r13                     # r9 = tail & mask
    add r13, r11, r9                    # r13 = slot_base for slot 1
WAIT_FOR_SLOT_1_TO_OPEN:
    lbu r11, r13, 31                    # r11 = load_dram_byte(slot_base + 31)
    bne r14, r11, WAIT_FOR_SLOT_1_TO_OPEN, false  # while (slot[31] != 0) spin
    # store shadow ray 1 (light 1)
    sw_d r4, r13, 0                     # store_dram_word(slot_base, hit_x)
    sw_d r10, r13, 4                    # store_dram_word(slot_base + 4, hit_y)
    sw_d r12, r13, 8                    # store_dram_word(slot_base + 8, hit_z)
    lw r11, LIGHT1_X                    # r11 = light1.x
    fpsub.32 r11, r11, r4               # r11 = light1.x - hit_x
    sw_d r11, r13, 12                   # store sdx
    lw r11, LIGHT1_Y                    # r11 = light1.y
    fpsub.32 r11, r11, r10              # r11 = light1.y - hit_y
    sw_d r11, r13, 16                   # store sdy
    lw r11, LIGHT1_Z                    # r11 = light1.z
    fpsub.32 r11, r11, r12              # r11 = light1.z - hit_z
    sw_d r11, r13, 20                   # store sdz
    lw r11, r0, 52                      # r11 = pix_xy
    sw_d r11, r13, 24                   # store pix_xy
    add r9, r14, 2                      # r9 = 2 (light_id for light 1)
    sb_d r9, r13, 29                    # store light_id = 2
    lb r11, r0, 60                      # r11 = bounce_count
    sb_d r11, r13, 28                   # store bounce_count
    add r9, r14, 1                      # r9 = 1 (ready marker)
    sb_d r9, r13, 31                    # mark slot as ready
    # claim slot 2
    lw r11, SPAWNED_RAY_POOL_LOW        # r11 = pool base
    add r11, r11, 4                     # r11 = pool + 4 (tail field)
    atomadd_d r9, r11, 32              # r9 = atomic_add_dram(tail, 32) - claim slot 2
    add r11, r11, 8                     # r11 = pool + 12
    lw r13, SPAWNED_RAY_POOL_MASK       # r13 = mask
    and r9, r9, r13                     # r9 = tail & mask
    add r13, r11, r9                    # r13 = slot_base for slot 2
WAIT_FOR_SLOT_2_TO_OPEN:
    lbu r11, r13, 31                    # r11 = load_dram_byte(slot_base + 31)
    bne r14, r11, WAIT_FOR_SLOT_2_TO_OPEN, false  # spin until slot empty
    # store shadow ray 2 (light 2)
    sw_d r4, r13, 0                     # store hit_x
    sw_d r10, r13, 4                    # store hit_y
    sw_d r12, r13, 8                    # store hit_z
    lw r11, LIGHT2_X                    # r11 = light2.x
    fpsub.32 r11, r11, r4               # r11 = light2.x - hit_x
    sw_d r11, r13, 12                   # store sdx
    lw r11, LIGHT2_Y                    # r11 = light2.y
    fpsub.32 r11, r11, r10              # r11 = light2.y - hit_y
    sw_d r11, r13, 16                   # store sdy
    lw r11, LIGHT2_Z                    # r11 = light2.z
    fpsub.32 r11, r11, r12              # r11 = light2.z - hit_z
    sw_d r11, r13, 20                   # store sdz
    lw r11, r0, 52                      # r11 = pix_xy
    sw_d r11, r13, 24                   # store pix_xy
    add r9, r14, 3                      # r9 = 3 (light_id for light 2)
    sb_d r9, r13, 29                    # store light_id = 3
    lb r11, r0, 60                      # r11 = bounce_count
    sb_d r11, r13, 28                   # store bounce_count
    add r9, r14, 1                      # r9 = 1 (ready marker)
    sb_d r9, r13, 31                    # mark slot as ready
    # if (ray->bounce_count > 2) { ray->active_ray = 0; goto ray_done; }
    add r13, r14, 3                     # r13 = 3 (max bounce threshold + 1)
    bne r13, r11, GENERATE_BOUNCE_RAY, true  # if bounce_count != 3 goto GENERATE_BOUNCE_RAY
    sb r14, r0, 63                      # ray->active_ray = 0
    lw r1, RAYS_COMPLETED_HIGH          # r1 = self.ray_result_addr_high
    setmembits r1                        # set_address_bits(finished_ray_high)
    lw r1, RAYS_COMPLETED_LOW           # r1 = self.ray_result_addr_low
    atomadd_d r15, r1, 1               # atomic_add(finished_ray_low, 1)
    beq r15, r15, ray_done, true        # goto ray_done

GENERATE_BOUNCE_RAY:
    # load 3 random floats from random table
    lw r1, RANDOM_TABLE_HIGH            # r1 = self.random_table_addr_high
    setmembits r1                        # set_address_bits(random_table_high)
    lw r1, RANDOM_TABLE_LOW             # r1 = random_table_low
    atomadd_d r2, r1, 16               # r2 = atomic_add_dram(random_table_low, 16) - advance index by 16 (not 12 as in C, TODO?)
    lw r3, RANDOM_TABLE_MASK            # r3 = mask
    and r2, r2, r3                      # r2 = index & mask
    add r1, r1, 4                       # r1 = random_table_low + 4 (skip count field)
    add r1, r1, r2                      # r1 = &random_table[index]
    lw_d r2, r1, 0                      # r2 = random1 (raw bits)
    lw_d r3, r1, 4                      # r3 = random2 (raw bits)
    lw_d r6, r1, 8                      # r6 = random3 (raw bits)
    # convert raw bits to float in [-0.5, 0.5):
    # mask mantissa to [1.0, 2.0) then subtract 1.5
    add r1, r14, 0x7F                   # r1 = 0x7F (exponent for 1.0)
    sll r1, r1, 23                      # r1 = 0x3F800000 (and_mask: clears sign+exp, keeps mantissa)
    lw r5, RANDOM_FLOAT_AND_MASK         # r5 = 0x3F800000 (or_mask: forces exponent to 127)
    or r2, r1, r2                      # r2 |= or_mask (clear top bits)
    or r3, r1, r3                      # r3 |= or_mask
    or r6, r1, r6                      # r6 |= or_mask
    and r2, r2, r5                       # r2 &= and_mask (force to [1.0, 2.0))
    and r3, r3, r5                       # r3 &= and_mask
    and r6, r6, r5                       # r6 &= and_mask
    lw r1, ONE_POINT_FIVE               # r1 = 1.5f
    fpsub.32 r2, r2, r1                 # random1 -= 1.5 -> [-0.5, 0.5)
    fpsub.32 r3, r3, r1                 # random2 -= 1.5
    fpsub.32 r6, r6, r1                 # random3 -= 1.5
    # update ray fields for bounce
    lb r5, r0, 60                       # r5 = ray->bounce_count
    add r5, r5, 1                       # bounce_count += 1
    sb r5, r0, 60                       # ray->bounce_count = bounce_count
    sb r14, r0, 62                      # ray->ray_depth = 0
    sw r14, r0, 44                      # ray->check_left = 0
    sw r14, r0, 48                      # ray->check_right = 0
    sw r14, r0, 40                      # ray->leaf_node_starting_point = 0 (will be set to 128 elsewhere TODO)
    or r1, r1, 0xFFFF                   # r1 = 0xFFFFFFFF (no hit sentinel) NOTE: r1 still holds 1.5, this sign-extends
    sw r1, r0, 56                       # ray->tri_index = 0xFFFFFFFF
    # update ray origin to hit point
    sw r4, r0, 0                        # ray->ox = hit_x
    sw r10, r0, 4                       # ray->oy = hit_y
    sw r12, r0, 8                       # ray->oz = hit_z
    # compute reflected direction: d' = d - 2*dot(d,n)*n
    lw r9, r0, 32                       # r9 = norm_z (stored earlier at offset 32)
    lw r4, r0, 12                       # r4 = ray->dx
    lw r10, r0, 16                      # r10 = ray->dy
    lw r12, r0, 20                      # r12 = ray->dz
    fpmul.32 r1, r7, r4                 # r1 = norm_x * dx
    fpmul.32 r5, r8, r10                # r5 = norm_y * dy
    fpmul.32 r11, r9, r12              # r11 = norm_z * dz
    fpadd.32 r1, r1, r5                 # r1 = norm_x*dx + norm_y*dy
    fpadd.32 r1, r1, r11               # r1 = dot(d, n)
    fpadd.32 r1, r1, r1                 # r1 = 2 * dot(d, n)
    fpmul.32 r11, r1, r7               # r11 = 2*dot * norm_x
    fpsub.32 r4, r4, r11               # r4 = dx - 2*dot*norm_x (reflected dx)
    fpmul.32 r11, r1, r8               # r11 = 2*dot * norm_y
    fpsub.32 r10, r10, r11             # r10 = dy - 2*dot*norm_y (reflected dy)
    fpmul.32 r11, r1, r9               # r11 = 2*dot * norm_z
    fpsub.32 r12, r12, r11             # r12 = dz - 2*dot*norm_z (reflected dz)
    # apply roughness perturbation: bdx = reflected_d + random * roughness
    lw r11, r0, 40                      # r11 = roughness (stored at offset 40 earlier)
    fpmul.32 r2, r2, r11               # random1 *= roughness
    fpmul.32 r3, r3, r11               # random2 *= roughness
    fpmul.32 r6, r6, r11               # random3 *= roughness
    fpadd.32 r4, r2, r4                 # bdx = reflected_dx + random1
    fpadd.32 r10, r3, r10              # bdy = reflected_dy + random2
    fpadd.32 r12, r6, r12              # bdz = reflected_dz + random3
    # normalize bdx, bdy, bdz via inv_sqrt
    fpmul.32 r1, r4, r4                 # r1 = bdx * bdx
    fpmul.32 r2, r10, r10              # r2 = bdy * bdy
    fpmul.32 r3, r12, r12               # r3 = bdz * bdz
    fpadd.32 r1, r1, r3                 # r1 = bdx^2 + bdz^2
    fpadd.32 r1, r1, r2                 # r1 = len_sq = bdx^2 + bdy^2 + bdz^2
    # save registers that INV_SQRT will clobber, set up call
    add r5, r8, 0                       # r5 = norm_y (save before INV_SQRT clobbers r8)
    add r6, r9, 0                       # r6 = norm_z (save before INV_SQRT clobbers r9)
    add r2, r10, 0                      # r2 = bdy (save)
    add r3, r12, 0                      # r3 = bdz (save)
    add r8, r1, 0                       # r8 = len_sq (INV_SQRT input)
    jmp r9, INV_SQRT                    # r8 = inv_sqrt(len_sq), returns in r8
    # r8 now = inv_sqrt result
    fpmul.32 r2, r2, r8                 # bdy *= inv_sqrt
    fpmul.32 r3, r3, r8                 # bdz *= inv_sqrt
    fpmul.32 r4, r4, r8                 # bdx *= inv_sqrt
    # check flip: if dot(bd, n) < 0, flip to keep ray above surface
    fpmul.32 r9, r7, r4                 # r9 = norm_x * bdx
    fpmul.32 r10, r2, r5                # r10 = norm_y * bdy (r5=norm_y saved above)
    fpmul.32 r11, r6, r3               # r11 = norm_z * bdz (r6=norm_z saved above)
    fpadd.32 r9, r9, r10               # r9 = norm_x*bdx + norm_y*bdy
    fpadd.32 r9, r9, r11               # r9 = check = dot(bd, n)
    and r10, r10, 0                     # r10 = 0 (for comparison with 0.0)
    fplt.32 r11, r9, r10                   # r11 = (check < 0.0)
    bne r11, r10, SKIP_FLIP, true       # if check >= 0 skip flip 
    # flip: bd -= 2*dot(bd,n)*n
    fpadd.32 r9, r9, r9                 # r9 = 2 * check
    fpmul.32 r10, r7, r9               # r10 = 2*check * norm_x
    fpmul.32 r11, r5, r9               # r11 = 2*check * norm_y
    fpmul.32 r12, r6, r9               # r12 = 2*check * norm_z
    fpsub.32 r4, r4, r10               # bdx -= 2*check*norm_x
    fpsub.32 r2, r2, r11               # bdy -= 2*check*norm_y
    fpsub.32 r3, r3, r12               # bdz -= 2*check*norm_z
SKIP_FLIP:
    sw r4, r0, 12                       # ray->dx = bdx
    sw r2, r0, 16                       # ray->dy = bdy
    sw r3, r0, 20                       # ray->dz = bdz
    lw r12, INFINITY                    # r12 = 0x7F7FFFFF (float_max)
    sw r12, r0, 36                      # ray->t_max = float_max
    # compute reciprocals for inv_dx, inv_dy, inv_dz
    add r9, r4, 0                       # r9 = bdx (RECIPROCAL input)
    jmp r10, RECIPROCAL                 # r9 = reciprocal(bdx)
    sw r9, r0, 24                       # ray->inv_dx = reciprocal(bdx)
    add r9, r2, 0                       # r9 = bdy
    jmp r10, RECIPROCAL                 # r9 = reciprocal(bdy)
    sw r9, r0, 28                       # ray->inv_dy = reciprocal(bdy)
    add r9, r3, 0                       # r9 = bdz
    jmp r10, RECIPROCAL                 # r9 = reciprocal(bdz)
    sw r9, r0, 32                       # ray->inv_dz = reciprocal(bdz)
    beq r15, r15, ray_done, true        # goto ray_done

SHADOW_RAY:
    sll r3, r2, 4                       # r3 = light_id << 4 (each shadow slot is 16 bytes)
    add r1, r1, r3                      # r1 = result_addr_low + shadow * 16 (advance to correct shadow slot)
    lw r4, r0, 56                       # r4 = ray->tri_index
    or r13, r14, 0xFFFF             # r13 = 0xFFFFFFFF
    beq r13, r4, SHADOW_RAY_MUST_BE_CALCULATED, true  # if (ray->tri_index == 0xFFFFFFFF) ray missed, calc lighting
    # ray hit something - shadow is blocked, store 1.0 as len_sq sentinel
    lw r4, ONE                          # r4 = 0x3F800000 = 1.0f
    sw_d r4, r1, 12                     # store_dram_word(result_addr_low + 12, 1.0) - blocked sentinel
    sb r14, r0, 63                      # ray->active_ray = 0
    beq r15, r15, ray_done, true        # goto ray_done
SHADOW_RAY_MUST_BE_CALCULATED:
    # ray missed (unobstructed) - compute light contribution
    lw_d r6, r1, 12                     # r6 = ndotl = load_dram_word(result_addr_low + 12)
    add r2, r2, -1                      # shadow = light_id - 1 (0-indexed)
    mul r2, r2, 24                      # shadow *= 24 (bytes per light struct)
    add r2, r2, LIGHT0_X               # r2 = &light_array[shadow] (base of this light)
    # load color (offsets 12,16,20 = r,g,b given our x,y,z,r,g,b layout)
    lw r3, r2, 12                       # r3 = light_r
    lw r4, r2, 16                       # r4 = light_g
    lw r5, r2, 20                       # r5 = light_b
    fpmul.32 r3, r3, r6                 # light_r *= ndotl
    fpmul.32 r4, r4, r6                 # light_g *= ndotl
    fpmul.32 r5, r5, r6                 # light_b *= ndotl
    sw_d r3, r1, 0                      # store_dram_word(result_addr_low, light_r)
    sw_d r4, r1, 4                      # store_dram_word(result_addr_low + 4, light_g)
    sw_d r5, r1, 8                      # store_dram_word(result_addr_low + 8, light_b)
    # compute squared distance from hit point to light position
    lw r3, r2, 0                        # r3 = light_x (position, offset 0)
    lw r4, r2, 4                        # r4 = light_y
    lw r5, r2, 8                        # r5 = light_z
    lw r6, r0, 0                        # r6 = ray->ox (hit point origin)
    lw r7, r0, 4                        # r7 = ray->oy
    lw r8, r0, 8                        # r8 = ray->oz
    fpsub.32 r3, r3, r6                 # r3 = light_x - ox
    fpsub.32 r4, r4, r7                 # r4 = light_y - oy
    fpsub.32 r5, r5, r8                 # r5 = light_z - oz
    fpmul.32 r3, r3, r3                 # r3 = (light_x - ox)^2
    fpmul.32 r4, r4, r4                 # r4 = (light_y - oy)^2
    fpmul.32 r5, r5, r5                 # r5 = (light_z - oz)^2
    fpadd.32 r3, r3, r4                 # r3 = dx^2 + dy^2
    fpadd.32 r3, r3, r5                 # r3 = len_sq = dx^2 + dy^2 + dz^2
    sw_d r3, r1, 12                     # store_dram_word(result_addr_low + 12, len_sq)
    sb r14, r0, 63                      # ray->active_ray = 0
    lw r1, RAYS_COMPLETED_HIGH          # r1 = self.ray_result_addr_high
    setmembits r1                        # set_address_bits(finished_ray_high)
    lw r1, RAYS_COMPLETED_LOW           # r1 = self.ray_result_addr_low
    atomadd_d r15, r1, 1               # atomic_add(finished_ray_low, 1)
    beq r15, r15, ray_done, true        # goto ray_done

RECIPROCAL:
    lw r11, NEG_MAX                     # r11 = 0x80000000
    and r12, r11, r9                    # r12 = sign bit of x (sign in r12)
    xor r11, r11, 0xFFFF                # r11 = 0x7FFFFFFF (sign extends 0xFFFF to flip all 32 bits)
    and r11, r11, r9                    # r11 = x & 0x7FFFFFFF = |x| (original magnitude in r11)
    srl r13, r9, 23                     # r13 = exp = x >> 23 (biased exponent)
    sub r13, r13, 254                   # r13 = new_exp = 254 - exp
    srl r9, r9, 12                      # r9 = x >> 12 (top mantissa bits for table index)
    and r9, r9, 0x1FFC                  # r9 = index = (x >> 12) & 0x7FF, pre-shifted by 2 (index in r9)
    lw r14, DIV_TABLE_HIGH              # r14 = div_table_high
    setmembits r14, r14                 # swap membits with r14 (r14 = old membits, membits = DIV_TABLE_HIGH)
    lw r14, DIV_TABLE_LOW               # r14 = div_table_low
    add r14, r14, r9                    # r14 = &div_table[index]
    lw_d r9, r14, 0                     # r9 = reciprocal_lookup = load_dram_word(table_addr)
    sll r14, r13, 23                    # r14 = new_exp << 23
    or r9, r14, r9                      # r9 = reciprocal_lookup |= new_exp (assemble initial estimate)
    sub r13, r13, 254                   # r13 = 254 - new_exp = original exp (recover for NR)
    fpmul.32 r13, r11, r9              # r13 = t = original_magnitude * r0 (NR: x * r0)
    lw r11, TWO                         # r11 = 2.0f
    fpsub.32 r13, r11, r13             # r13 = 2 - t = 2 - x*r0
    fpmul.32 r9, r9, r13               # r9 = r0 * (2 - x*r0) (one NR step, result in r9)
    or r9, r9, r12                      # r9 |= sign (restore sign bit)
    setmembits r14, r14                 # restore membits
    jmp r15, r10                        # return (result in r9)

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

EAT_RAY_INTERRUPT: #working with r6-r14
    add r4, r8, 0                           # r4 = return address (saved from r8 by caller convention)
    and r6, r15, 1                          # r6 = self.thread_id & 1 (is_odd_thread)
    add r6, r6, 32                          # r6 = interrupt channel = 32 + is_odd_thread
    intdis r6                               # disable_interrupts(channel)
    nonblock r7, r6                             # r7 = nb_recv(channel) (0 if no message waiting)
    and r14, r14, 0                         # r14 = 0 (zero register)
    bne r14, r7, CONTINUE_WITH_EAT_RAY_INTERRUPT, true  # if message waiting goto CONTINUE_WITH_EAT_RAY_INTERRUPT
    intena r6                               # enable_interrupts(channel) (nothing to do)
    jmp r15, r4                             # return
CONTINUE_WITH_EAT_RAY_INTERRUPT:
    block r7, r6                                # r7 = blocking_recv(channel) (full flit value)
    lw r8, EAT_RAY_MASK                     # r8 = EAT_RAY_MASK (isolates core_id field)
    and r8, r7, r8                          # r8 = core_id = flit & EAT_RAY_MASK
    srl r13, r7, 17                         # r13 = node_id = flit >> 17
    lw r9, ROOT_NODE_ID_SENDER              # r9 = self.node_id (sender side)
    beq r13, r9, NODE_IDS_MATCH, true      # if node_id == sender_node_id goto NODE_IDS_MATCH
    lw r9, ROOT_NODE_ID_RECEIVER            # r9 = self.node_id (receiver side)
    beq r13, r9, NODE_IDS_MATCH, true      # if node_id == receiver_node_id goto NODE_IDS_MATCH
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
    intena r6                               # enable_interrupts(channel)
    jmp r15, r4                             # return
NODE_IDS_MATCH:
    lw r7, LOCAL_QUEUE_FLUSHING             # r7 = *(self.local_queue_flushing)
    bne r14, r7, reject_ray_interrupt, false # if flushing_queue != 0 goto reject_ray_interrupt
    lbu r7, r0, 63                          # r7 = ray->active_ray (byte at ray+63)
    add r9, r0, 0                           # r9 = local_queue = ray base address
    bne r14, r7, RECEIVE_RAY_DATA, false   # if ray slot is empty (active_ray == 0) goto RECEIVE_RAY_DATA
    lw r10, ROOT_NODE_ID_SENDER             # r10 = sender node id
    beq r13, r10, SENDER_QUEUE_EAT_RAY_INTERRUPT, true  # if node_id == sender goto SENDER_QUEUE
    add r9, r14, LOCAL_RAY_QUEUE              # r9 = receiver ray queue base address
    add r9, r9, 524
    beq r15, r15, CHECK_IF_SPACE_IN_QUEUE, true  # unconditional goto CHECK_IF_SPACE_IN_QUEUE
SENDER_QUEUE_EAT_RAY_INTERRUPT: 
    add r9, r14, LOCAL_RAY_QUEUE                # r9 = sender ray queue base address
CHECK_IF_SPACE_IN_QUEUE:
    add r9, r9, 8                           # r9 = &queue.count (skip head and tail fields)
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
    intena r6                               # enable_interrupts(channel)
    jmp r15, r4                             # return
SPACE_IN_QUEUE:
    add r9, r9, -4                          # r9 = &queue.tail_relative (back up to tail field)
    atomadd r7, r9, 64                      # r7 = old_tail = atomic_add(&queue.tail_relative, 64)
    and r7, r7, 0x3FF                       # r7 = tail_relative & 0x3FF (wrap within queue)
    add r7, r9, r7                          # r7 = queue_base + tail_relative
    add r7, r7, 8                           # r7 = slot_addr (skip head+tail fields to reach slots)
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
    intena r6                               # enable_interrupts(channel)
    jmp r15, r4                             # return


IS_IDLE_BRANCH:
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
    add r6, r14, PREVIOUSLY_IDLE            # r6 = &PREVIOUSLY_IDLE
    atomadd r6, r6, 1                       # atomic_add(&previously_idle, 1)
    beq r6, r14, ADD_IDLE_CORE, true       # if old_value == 0 goto ADD_IDLE_CORE
    jmp r15, r2                             # return 
    
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
    sw r5, SEARCH_FOR_IDLE_CORES_STORAGE # save idle_queue_address_high to scratch storage
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



download_bvh_tree:
    # NOTE:
    # The current C snippet has two real problems:
    #   1) the root push in the C is inconsistent with the stack growth direction
    #   2) the recurse logic has an unconditional goto that makes the owner checks bogus
    # This assembly follows the intended behavior, not those broken lines literally.

    and r14, r14, 0                          # r14 = 0

    # *(self.sram_alloc_count) = self.node_array_top;
    lw r11, NODE_ARRAY_TOP
    sw r11, SRAM_ALLOC_COUNT

    # set_address_bits(self.node_array_high);
    lw r12, NODE_ARRAY_HIGH
    setmembits r11, r12                      # r11 = old membits (ignored), membits = node_array_high

    # stack_top = DFS_STACK;
    add r2, r14, DFS_STACK                   # r2 = stack_top

    # -- push root onto stack --
    sw r14, r2, 0                            # dram_idx = 0
    add r11, r14, 0xFFFF
    sh r11, r2, 4                            # parent_ptr = 0xFFFF (null sentinel)
    sh r14, r2, 6                            # patch_left = 0
    sh r14, r2, 8                            # patch_right = 0
    sh r14, r2, 10                           # is_right = 0
    sw r14, r2, 12                           # depth = 0
    add r2, r2, 16                           # stack_top++

    # leaf_node_table_ptr = self.leaf_core_lookup_table;
    add r3, r14, LEAF_CORE_LOOKUP_TABLE      # r3 = leaf_node_table_ptr

dfs_loop:
    # if (stack_top == DFS_STACK) goto dfs_done;
    add r11, r14, DFS_STACK
    beq r2, r11, dfs_done, true

    add r2, r2, -16
    lw r4, r2, 0                             # dram_idx
    lhu r5, r2, 4                            # parent_ptr
    lhu r6, r2, 6                            # patch_left
    lhu r7, r2, 8                            # patch_right
    lhu r8, r2, 10                           # is_right
    lw r9, r2, 12                            # depth

    lw r10, SRAM_NODE_ALLOC_PTR              # address of alloc pointer / next free slot
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

    # -- copy metadata --
    lhu_d r10, r12, 30
    sh r10, r13, 30                          # core_owner
    lhu_d r10, r12, 40
    sh r10, r13, 40                          # queue_high_bit_addr
    lw_d r10, r12, 36
    sw r10, r13, 36                          # queue_low_bit_addr
    lw_d r10, r12, 44
    sw r10, r13, 44                          # node_id

    add r11, r14, 0xFFFF
    sh r11, r13, 42                          # prev_index = 0xFFFF
    sb r8, r13, 32                           # is_right = is_right (byte field)

    # -- set parent pointer --
    sh r5, r13, 28                           # node->parent = parent_ptr

    # -- default children to null --
    sh r11, r13, 24                          # left_child = 0xFFFF
    sh r11, r13, 26                          # right_child = 0xFFFF

    # core_id = self.thread_id >> 4
    srl r11, r15, 4

    # if (core_owner != 0xFFFF && core_owner != self.core_id) leaf_node_table_ptr[0] = node;
    lhu r10, r13, 30                         # r10 = core_owner
    beq r10, r11, SKIP_LEAF_TABLE_INSERT, true
    add r14, r14, 0xFFFF
    beq r10, r14, SKIP_LEAF_TABLE_INSERT, true
    and r14, r14, 0
    sh r13, r3, 0
    add r3, r3, 2
SKIP_LEAF_TABLE_INSERT:
    and r14, r14, 0
    # if (parent_ptr != 0xFFFF) patch parent child pointer
    add r12, r14, 0xFFFF
    beq r5, r12, SKIP_PATCH, true
    add r12, r14, 1
    beq r8, r12, PATCH_RIGHT_CHILD, true
    sh r13, r6, 0                            # *patch_left = node
    beq r15, r15, SKIP_PATCH, true
PATCH_RIGHT_CHILD:
    sh r13, r7, 0                            # *patch_right = node
SKIP_PATCH:

    # if (owner == self->core_id) self->root_node = node;
    lhu r10, r13, 30                         # owner = dram_node->core_owner
    bne r10, r11, CHECK_RECURSE, true
    sw r13, ROOT_NODE_ID
CHECK_RECURSE:

    # recurse if owner == 0xFFFF || owner == self->core_id
    add r14, r14, 0xFFFF
    beq r10, r14, DO_RECURSE, true
    and r14, r14, 0
    beq r10, r11, SET_NODE_ID, true
    beq r15, r15, dfs_loop, true             # foreign owner: stop here
SET_NODE_ID:
    lw r10, r12, 44                        # node_id
    sw r10, ROOT_NODE_ID
DO_RECURSE:
    # -- push right child first (so left is processed first) --
    and r14, r14, 0
    lw_d r10, r12, 24                        # right_idx
    lw_d r11, r12, 28                        # left_idx

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
    lw r10, ROOT_NODE_ID
    add r11, r14, LEAF_CORE_LOOKUP_TABLE
    add r11, r11, 256
    sh r10, r11, 0
    
    lw r1, LOCAL_RAY_QUEUE
    sw r14, r1, 0
    sw r14, r1, 4
    sw r14, r1, 8
    add r1, r1, 75
    add r2, r14, 16
queue_loop_1:
    beq r2, r14, queue_loop_1_done, true
    sw r14, r1, 0
    add r1, r1, 64
    add r2, r2, -1
    beq r15, r15, queue_loop_1, true

queue_loop_1_done:

    sb r14, r1, 1
    sb r14, r1, 5
    sb r14, r1, 9

    add r1, r1, 76

    add r2, r14, 16
queue_loop_2:
    beq r2, r14, queue_loop_2_done, true
    sw r14, r1, 0
    add r1, r1, 64
    add r2, r2, -1
    beq r15, r15, queue_loop_2, true

queue_loop_2_done:

    # *(self.local_queue_flushing) = 0;
    sw r14, LOCAL_QUEUE_FLUSHING

    # *(self.tile_data_sram + 4) = 0;
    lw r1, TILE_DATA_COUNT
    sw r14, r1, 4

    # *(self.ray_send_pending_addr) = 0;
    sw r14, RAY_SEND_PENDING_ADDR


    # ray_base = self.ray_array_base;
    lw r1, RAY_ARRAY

    # ray_array_index = self.thread_id << 6;
    sll r2, r15, 6

    # ray = ray_base + index
    add r1, r1, r2

    # *(ray + 63) = 0;
    sb r14, r1, 63

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
    intena 33
    intena 34
    intena 35
    intena 36
    relinquish true
    beq r15, r15, GRAB_FROM_TILE, true







NODE_ID_TABLE_HIGH:
.data -1
NODE_ID_TABLE_LOW:
.data -1
LEAF_SIZE_OF_GEO:
.data 6789
LEAF_START_OF_GEO:
.data 6789
leaf_start_of_code:
.data 5678
VERTEX_ARRAY_BASE:       
.data 0
SRAM_NODE_ALLOC_PTR:     
.data 0
NODE_ARRAY_TOP:         
.data 0
BRANCH_START_OF_CODE:    
.data -1
BRANCH_NUM_INSTRUCTION_BYTES: 
.data -1
BRANCH_START_OF_GEO:     
.data -1
BRANCH_SIZE_OF_GEO:      
.data -1
SAVED_BRANCH_HIGH:       
.data -1
SAVED_BRANCH_LOW:        
.data -1
SEARCH_FOR_IDLE_CORES_STORAGE: 
.data -1
BRANCH_IDLE_THRESHOLD:    
.data -1
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
RAY_SEND_PENDING_ADDR:  
.data 0
LOCAL_QUEUE:            
.data 0
LOCAL_QUEUE_FLUSHING:   
.data 0
ROOT_NODE_ID_SENDER:    
.data -1
ROOT_NODE_ID_RECEIVER:  
.data -1
EMERGENCY_QUEUE_HIGH: 
.data -1
EMERGENCY_QUEUE_LOW: 
.data -1
SPAWNED_RAY_POOL_HIGH: 
.data -1
SPAWNED_RAY_POOL_LOW: 
.data -1
TILE_QUEUE_HIGH: 
.data -1
TILE_QUEUE_LOW: 
.data -1
PIXEL_DONE_HIGH:
.data 0
PIXEL_DONE_LOW:
.data 168_000_004
RAY_RESULT_HIGH: 
.data -1
RAY_RESULT_LOW: 
.data -1
RAYS_COMPLETED_HIGH: 
.data -1
RAYS_COMPLETED_LOW: 
.data -1
FRAME_BUF_HIGH: 
.data -1
FRAME_BUF_LOW: 
.data -1
NODE_ARRAY_HIGH: 
.data -1
NODE_ARRAY_LOW: 
.data -1
TRIANGLE_ARRAY_HIGH: 
.data -1
TRIANGLE_ARRAY_LOW: 
.data -1
INT_TO_FLOAT_TABLE_HIGH: 
.data -1
INT_TO_FLOAT_TABLE_LOW: 
.data -1
DIV_TABLE_HIGH: 
.data -1
DIV_TABLE_LOW: 
.data -1
INV_SQRT_TABLE_HIGH: 
.data -1
INV_SQRT_TABLE_LOW: 
.data -1
IDLE_QUEUE_HIGH: 
.data -1
IDLE_QUEUE_LOW: 
.data -1
RANDOM_TABLE_HIGH: 
.data -1
RANDOM_TABLE_LOW: 
.data -1
CAM_X: 
.data -1
CAM_Y: 
.data -1
CAM_Z: 
.data -1
CAM_CX:
.data -1
CAM_CY: 
.data -1
CAM_INV_FOCAL: 
.data -1
RAY_SEND_PENDING: 
.data -1
PULLED_FROM_FULL_QUEUE_CNT: 
.data -1
CORE_ID_TO_SWITCH_TO: 
.data -1
TILE_DATA_COUNT: 
.data 0 #count
TILE_IS_ACTIVE: 
.data 0 
TILE_X_INDEX:
.data 0
TILE_Y_INDEX:
.data 0
TILE_INTER_INDEX_X: 
.data 0 
TILE_INTER_INDEX_Y:
.data 0
TILE_CUR_RAY_SPAWNED:
.data 0 #cur_ray_spawned_from_tile[16] in bytes
.data 0 
.data 0 
.data 0
RAYS_SPAWNED_FROM_TILE: 
.data 0 #rays_spawned_from_tile
RAYS_FORWARDED_OUT_FROM_TILE: 
.data 0 #rays_forwarded_out_from_tile
RAYS_PROCESSED: 
.data 0
LAST_OBSERVED_CYCLE: 
.data 0
PREVIOUSLY_IDLE: 
.data 0
FLOAT_TO_BYTE_RGB_TABLE: 
.data(128) 0
LIGHT0_X: 
.data -1
LIGHT0_Y: 
.data -1
LIGHT0_Z: 
.data -1
LIGHT0_R: 
.data -1
LIGHT0_G: 
.data -1
LIGHT0_B: 
.data -1
LIGHT1_X: 
.data -1
LIGHT1_Y: 
.data -1
LIGHT1_Z: 
.data -1
LIGHT1_R: 
.data -1
LIGHT1_G: 
.data -1
LIGHT1_B: 
.data -1
LIGHT2_X: 
.data -1
LIGHT2_Y: 
.data -1
LIGHT2_Z: 
.data -1
LIGHT2_R: 
.data -1
LIGHT2_G: 
.data -1
LIGHT2_B: 
.data -1
//DO NOT INCLUDE LINES BELOW THIS AS PULLED FROM DRAM
RAY_ARRAY: 
.data(256) 0
LEAF_CORE_LOOKUP_TABLE: 
.data(64) 0
LOCAL_RAY_QUEUE: 
.data(1048) 0
DFS_STACK: 
.data(256) 0
SRAM_ALLOC_COUNT:       
.data 0
ROOT_NODE_ADDRESS: 
.data 0