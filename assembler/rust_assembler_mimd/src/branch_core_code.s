.org 0x2C //TODO

# 0x196C <- 6508 bytes append to the end
# 15372 - 6508 = 8864

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
beq r15, r15, download_bvh_tree, true
SWITCH_DRAM_QUEUE:
    lw r12, NODE_ID_TABLE_HIGH
    setmembits r12
    lw r12, NODE_ID_TABLE_LOW
    lw r11, CORE_ID_TO_SWITCH_TO
    sll r11, r11, 2
    add r12, r12, r11
    lw_d r9, r12, 0           # main queue high
    lw_d r10, r12, 4          # main queue low
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
    bne r10, r9, WAIT_FOR_FLUSH_READY_TWO, true #VALIDATED
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
    # place to remove lock 
    lw r9, RAY_QUEUE_LOW
    add r9, r9, 20
    atomadd_d r10, r9, -1 
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
    # place to remove lock 
    lw r9, RAY_QUEUE_LOW
    add r9, r9, 20
    atomadd_d r10, r9, -1 
LEGAL_TO_SWITCH:
    add r9, r14, LOCAL_QUEUE_FLUSHING
    atomadd r15, r9, 1
    add r10, r14, 16 
WAIT_FOR_FLUSH_READY:
    lw r9, LOCAL_QUEUE_FLUSHING
    switchctx
    bne r10, r9, WAIT_FOR_FLUSH_READY, true
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
    # AI [SL] stackless traversal (STACKLESS_TRAVERSAL_PLAN.md): ray byte 62 = entry direction into node r1:
    #   0 = from the parent (test this node), 1 = back from the left child (go right), 2 = back from the right child (go up).
    #   Words 44 and 48 (old visited bitfields) are no longer used.
    yield r8                        # r8 = scratch for yield
    and r14, r14, 0
    lbu r2, r0, 62                   # r2 = entry direction (byte 62, was the depth byte)
    and r7, r7, 0
    beq r2, r7, DO_AABB, true       # from the parent: test this node
    add r3, r7, 1
    bne r2, r3, SL_ASCEND, true     # from the right child: both subtrees done, go up
    sb r7, r0, 62                   # from the left child: enter the right child from its parent
    lhu r1, r1, 26                  # r1 = node->right_child
    beq r15, r15, start_ray_traversal, true
SL_ASCEND:                          # leave node r1 upward (miss, or both children done). Clobbers r6, r7.
    lbu r6, r1, 30                  # r6 = node->is_right
    add r6, r6, 1                   # 1 = back from the left child, 2 = back from the right child
    sb r6, r0, 62
    lhu r6, r1, 28                  # r6 = node->parent
    or r7, r7, 0xFFFF
    srl r7, r7, 16                  # r7 = 0x0000FFFF
    beq r6, r7, COMPLETE_RAY, false # no parent: the global root is finished
    add r1, r6, 0
    beq r15, r15, start_ray_traversal, true
DO_AABB:
    # int hit = AABB_Intersect(node, ray);
    # TODO ask alex abt function call protocl\ol
    jmp r8, AABB_INTERSECT 
AABB_INTERSECT_RETURN:             
    # ASSUME r11 CONTAINS INFO FROM FUNCTION
    # if (hit)
    beq r11, r7, AABB_MISS, true

    # if (node->tri_count == 0) <- ASSUME RAY -> TRI_INDEX
    ; beq r6, r7, IS_INTERNAL_NODE, true
    ; beq r15, r15, IS_LEAF_NODE, true

IS_INTERNAL_NODE:
    # AI fix: ray_depth++ moved to TRAVERSE_OWN_CHILD so forwarded rays carry the stub's own depth

    # if (node->core_owner != 0xFFFF)
    lw r6, r1, 36                  # r6 = node->dram_queue 
    or r7, r7, 0xFFFF
    beq r6, r7, TRAVERSE_OWN_CHILD, true   # owner == 0xFFFF means we own it
    lw r14, RAY_QUEUE_LOW
    beq r6, r14, TRAVERSE_OWN_CHILD, false
    and r14, r14, 0
    add r13, r14, 128               # AI fix: ray->leaf_node_starting_point = 128 (receiver starts at its treelet root)
    sw r13, r0, 40
    and r13, r13, 0
    add r13, r13, -1
    # uint16_t ray_send_pending_addr = self.ray_send_pending_addr;
    add r8, r14, RAY_SEND_PENDING_ADDR    # r8 = self.ray_send_pending_addr

    # atomic_add(ray_send_pending_addr, 1)
    atomadd r9, r8, 1               # r9 = clobber
    lw r12, r1, 44                  # r12 = node->node_id TODO confirm offset
    or r13, r13, 0xFFFF
    lh r6, r1, 34                  # r6 = node->core_owner
    beq r6, r13, REJECT_PATH, false
    srl r9, r15, 4                  # AI [154] (Alex): r9 = my core id. A cached owner can be this core itself (a NoC clone copies the
    beq r6, r9, REJECT_PATH, false  #   donor's core_owner caches, and the donor may have cached the core that later became its clone;
                                    #   B5 crashed at 6.06M sending a request to itself): treat it as no cached owner (DRAM path re-caches)
    # uint32_t is_thread_odd = self.thread_id & 1;
    # is_thread_odd += 32;
    # disable_interrupts(is_thread_odd)
    and r10, r15, 0xF               # r10 = thread_id
    and r11, r10, 1                 # r11 = is_thread_odd
    add r11, r11, 32                 

    # disable_interrupts(is_thread_odd);
    intdis r11         

    # uint32_t request_word = (node->node_id << 17) | self.thread_id;

    sll r12, r12, 17
    or r12, r12, r15                # r12 = request_word

    # send_packet(request_word, node->core_owner, 32);

    sendflit r12, r6, 32            # TODO confirm notation w/ Alex

# uint32_t sent = 0;
    and r3, r3, 0                   # r3 = sent = 0

SEND_RAY_LOOP:
    # uint32_t msg_available = nb_recv(self.thread_id + 16);
    switchctx
    and r7, r7, 0
    and r10, r15, 0xF               # r10 = thread_id
    add r11, r10, 16                # r11 = thread_id + 16
    nonblock r12, r11               # r12 = msg_available
    beq r12, r7, CHECK_DATA_MAILBOX, true   # r7=0, nothing on shallow mailbox

    # uint32_t msg = blocking_receive(self.thread_id + 16);
    block r12, r11                  # r12 = msg
    srl r9, r12, 31                 # AI [113]: a late NoC-clone handshake word (bit 31) in my response mailbox: skip it
    bne r9, r7, CHECK_DATA_MAILBOX, true

    # uint32_t header = msg >> 24;
    srl r9, r12, 24                # r13 = header

    # if (header == ack_ray)  -- ack_ray = 5
    and r11, r11, 0
    add r11, r11, 5                 # r11 = 5 (ack_ray)
    bne r9, r11, REJECT_PATH, true

    # ACK path: for (i = 0; i < 16; i++) send_packet(ray[i], core_owner, mailbox)
    lhu r6, r1, 34                  # r6 = node->core_owner
    srl r10, r12, 4
    sll r10, r10, 19
    srl r10, r10, 13
    and r11, r12, 0xF               # r11 = dest mailbox from ack msg low nibble
    add r11, r11, 0                 # AI fix: data goes to the 16-deep data mailbox (thread_id), not 16+thread_id (1-deep response mailbox)
    or r10, r10, r11
    add r8, r0, 0                  # r13 = ray base ptr
    and r14, r14, 0                 # r14 = i = 0
RAY_SEND_LOOP:
    lw r9, r8, 0                   # r9 = ray word i
    sendflit r9, r10            # send word to core_owner on mailbox
    add r8, r8, 4                 # r13 += 4 (next word)
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
    and r7, r7, 0
    add r9, r9, 8
ENSURE_SPACE_IN_QUEUE:
    add r8, r7, 255                 # r8 = 255
    lw_d r10, r9, 0                 # AI fix: peek the count first (test-and-test-and-set). Blind +1/-1 spinning from hundreds of
    bgt r10, r8, ENSURE_SPACE_IN_QUEUE, true   #   producers kept the visible count above 255 forever (livelock on root's queue, runs 17-20)
    atomadd_d r10, r9, 1
    blte r10, r8, SPACE_IN_DRAM_QUEUE_FOR_SEND, true
    atomadd_d r15, r9, -1
    beq r15, r15, ENSURE_SPACE_IN_QUEUE, true   # spin while count > 255
SPACE_IN_DRAM_QUEUE_FOR_SEND:
    add r9, r9, -4                 # r9 = queue base (tail field)
    atomadd_d r10, r9, 64           # r10 = old tail, advance tail by 64 bytes
    and r10, r10, 0x3FFF            # r10 = tail & 0x3FFF (ring mask)
    add r11, r9, 16224                # r11 = queue base + 536 (start of ray slots)
    add r11, r11, r10               # r11 = write_addr = slot base + tail offset
WAIT_FOR_SLOT_TO_OPEN:
    lbu_d r10, r11, 63              # r10 = slot[63] (valid byte)
    bne r10, r7, WAIT_FOR_SLOT_TO_OPEN, true   # spin while slot occupied (r7=0)

    add r9, r0, 0                  # r13 = ray base ptr
    and r14, r14, 0                 # r14 = i = 0
RAY_DRAM_WRITE_LOOP:
    lw r10, r9, 0                  # r10 = ray word i
    sw_d r10, r11, 0                # write to DRAM slot
    add r9, r9, 4                 # r13 += 4
    add r11, r11, 4                 # r11 write_addr += 4
    add r14, r14, 1                 # i++
    and r12, r12, 0
    add r12, r12, 16                # r12 = 16
    bgt r12, r14, RAY_DRAM_WRITE_LOOP, true   # loop while i < 16

    lw r9, r1, 36                   # r9 = queue_low_bit_addr (reload)
    add r9, r9, 20                  # r9 = &lock field (offset 20 from queue base)

ENSURE_NO_WRITERS:
    and r11, r11, 0                 # r11 = 0
    lw_d r10, r9, 0                 # AI fix [66]: peek first (test-and-test-and-set). Blind +1/-1 retries from many readers kept the lock
    bgt r11, r10, ENSURE_NO_WRITERS, true   #   off -8192 forever, so a writer (clone joining / donor leaving an owner list) never got in: the cloning freeze
    atomadd_d r10, r9, 1            # r10 = old lock value, increment
    blte r11, r10, SKIP_UNDO_LOCK, true   # old val >= 0 means no writer held it
    atomadd_d r11, r9, -1           # undo our increment
    beq r15, r15, ENSURE_NO_WRITERS, true        # retry claim

SKIP_UNDO_LOCK:
    lw_d r10, r9, 4                 # r10 = core_owner_count
    beq r10, r7, NO_OWNER, true     # r7=0, no owners

    # pick owner round-robin: idx = (core_id ^ clock) % core_owner_count
    getclk r11                      # r11 = clock
    srl r12, r15, 4                 # r12 = core_id
    #Adjusted because self was selected, so now cannot pick self
    xor r14, r12, r11               # r12 = core_id ^ clock = raw idx
    lhu r11, r1, 42                 # r13 = node->prev_index
    bne r14, r11, SKIP_BUMP, true
    #beq r12, r11, BUMP_IDX, true    # if idx == prev_idx, bump to avoid repeat
    #beq r15, r15, SKIP_BUMP, true
BUMP_IDX:
    add r14, r14, 1                 # r12 = idx + 1
SKIP_BUMP:
    mod r14, r14, r10               # r12 = idx % core_owner_count
    sh r14, r1, 42                  # node->prev_index = idx
    sll r14, r14, 1                 # r12 = idx * 2 (uint16 slots)
    add r9, r9, r14                 # r9 = &core_slots[idx]
    and r14, r14, 0
    lh_d r11, r9, 8                # r10 = core_to_cache (core_slots at +28 from lock field)
    beq r11, r12, NO_OWNER, true   #if picked self, fall back
    sh r11, r1, 34                  # node->core_owner = core_to_cache
    beq r15, r15, SKIP_EMERGENCY_ENQUEUE, true

NO_OWNER:
    and r11, r11, 0
    add r11, r11, 0xFFFF            # r11 = 0xFFFF
    sh r11, r1, 34                  # node->core_owner = 0xFFFF
    lw r9, r1, 36                   # AI [95] emergency-queue producer (re-enabled). r9 = queue base (membits are still this queue's)
    lw_d r10, r9, 24                # owner_count
    bne r10, r7, SKIP_EMERGENCY_ENQUEUE, true   # owners exist (self-pick fallback): nothing to do
    lw_d r10, r9, 8                 # rays waiting (count at +8; the branch read -12 = the lock field's -12, wrong after the reload)
    lw r11, EMERG_MIN_RAYS
    blte r10, r11, SKIP_EMERGENCY_ENQUEUE, true
    lw r9, EMERGENCY_QUEUE_HIGH     # stack 0: emergency queue and the per-queue flag table
    setmembits r9
    lw r11, r1, 44                  # q = node->node_id (queue index)
    sll r11, r11, 2
    lw r12, EMERG_FLAG_LOW
    add r12, r12, r11               # &flag[q] (was queue+16924, inside the ray slots)
    atomadd_d r10, r12, 1
    bne r10, r7, EMERG_DONE, true   # already queued, or a core is on its way
    lw r9, EMERGENCY_QUEUE_LOW
    add r9, r9, 8                   # &count
    atomadd_d r10, r9, 1            # old count
    add r11, r7, 64
    bgt r11, r10, EMERG_CLAIM, true
    atomadd_d r11, r9, -1           # full: undo and clear the flag (was: spin forever holding this queue's reader lock); the next spill retries
    sw_d r7, r12, 0
    beq r15, r15, EMERG_DONE, true
EMERG_CLAIM:
    add r9, r9, -4                  # &tail
    atomadd_d r10, r9, 4            # old tail
    and r10, r10, 0xFF              # 64 slots x 4 bytes
    add r9, r9, r10
    add r9, r9, 8                   # slots start at base+12 (was base+8 = the count field)
EMERG_SLOT_WAIT:
    lbu_d r11, r9, 2
    bne r11, r7, EMERG_SLOT_WAIT, true
    lw r11, r1, 44
    sh_d r11, r9, 0                 # slot.q
    add r11, r7, 1
    sb_d r11, r9, 2                 # slot.valid = 1
EMERG_DONE:
    lhu r9, r1, 40                  # restore this queue's membits for the lock release below
    setmembits r9

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
    beq r12, r7, CHECK_INTERRUPT_MAILBOX, true   # r7=0, nothing available

    add r13, r0, 0                 # r13 = slot ptr (starts at 0 = invalid sentinel)
    and r14, r14, 0                 # r14 = i = 0
DATA_RECV_LOOP:
    block r9, r10                   # r9 = ray_word from data mailbox
    sw r9, r13, 0                   # *slot = ray_word
    add r13, r13, 4                 # slot += 4
    add r14, r14, 1                 # i++
    and r11, r11, 0
    add r11, r11, 16                # r11 = 16
    bgt r11, r14, DATA_RECV_LOOP, true   # loop while i < 16
    and r14, r14, 0
    # *(slot - 16) = leaf_core_lookup_table->leaf_core_ptrs[leaf_node_index << 1]
    lw r9, r0, 40                   # r9 = ray->leaf_node_starting_point
    sll r9, r9, 1                   # r9 = leaf_node_index * 2 (uint16 array)
    add r11, r14, LEAF_CORE_LOOKUP_TABLE  # r11 = base address of lookup table in SRAM
    add r11, r11, r9                # r11 = &leaf_core_ptrs[leaf_node_index]
    lhu r9, r11, 0                  # r9 = leaf_core_data_addr
    sw r9, r13, -16                 # *(slot - 16) = leaf_core_data_addr
    and r13, r13, 0
    or r13, r13, 0xFFFF            # r13 = slot = 0xFFFF sentinel (low 16; full 32 not possible in imm)

CHECK_INTERRUPT_MAILBOX:
    beq r15, r15, DONE_WITH_INTERRUPT, true   # AI [146] (Alex): a sending context no longer polls 32/33 (it rejected every request it took).
                                    #   Context 15 (IRQ_CTX) and yielding workers serve them through EAT_RAY_INTERRUPT.
    and r10, r15, 0xF               # r10 = thread_id
    and r11, r10, 1                 # r11 = thread_id & 1
    add r11, r11, 32                # r11 = interrupt mailbox index
    nonblock r12, r11               # r12 = nb_recv(interrupt mailbox)
    beq r12, r7, DONE_WITH_INTERRUPT, true   # r7=0, nothing available
    block r12, r11                  # r12 = message

    srl r8, r12, 17                 # r8 = supposed_node_id (message >> 17)
    lw r9, ROOT_NODE_ID             # r9 = self.root_node_id
    bne r8, r9, WRONG_CORE_SEND, true   # node mismatch -> wrong core
    and r11, r11, 0
    add r8, r11, LOCAL_RAY_QUEUE              # r8 = self.local_queue
    add r8, r8, 8                   # r8 = skip head and tail
    and r9, r15, 1                  # r9 = thread_id & 1
    add r11, r11, 1036              # r11 = 1036
    mul r9, r9, r11                 # r9 = odd_thread * 1036
    add r8, r8, r9                  # r8 = &local_queue for this thread parity
    and r9, r9, 0                   # AI fix [124]: no count++ here (was +1 then undone: a phantom ray a consumer could claim)
    lw r11, LOCAL_QUEUE_FLUSHING   # r11 = flushing flag
    and r14, r14, 0
    add r14, r14, 16                # r14 = 16 (max queue)
    beq r15, r15, REJECT_INTERRUPT, true    # AI fix: always reject while in the send loop (its ACK omitted our core id and its slot was never used; EAT_RAY_INTERRUPT accepts rays correctly)
    beq r11, r7, NO_FLUSH, true     # r7=0; if not flushing proceed
REJECT_INTERRUPT:
    and r9, r9, 0                   # AI fix [124]: (undo removed with the increment)
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
    or r11, r11, r9   #was or r11, r11, r14
    sendflit r14, r11   #was r9, r11              # send reject
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
DECREMENT_PENDING:
    and r10, r15, 0xF               # r10 = thread_id
    and r11, r10, 1                 # r11 = thread_id & 1
    add r11, r11, 32                # r11 = interrupt mailbox index
    intena r11                      # disable interrupts
    and r14, r14, 0
    add r8, r14, RAY_SEND_PENDING_ADDR    # r8 = &ray_send_pending
    atomadd r9, r8, -1              # decrement pending count
    beq r15, r15, ray_done, true

TRAVERSE_OWN_CHILD:
    lbu r2, r1, 31                  # AI [B1]: tri_count != 0: a BVH leaf in the spine, test its triangles here
    and r7, r7, 0                   #   (r7 is -1 on the paths into here)
    bne r2, r7, BR_IS_LEAF_NODE, false
    and r2, r2, 0                   # AI [SL]: enter the left child from its parent
    sb r2, r0, 62
    lhu r1, r1, 24                  # r1 = node->left_child
    beq r15, r15, start_ray_traversal, true
BR_IS_LEAF_NODE:                            # AI [B1]: test a spine BVH leaf's triangles (same loop as the leaf firmware's IS_LEAF_NODE)
    lhu r2, r1, 32                          # r2 = tri_start (byte offset into the spine index list)
    lbu r3, r1, 31                          # r3 = tri_count
BR_TRI_LOOP:
    beq r15, r15, BR_triangle_intersect, true
BR_TRI_RETURN:                              # r0 = ray, r1 = node, r2/r3 kept by BR_triangle_intersect
    add r2, r2, 12                          # index records are 12 bytes
    lbu r5, r0, 61                          # light_id: shadow ray?
    and r4, r4, 0
    lw r6, r0, 56                           # hit triangle (-1 = none yet)
    beq r4, r5, BR_SHADOW_RAY_NOT_OCCLUDED, true
    and r5, r5, 0
    add r5, r5, -1
    beq r5, r6, BR_SHADOW_RAY_NOT_OCCLUDED, true
    beq r15, r15, BR_SHADOW_RAY_OCCLUDED, true
BR_SHADOW_RAY_NOT_OCCLUDED:
    add r3, r3, -1
    bne r4, r3, BR_TRI_LOOP, true
    beq r15, r15, SL_ASCEND, true           # leaf done: leave it upward
BR_SHADOW_RAY_OCCLUDED:                     # AI [B1]: copy of the leaf SHADOW_RAY_OCCLUDED (result word = 1.0, then RAYS_COMPLETED++)
                                    # AI [127] (Alex): RAYS_COMPLETED++ moved to the end, after the result word is in DRAM

    # BIG TODO; Alex explain the math for ray_result_addr stuff

    # uint32_t finished_ray_high = self.ray_result_addr_high; TODO ALEX TO CONFIRM THIS CHUNK
    lw r10, RAY_RESULT_HIGH         # r10 = ray_result_high
    setmembits r10                  # set_address_bits(finished_ray_high);
    # uint32_t result_addr_low = self.ray_result_addr_low;
    lw r11, RAY_RESULT_LOW          # r11 = ray_result_low
    # AI [127]: removed `atomadd_d r12, r11, 1` here: it added 1 to the first word of the result buffer (pixel 0, bounce 0,
    #   red) on every occluded shadow ray; the finished-ray counter is RAYS_COMPLETED.

    # uint32_t pix_index = ray->pix_y;
    lhu r13, r0, 54                  # r13 = ray->pix_y
    sll r13, r13, 9                  # r13 = pix_y * 512  
    add r12, r13, 0                  # r12 = pix_y * 512
    sll r13, r13, 2                  # r13 = pix_y * 2048
    add r12, r13, r12                # r12 = pix_y * 2560

    # pix_index += ray->pix_x;
    lhu r13, r0, 52                  # r13 = ray -> pix_x 
    add r12, r13, r12                # r12 = pix_y * 2560 + pix_x = pix_index
    sll r12, r12, 8                  # r12 = pix_index <<= 8
    add r11, r12, r11                # r11 = result_addr_low + pix_index

    lbu r10, r0, 60                  # r10 = ray->bounce_count = bounce
    sll r10, r10, 6                  # r10 = bounce << 6
    add r11, r10, r11                # r11 = result_addr_low + pix_index + bounce

    lbu r10, r0, 61                  # r10 = ray->light_id = shadow
    sll r10, r10, 4                  # r10 = shadow << 4
    add r11, r10, r11                # r11 = result_addr_low = result_addr_low + pix_index + shadow << 4

    # Write 1.0 to len_sq slot to mark as occluded (blocked)
    # uint32_t one = 0x3F800000;
    lw r10, ONE                     # r10 = 0x3F800000
    add r11, r11, 12                # r11 = result_addr_low + 12
    sw_d r10, r11, 0                # store_dram_word(result_addr_low + 12, one)
    lw_d r10, r11, 0                # AI [127]: read back the result word (returns after the store landed), RAW wait,
    and r10, r10, 0                 #   then RAYS_COMPLETED++
    lw r10, RAYS_COMPLETED_HIGH
    setmembits r10
    lw r11, RAYS_COMPLETED_LOW
    atomadd_d r15, r11, 1

    # ray->active_ray = 0;
    and r7, r7, 0                   #r7 = 0
    sb r7, r0, 63                   # ray->active_ray = 0 (r7=0)

    beq r15, r15, ray_done, true
# AI [B1]: BR_triangle_intersect = the leaf firmware's triangle_intersect, labels renamed (BR_/BR_TI_). Clobbers r4-r14,
#   keeps r0-r3. Uses INDEX_ARRAY_BASE, VERTEX_ARRAY_BASE, RAY_TRIANGLE_REG_SPILL (64 B per context), EPSILON, RECIPROCAL.
BR_triangle_intersect: 
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
    beq r8, r12, BR_TRI_RETURN, false #I have 9, 10, and 12 available
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
    beq r6, r10, BR_TI_ELSE_1, false   # AI fix [87]: was bne, so det > 0 got the det < 0 test (reject u > 0) and vice versa:
                                                          #   every triangle was rejected (run 53: 1301 det checks, 0 past the u/v tests)
    fplt r6, r12, r10
    fplt r7, r8, r12
    or r6, r6, r7
    bne r6, r10, BR_TRI_RETURN, true
    beq r15, r15, BR_TI_END_1, true
BR_TI_ELSE_1:
    fplt r6, r10, r12
    fplt r7, r12, r8
    or r6, r6, r7
    bne r6, r10, BR_TRI_RETURN, true
BR_TI_END_1:
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
    beq r13, r11, BR_TI_ELSE_2, false
    fplt.32 r5, r7, r11
    fplt.32 r6, r8, r12
    or r5, r5, r6
    beq r5, r11, BR_TI_END_2, true  # AI fix [87]: was bne (continued when the v test FAILED, returned when it passed)
    beq r15, r15, BR_TRI_RETURN, true
BR_TI_ELSE_2:
    fplt.32 r5, r11, r7
    fplt.32 r6, r12, r8
    or r5, r5, r6
    beq r5, r11, BR_TI_END_2, true  # AI fix [87]: was bne (continued when the v test FAILED, returned when it passed)
    beq r15, r15, BR_TRI_RETURN, true
BR_TI_END_2:
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
    beq r9, r11, BR_TI_ELSE_3, false
    fplt.32 r6, r5, r6
    fplt.32 r7, r7, r5
    or r6, r6, r7
    beq r11, r6, BR_TI_END_3, false
    beq r15, r15, BR_TRI_RETURN, true
BR_TI_ELSE_3:
    fplt.32 r6, r6, r5
    fplt.32 r7, r5, r7
    or r6, r6, r7
    beq r11, r6, BR_TI_END_3, false
    beq r15, r15, BR_TRI_RETURN, true
BR_TI_END_3:
    add r9, r8, 0
    jmp r10, RECIPROCAL
    fpmul.32 r5, r5, r9
    sw r5, r0, 36
    lw r6, INDEX_ARRAY_BASE         # AI fix: tri id is at INDEX_ARRAY_BASE + r2 (was `lw r6, r2, 0`, an absolute SRAM read into code)
    add r6, r6, r2
    lw r6, r6, 0
    sw r6, r0, 56
    beq r15, r15, BR_TRI_RETURN, true
AABB_MISS:
    beq r15, r15, SL_ASCEND, true   # AI [SL]: was: set the parent's visited bit, depth--, go to the parent
ray_done:                                # AI [115]: removed `intena 34` here ([102b]): context 15 serves NoC clone requests
    lbu r9, r0, 63                  # ray->active_ray
    and r7, r7, 0
    bne r9, r7, start_ray_traversal, true   # r7=0

    yield r8
    and r7, r7, 0  # AI fix: re-zero after yield (EAT_RAY_INTERRUPT may run at any yield and clobbers r4, r6-r14)
    and r14, r14, 0                 # AI [114]: every context drains again (was [94]: context 15 spawn-only, skipped the queues)
    getclk r9                            # AI [143] (Alex): a ray just left this context (sent or finished): busy = a reject within the
    lw r10, REJ_LAST_TS                  #   last IDLE_WINDOW and >= 2 rejects in the current streak. Cooldown checked here in SRAM first
    sub r10, r9, r10                     #   (CLONE_REQUEST starts with a DRAM read), and REJ_CNT is cleared so one streak asks once.
    lw r11, IDLE_WINDOW
    blte r11, r10, RD_REJ_DONE, true
    lw r10, REJ_CNT
    add r11, r14, 1
    blte r10, r11, RD_REJ_DONE, true
    lw r10, CLONE_NEXT_REQ
    bgt r10, r9, RD_REJ_DONE, true
    sw r14, REJ_CNT
    jmp r7, CLONE_REQUEST            # uses r9-r14 and the link only; returns with r14 = 0 and membits = RAY_QUEUE_HIGH
    and r7, r7, 0                        # r7 was the link: back to 0 (r14 is 0 on return)
RD_REJ_DONE:

    # check local ray queue
    and r10, r15, 0xF               # thread_id
    and r11, r10, 1                 # odd_thread
    and r12, r12, 0
    add r12, r12, 1036
    mul r11, r11, r12               # offset = odd_thread * 1036
    add r12, r7, LOCAL_RAY_QUEUE
    add r11, r11, r12               # offset += self.local_ray_queue
    add r12, r11, 0                 # AI fix [75] (redo of [49]): use the parity-selected queue. Before, every context drained the EVEN
                                    #   queue and rays delivered to the odd (receiver) local queue at +1036 were never taken: lost rays.

    add r12, r12, 8
    atomadd r14, r12, -1            # decrement count
    bgt r14, r7, SLOT_AVAILABLE_LOCAL_RAY_QUEUE, true
    atomadd r14, r12, 1
    beq r15, r15, no_rays_available, true
SLOT_AVAILABLE_LOCAL_RAY_QUEUE:
    add r12, r12, -8
    atomadd r13, r12, 64            # slot = atomic_add(head, 64)
    and r13, r13, 0x3FF
    add r12, r12, r13               # queue_head + slot
    add r12, r12, 12
    add r5, r12, 0                  # AI fix [83]: wait until the intake handler has written the whole slot (byte 63 = 1); r5 survives yields
LOCAL_SLOT_WAIT_B:
    lbu r9, r5, 63
    and r7, r7, 0
    bne r9, r7, LOCAL_SLOT_OK_B, true
    yield r8
    beq r15, r15, LOCAL_SLOT_WAIT_B, true
LOCAL_SLOT_OK_B:
    add r12, r5, 0

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
    lw r9, r12, 40                  # AI fix: keep the queued ray's word 40 (was forced to 128, which also discarded a returning ray's marker)
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
    and r10, r15, 1                 # AI fix [124]: only now give the slot back to producers (used--), after the copy
    mul r10, r10, 1036
    add r10, r10, LOCAL_RAY_QUEUE
    add r10, r10, 2072
    atomadd r10, r10, -1
    lw r1, r0, 40                   # r1 = ray->leaf_node_starting_point
    beq r15, r15, RESOLVE_START_NODE, true   # AI fix: was `lhu r1, r1, LEAF_CORE_LOOKUP_TABLE` without the <<1 (read byte 128, not entry 128)
    #ABOVE, WE ASSUME THE QUEUE HAS BEEN INSERTED WITH THE CORRECT SRAM ADDRESS TODO
    beq r15, r15, start_ray_traversal, true  

CHECK_ODD_FOR_NO_RAYS:
    and r11, r10, 1
    bne r11, r7, ray_done, true     # odd thread loops back

no_rays_available:
    # (continues in rest of main loop file)
    
    lw r3, LOCAL_QUEUE_FLUSHING          # uint8_t flushing_queue = *(self.local_queue_flushing)
    and r14, r3, 0                       # r14 = 0
    bne r3, r14, FLUSH_PARK, false       # AI [63]: was INF_LOOP (never resumed)
NOT_FLUSHING_CORE:
    yield r8                             # yield()
    and r14, r14, 0  # AI fix: re-zero after yield (EAT_RAY_INTERRUPT may run at any yield and clobbers r4, r6-r14)
    lw r3, RAY_QUEUE_HIGH                # int queue_address_high = self.ray_queue_address_high
    setmembits r3                        # set_address_bits(queue_address_high)
    lw r3, RAY_QUEUE_LOW                 # int queue_address_low = self.ray_queue_address_low
    and r5, r15, 1                       # r5 = odd thread (bit 0 of r15)  AI fix: was r14, which is the zero register below
    mul r5, r5, 32612                    # r5 *= 32612 (offset to receiver queue for odd threads)  AI fix: was r14
    add r3, r3, r5                       # queue_address_low += r5 (select correct queue)  AI fix: was r14
    lw_d r4, r3, 8                       # int cur_ray_count = load_dram_word(queue_address_low + 8)
    blte r4, r14, DRAM_RAY_QUEUE_EMPTY, true  # if (cur_ray_count <= 0) goto DRAM_RAY_QUEUE_EMPTY
    add r5, r14, 192                     # r5 = 192  AI [55]: 'full' threshold for the clone trigger was 256; after [42] the count never exceeds ~256, so the trigger never fired
    blte r4, r5, PULL_ELEM_FROM_DRAM_QUEUE, true  # AI [56]: below the threshold just pull (was: reset the streak). The counter is now cumulative and resets only after a clone request.
    add r5, r14, PULLED_FROM_FULL_QUEUE_CNT  # r5 = &PULLED_FROM_FULL_QUEUE_CNT
    atomadd r5, r5, 1                    # uint32_t num_times_pulled = atomic_add(pulled_from_full_queue_address, 1)
    lw r6, CLONE_BUSY_PULLS              # AI [53]: busy threshold (was -1 = disabled)
    blteu r5, r6, PULL_ELEM_FROM_DRAM_QUEUE, true  # if (num_times_pulled <= BRANCH_BUSY_THRESHOLD) goto PULL_ELEM_FROM_DRAM_QUEUE  AI fix: operands were swapped
    jmp r7, CLONE_REQUEST                # AI [53]: was SEARCH_FOR_IDLE_CORES. Returns to RESET_PULLED_FROM_FULL_QUEUE_CNT.
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
    sw r6, r0, 0                         # store to ray SRAM [0]  AI fix: was sw_d (wrote to DRAM)
    sw r7, r0, 4                         # store to ray SRAM [4]  AI fix: was sw_d (wrote to DRAM)
    sw r8, r0, 8                         # store to ray SRAM [8]  AI fix: was sw_d (wrote to DRAM)
    sw r9, r0, 12                        # store to ray SRAM [12]  AI fix: was sw_d (wrote to DRAM)
    sw r10, r0, 16                       # store to ray SRAM [16]  AI fix: was sw_d (wrote to DRAM)
    sw r11, r0, 20                       # store to ray SRAM [20]  AI fix: was sw_d (wrote to DRAM)
    sw r12, r0, 24                       # store to ray SRAM [24]  AI fix: was sw_d (wrote to DRAM)
    sw r13, r0, 28                       # store to ray SRAM [28]  AI fix: was sw_d (wrote to DRAM)
    lw_d r6, r4, 32                      # load ray word [32]
    lw_d r7, r4, 36                      # load ray word [36]
    lw_d r8, r4, 40                      # load ray word [40]
    lw_d r9, r4, 44                      # load ray word [44]
    lw_d r10, r4, 48                     # load ray word [48]
    lw_d r11, r4, 52                     # load ray word [52]
    lw_d r12, r4, 56                     # load ray word [56]
    lw_d r13, r4, 60                     # load ray word [60]
    sw r6, r0, 32                        # store to ray SRAM [32]  AI fix: was sw_d (wrote to DRAM)
    sw r7, r0, 36                        # store to ray SRAM [36]  AI fix: was sw_d (wrote to DRAM)
    sw r8, r0, 40                        # store to ray SRAM [40]  AI fix: was sw_d (wrote to DRAM)
    sw r9, r0, 44                        # store to ray SRAM [44]  AI fix: was sw_d (wrote to DRAM)
    sw r10, r0, 48                       # store to ray SRAM [48]  AI fix: was sw_d (wrote to DRAM)
    sw r11, r0, 52                       # store to ray SRAM [52]  AI fix: was sw_d (wrote to DRAM)
    sw r12, r0, 56                       # store to ray SRAM [56]  AI fix: was sw_d (wrote to DRAM)
    sw r13, r0, 60                       # store to ray SRAM [60]  AI fix: was sw_d (wrote to DRAM)
    sb_d r14, r4, 63                     # write_dram_byte(queue_address_low + 63, 0) -- mark slot as consumed
    add r6, r14, 1                       # r6 = 1
    sb r6, r0, 63                        # ray->active_ray = 1
    lw r1, r0, 40                        # r1 = ray->leaf_node_starting_point
    beq r15, r15, RESOLVE_START_NODE, true   # AI: shared resolver (root / table index / returning-ray stub search)
# AI: RESOLVE_START_NODE -- r1 = ray word 40 in, r1 = SRAM node to start at out, then start_ray_traversal.
#   bit 31 set -> returning ray (from a leaf, via the receiver half): it has traversed everything below our treelet root.
#                 The leaf marked our root visited and decremented depth, so resume at our root's parent (spine).
#                 Root with no parent -> ray is complete.
#   otherwise  -> LEAF_CORE_LOOKUP_TABLE[word40]; 128 = own treelet root (fresh forwarded ray).
# Clobbers r6, r7, r14.
RESOLVE_START_NODE:
    and r14, r14, 0
    add r6, r14, RAYS_PROCESSED          # AI [53]: count rays started (was never incremented)
    atomadd r6, r6, 1
    bgt r14, r1, RESUME_ABOVE_TREELET, false  # 0 > r1 (signed) -> marker bit set
    sll r1, r1, 1
    lhu r1, r1, LEAF_CORE_LOOKUP_TABLE
    beq r15, r15, start_ray_traversal, true
RESUME_ABOVE_TREELET:
    lw r1, ROOT_NODE_ADDRESS                 # AI [SL]: the returning ray finished our whole treelet: leave our root upward
    beq r15, r15, SL_ASCEND, true            #   (completes the ray if the root is the global root)
DRAM_RAY_QUEUE_EMPTY:
    yield r8                             # yield()
    and r14, r14, 0  # AI fix: re-zero after yield (EAT_RAY_INTERRUPT may run at any yield and clobbers r4, r6-r14)
    beq r15, r15, CHECK_SPAWNED_RAY_POOL, true  # AI fix [46]: skip the emergency-queue check. It used RAY_QUEUE_HIGH/LOW (this core's own ray queue) instead of
                                                #   EMERGENCY_QUEUE_*, and on a count race it did count+1 (never undone) and head += 4 (emergency stride) on the RAY queue,
                                                #   so head drifted off the 64-byte grid and every later pull read a ray 12 bytes late (runs 16/19/22/23 crashes).
                                                #   Only cloning fills the emergency queue, and cloning is disabled [5][34]. Re-enable with EMERGENCY_QUEUE_* when cloning returns.
#AI[100]     lw r3, RAY_QUEUE_HIGH                # (reload) queue_address_high
#AI[100]     setmembits r3                        # set_address_bits(queue_address_high)
#AI[100]     lw r3, RAY_QUEUE_LOW                 # (reload) queue_address_low
#AI[100]     lw_d r4, r3, 8                       # count = load_dram_word(emergency_queue_low + 8)
#AI[100]     blte r4, r14, CHECK_SPAWNED_RAY_POOL, true  # if (count <= 0) goto CHECK_SPAWNED_RAY_POOL
#AI[100]     add r3, r3, 8                        # emergency_queue_low += 8
#AI[100]     atomadd_d r4, r3, 1                  # uint32_t old_cnt = atomic_add_dram(emergency_queue_low, 1)
#AI[100]     blte r4, r14, EMERGENCY_SWITCH_BEGIN, false  # if (old_cnt > 0) goto EMERGENCY_SWITCH_BEGIN -- differs: pseudocode checks <= 0 to UNDO
#AI[100]     atomadd_d r4, r3, -1                 # atomic_add_dram(emergency_queue_low, -1) -- undo increment
#AI[100]     beq r15, r15, CHECK_SPAWNED_RAY_POOL, true  # goto CHECK_SPAWNED_RAY_POOL
#AI[100] EMERGENCY_SWITCH_BEGIN:
#AI[100]     add r3, r3, -8                       # emergency_queue_low -= 8 (back to base)
#AI[100]     atomadd_d r4, r3, 4                  # uint32_t byte_index = atomic_add_dram(emergency_queue_low, 4)
#AI[100]     and r4, r4, 0xFF                     # byte_index &= 0x000000FF
#AI[100]     add r3, r3, r4                       # emergency_queue_low += byte_index
#AI[100]     add r3, r3, 12                       # emergency_queue_low += 12
#AI[100] ENSURE_EMERGENCY_SLOT_READY_TWO:
#AI[100]     lhu_d r4, r3, 2                      # uint16_t is_ready = load_dram_byte(emergency_queue_low + 2)
#AI[100]     beq r4, r14, ENSURE_EMERGENCY_SLOT_READY_TWO, false  # if (is_ready == 0) goto ENSURE_EMERGENCY_SLOT_READY
#AI[100]     lhu_d r4, r3, 0                      # uint32_t new_node_id = load_dram_half(emergency_queue_low)
#AI[100]     add r5, r14, 1                       # r5 = 1
#AI[100]     sh_d r5, r3, 0                       # store_dram_byte(emergency_queue_low + 2, 0) -- mark slot consumed; differs: pseudocode writes to +2 but asm writes to +0
#AI[100]     add r5, r14, LOCAL_QUEUE_FLUSHING   
#AI[100]     atomadd r15, r5, 1
#AI[100]     add r6, r14, 16
#AI[100] EMERGENCY_SLOT_FLUSH_LOOP:
#AI[100]     lw r5, LOCAL_QUEUE_FLUSHING
#AI[100]     switchctx
#AI[100]     beq r5, r6, EMERGENCY_SLOT_FLUSH_LOOP, true
#AI[100]     sw r4, CORE_ID_TO_SWITCH_TO         # *(self.local_queue_flushing + 4) = new_node_id
#AI[100]     #TODO
#AI[100]     beq r15, r15, SWITCH_DRAM_QUEUE, true  # goto switch_dram_queue

CHECK_SPAWNED_RAY_POOL:
    jmp r2, CLONE_IDLE_HOOK              # AI [53]: was IS_IDLE_BRANCH. AI [94]: called before the spawn gate (the hook only acts in context 0)
    and r2, r15, 0xF                     # AI [117] (Alex): contexts SPAWN_CTX_MIN..14 take new work when their queues are empty; lower ones
    add r3, r14, 4                       #   only drain. AI [146] (Alex): SPAWN_CTX_MIN (immediate). AI [B3] (Alex): 4 = contexts 4-14 spawn (11), 0-3 stay drain-only; B2 7 (8), B1 11 (4).
    bgt r3, r2, ray_done, true           #   15 is the interrupt context [115]. Was [114b]: mask 2 (0,1,4,5,8,9,12,13).
    xor r2, r2, 15
    beq r2, r14, ray_done, true
    lw r2, SPAWNED_RAY_POOL_HIGH         # uint32_t spawned_ray_pool_high = self.spawned_ray_pool_high
    setmembits r15, r2                        # set_address_bits(spawned_ray_pool_high)
    lw r2, SPAWNED_RAY_POOL_LOW          # uint32_t spawned_ray_pool_low = self.spawned_ray_pool_low
    lw_d r3, r2, 8                       # uint32_t count = load_dram_word(spawned_ray_pool_low + 8)
    blte r3, r14, GRAB_FROM_TILE, true   # if (count <= 0) goto grab_from_tile
    add r2, r2, 8                        # spawned_ray_pool_low += 8
    atomadd_d r3, r2, -1                 # uint32_t old_cnt = atomic_add(spawned_ray_pool_low, -1)
    bgt r3, r14, CONTINUE_REMOVING_FROM_SPAWNED_RAY_POOL, true  # if (old_cnt > 0) goto CONTINUE -- differs: pseudocode checks old_cnt <= 0 to undo
    atomadd_d r3, r2, 1                  # atomic_add(spawned_ray_pool_low, 1) -- undo decrement
    beq r15, r15, GRAB_FROM_TILE, true   # goto grab_from_tile
CONTINUE_REMOVING_FROM_SPAWNED_RAY_POOL:
    lw r4, RAYS_ENTERED_HIGH             # AI [B4] (Alex): RAYS_ENTERED moved to stack 2 (RAYS_COMPLETED stays on stack 0)
    setmembits r4
    lw r4, RAYS_ENTERED_LOW              # AI [74]: a pooled (shadow/bounce) ray enters traversal
    atomadd_d r15, r4, 1                 # AI fix [81]: dummy dest r15 (was r4: the late far reply overwrote the pool mask loaded into r4)
    lw r4, SPAWNED_RAY_POOL_HIGH         # AI [B4]: back to the pool's membits
    setmembits r4
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
    beq r4, r14, IS_NOT_SHADOW, false    # if (light_id == 0) goto IS_NOT_SHADOW  AI fix: was `blte r14, r4` (0 <= light_id: always true, so shadow rays got t_max = INF)
    add r9, r8, 0                        # r9 = inv_len (for shadow ray t_max = 1/|d| = distance to light)
    jmp r10, RECIPROCAL                  # ray->t_max = reciprocal(inv_len)
    sw r9, r0, 36                        # AI fix: store ray->t_max (result was computed but never stored)
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
    add r1, r14, 19968                   # AI fix [94]: start pooled rays at the global root (node 0's slot), like primaries. Was
                                         #   ROOT_NODE_ADDRESS = this core's treelet root, so shadow rays taken by a non-root core started
                                         #   mid-tree with depth 0 and only saw part of the scene.
    beq r15, r15, start_ray_traversal, true  # goto start_ray_traversal
GRAB_FROM_TILE:
    lh r2, TILE_IS_ACTIVE                # uint16_t is_active = *(self.tile_data_sram->is_active)
    and r14, r14, 0                      # r14 = 0
    beq r2, r14, GET_NEW_TILE, false     # if (!is_active) goto get_new_tile
    lw r2, TILE_DATA_COUNT               # uint32_t tile_total_count = *(self.tile_data_sram->count)
    sll r2, r2, 16                       # AI [122]: count is the low 16 bits (the tile index sits in the high 16)
    srl r2, r2, 16
    add r3, r14, 255                     # r3 = 255
    bgt r2, r3, GET_NEW_TILE, true       # AI fix [120]: exhausted tile -> GET_NEW_TILE (gate + getowner). Was SKIP_RETURNING_TILE, which
                                         #   is inside GET_NEW_TILE's getowner region: it reached `relinquish` without owning the core
                                         #   (run 89 panic, core 3035 cycle 3.46M: ctx 6 relinquished while ctx 4 held ownership).
    lw r2, RAYS_SPAWNED_FROM_TILE        # uint32_t rays_spawned_from_tile = *(self.tile_data_sram->rays_spawned_from_tile)
    add r3, r14, 7                       # r3 = 7  # TODO, Threshold for when to return tile to queue
    bgt r3, r2, SPAWN_FROM_TILE, false   # if (rays_spawned_from_tile < 7) goto spawn_from_tile
    lw r4, RAYS_FORWARDED_OUT_FROM_TILE  # uint32_t rays_forwarded_out_from_tile = *(self.tile_data_sram->rays_forwarded_out_from_tile)
    sll r4, r4, 1                        # rays_forwarded_out_from_tile <<= 1
    bgt r2, r4, SPAWN_FROM_TILE, true    # if (rays_forwarded_out_from_tile < rays_spawned_from_tile) goto spawn_from_tile
GET_NEW_TILE:
    add r2, r14, GRAB_FROM_TILE_ATOMADDER
    atomadd r2, r2, 1
    bne r2, r14, ray_done, false
                                         # AI [122] (Alex): no getowner here any more. It waited for every other context to yield,
                                         #   but contexts in SEND_RAY_LOOP / ENSURE_SPACE never yield, so the core froze with all
                                         #   yielding contexts parked, context 15 included (run 90: ~75 branch cores at 5M). The gate
                                         #   above serializes grabbers; spawners read the tile index from the same word as their ray
                                         #   number (TILE_DATA_COUNT = tile << 16 | count), so a grab cannot mix two tiles' data.
    lw r2, TILE_QUEUE_HIGH               # uint32_t tile_pool_high = self.tile_pool_high
    setmembits r2                        # set_address_bits(tile_pool_high)
    lw r2, TILE_QUEUE_LOW                # uint32_t tile_pool_low = self.tile_pool_low
    lhu r3, TILE_IS_ACTIVE               # uint8_t tile_rays_spawned = *(self.tile_data_sram->is_active)  -- differs: pseudocode checks count not is_active
    beq r3, r14, SKIP_RETURNING_TILE, false  # if (tile_rays_spawned != 0) goto skip_returning_tile  -- differs: pseudocode checks count > 255
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
    add r3, r14, TILE_DATA_COUNT         # r3 = tile_rays_spawned (count). AI [122]: close the old tile and read its count in one
    atomadd r3, r3, 0x4000               #   atomic step (was lbu). Without getowner other contexts may still be spawning from it;
    and r3, r3, 0xFF                     #   the +0x4000 sends them to GET_NEW_TILE, so the count returned to the pool is exact.
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
    lw_d r3, r2, 0
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
    add r4, r14, 0x7FFF
    add r4, r4, 0x7FFF
    add r4, r4, 1
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
    sll r7, r3, 16                       # AI [122]: packed TILE_DATA_COUNT = tile << 16 | count, stored after X/Y below
    or r7, r7, r4

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
    add r2, r14, TILE_DATA_COUNT
    sw r14, r2, 16
    sw r14, r2, 20
    sw r14, r2, 24
    sw r14, r2, 28
    sw r14, r2, 36
# TILE_DATA_COUNT: 
# .data 0 #count
# TILE_IS_ACTIVE: 
# .data 0 
# TILE_INTER_INDEX_X: 
# .data 0 
# TILE_INTER_INDEX_Y:
# .data 0
# TILE_CUR_RAY_SPAWNED:
# .data 0 #cur_ray_spawned_from_tile[16] in bytes
# .data 0 
# .data 0 
# .data 0
# RAYS_SPAWNED_FROM_TILE: 
# .data 0 #rays_spawned_from_tile
# RAYS_FORWARDED_OUT_FROM_TILE: 
# .data 0 #rays_forwarded_out_from_tile
    # *(self.tile_data_sram->cur_ray_spawned_from_tile + self.thread_id) = 1;
    and r3, r15, 0xF                     # r3 = thread_id
    add r3, r2, r3
    add r4, r14, 1
    sb r4, r3, 16
    sw r4, r2, 32                         # cur_ray_spawned_from_tile[thread_id] = 1
    sw r7, TILE_DATA_COUNT               # AI [122]: publish the new tile (index + count in one store); no getowner to release
    sw r4, TILE_IS_ACTIVE

    and r14, r14, 0                      # AI fix [69]: release the tile-grab gate. It was never reset, so each core could fetch one tile ever.
    sw r14, GRAB_FROM_TILE_ATOMADDER

    # Bro tf were you cooking below this????
SPAWN_FROM_TILE:
    lw r2, RAYS_ENTERED_HIGH             # AI [74]: admission control. Rays in flight = RAYS_ENTERED - RAYS_COMPLETED. Unbounded tile
    setmembits r2                        #   spawning filled the queue cycle node 4 <-> node 5 (and root) until every context of those cores
    lw r2, RAYS_ENTERED_LOW              #   blocked in ENSURE_SPACE_IN_QUEUE: deadlock (run 42). AI [B4] (Alex): RAYS_ENTERED on stack 2,
    lw_d r3, r2, 0                       #   RAYS_COMPLETED on stack 0 (both were on stack 0).
    lw r2, RAYS_COMPLETED_HIGH
    setmembits r2
    lw r2, RAYS_COMPLETED_LOW            # AI [126]: was TRAVERSALS_DONE_LOW (removed duplicate counter)
    lw_d r4, r2, 0
    sub r3, r3, r4
    lw r4, INFLIGHT_CAP
    bgt r3, r4, ray_done, false          # too many rays in flight: do not start a new primary ray now
                                         # AI [B4] (Alex): self-organizing branch growth. With few rays in flight, ask the idle pool for one
                                         #   more owner of my node (CLONE_REQUEST), with probability p(in flight): 1/3 at <= 30K, then
                                         #   ((100K - n) / 70K)^2 / 3, ~0 at 100K. Test: rand16 * 876 < ((100K - n) >> 4)^2 (both < 2^31).
                                         #   rand16 = low 16 bits of (getclk ^ r15 << 7), then ^= >> 11. Rate limits: BR_GROW_NEXT (one try per
                                         #   BR_GROW_RETRY = 100K cycles per core, even when the idle pool is empty) and, on a granted request,
                                         #   CLONE_REQUEST's own per-core CLONE_NEXT_REQ (200K). No extra DRAM polling: n comes from the read above.
    lw r5, BR_GROW_FULL                  # r5 = 100000
    sub r5, r5, r3                       # d = 100000 - in flight
    and r14, r14, 0
    blte r5, r14, BR_GROW_DONE, true     # >= 100K in flight: never
    getclk r6
    lw r7, BR_GROW_NEXT
    bgt r7, r6, BR_GROW_DONE, true       # per-core retry cooldown
    lw r7, BR_GROW_RETRY
    add r7, r6, r7
    sw r7, BR_GROW_NEXT
    sll r7, r15, 7                       # rand = getclk ^ (r15 << 7)
    xor r6, r6, r7
    srl r7, r6, 11
    xor r6, r6, r7                       # rand ^= rand >> 11
    sll r6, r6, 16
    srl r6, r6, 16                       # rand16
    mul r6, r6, 876                      # rand16 * 876 (max 57,408,660). AI [B4] (Alex): 3 x 292, so p is a third: 1/3 at <= 30K
    srl r5, r5, 4
    mul r5, r5, r5                       # ((100K - n) >> 4)^2 (19,140,625 at n = 30K)
    blte r5, r6, BR_GROW_DONE, true
    jmp r7, CLONE_REQUEST                # uses r9-r14 and the link (r7) only; returns with r14 = 0, membits = RAY_QUEUE_HIGH
BR_GROW_DONE:
    and r14, r14, 0                      # r14 = 0
    add r2, r14, TILE_DATA_COUNT         # uint16_t tile_data_sram_address = &(self.tile_data_sram->count)
    atomadd r3, r2, 1                    # uint32_t ray_num_from_tile = atomic_add(tile_data_sram_address, 1)
    srl r9, r3, 16                       # AI [122]: r9 = tile index, from the same word as the ray number
    sll r3, r3, 16
    srl r3, r3, 16                       # r3 = ray number
    add r4, r14, 255                     # r4 = 255
    bgt r3, r4, GET_NEW_TILE, false      # if (ray_num_from_tile > 255) goto get_new_tile
    lw r6, RAYS_ENTERED_HIGH             # AI [B4]: stack 2 (membits may be stack 0 or RAY_QUEUE_HIGH here)
    setmembits r6
    lw r5, RAYS_ENTERED_LOW              # AI fix [76]: count the ray only once it is really spawned (was before the tile-exhausted
    atomadd_d r15, r5, 1                 #   check, so every visit to an exhausted tile leaked one count; run 44 hit the cap with ~0 real rays)
    add r2, r2, 32                       # tile_data_sram_address += 28 (point to rays_spawned counter)
    atomadd r15, r2, 1                   # atomic_add(tile_data_sram_address, 1) -- increment rays spawned
    add r2, r2, -32                       # tile_data_sram_address -= 28 
    and r4, r3, 0xF                      # uint32_t intra_tile_x = ray_num_from_tile & 0xF
    srl r5, r3, 4                        # uint32_t intra_tile_y = ray_num_from_tile >> 4
    add r6, r14, 160                     # AI [122]: tile x/y from the index in r9 (was loaded from TILE_INTER_INDEX_X/Y, which a
    div r7, r9, r6                       #   concurrent grab could already have rewritten)
    mul r6, r7, 160
    sub r6, r9, r6                       # r6 = inter_tile_x, r7 = inter_tile_y
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

# --- Camera-space direction ---
    lw r5, CAM_CX
    lw r6, CAM_CY
    lw r7, CAM_INV_FOCAL
    fpsub.32 r8, r3, r5                  # r8 = dx_cam = fpix_x - CAM_CX
    fpsub.32 r9, r6, r4                  # r9 = dy_cam = fpix_y - CAM_CY
    fpmul.32 r2, r8, r7                  # r2 = dx_cam *= inv_focal
    fpmul.32 r3, r9, r7                  # r3 = dy_cam *= inv_focal
    lw r4, NEG_ONE                       # r4 = dz_cam = -1.0
    # Now: r2 = dx_cam, r3 = dy_cam, r4 = dz_cam (in camera space)

    # --- Basis transform: world_dir = dx_cam*right + dy_cam*up - dz_cam*forward ---
    # (negation on forward: dz_cam = -1 means "along forward", so -dz_cam*forward = +forward)

    # X component
    lw r5, CAM_RIGHT_X
    lw r6, CAM_UP_X
    lw r7, CAM_DX
    fpmul.32 r5, r2, r5                  # dx_cam * right.x
    fpmul.32 r6, r3, r6                  # dy_cam * up.x
    fpmul.32 r7, r4, r7                  # dz_cam * forward.x
    fpadd.32 r5, r5, r6
    fpsub.32 r8, r5, r7                  # r8 = dx_world

    # Y component
    lw r5, CAM_RIGHT_Y
    lw r6, CAM_UP_Y
    lw r7, CAM_DY
    fpmul.32 r5, r2, r5
    fpmul.32 r6, r3, r6
    fpmul.32 r7, r4, r7
    fpadd.32 r5, r5, r6
    fpsub.32 r9, r5, r7                  # r9 = dy_world

    # Z component
    lw r5, CAM_RIGHT_Z
    lw r6, CAM_UP_Z
    lw r7, CAM_DZ
    fpmul.32 r5, r2, r5
    fpmul.32 r6, r3, r6
    fpmul.32 r7, r4, r7
    fpadd.32 r5, r5, r6
    fpsub.32 r10, r5, r7                 # r10 = dz_world

    # Move world dirs into r2, r3, r4 (they need to survive INV_SQRT + 3x RECIPROCAL).
    add r2, r8, 0                        # r2 = dx_world
    add r3, r9, 0                        # r3 = dy_world
    add r4, r10, 0                       # r4 = dz_world

    # --- Length squared ---
    fpmul.32 r5, r2, r2                  # dx²
    fpmul.32 r6, r3, r3                  # dy²
    fpmul.32 r7, r4, r4                  # dz²
    fpadd.32 r5, r5, r6
    fpadd.32 r8, r5, r7                  # r8 = len_sq (INV_SQRT input)

    # --- Inverse length ---
    jmp r9, INV_SQRT                     # r8 in/out (= inv_len on return), r9 link, r10+ clobbered
    # r2, r3, r4 (world dirs) preserved; r8 now holds inv_len


    fpmul.32 r9, r8, r2                   # inv_dx intermediate: inv_len * dx
    sw r9, r0, 12
    jmp r10, RECIPROCAL                  # ray->inv_dx = reciprocal(inv_len * dx)  -- differs: pseudocode does reciprocal(dx) separately
    sw r9, r0, 24                        # store ray->inv_dx
    fpmul.32 r9, r8, r3                   # inv_dy intermediate
    sw r9, r0, 16
    jmp r10, RECIPROCAL                  # ray->inv_dy = reciprocal(inv_len * dy)
    sw r9, r0, 28                        # store ray->inv_dy
    fpmul.32 r9, r8, r4                   # inv_dz intermediate
    sw r9, r0, 20
    jmp r10, RECIPROCAL                  # ray->inv_dz = reciprocal(inv_len * dz)
    sw r9, r0, 32                        # store ray->inv_dz
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
    add r1, r14, 19968             # node = self.sram_node_base_address  AI [53]/[61]: node base moved (was 16128)
    beq r15, r15, start_ray_traversal, true   # goto start_ray_traversal
SKIP_GRABBING_TILE_RAYS:                 # AI [122]: only the gate to give back now (was also setctx 16 / relinquish, [69])
    and r14, r14, 0
    sw r14, GRAB_FROM_TILE_ATOMADDER
    yield r8                             # yield()
    and r2, r2, 0                        # AI [135] (Alex): poll RAYS_COMPLETED only on every 64th idle pass of this core
    add r2, r2, DONE_POLL_CNT            #   (all contexts share the count). The poll was ~62 requests/cycle into stack 0 in run 103.
    atomadd r3, r2, 1
    and r3, r3, 63
    and r2, r2, 0
    bne r3, r2, ray_done, true
    lw r2, RAYS_COMPLETED_HIGH           # uint32_t finished_ray_high = self.ray_result_addr_high  -- differs: pseudocode uses ray_result_addr, asm uses RAYS_COMPLETED
    setmembits r2                        # set_address_bits(finished_ray_high)
    lw r2, RAYS_COMPLETED_LOW            # uint32_t finished_ray_low = self.ray_result_addr_low
    lw_d r2, r2, 0                       # uint32_t rays_finished = load_dram_word(finished_ray_low)
    lw r3, MAX_RAYS                      # uint32_t max_rays = 2560 * 1440 * 16 = 58,982,400 (AI [126]: comment was "* 4")
    bne r2, r3, ray_done, true           # if (rays_finished != max_rays) goto ray_done
    yield r8                             # yield()

# below is the final pass of the main loop, calculating the color of the final image
    getowner                             # get_thread_ownership()
    setctx 14                            # set_ctx(14)  -- differs: pseudocode uses 15
    relinquish true                         # relinquish_ownership(1)
    yield r8                             # yield()
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

FLUSH_PARK:                              # AI [63]: park while LOCAL_QUEUE_FLUSHING is set, then go back to the main loop
    yield r8
    lw r8, LOCAL_QUEUE_FLUSHING
    and r7, r7, 0
    bne r8, r7, FLUSH_PARK, true
    beq r15, r15, ray_done, true
INF_LOOP:
    yield r8                            # yield()
    beq r15, r15, INF_LOOP, true         # goto inf_loop

AABB_INTERSECT: #do not use r4, r9. r0 = ray, r1 = node, r7 = 0
    and r7, r7, 0
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
    lw r10, EPSILON                     # AI [109]: epsilon stays in r10 for the y/z axes
    fpminmax.32 r12, r12, r10, true     # AI [109]: tmin = max(tmin, epsilon), so one compare covers both
    fplt.32 r11, r12, r13               #   "tmin < tmax" and "epsilon < tmax" (was 2 compares + and per axis)
    beq r7, r11, AABB_INTERSECT_RETURN, false  # if (tmax < EPSILON) return false
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
    fplt.32 r11, r12, r13               # AI [109]: tmin already includes epsilon
    beq r7, r11, AABB_INTERSECT_RETURN, false  # if (tmax < EPSILON) return false
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
    fplt.32 r11, r12, r13               # AI [109]: tmin already includes epsilon
    beq r15, r15, AABB_INTERSECT_RETURN, true # return r11

COMPLETE_RAY: #Only register in use is r0. everything else is fair game.
                                        # AI [126]/[127] (Alex): RAYS_COMPLETED is the one completion counter. Every finished ray
                                        #   (primary / bounce / shadow, hit or miss) adds 1 exactly once, and only AFTER its result
                                        #   words are in DRAM: each exit below reads back its last result store (the load returns
                                        #   after the store; the RAW wait holds the increment) and then increments. Leaf: in
                                        #   SHADOW_RAY_OCCLUDED. The frame-end check compares it with MAX_RAYS.
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
    lw r1, RAYS_COMPLETED_HIGH          # AI [127]: RAYS_COMPLETED++ miss: no result words to write
    setmembits r1
    lw r1, RAYS_COMPLETED_LOW
    atomadd_d r15, r1, 1
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
    lw_d r13, r1, 60                    # AI [127]: read back the last result word (returns after the stores above landed)
    and r13, r13, 0                     #   RAW wait on it
    lw r1, RAYS_COMPLETED_HIGH          # AI [127]: RAYS_COMPLETED++ only after this ray's results are in DRAM
    setmembits r1
    lw r1, RAYS_COMPLETED_LOW
    atomadd_d r15, r1, 1
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
    # AI fix [77]: removed `switchctx` here. A producer that switched out between claiming slot 1 and marking it ready could be frozen
    #   by another context's getowner while a consumer spins (no yield) on that slot, and that consumer's core can then never finish
    #   its own getowner (run 44: 16 cores stuck that way). Slots 0 and 2 never had it.
    lbu_d r11, r13, 31                    # r11 = load_dram_byte(slot_base + 31)
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
    lbu_d r11, r13, 31                    # r11 = load_dram_byte(slot_base + 31)
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
                                        # AI [126]: RAYS_COMPLETED++ removed here; this ray was already counted in COMPLETE_RAY
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
                                        # AI fix [51]: word 40 is zeroed below, after roughness is read back (it held roughness until then)
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
    sw r14, r0, 40                      # AI fix [51]: ray->leaf_node_starting_point = 0 now that roughness has been read (r14 = 0)
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
    # AI fix [94]: the bounce ray goes into the spawned-ray pool like the shadow rays, instead of restarting here at the global root.
    #   A drain context that restarted it had to push it into the root main queue (an upstream edge): run 64 showed exactly these
    #   rays (bounce 1, depth 1) closing the deadlock loop. Pool rays are injected only by the spawn-only context ([94] part 3).
    lw r13, SPAWNED_RAY_POOL_HIGH
    setmembits r13
    lw r13, SPAWNED_RAY_POOL_LOW
    add r13, r13, 8                     # &count
BOUNCE_POOL_SPACE:
    atomadd_d r11, r13, 1
    lw r9, MAX_RAYS_IN_RAY_POOL
    bgt r9, r11, BOUNCE_POOL_OK, true
    atomadd_d r15, r13, -1
    beq r15, r15, BOUNCE_POOL_SPACE, true
BOUNCE_POOL_OK:
    add r13, r13, -4                    # &tail
    atomadd_d r11, r13, 32
    lw r9, SPAWNED_RAY_POOL_MASK
    and r11, r9, r11
    add r13, r11, r13
    add r13, r13, 8                     # slot base = pool + 12 + tail
    and r14, r14, 0
BOUNCE_SLOT_WAIT:
    lbu_d r11, r13, 31
    bne r11, r14, BOUNCE_SLOT_WAIT, false
    lw r11, r0, 0
    sw_d r11, r13, 0                    # ox (hit point)
    lw r11, r0, 4
    sw_d r11, r13, 4
    lw r11, r0, 8
    sw_d r11, r13, 8
    lw r11, r0, 12
    sw_d r11, r13, 12                   # dx (bounce direction; the consumer normalizes and recomputes 1/d)
    lw r11, r0, 16
    sw_d r11, r13, 16
    lw r11, r0, 20
    sw_d r11, r13, 20
    lw r11, r0, 52
    sw_d r11, r13, 24                   # pix_xy
    lb r11, r0, 60
    sb_d r11, r13, 28                   # bounce_count
    sb_d r14, r13, 29                   # light_id = 0
    add r9, r14, 1
    sb_d r9, r13, 31                    # ready
    sb r14, r0, 63                      # this context's ray is done
    beq r15, r15, ray_done, true

SHADOW_RAY:
    sll r3, r2, 4                       # r3 = light_id << 4 (each shadow slot is 16 bytes)
    add r1, r1, r3                      # r1 = result_addr_low + shadow * 16 (advance to correct shadow slot)
    lw r4, r0, 56                       # r4 = ray->tri_index
    or r13, r14, 0xFFFF             # r13 = 0xFFFFFFFF
    beq r13, r4, SHADOW_RAY_MUST_BE_CALCULATED, true  # if (ray->tri_index == 0xFFFFFFFF) ray missed, calc lighting
    # ray hit something - shadow is blocked, store 1.0 as len_sq sentinel
    lw r4, ONE                          # r4 = 0x3F800000 = 1.0f
    sw_d r4, r1, 12                     # store_dram_word(result_addr_low + 12, 1.0) - blocked sentinel
    lw_d r4, r1, 12                     # AI [127]: read back the result word, RAW wait, then count
    and r4, r4, 0
    lw r1, RAYS_COMPLETED_HIGH          # AI [127]: RAYS_COMPLETED++ only after this ray's results are in DRAM
    setmembits r1
    lw r1, RAYS_COMPLETED_LOW
    atomadd_d r15, r1, 1
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
    lw_d r3, r1, 12                     # AI [127]: read back the last result word, RAW wait, then count
    and r3, r3, 0
    lw r1, RAYS_COMPLETED_HIGH          # AI [127]: RAYS_COMPLETED++ only after this ray's results are in DRAM
    setmembits r1
    lw r1, RAYS_COMPLETED_LOW
    atomadd_d r15, r1, 1
    sb r14, r0, 63                      # ray->active_ray = 0
                                        # AI [126]: RAYS_COMPLETED++ removed here; this ray was already counted in COMPLETE_RAY
    beq r15, r15, ray_done, true        # goto ray_done

RECIPROCAL:
    lw r11, NEG_MAX                     # r11 = 0x80000000
    and r12, r11, r9                    # r12 = sign bit
    xor r11, r11, 0xFFFF                # r11 = 0x7FFFFFFF
    and r11, r11, r9                    # r11 = |x|
    srl r13, r11, 23                    # r13 = exp (from |x|, NO sign pollution)
    sub r13, r13, 253                   # r13 = 254 - exp = new_exp
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

#UNCONDITIONAL JUMP

EAT_RAY_INTERRUPT: #working with r6-r14
    add r4, r8, 0                           # r4 = return address (saved from r8 by caller convention)
    and r14, r14, 0                         # r14 = 0 (zero register)
    add r6, r14, 32                         # AI [115]: take pipe 32, else 33 (was 32 + my parity: senders always use 32, and the
    nonblock r7, r6                         #   dedicated context 15 is odd). An odd worker that finds a request on 32 also takes it,
    bne r14, r7, EAT_RAY_HAVE, true         #   and the `intena r6` on exit then leaves 32 enabled for it.
    add r6, r14, 33
    nonblock r7, r6
    bne r14, r7, EAT_RAY_HAVE, true
    jmp r15, r4                             # return (nothing waiting)
EAT_RAY_HAVE:
    intdis r6                               # disable_interrupts(channel)
CONTINUE_WITH_EAT_RAY_INTERRUPT:
    block r7, r6                                # r7 = blocking_recv(channel) (full flit value)
    add r8, r7, 0
    srl r13, r7, 17                         # r13 = node_id = flit >> 17
    lw r9, ROOT_NODE_ID              # r9 = self.node_id (sender side)
    beq r13, r9, NODE_IDS_MATCH, true      # if node_id == sender_node_id goto NODE_IDS_MATCH
    add r9, r9, 8192
    beq r13, r9, NODE_IDS_MATCH, true      # if node_id == receiver_node_id goto NODE_IDS_MATCH
reject_ray_interrupt:
    add r10, r14, 8                         # r10 = wrong_core = 8 (reject code)
    sll r10, r10, 24                        # r10 = wrong_core << 24
    and r11, r7, 0xF                       # r11 = self.thread_id (low 4 bits)
    srl r12, r7, 4                          # AI fix [47]: r12 = request >> 4 (core id in low 13 bits; was `and r12, r7, 0xFFF0`, which kept only 12
    sll r12, r12, 19                        #   bits, so WRONG_CORE rejects for cores >= 4096 went to core - 4096)
    srl r12, r12, 13                        # r12 = core_id << 6 (channel position), same as the ACK/REJECT paths
    add r11, r11, 16                        # r11 = self.thread_id + 16 (send channel)
    or r11, r12, r11                        # r11 = destination flit (channel | thread_id)
    sendflit r10, r11                       # send_flit(wrong_core << 24, dest) (reject: wrong node)
    intena r6                               # enable_interrupts(channel)
    jmp r15, r4                             # return

#UNCONDITIONED BRANCH

NODE_IDS_MATCH:
    lw r7, LOCAL_QUEUE_FLUSHING             # r7 = *(self.local_queue_flushing)
    bne r14, r7, reject_ray_interrupt, false # if flushing_queue != 0 goto reject_ray_interrupt
    lbu r9, r0, 63                          # r7 = ray->active_ray (byte at ray+63)
    add r7, r0, 0                           # r9 = local_queue = ray base address
    bne r14, r14, RECEIVE_RAY_DATA, false   # AI fix: never taken. Was 'beq r14, r9' = deposit straight into the interrupted context's ray slot when inactive, without setting r1/word40; the interrupted code then overwrote or mis-started it. Always go through the local queue.
    lw r10, ROOT_NODE_ID             # r10 = sender node id
    beq r13, r10, SENDER_QUEUE_EAT_RAY_INTERRUPT, true  # if node_id == sender goto SENDER_QUEUE
    add r9, r14, LOCAL_RAY_QUEUE              # r9 = receiver ray queue base address
    add r9, r9, 1036
    beq r15, r15, CHECK_IF_SPACE_IN_QUEUE, true  # unconditional goto CHECK_IF_SPACE_IN_QUEUE
SENDER_QUEUE_EAT_RAY_INTERRUPT: 
    add r9, r14, LOCAL_RAY_QUEUE                # r9 = sender ray queue base address
CHECK_IF_SPACE_IN_QUEUE:
    add r10, r9, 2072                       # AI fix [124]: r10 = &used (slots taken and not yet freed by their consumer). Space was
    atomadd r7, r10, 1                      #   checked on count, which a consumer decrements BEFORE copying the slot, so a producer
    add r9, r9, 8                           #   could reuse the slot being copied (run 94: torn ray, r1 odd, panic at 4.95M).
    add r12, r14, 16                        # r12 = 16 (max queue entries)
    bgt r12, r7, SPACE_COUNT_UP, true     # if old_used < 16: reserve
    atomadd r7, r10, -1                     # full: undo
    add r7, r14, 7                          # r7 = reject_ray = 7 (reject code)
    sll r7, r7, 24                          # r7 = reject_ray << 24
    srl r9, r8, 4                       # r9 = core_id high nibble
    sll r9, r9, 19
    srl r9, r9, 13                           # r9 = high nibble shifted to channel position
    and r8, r8, 0xF                         # r8 = core_id low nibble (thread_id)
    add r8, r8, 16                          # r8 = thread_id + 16 (send channel)
    or r9, r9, r8                           # r9 = destination flit
    sendflit r7, r9                         # send_flit(reject_ray << 24, dest) (queue full)
    getclk r7                               # AI [143] (Alex): busyness. Time the rejects: one within IDLE_WINDOW (50K) of the previous
    lw r9, REJ_LAST_TS                      #   reject adds to REJ_CNT, an older one starts it over at 1. SRAM / ALU only after the
    sub r9, r7, r9                          #   sendflit, so no context switch can split it (contexts switch only on yield, blocking
    sw r7, REJ_LAST_TS                      #   receives and not-ready registers): no atomics needed even if several contexts reject.
    lw r10, IDLE_WINDOW
    lw r12, REJ_CNT
    add r12, r12, 1
    bgt r10, r9, REJ_CNT_KEEP, true
    and r12, r12, 0
    add r12, r12, 1
REJ_CNT_KEEP:
    sw r12, REJ_CNT
    intena r6                               # enable_interrupts(channel)
    jmp r15, r4                             # return
SPACE_COUNT_UP:
    atomadd r7, r9, 1                       # AI fix [124]: count = rays available to consumers (r9 = &count)
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
    srl r10, r8, 4
    sll r10, r10, 19
    srl r10, r10, 13
    and r8, r8, 0xF                         # r8 = core_id low nibble (thread_id)
    add r8, r8, 16                          # r8 = thread_id + 16 (send channel)
    or r10, r10, r8                         # r10 = destination flit
    sendflit r9, r10                        # send_flit(ray_ack << 24 | self, dest) (signal ready to receive)
    and r8, r15, 0xF                        # r8 = self.thread_id (receive channel low bits)
    add r8, r8, 0                           # AI fix: read ray data from the data mailbox (thread_id), not 16+thread_id
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
    add r9, r14, 1                          # AI fix [83]: publish the slot only after all 16 words arrived (count was bumped first,
    sb r9, r7, 63                           #   and ray_done could copy a half-written slot). Consumers wait for byte 63.
    intena r6                               # enable_interrupts(channel)
    jmp r15, r4                             # return


# ---------------------------------------------------------------------------------------------
# AI [53] CORE CLONING (static-copy donation). See AI_AUTOMATED_CHANGES.txt [53] for the protocol.
# CLONE_IDLE_HOOK: called from the idle path with link r2. Context 0 only. Returns with r14 = 0.
#   Clobbers r3-r13 and membits.
# ---------------------------------------------------------------------------------------------
CLONE_IDLE_HOOK:
    and r14, r14, 0
    and r3, r15, 0xF
    bne r3, r14, CLONE_HOOK_RET, true    # context 0 only
    lw r3, PREVIOUSLY_IDLE
    bne r3, r14, CLONE_POLL_REQUEST, false   # already in the idle pool: look for a request
    getclk r3                            # AI [84]: no idle registration during warm-up. Before rays reach the deep leaves every core
    lw r4, CLONE_WARMUP                  #   looks idle, so hot leaf nodes donated almost all their cores to the root
    blte r3, r4, CLONE_HOOK_RET, true    #   (run 50: node 4 down to 1 owner with a full queue, node 5 to 13 of 94).
    getclk r3
    lw r4, LAST_OBSERVED_CYCLE
    sub r3, r3, r4                       # cycles since the last idle check
    lw r5, IDLE_WINDOW
    blte r3, r5, CLONE_HOOK_RET, true    # check at most once per IDLE_WINDOW
    getclk r4
    sw r4, LAST_OBSERVED_CYCLE
    lw r4, CLONE_WARMUP_DONE             # AI [136b]: set once reached on this core: skip the DRAM read from then on
    bne r4, r14, CLONE_WARMUP_PASSED, true   # AI [136c]: a flag in the not-downloaded area (0 at power-up; a clone reboot keeps it)
    lw r3, RAYS_COMPLETED_HIGH           # AI [136]: warm-up counted in work, not cycles. With the memory model the boot takes ~750K
    setmembits r3                        #   cycles, so the 400K-cycle CLONE_WARMUP ended before any ray existed and nearly every leaf
    lw r3, RAYS_COMPLETED_LOW            #   registered idle; hot leaf nodes were donated away (run 103: node 4 89 -> 29 owners).
    lw_d r3, r3, 0                       #   No idle registration until CLONE_WARMUP_RAYS rays have completed (checked once per IDLE_WINDOW).
    lw r4, RAY_QUEUE_HIGH
    setmembits r4                        # leave membits as the scan path below does
    add r4, r14, 1000                    # AI [136c]: CLONE_WARMUP_RAYS as an immediate: data below the DO-NOT-INCLUDE line is never
    bgt r4, r3, CLONE_HOOK_RET, true     #   downloaded, so the .data 1000 read as 0 and the gate never held (run 105)
    add r4, r14, 1
    sw r4, CLONE_WARMUP_DONE             # AI [136b]: reached: never poll again
CLONE_WARMUP_PASSED:
    # AI [59]: idle = no context holds an active ray AND my DRAM queue is empty, at CLONE_IDLE_MAX_RAYS consecutive
    #   checks (one per IDLE_WINDOW). Counting rays started (the [53] test) marked busy leaves idle: one leaf ray can
    #   occupy a context for tens of thousands of cycles.
    and r6, r6, 0
    add r6, r6, RAY_ARRAY
    add r8, r14, 16
CLONE_IDLE_SCAN:
    lbu r7, r6, 63
    bne r7, r14, CLONE_NOT_IDLE, false   # a context holds a ray: busy
    add r6, r6, 64
    add r8, r8, -1
    bne r8, r14, CLONE_IDLE_SCAN, true
    lw r3, RAY_QUEUE_HIGH
    setmembits r3
    lw r3, RAY_QUEUE_LOW
    lw_d r4, r3, 8                       # my DRAM queue count
    bgt r4, r14, CLONE_NOT_IDLE, false   # work waiting: busy
    lw r4, TILE_IS_ACTIVE                # AI fix [69]: a core with a partly spawned tile is not idle
    beq r4, r14, CLONE_IDLE_TILE_OK, false
    lw r4, TILE_DATA_COUNT
    sll r4, r4, 16                       # AI [122]: count = low 16 bits
    srl r4, r4, 16
    add r5, r14, 255
    blte r4, r5, CLONE_NOT_IDLE, false
CLONE_IDLE_TILE_OK:
    lw r5, CLONE_IDLE_STREAK
    add r5, r5, 1
    sw r5, CLONE_IDLE_STREAK
    lw r4, CLONE_IDLE_MAX_RAYS           # (now: consecutive idle checks required)
    bgt r4, r5, CLONE_HOOK_RET, true     # not idle long enough yet
    lw_d r4, r3, 24                      # owners of my node's queue
    add r5, r14, 1
    blte r4, r5, CLONE_HOOK_RET, true    # sole owner: never donate (the node would be orphaned)
    add r3, r14, 1
    sw r3, PREVIOUSLY_IDLE               # register once
    lw r3, IDLE_QUEUE_HIGH
    setmembits r3
    lw r4, IDLE_QUEUE_LOW                # idle pool: head(0) tail(4) count(8), slots {u16 core, u16 valid} from +20
    add r5, r4, 4
    atomadd_d r6, r5, 4                  # old tail
    and r6, r6, 0x7FFF
    add r6, r6, r4
    add r6, r6, 20                       # my slot
CLONE_ENQ_WAIT:
    lhu_d r7, r6, 2
    bne r7, r14, CLONE_ENQ_WAIT, false   # wait until the slot is free
    srl r7, r15, 4
    sh_d r7, r6, 0                       # slot.core = me
    add r7, r14, 1
    sh_d r7, r6, 2                       # slot.valid = 1
    add r5, r4, 8
    atomadd_d r7, r5, 1                  # count++ (published after the slot is written)
    beq r15, r15, CLONE_HOOK_RET, true
CLONE_POLL_REQUEST:
    lw r3, IDLE_QUEUE_HIGH
    setmembits r3
    lw r4, CLONE_REQ_TABLE_LOW
    srl r5, r15, 4
    sll r5, r5, 2
    add r4, r4, r5                       # &REASSIGN[me]
    lw_d r5, r4, 0
    beq r5, r14, CLONE_HOOK_RET, true    # no request
    and r9, r9, 0                        # r9 = 0: core not stopped yet
    jmp r13, CLONE_SAFE_CHECK            # quick check before draining
    add r3, r14, 1                       # AI [63]: drain first. With LOCAL_QUEUE_FLUSHING set the intake handler rejects new rays
    sw r3, LOCAL_QUEUE_FLUSHING          #   and idle contexts park in FLUSH_PARK; in-flight rays finish normally.
    getclk r3                            # AI [145]: r3 = drain start cycle (r2, r3, r5 survive yields; r4, r6-r14 do not)
CLONE_DRAIN_WAIT:
    yield r8
    and r14, r14, 0
    getclk r4                            # AI [145] (Alex): drain timeout back (removed in [98] on "the drain always finishes"). It does not
    sub r4, r4, r3                       #   when a context holds a ray it cannot push (target DRAM queue full: ENSURE_SPACE_IN_QUEUE forever):
    lw r6, IDLE_WINDOW                   #   run 111 ended with ~24% of leaf contexts parked in FLUSH_PARK on frozen donors. After IDLE_WINDOW
    blte r6, r4, CLONE_DRAIN_GIVEUP, false #   (50K) cycles: clear LOCAL_QUEUE_FLUSHING and resume (the request is kept for a later try).
    jmp r13, CLONE_QUIET_CHECK           # r6 = 0 once no context holds a ray and the local queue is empty
    bne r6, r14, CLONE_DRAIN_WAIT, true
    add r6, r14, GRAB_FROM_TILE_ATOMADDER # AI fix [96]: take the tile-grab gate first. Context 15 (spawn-only [94]) can hold getowner in
    atomadd r6, r6, 1                    #   the tile path, and a second getowner trips the ownership assert (run 66: core 6175, cycle 2.02M).
    bne r6, r14, CLONE_DRAIN_WAIT, true  # gate busy: retry (its holder resets it to 0)
    getowner                             # quick now: the other contexts sit in yield loops
    add r9, r14, 1                       # r9 = 1: we own the core
    jmp r13, CLONE_SAFE_CHECK            # recheck with the core stopped
    lw r3, IDLE_QUEUE_HIGH
    setmembits r3
    lw r4, CLONE_REQ_TABLE_LOW           # AI [63]: recompute &REASSIGN[me] (r4 was clobbered by the yields)
    srl r6, r15, 4
    sll r6, r6, 2
    add r4, r4, r6
    lw_d r5, r4, 0                       # AI fix [89]: reload the request (requester + 1). r5 does not survive the drain-loop yields on
                                         #   the leaf: EAT_RAY_INTERRUPT saves the flit in r5, so the donor copied the boot entry of a garbage
                                         #   core id and rebooted with a garbage node index (the clones stuck forever in FIND_BRANCH_NODE).
    bne r5, r14, CLONE_REQ_HAVE, true    # AI fix [121]: no request left (r9 = 1: we own the core): abort instead of copying core -1's entry,
    sw r14, PREVIOUSLY_IDLE              #   and leave the idle pool flag clear so the core can register again
    beq r15, r15, CLONE_BUSY_ABORT, true
CLONE_REQ_HAVE:
    sw_d r14, r4, 0                      # consume the request
    add r5, r5, -1                       # r5 = requester core id
    lw r3, RAY_QUEUE_HIGH                # leave my old node's owner list (same writer lock as initialize_core)
    setmembits r3
    lw r3, RAY_QUEUE_LOW
    add r4, r3, 12
    atomadd_d r6, r4, 1                  # my ticket
CLONE_TICKET_WAIT:
    lw_d r7, r3, 16
    bne r7, r6, CLONE_TICKET_WAIT, true
    add r4, r3, 20
    add r7, r14, -8192
    atomadd_d r8, r4, r7                 # writer: lock -= 8192
CLONE_WRITER_WAIT:
    lw_d r8, r4, 0
    bne r8, r7, CLONE_WRITER_WAIT, true  # wait for readers to drain
    lw_d r9, r3, 24                      # owner_count
    lw r12, CLONE_MIN_OWNERS             # AI fix [72]: never leave a node with fewer owners than this (checked under the writer lock;
    blte r9, r12, CLONE_LAST_OWNER, false #   the registration-time check races when many owners of one node donate at once)
    add r10, r3, 28                      # core_slots
    srl r11, r15, 4
                                         # AI [125] (Alex): O(1) leave fast path enabled (was commented out in [100]):
#Alex's O(1) fast path: the core_slots list must stay packed for random owner picks, so a leave swaps the last
#   entry into the leaver's slot and the moved core's position changes. Each core caches where it THINKS it is (CLONE_MY_SLOT,
#   written at registration) and checks that one slot with a single DRAM read; on a miss (stale after someone else's swap, or never
#   set for cores placed at startup) it falls back to the linear search below. CLONE_FOUND_SLOT expects r13 = &core_slots[i].
     lw r12, CLONE_MY_SLOT                # cached index (0xFFFF = unknown)
     blte r9, r12, CLONE_O1_MISS, true    # index >= owner_count: cannot be valid
     sll r13, r12, 1
     add r13, r13, r10
     lhu_d r8, r13, 0
     beq r8, r11, CLONE_FOUND_SLOT, true  # hit: O(1)
CLONE_O1_MISS:
    and r12, r12, 0
CLONE_FIND_SLOT:
    beq r12, r9, CLONE_SLOT_DONE, false
    sll r13, r12, 1
    add r13, r13, r10
    lhu_d r8, r13, 0
    beq r8, r11, CLONE_FOUND_SLOT, false
    add r12, r12, 1
    beq r15, r15, CLONE_FIND_SLOT, true
CLONE_FOUND_SLOT:
    add r12, r9, -1
    sll r12, r12, 1
    add r12, r12, r10                    # last slot
    lhu_d r8, r12, 0
    sh_d r8, r13, 0                      # slots[i] = last
    sh_d r14, r12, 0
    add r12, r3, 24
    atomadd_d r8, r12, -1                # owner_count--
    beq r15, r15, CLONE_SLOT_DONE, true
CLONE_LAST_OWNER:                        # AI fix [72]: abort the donation: release the lock, resume, and allow re-registering later
    add r12, r3, 20
    atomadd_d r8, r12, 8192              # release the writer lock
    add r12, r3, 16
    atomadd_d r8, r12, 1                 # now_serving++
    and r14, r14, 0
    sw r14, PREVIOUSLY_IDLE
    sw r14, LOCAL_QUEUE_FLUSHING
    setctx 16                            # undo the getowner
    relinquish false
    sw r14, GRAB_FROM_TILE_ATOMADDER     # AI fix [96]: release the gate
    beq r15, r15, CLONE_HOOK_RET, true
CLONE_SLOT_DONE:
    add r12, r3, 20
    atomadd_d r8, r12, 8192              # release the writer lock
    add r12, r3, 16
    atomadd_d r8, r12, 1                 # now_serving++
    and r3, r3, 0
    setmembits r3                        # boot table (initialize_core: 20000 + core*8) is in stack 0
    srl r8, r15, 4                       # AI [102]: CLONE_SRC[me] = requester + 1: my boot asks it for its geometry over the NoC
    sll r8, r8, 2
    lw r9, CLONE_SRC_LOW
    add r8, r8, r9
    add r9, r5, 1
    sw_d r9, r8, 0
    sll r5, r5, 3
    add r5, r5, 20000
    lw_d r6, r5, 0                       # requester's node_id
    lw_d r7, r5, 4                       # requester's is_branch | index
    add r9, r14, 1                       # AI [61]: mark the copied entry as a clone reboot (bit 30)
    sll r9, r9, 30
    or r7, r7, r9
    srl r8, r15, 4
    sll r8, r8, 3
    add r8, r8, 20000
    sw_d r6, r8, 0
    sw_d r7, r8, 4                       # I am now a copy of the requester's node
    intdis 32
    intdis 33
    intdis 34
    intdis 35
    intdis 36
    and r0, r0, 0                        # AI [58]: the bootloader's `and r0; setmembits r0` back-to-back reads a stale r0 (no forwarding
                                         #   into setmembits), so r0 must already be 0 when we jump there
    beq r15, r15, 0, true                # reboot through the bootloader (context 0 owns the core, all others parked)
CLONE_SAFE_CHECK:                        # link r13. Returns only if no ray is held anywhere on this core.
    and r6, r6, 0
    add r6, r6, RAY_ARRAY
    add r8, r14, 16
CLONE_SLOT_LOOP:
    lbu r7, r6, 63
    bne r7, r14, CLONE_BUSY_ABORT, false # some context holds an active ray
    add r6, r6, 64
    add r8, r8, -1
    bne r8, r14, CLONE_SLOT_LOOP, true
    add r6, r14, LOCAL_RAY_QUEUE
    lw r7, r6, 8                         # even local queue count (the receiver local queue is never drained, see NOTE after [49])
    bne r7, r14, CLONE_BUSY_ABORT_RET, false
    lw r7, TILE_IS_ACTIVE                # AI fix [69]: never donate while holding a partly spawned tile (its pixels would be lost)
    beq r7, r14, CLONE_SAFE_TILE_OK, false
    lw r7, TILE_DATA_COUNT
    sll r7, r7, 16                       # AI [122]: count = low 16 bits
    srl r7, r7, 16
    add r8, r14, 255
    blte r7, r8, CLONE_BUSY_ABORT_RET, false
CLONE_SAFE_TILE_OK:
    jmp r15, r13
CLONE_NOT_IDLE:
    sw r14, CLONE_IDLE_STREAK            # AI [59]: busy at this check: restart the streak
    beq r15, r15, CLONE_HOOK_RET, true
CLONE_BUSY_ABORT_RET:
CLONE_DRAIN_GIVEUP:                      # AI [63]: could not drain in time: resume, keep the request for a later try
    and r14, r14, 0
    sw r14, LOCAL_QUEUE_FLUSHING
    beq r15, r15, CLONE_HOOK_RET, true
CLONE_QUIET_CHECK:                       # AI [63]: link r13. r6 = 0 if no context holds a ray and the local queue is empty, else 1
    and r6, r6, 0
    add r6, r6, RAY_ARRAY
    add r8, r14, 16
CLONE_QUIET_LOOP:
    lbu r7, r6, 63
    bne r7, r14, CLONE_QUIET_BUSY, false
    add r6, r6, 64
    add r8, r8, -1
    bne r8, r14, CLONE_QUIET_LOOP, true
    add r6, r14, LOCAL_RAY_QUEUE
    lw r7, r6, 8
    bne r7, r14, CLONE_QUIET_BUSY, false
    and r6, r6, 0
    jmp r15, r13
CLONE_QUIET_BUSY:
    add r6, r14, 1
    jmp r15, r13
CLONE_BUSY_ABORT:
    beq r9, r14, CLONE_HOOK_RET, true    # not stopped yet: just return
    sw r14, LOCAL_QUEUE_FLUSHING         # AI [63]: end the drain
    setctx 16                            # undo the getowner: make every context runnable again
    relinquish false
    sw r14, GRAB_FROM_TILE_ATOMADDER     # AI fix [96]: release the gate
CLONE_HOOK_RET:
    and r14, r14, 0
    jmp r15, r2
# CLONE_REQUEST: busy side. Link r7. Uses r9-r14 only (r14 returns 0); restores membits to RAY_QUEUE_HIGH.
CLONE_REQUEST:
    and r14, r14, 0
                                         # AI [95]: [90] CLONE_MAX_OWNERS limit removed
    lw r9, IDLE_QUEUE_HIGH
    setmembits r9
    lw r10, IDLE_QUEUE_LOW
    lw_d r11, r10, 8                     # peek count
    blte r11, r14, CLONE_REQ_RET, true
    lw r9, EMERGENCY_QUEUE_HIGH          # AI [100]: per-node request cooldown. {next_allowed, lock} at CLONE_REQ_CD_LOW + q*8 (stack 0).
    setmembits r9                        #   Without it every owner of a hot node asked independently (no [90] cap): node 5 reached 1756
    lw r9, ROOT_NODE_ID                  #   cores in run 69, then most of them left at once and the serialized exodus stalled the chip.
    sll r9, r9, 3
    lw r11, CLONE_REQ_CD_LOW
    add r9, r9, r11
    getclk r12
    lw r11, CLONE_NEXT_REQ               # AI [137] (Alex): cooldown per requesting core (was per node in DRAM, which capped a node's
    bgt r11, r12, CLONE_REQ_RET, true    #   growth at one core per cooldown no matter how many owners it had: linear growth)
    add r13, r9, 4
    atomadd_d r11, r13, 1
    bne r11, r14, CLONE_REQ_RET, false   # another owner of my node is requesting right now
    lw r11, CLONE_REQ_COOLDOWN
    add r12, r12, r11
    sw r12, CLONE_NEXT_REQ               # AI [137]: my next allowed request = now + cooldown
    sw_d r14, r13, 0                     # release (late losers' increments are wiped here)
    lw r9, IDLE_QUEUE_HIGH
    setmembits r9
    add r12, r10, 8
    atomadd_d r11, r12, -1
    bgt r11, r14, CLONE_REQ_CLAIM, true
    atomadd_d r11, r12, 1                # undo
    beq r15, r15, CLONE_REQ_RET, true
CLONE_REQ_CLAIM:
    atomadd_d r11, r10, 4                # old head
    and r11, r11, 0x7FFF
    add r11, r11, r10
    add r11, r11, 20
CLONE_REQ_WAIT:
    lhu_d r12, r11, 2
    beq r12, r14, CLONE_REQ_WAIT, false  # wait for the enqueuer to publish
    lhu_d r12, r11, 0                    # idle core id
    sh_d r14, r11, 2                     # free the slot
    srl r13, r15, 4
    beq r12, r13, CLONE_REQ_SELF, false  # never ask myself (AI fix [72]: but drop my registration, or I could never be asked again)
    lw r11, CLONE_REQ_TABLE_LOW
    sll r12, r12, 2
    add r11, r11, r12
    add r13, r13, 1
    sw_d r13, r11, 0                     # REASSIGN[idle] = me + 1
    beq r15, r15, CLONE_REQ_RET, true
CLONE_REQ_SELF:
    sw r14, PREVIOUSLY_IDLE              # AI fix [72]
CLONE_REQ_RET:
    lw r9, RAY_QUEUE_HIGH
    setmembits r9
    and r14, r14, 0
    jmp r15, r7

# AI [64]: the routines below were replaced by CLONE_IDLE_HOOK / CLONE_REQUEST ([53]) and are commented out to free SRAM (unchanged text, prefixed '#AI[64] ')
#AI[64] IS_IDLE_BRANCH:
#AI[64]     getclk r3                               # r3 = current_cycle = get_cycle_count()
#AI[64]     lw r4, LAST_OBSERVED_CYCLE              # r4 = self.last_observed_cycle
#AI[64]     sub r3, r3, r4                          # r3 = time_diff = current_cycle - last_observed_cycle
#AI[64]     and r14, r14, 0                         # r14 = 0 (zero register)
#AI[64]     lw r5, IDLE_WINDOW                      # r5 = IDLE_WINDOW (minimum time between idle checks)
#AI[64]     bgt r3, r5, PASSED_BRANCH_WINDOW, false # if time_diff <= IDLE_WINDOW goto return (too soon)
#AI[64]     jmp r15, r2                             # return 0 (not enough time has passed)
#AI[64] PASSED_BRANCH_WINDOW:
#AI[64]     lw r4, PREVIOUSLY_IDLE                  # r4 = self.previously_idle
#AI[64]     beq r4, r14, NOT_PREVIOUSLY_IDLE, false # if previously_idle == 0 goto NOT_PREVIOUSLY_IDLE
#AI[64]     jmp r15, r2                             # return 0 (already marked idle, nothing to do)
#AI[64] NOT_PREVIOUSLY_IDLE:
#AI[64]     getclk r5                               # r5 = current_cycle (fresh timestamp)
#AI[64]     sw r5, LAST_OBSERVED_CYCLE              # self.last_observed_cycle = current_cycle
#AI[64]     lw r5, RAYS_PROCESSED                   # r5 = self.rays_processed
#AI[64]     sw r14, RAYS_PROCESSED                  # self.rays_processed = 0 (reset counter)
#AI[64]     sll r5, r5, 16                          # r5 = rays_processed << 16 (fixed-point scale for division)
#AI[64]     div r5, r5, r3                          # r5 = ratio = (rays_processed << 16) / time_diff
#AI[64]     lw r4, BRANCH_IDLE_THRESHOLD            # r4 = BRANCH_IDLE_THRESHOLD
#AI[64]     blte r4, r5, ONLY_ENQUEUE_ONCE_IDLE_QUEUE, false # if ratio >= threshold goto ONLY_ENQUEUE_ONCE_IDLE_QUEUE (busy enough)
#AI[64]     jmp r15, r2                             # return 0 (not idle enough to enqueue)
#AI[64] ONLY_ENQUEUE_ONCE_IDLE_QUEUE:
#AI[64]     add r6, r14, PREVIOUSLY_IDLE            # r6 = &PREVIOUSLY_IDLE
#AI[64]     atomadd r6, r6, 1                       # atomic_add(&previously_idle, 1)
#AI[64]     beq r6, r14, ADD_IDLE_CORE, true       # if old_value == 0 goto ADD_IDLE_CORE
#AI[64]     jmp r15, r2                             # return 
    
#AI[64] ADD_IDLE_CORE:
#AI[64]     lw r3, IDLE_QUEUE_HIGH                  # r3 = self.idle_queue_address_high
#AI[64]     setmembits r7, r3                       # set_address_bits(idle_queue_high), r7 = old membits (saved)  AI fix: operands were swapped
#AI[64]     lw r4, IDLE_QUEUE_LOW                   # r4 = idle_queue_address_low (base of idle_core_queue_dram)
#AI[64]     add r4, r4, 8                           # r4 = &idle_queue.count (skip head_relative + tail_relative)
#AI[64]     atomadd_d r5, r4, 1                     # r5 = old_count = atomic_add_dram(&count, 1)
#AI[64]     add r4, r4, -4                          # r4 = &idle_queue.tail_relative
#AI[64]     atomadd_d r5, r4, 4                     # r5 = old_tail = atomic_add_dram(&tail_relative, 4)
#AI[64]     add r4, r4, 16                           # r4 = &idle_queue.slots (skip tail_relative + count)
#AI[64]     and r5, r5, 0x7FFF                      # r5 = slot_offset = old_tail & 0x7FFF (wrap within slots)
#AI[64]     add r4, r4, r5                          # r4 = slot_addr = &slots + slot_offset
#AI[64] IDLE_CORE_INSERT_SPINLOCK:
#AI[64]     lhu_d r5, r4, 2                         # r5 = is_valid = load_dram_half(slot_addr + offsetof(is_valid))
#AI[64]     bne r14, r5, IDLE_CORE_INSERT_SPINLOCK, false  # spin until is_valid == 0 (slot is free)
#AI[64]     srl r5, r15, 4                          # r5 = self.core_id = r15 >> 4 (strip thread_id bits)
#AI[64]     sh_d r5, r4, 0                          # store_dram_half(core_id, slot_addr + offsetof(core_id))
#AI[64]     add r5, r14, 1                          # r5 = 1
#AI[64]     sh_d r5, r4, 2                          # store_dram_half(1, slot_addr + offsetof(is_valid)) (mark ready)
#AI[64]     setmembits r7
#AI[64]     jmp r15, r2                             # return

#AI[64] SEARCH_FOR_IDLE_CORES: #There's no documentation of who uses this function
#AI[64] #I am going to assume that r3 has a return address
#AI[64]     and r14, r14, 0                     # r14 = 0 (zero register)
#AI[64]     lw r5, IDLE_QUEUE_HIGH      # r5 = self.idle_queue_address_high
#AI[64]     setmembits r15, r5                  # set_address_bits(idle_queue_high)  AI fix: was 'setmembits r5, r4' (set bits to r4 = ray count -> bad stack index panic)
#AI[64]     sw r5, SEARCH_FOR_IDLE_CORES_STORAGE # save idle_queue_address_high to scratch storage  AI fix: was r4
#AI[64]     add r5, r14, DFS_STACK              # r5 = &DFS_STACK (dfs stack pointer)
#AI[64]     lw r6, IDLE_QUEUE_LOW       # r6 = current = self.idle_queue_address_low
#AI[64]     or r8, r8, 0xFFFF                   # r8 = 0xFFFFFFFF (found_core_id sentinel = not found)
#AI[64]     atomadd_d r9, r6, -1                # r9 = old_count = atomic_add_dram(current.count, -1)
#AI[64]     lw r4, SEARCH_FOR_IDLE_CORES_STORAGE;
#AI[64]     setmembits r4
#AI[64]     add r4, r6, 0                       # r4 = current (base addr of leaf idle_core_queue_dram)
#AI[64]     bgt r9, r14, CLAIM_SLOT, false      # if old_count > 0 goto CLAIM_SLOT (fast path: slot available)
#AI[64]     atomadd_d r9, r6, 1                 # revert: atomic_add_dram(current.count, 1)
#AI[64]     lw_d r7, r6, 12                     # r7 = current.parent_node_high (idle_core_queue_dram.parent_node_high)
#AI[64]     lw_d r6, r6, 16                     # r6 = current.parent_node_low (idle_core_queue_dram.parent_node_low)
#AI[64]     setmembits r7                       # set_address_bits(parent_node_high)
#AI[64] ASCEND:
#AI[64]     lh_d r9, r6, 24                     #r9 = is_left
#AI[64]     lh_d r10, r6, 26                    #r10 = height
#AI[64]     lw_d r11, r6, 0                     #r11 = parent_high
#AI[64]     sw r11, SAVED_BRANCH_HIGH           # save parent_high before DFS_LOOP clobbers r11
#AI[64]     lw_d r12, r6, 4                     #r12 = parent_low
#AI[64]     sw r12, SAVED_BRANCH_LOW            # save parent_low before DFS_LOOP clobbers r12
#AI[64]     or r13, r13, 0xFFFF                 # r13 = 0xFFFFFFFF (sentinel for null parent)
#AI[64]     beq r11, r13, SEARCH_DONE, false    # if parent_high == 0xFFFFFFFF goto SEARCH_DONE (reached root)
#AI[64]     setmembits r11                      # set_address_bits(parent_high)
#AI[64] PUSH_SIBLING:
#AI[64]     beq r14, r9, RIGHT_NODE, false      # if is_left == 0 goto RIGHT_NODE (we are right child, sibling is left)
#AI[64]     lw_d r6, r12, 16                    # r6 = sibling_high = parent->right_high (we are left child)
#AI[64]     lw_d r7, r12, 20                    # r7 = sibling_low = parent->right_low
#AI[64]     beq r15, r15, SKIP_RIGHT_NODE, true # unconditional goto SKIP_RIGHT_NODE
#AI[64] RIGHT_NODE:
#AI[64]     lw_d r6, r12, 8                     # r6 = sibling_high = parent->left_high (we are right child)
#AI[64]     lw_d r7, r12, 12                    # r7 = sibling_low = parent->left_low
#AI[64] SKIP_RIGHT_NODE:
#AI[64]     sw r6, r5, 0                        # dfs_stack[top].high = sibling_high
#AI[64]     sw r7, r5, 4                        # dfs_stack[top].low = sibling_low
#AI[64]     sh r10, r5, 8                       # dfs_stack[top].height = height (sibling same height as us)
#AI[64]     add r5, r5, 12                      # dfs_top++ (advance stack pointer by sizeof(DFS_Entry))
#AI[64] DFS_LOOP_CORE_SEARCH:
#AI[64]     add r13, r14, DFS_STACK             # r13 = base address of DFS_STACK
#AI[64]     beq r13, r5, SIBLING_EXHAUSTED, false # if stack empty (top == base) goto SIBLING_EXHAUSTED
#AI[64]     add r5, r5, -12                     # dfs_top-- (pop stack)
#AI[64]     lw r4, r5, 0                        # r4 = dfs_stack[top].high
#AI[64]     setmembits r4                       # set_address_bits(dfs_node_high)
#AI[64]     lw r4, r5, 4                        # r4 = dfs_node = dfs_stack[top].low
#AI[64]     lhu r13, r5, 8                      # r13 = dfs_node_height = dfs_stack[top].height
#AI[64]     beq r13, r14, TRY_DEQUEUE, true    # if dfs_node_height == 0 goto TRY_DEQUEUE (leaf node)
#AI[64]     add r13, r13, -1                    # r13 = child_height = dfs_node_height - 1
#AI[64]     lw_d r11, r4, 16                    # r11 = right_high = dfs_node->right_high
#AI[64]     lw_d r12, r4, 20                    # r12 = right_low = dfs_node->right_low
#AI[64]     sw r11, r5, 0                       # dfs_stack[top].high = right_high (push right child)
#AI[64]     sw r12, r5, 4                       # dfs_stack[top].low = right_low
#AI[64]     sh r13, r5, 8                       # dfs_stack[top].height = child_height
#AI[64]     add r5, r5, 12                      # dfs_top++
#AI[64]     lw_d r11, r4, 8                     # r11 = left_high = dfs_node->left_high
#AI[64]     lw_d r12, r4, 12                    # r12 = left_low = dfs_node->left_low
#AI[64]     sw r11, r5, 0                       # dfs_stack[top].high = left_high (push left child, visited first)
#AI[64]     sw r12, r5, 4                       # dfs_stack[top].low = left_low
#AI[64]     sh r13, r5, 8                       # dfs_stack[top].height = child_height
#AI[64]     add r5, r5, 12                      # dfs_top++
#AI[64]     beq r15, r15, DFS_LOOP_CORE_SEARCH, true       # unconditional goto DFS_LOOP
#AI[64] TRY_DEQUEUE:
#AI[64]     add r4, r4, 8                       # r4 = count_addr = dfs_node + offsetof(idle_core_queue_dram, count)
#AI[64]     atomadd_d r9, r4, -1               # r9 = old_count = atomic_add_dram(count_addr, -1)
#AI[64]     bgt r9, r14, CLAIM_SLOT, false     # if old_count > 0 goto CLAIM_SLOT (successfully claimed a slot)
#AI[64]     atomadd_d r9, r4, 1                # revert: atomic_add_dram(count_addr, 1)
#AI[64]     beq r15, r15, DFS_LOOP_CORE_SEARCH, true       # unconditional goto DFS_LOOP (try next node)
#AI[64] CLAIM_SLOT:
#AI[64]     add r4, r4, -8                      # r4 = dfs_node base (head_relative is at offset 0)
#AI[64]     atomadd_d r9, r4, 4                # r9 = old_head = atomic_add_dram(head_relative, 4)
#AI[64]     and r9, r9, 0x7FFF                 # r9 = head_relative & 0x7FFF (wrap within 8192 slots * 4 bytes)
#AI[64]     add r4, r4, r9                      # r4 = dfs_node + head_relative
#AI[64]     add r4, r4, 20                      # r4 = slot_addr = dfs_node + offsetof(slots) + head_relative
#AI[64] SPINLOCK_VALID:
#AI[64]     lhu_d r9, r4, 2                     # r9 = is_valid = load_dram_half(slot_addr + offsetof(is_valid))
#AI[64]     beq r9, r14, SPINLOCK_VALID, false # spin until is_valid != 0 (enqueuer hasn't written yet)
#AI[64]     lhu_d r8, r4, 0                     # r8 = found_core_id = load_dram_half(slot_addr + offsetof(core_id))
#AI[64]     sh_d r14, r4, 2                     # store_dram_half(0, slot_addr + offsetof(is_valid)) (clear slot)
#AI[64]     beq r15, r15, SEARCH_DONE, true    # unconditional goto SEARCH_DONE
#AI[64] SIBLING_EXHAUSTED:
#AI[64]     lw r11, SAVED_BRANCH_HIGH           # r11 = saved parent_high
#AI[64]     setmembits r11                      # set_address_bits(parent_high)
#AI[64]     lw r6, SAVED_BRANCH_LOW            # r6 = current = saved parent_low (ascend to parent)
#AI[64]     beq r15, r15, ASCEND, true         # unconditional goto ASCEND
#AI[64] SEARCH_DONE:
#AI[64]     or r9, r9, 0xFFFF                   # r9 = 0xFFFFFFFF (sentinel value for comparison)
#AI[64]     beq r9, r8, ray_done, false        # if found_core_id == 0xFFFFFFFF (not found) goto RAY_DONE
#AI[64]     sendflit r15, r8, 34               # send_flit(self.thread_id, found_core_id, 34) (probe message)
#AI[64]     and r9, r15, 0xF                   # r9 = self.thread_id = r15 & 0xF
#AI[64]     add r9, r9, 16                     # r9 = 16 + self.thread_id (receive channel)
#AI[64]     block r9, r9                        # r9 = will_accept_change = blocking_recv(16 + self.thread_id)
#AI[64]     srl r11, r9, 24                     # r11 = will_accept_change >> 24 (response code)
#AI[64]     add r10, r14, 14                    # r10 = REJECT_CHANGE = 14
#AI[64]     beq r11, r10, ray_done, false      # if response == REJECT_CHANGE goto RAY_DONE
#AI[64]     add r10, r14, 1                     # r10 = 1
#AI[64]     sendflit r10, r8, 0                # send_flit(1, found_core_id, 0) (acknowledge transfer)
#AI[64]     and r11, r9, 1                      # r11 = will_accept_change & 1 (target core type: 0=leaf, 1=branch)
#AI[64]     lw r12, IS_BRANCH_CORE             # r12 = self.is_branch_core
#AI[64]     beq r11, r12, TRANSFER_GEO, false  # if target type == self type, skip code transfer
#AI[64]     lw r12, BRANCH_START_OF_CODE       # r12 = branch_start_of_code
#AI[64]     lw r5, BRANCH_NUM_INSTRUCTION_BYTES # r5 = num instruction bytes
#AI[64]     add r5, r12, r5                     # r5 = end address of code region
#AI[64] TRANSFER_BRANCH_CODE_LOOP:
#AI[64]     lw r6, r12, 0                       # r6 = instruction_to_send = *(branch_start_of_code + i)
#AI[64]     sendflit r6, r8, 0                  # send_flit(instruction_to_send, found_core_id, 0)
#AI[64]     add r12, r12, 4                     # i += 4
#AI[64]     bne r5, r12, TRANSFER_BRANCH_CODE_LOOP, true # loop until end of code region
#AI[64] TRANSFER_GEO:
#AI[64]     lw r12, BRANCH_START_OF_GEO        # r12 = branch_start_of_geometry
#AI[64]     lw r5, BRANCH_SIZE_OF_GEO          # r5 = size_of_geo in bytes
#AI[64]     add r5, r12, r5                     # r5 = end address of geometry region
#AI[64] TRANSFER_BRANCH_GEO_LOOP:
#AI[64]     lw r6, r12, 0                       # r6 = word_to_transfer = *(branch_start_of_geometry + i)
#AI[64]     sendflit r6, r8, 0                  # send_flit(word_to_transfer, found_core_id, 0)
#AI[64]     add r12, r12, 4                     # i += 4
#AI[64]     bne r5, r12, TRANSFER_BRANCH_GEO_LOOP, true # loop until end of geometry region
#AI[64]     beq r15, r15, ray_done, true       # unconditional goto RAY_DONE



IRQ_CTX:                                 # AI [115]: dedicated interrupt context (15). Handlers return to the yield.
    intena 32
    intena 33
    intena 34
IRQ_CTX_LOOP:
    yield r8
    beq r15, r15, IRQ_CTX_LOOP, true
NOC_GEO_RECEIVE:                         # AI [102]: link r13, r14 = 0. NoC clone boot: receive the geometry from a live owner of my node
                                         #   (Alex's original protocol: the requester streams its SRAM contents over the NoC) instead of the
                                         #   DFS download from DRAM. Returns (-> DFS from DRAM) if this is no NoC clone, the source no longer
                                         #   owns my node, or nothing arrives within NOC_RX_TIMEOUT cycles.
    lw r12, EMERGENCY_QUEUE_HIGH         # stack 0
    setmembits r12
    srl r11, r15, 4                      # my core id
    sll r12, r11, 2
    lw r10, CLONE_SRC_LOW
    add r12, r12, r10                    # &CLONE_SRC[me]
    lw_d r10, r12, 0                     # source core + 1 (written by my donor path), 0 = none
    beq r10, r14, NOC_RX_FAIL, true
    sw_d r14, r12, 0                     # consume
    add r10, r10, -1
    sll r7, r10, 6                       # source core << 6
    add r6, r14, 16                      # AI [113]: replies (OFFER/REFUSE/BUSY/NACK) come to my response mailbox 16 + context (context 0
NOC_RX_DRAIN:                            #   at boot), lane 0. Only the REQUEST travels on the source's pipe 34 (lane 1). Drop stale words first.
    nonblock r12, r6
    beq r12, r14, NOC_RX_DRAINED, true
    block r12, r6
    beq r15, r15, NOC_RX_DRAIN, true
NOC_RX_DRAINED:
    or r10, r7, 34                       # source, pipe 34
    jmp r12, NOC_NODE_KEY                # r9 = key of my node
    sll r11, r11, 17
    or r5, r11, r9                       # r5 = REQUEST: (my core id << 17) | node key, bit 31 = 0 (r4, r5 are free before the DFS)
    getclk r4
    lw r12, NOC_RX_TIMEOUT
    add r4, r4, r12                      # r4 = deadline
NOC_RX_SEND:
    sendflit r5, r10                     # 1. REQUEST
NOC_RX_WAIT:
    nonblock r12, r6
    bne r12, r14, NOC_RX_GOT, true
    getclk r12
    bgt r4, r12, NOC_RX_WAIT, true
    beq r15, r15, NOC_RX_FAIL, true      # AI [113]: timeout, no CANCEL: a source that offers drops it after NOC_GO_TIMEOUT by itself; a
                                         #   late reply left in mailbox 16 is skipped by the ray-send loop (bit 31 set)
NOC_RX_GOT:
    block r12, r6
    srl r8, r12, 4                       # AI [113]: r8 = the source's streaming context (bits 4..7 of an OFFER, 0 in the others)
    and r8, r8, 0xF
    sll r11, r8, 4
    sub r12, r12, r11                    # strip it
    lw r11, NOC_MAGIC
    beq r12, r11, NOC_RX_GO, true        # 2. OFFER  (0xE0000001 | ctx << 4)
    add r11, r11, 1
    beq r12, r11, NOC_RX_FAIL, true      # 2'. REFUSE (0xE0000002): the source left the node
    add r11, r11, 1
    beq r12, r11, NOC_RX_BUSY, true      # 2''. BUSY (0xE0000003): it is streaming to another clone
    add r11, r11, 1
    beq r12, r11, NOC_RX_BUSY, true      # AI [113] 2'''. NACK (0xE0000004): the router bounced my REQUEST (source pipe 34 full)
    beq r15, r15, NOC_RX_WAIT, true      # anything else: stale, ignore
NOC_RX_BUSY:
    getclk r12
    add r12, r12, 2000
NOC_RX_PAUSE:
    getclk r11
    bgt r12, r11, NOC_RX_PAUSE, true
    bgt r4, r11, NOC_RX_SEND, true       # ask again until the deadline
    beq r15, r15, NOC_RX_FAIL, true      # (no offer outstanding, so no CANCEL)
NOC_RX_GO:
    srl r11, r15, 4                      # 3. GO = 0xC0000000 | my id: only now does the source stream (on my pipe 0)
    add r12, r14, 3
    sll r12, r12, 30
    or r11, r11, r12
    add r12, r8, 16                      # AI [113]: GO goes to the source's response mailbox 16 + its streaming context, lane 0
    or r12, r7, r12
    sendflit r11, r12
    getclk r4                            # AI [113]: the source streams only within NOC_GO_TIMEOUT of its OFFER, so a stream not started
    lw r12, NOC_GO_TIMEOUT               #   2x that after my GO never will: fall back to DRAM instead of blocking forever.
    add r4, r4, r12
    add r4, r4, r12
NOC_RX_FIRST:
    nonblock r9, r14
    bne r9, r14, NOC_RX_REGION, true
    getclk r12
    bgt r4, r12, NOC_RX_FIRST, true
    beq r15, r15, NOC_RX_FAIL, true
NOC_RX_REGION:                           # stream: {SRAM addr, word count, words...}*, 0
    block r9, r14
    beq r9, r14, NOC_RX_OK, true
    block r10, r14
NOC_RX_WORD:
    block r11, r14
    sw r11, r9, 0
    add r9, r9, 4
    add r10, r10, -1
    bne r10, r14, NOC_RX_WORD, true
    beq r15, r15, NOC_RX_REGION, true
NOC_RX_OK:
    lw r12, NODE_ARRAY_HIGH
    setmembits r12
    beq r15, r15, dfs_done, true
NOC_RX_FAIL:
    jmp r15, r13
NOC_GEO_SEND_INTERRUPT:                  # AI [102]: pipe 34 (was the unfinished SWITCH_ROLES_INTERRUPT). A NoC clone asks for my geometry:
                                         #   flit 1 = its core id, flit 2 = the queue address of the node it is joining. Same handler
    add r4, r8, 0                        #   convention as EAT_RAY_INTERRUPT (return address r8 -> r4; uses r4, r6-r14).
    intdis 34
    and r14, r14, 0
    add r6, r14, 34
    nonblock r7, r6
    bne r7, r14, NOC_GS_GO, true
    intena 34
    jmp r15, r4
NOC_GS_GO:
    block r7, r6                         # one handshake word
    srl r9, r7, 31
    beq r9, r14, NOC_GS_REQ, true
    intena 34                            # AI [113]: only REQUESTs travel on pipe 34 now; a bit-31 word is stale: drop
    jmp r15, r4
NOC_GS_REQ:
    add r9, r14, NOC_GS_BUSY             # AI [102b]: one stream at a time per core
    atomadd r9, r9, 1
    bne r9, r14, NOC_GS_BUSYREPLY, false
    sll r11, r7, 15
    srl r11, r11, 15                     # its key
    srl r7, r7, 17                       # clone core id
    jmp r12, NOC_NODE_KEY                # r9 = my node's key
    sll r13, r7, 6
    or r13, r13, 16                      # AI [113]: clone's response mailbox 16 (it asks from context 0 at boot), lane 0
    lw r10, NOC_MAGIC
    beq r9, r11, NOC_GS_OFFER, true
    add r10, r10, 1                      # 2'. REFUSE: I no longer own that node (it falls back to DRAM)
    sendflit r10, r13
    beq r15, r15, NOC_GS_RET, true
NOC_GS_OFFER:
    and r9, r15, 0xF                     # AI [113]: OFFER = NOC_MAGIC | (my context << 4): the clone sends GO to my 16 + context
    sll r9, r9, 4
    or r9, r10, r9
    sendflit r9, r13                     # 2. OFFER
    getclk r11
    lw r9, NOC_GO_TIMEOUT
    add r11, r11, r9                     # deadline for the clone's GO
NOC_GS_WAITGO:                           # AI [113]: GO/CANCEL arrive in my own response mailbox 16 + context; I also keep pipe 34 drained
    and r12, r15, 0xF                    #   (contexts switch only on yield/stall, so nobody else reads it while I spin) [102e]
    add r12, r12, 16
    nonblock r9, r12
    bne r9, r14, NOC_GS_GOTGO, true
    nonblock r9, r6
    bne r9, r14, NOC_GS_GOTWORD, true
    getclk r9
    bgt r11, r9, NOC_GS_WAITGO, true
    beq r15, r15, NOC_GS_RET, true       # no answer: the clone gave up, do not stream
NOC_GS_GOTWORD:
    block r9, r6
    srl r12, r9, 31
    bne r12, r14, NOC_GS_WAITGO, true    # AI [113]: stale bit-31 word on 34: drop
    srl r12, r9, 17                      # another clone's REQUEST: answer BUSY right away
    sll r12, r12, 6
    or r12, r12, 16                      # AI [113]: to its response mailbox 16
    add r8, r10, 2
    sendflit r8, r12
    beq r15, r15, NOC_GS_WAITGO, true
NOC_GS_GOTGO:
    and r12, r15, 0xF                    # AI [113]: read it from my 16 + context
    add r12, r12, 16
    block r9, r12
    sll r12, r9, 3
    srl r12, r12, 3                      # id field
    bne r12, r7, NOC_GS_WAITGO, true     # not my clone (stale): keep waiting
    srl r12, r9, 29
    add r8, r14, 4
    beq r12, r8, NOC_GS_RET, true        # 3'. CANCEL (0x80000000 | id)
    add r8, r14, 6
    bne r12, r8, NOC_GS_WAITGO, true     # not a GO either: keep waiting
    sll r9, r7, 6                        # 3. GO (0xC0000000 | id): stream on the clone's pipe 0
NOC_GS_OK:
    add r10, r14, ROOT_NODE_ADDRESS
    add r11, r14, 1
    jmp r12, NOC_SEND_REGION
    add r10, r14, ROOT_NODE_ID
    add r11, r14, 1
    jmp r12, NOC_SEND_REGION
    add r10, r14, SRAM_NODE_ALLOC_PTR
    add r11, r14, 1
    jmp r12, NOC_SEND_REGION
    add r10, r14, LEAF_CORE_LOOKUP_TABLE
    add r11, r14, 65
    jmp r12, NOC_SEND_REGION
    add r10, r14, INDEX_ARRAY_BASE       # AI [B1]: spine geometry pointers: INDEX_ARRAY_BASE, VERTEX_ARRAY_BASE, BR_GEO_END
    add r11, r14, 1
    jmp r12, NOC_SEND_REGION
    add r10, r14, VERTEX_ARRAY_BASE
    add r11, r14, 1
    jmp r12, NOC_SEND_REGION
    add r10, r14, BR_GEO_END
    add r11, r14, 1
    jmp r12, NOC_SEND_REGION
    lw r10, BRANCH_START_OF_GEO          # node array + spine geometry: [base, BR_GEO_END)  AI [B1]: was [base, alloc pointer)
    lw r11, BR_GEO_END
    sub r11, r11, r10
    srl r11, r11, 2
    jmp r12, NOC_SEND_REGION
    sendflit r14, r9                     # end of stream
NOC_GS_RET:
    sw r14, NOC_GS_BUSY
    intena 34
NOC_GS_BACKOFF:
    jmp r15, r4
NOC_GS_BUSYREPLY:                        # AI [102d]: another context is streaming. Read the request and answer BUSY: pipes >= 16 hold one
    srl r7, r7, 17                       #   flit, and an unread word blocks lane 1 (ray requests 32/33) at this router.
    sll r13, r7, 6
    or r13, r13, 16                      # AI [113]: BUSY to the clone's response mailbox 16
    lw r10, NOC_MAGIC
    add r10, r10, 2
    sendflit r10, r13
    intena 34
    jmp r15, r4
NOC_NODE_KEY:                            # AI [102b]: link r12. r9 = ((RAY_QUEUE_HIGH & 3) << 15) | ((RAY_QUEUE_LOW >> 17) & 0x7FFF): identifies my
    lw r9, RAY_QUEUE_HIGH                #   node's queue (queues are 128KB apart from 1_115_000_000 in each stack). Uses r8, r9.
    and r9, r9, 3
    sll r9, r9, 15
    lw r8, RAY_QUEUE_LOW
    srl r8, r8, 17
    and r8, r8, 0x7FFF
    or r9, r9, r8
    jmp r15, r12
NOC_SEND_REGION:                         # link r12: r10 = SRAM address, r11 = word count (skipped if 0), r9 = destination. Uses r13.
    beq r11, r14, NOC_SR_RET, false
    sendflit r10, r9
    sendflit r11, r9
NOC_SR_LOOP:                             # AI [102e]: keep pipe 34 drained while streaming (BUSY to new requests, drop stale words)
    nonblock r8, r6
    bne r8, r14, NOC_SR_POLL, false
NOC_SR_WORD:
    lw r13, r10, 0
    sendflit r13, r9
    add r10, r10, 4
    add r11, r11, -1
    bne r11, r14, NOC_SR_LOOP, true
    beq r15, r15, NOC_SR_RET, true
NOC_SR_POLL:
    block r8, r6
    srl r7, r8, 31
    bne r7, r14, NOC_SR_WORD, true       # stale GO/CANCEL: drop
    srl r7, r8, 17
    sll r7, r7, 6
    or r7, r7, 16                        # AI [113]: BUSY to the clone's response mailbox 16
    lw r8, NOC_MAGIC
    add r8, r8, 2
    sendflit r8, r7                      # BUSY
    beq r15, r15, NOC_SR_WORD, true
NOC_SR_RET:
    jmp r15, r12
download_bvh_tree:
    and r14, r14, 0
    # AI [152] (Alex): point the read-only math tables at this core's own stack (main.rs writes a copy into every stack at
    #   2_000_000_000+). Stack = (core_id >> 12) * 4 + ((core_id >> 5) & 3); membits = stack >> 1, address bit 31 = stack & 1.
    srl r9, r15, 4                       # core id
    srl r10, r9, 12                      # y_stack
    sll r10, r10, 2
    srl r9, r9, 5
    and r9, r9, 3                        # x_stack
    or r9, r9, r10                       # my stack 0..7
    srl r10, r9, 1                       # r10 = membits of my stack
    and r9, r9, 1
    sll r9, r9, 31                       # r9 = bit 31 of my stack
    sw r10, DIV_TABLE_HIGH
    lw r11, DIV_TABLE_LOW
    or r11, r11, r9
    sw r11, DIV_TABLE_LOW
    sw r10, INV_SQRT_TABLE_HIGH
    lw r11, INV_SQRT_TABLE_LOW
    or r11, r11, r9
    sw r11, INV_SQRT_TABLE_LOW
    sw r10, INT_TO_FLOAT_TABLE_HIGH
    lw r11, INT_TO_FLOAT_TABLE_LOW
    or r11, r11, r9
    sw r11, INT_TO_FLOAT_TABLE_LOW
    jmp r13, NOC_GEO_RECEIVE             # AI [102]: returns only when the geometry must come from DRAM (DFS below)
    # NOTE:
    # The current C snippet has two real problems:
    #   1) the root push in the C is inconsistent with the stack growth direction
    #   2) the recurse logic has an unconditional goto that makes the owner checks bogus
    # This assembly follows the intended behavior, not those broken lines literally.

    and r14, r14, 0                          # r14 = 0

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
    and r14, r14, 0
    add r11, r14, DFS_STACK
    beq r2, r11, BR_SPINE_GEO_COPY, true    # AI [B1]: was dfs_done; copy the spine triangles first

    add r2, r2, -16
    lw r4, r2, 0                             # dram_idx
    lhu r5, r2, 4                            # parent_ptr
    lhu r6, r2, 6                            # patch_left
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
    lbu_d r10, r12, 24                       # AI [B1]: tri_count (low byte of DRAM word 6) -> SRAM byte 31, as the leaf DFS does
    sb r10, r13, 31                          #   (0 for internal nodes and stubs; > 0 only for BVH leaves absorbed into the spine)
    lhu_d r10, r12, 32                       # AI [B1]: tri_start = byte offset of its first record in the spine index list
    sh r10, r13, 32

    # -- copy metadata --
    or r10, r10, 0xFFFF
    sh r10, r13, 34                          # core_owner
    lhu_d r10, r12, 40
    sh r10, r13, 40                          # queue_high_bit_addr
    lw_d r10, r12, 36
    sw r10, r13, 36                          # queue_low_bit_addr
    lw_d r10, r12, 44
    sw r10, r13, 44                          # node_id

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

    # if (core_owner != 0xFFFF && core_owner != self.core_id) leaf_node_table_ptr[0] = node;
    lw r10, r13, 36                         # r10 = core_owner
    beq r10, r11, SKIP_LEAF_TABLE_INSERT, true
    or r14, r14, 0xFFFF
    beq r10, r14, SKIP_LEAF_TABLE_INSERT, true
    and r14, r14, 0
    add r14, r14, LEAF_CORE_LOOKUP_TABLE     # AI fix [48]: bound the table at 128 entries. The DFS also visits the unowned spine, whose 173 stubs
    add r14, r14, 256                        #   (one per branch) plus the treelet's own stubs overflowed the 130-entry table into
    blte r14, r3, SKIP_LEAF_TABLE_INSERT, false  #   LOCAL_RAY_QUEUE (header + slots). Only entry 128 (own root, set after the DFS) is still read.
    and r14, r14, 0
    sh r13, r3, 0
    add r3, r3, 2
SKIP_LEAF_TABLE_INSERT:
    and r14, r14, 0
    # if (parent_ptr != 0xFFFF) patch parent child pointer
    or r14, r14, 0xFFFF
    srl r14, r14, 16                         # AI fix [99]: the immediate sign-extends to 0xFFFFFFFF, never equal to the lhu parent_ptr 0xFFFF,
                                             #   so the root was "patched" through patch_left = 0: SRAM word 0 (reboot entry) = 16704. The next
                                             #   reboot of that core hit an invalid opcode (run 67 crash; run 68 BOOT_CLOBBER at this sh).
    beq r5, r14, SKIP_PATCH, true
    sh r13, r6, 0                            # *patch_left = node
SKIP_PATCH:
    and r14, r14, 0
    # if (owner == self->core_id) self->root_node = node;
    lw r10, r13, 36                         # owner = dram_node->core_owner
    bne r10, r11, CHECK_RECURSE, true
    lw r14, r13, 44                          # node_id
    sw r13, ROOT_NODE_ADDRESS
    and r14, r14, 0
CHECK_RECURSE:
    and r14, r14, 0                          # AI [B1]: a BVH leaf (tri_count != 0) has no children: copied, not recursed
    lbu r7, r13, 31
    bne r7, r14, dfs_loop, false

    # recurse if owner == 0xFFFF || owner == self->core_id
    or r14, r14, 0xFFFF
    beq r10, r14, DO_RECURSE, true
    lw r14, RAY_QUEUE_LOW
    beq r10, r14, SET_NODE_ID, true
    beq r15, r15, dfs_loop, true             # foreign owner: stop here
SET_NODE_ID:
    lw r10, r13, 44                        # node_id
    sw r10, ROOT_NODE_ID
DO_RECURSE:
    # -- push right child first (so left is processed first) --
    and r14, r14, 0
    lw_d r11, r12, 24                        # left_index
    srl r11, r11, 8
    add r10, r11, 1                        # right_idx

    add r12, r9, 1                           # child_depth = depth + 1

    sw r10, r2, 0                            # right_idx
    sh r13, r2, 4                            # parent = node

    add r10, r13, 26
    sh r10, r2, 6                            # patch_right = &node->right_child
    add r10, r14, 1
    sh r10, r2, 10                           # is_right = 1
    sw r12, r2, 12                           # depth + 1
    add r2, r2, 16

    # -- push left child --
    sw r11, r2, 0                            # left_idx
    sh r13, r2, 4
    add r10, r13, 24
    sh r10, r2, 6                            # patch_left = &node->left_child
    sh r14, r2, 10                           # is_right = 0
    sw r12, r2, 12
    add r2, r2, 16

    beq r15, r15, dfs_loop, true

BR_SPINE_GEO_COPY:                          # AI [B1]: spine triangles (BVH leaves absorbed into the shared spine). DRAM at
    and r14, r14, 0                          #   SPINE_GEO_HIGH/LOW: {index bytes, vertex bytes, index records (12 B), vertices
    lw r12, SPINE_GEO_HIGH                   #   (12 B)}, padded to 16 B. Copied right after the nodes; same record format and
    setmembits r12                           #   INDEX_ARRAY_BASE / VERTEX_ARRAY_BASE use as the leaf firmware.
    lw r1, SPINE_GEO_LOW
    lw_d r3, r1, 0                           # r3 = index bytes
    lw_d r4, r1, 4                           # r4 = vertex bytes
    add r1, r1, 8
    lw r6, SRAM_NODE_ALLOC_PTR
    sw r6, INDEX_ARRAY_BASE
    add r5, r6, r3
    sw r5, VERTEX_ARRAY_BASE
    add r5, r5, r4                           # r5 = end of the copy
    sw r5, BR_GEO_END
BR_GEO_COPY_LOOP:                            # 4 words per pass: the four loads are in flight together
    blte r5, r6, BR_GEO_COPY_DONE, false
    lw_d r7, r1, 0
    lw_d r8, r1, 4
    lw_d r9, r1, 8
    lw_d r10, r1, 12
    sw r7, r6, 0
    sw r8, r6, 4
    sw r9, r6, 8
    sw r10, r6, 12
    add r1, r1, 16
    add r6, r6, 16
    beq r15, r15, BR_GEO_COPY_LOOP, true
BR_GEO_COPY_DONE:
    lw r12, NODE_ARRAY_HIGH                  # membits as after the DFS / NoC receive
    setmembits r12
dfs_done:
    # *(self.leaf_core_lookup_table + 256) = self->root_node;
    lw r10, JUMP_TO_RAY_EAT_INTERRUPT
    sw r10, 65408
    sw r10, 65412
    lw r10, JUMP_TO_SWITCH_ROLES_INTERRUPT
    sw r10, 65416
    and r14, r14, 0                         # r14 = 0
    lw r10, ROOT_NODE_ADDRESS               # r10 = ROOT_NODE_ADDRESS
    add r11, r14, LEAF_CORE_LOOKUP_TABLE    # r11 = leaf_core_lookup_table + 0
    add r11, r11, 256                       # r11 = leaf_core_lookup_table + 256
    sh r10, r11, 0                          # leaf_core_lookup_table + 256 = ROOT_NODE_ADDRESS
    
    add r1, r14, LOCAL_RAY_QUEUE
    sw r14, r1, 0
    sw r14, r1, 4
    sw r14, r1, 8
    add r1, r1, 12
    add r2, r14, 16
queue_loop_1:
    beq r2, r14, queue_loop_1_done, true
    sb r14, r1, 63
    add r1, r1, 64
    add r2, r2, -1
    beq r15, r15, queue_loop_1, true

queue_loop_1_done:
    sw r14, r1, 0
    sw r14, r1, 4
    sw r14, r1, 8

    add r1, r1, 12

    add r2, r14, 16
queue_loop_2:
    beq r2, r14, queue_loop_2_done, true
    sb r14, r1, 63
    add r1, r1, 64
    add r2, r2, -1
    beq r15, r15, queue_loop_2, true

queue_loop_2_done:
    add r1, r14, LOCAL_RAY_QUEUE         # AI fix [148]: zero both queues' `used` slot counters ([124]: even at +2072, receiver at
    add r1, r1, 2072                     #   +1036+2072). Only head/tail/count were cleared, and this SRAM is not downloaded, so a
    sw r14, r1, 0                        #   clone rebooted from a leaf kept leaf data there (LQAUDIT, run 113: used = +-2e9). Negative:
    add r1, r1, 1036                     #   the `old_used < 16` check always passes, count runs past the 16 slots and new rays
    sw r14, r1, 0                        #   overwrite unread ones (lost rays). Positive: the queue rejects every ray forever.

    # *(self.local_queue_flushing) = 0;
    sw r14, LOCAL_QUEUE_FLUSHING

    # *(self.tile_data_sram + 4) = 0;
    add r1, r14, TILE_DATA_COUNT
    sw r14, r1, 4

    # *(self.ray_send_pending_addr) = 0;
    sw r14, RAY_SEND_PENDING_ADDR



    # *(ray + 63) = 0;

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
    lw r10, 65520                        # AI [61]: clone reboot? (flag from initialize_core) -> register as an owner now
    and r14, r14, 0
    beq r10, r14, CLONE_REG_DONE, true
    sw r14, 65520
    getclk r10                           # AI [100]: minimum residency: a clone may not register as idle for CLONE_RESIDENCY cycles
    lw r11, CLONE_RESIDENCY              #   (reuses the warm-up gate, which the reboot reset to CLONE_WARMUP)
    add r10, r10, r11
    sw r10, CLONE_WARMUP
    lw r2, RAY_QUEUE_HIGH
    setmembits r2
    lw r3, RAY_QUEUE_LOW
    add r4, r3, 12
    atomadd_d r5, r4, 1                  # my ticket
CLONE_REG_TICKET:
    lw_d r6, r3, 16
    bne r6, r5, CLONE_REG_TICKET, true
    add r4, r3, 20
    add r6, r14, -8192
    atomadd_d r7, r4, r6                 # writer lock
CLONE_REG_WRITER:
    lw_d r7, r4, 0
    bne r7, r6, CLONE_REG_WRITER, true
    add r4, r3, 24
    atomadd_d r7, r4, 1                  # old owner_count = my slot index
     sw r7, CLONE_MY_SLOT                 # remember where I registered (O(1) leave fast path)
    sll r7, r7, 1
    add r7, r7, r3
    srl r8, r15, 4
    sh_d r8, r7, 28                      # core_slots[index] = me
    add r4, r3, 20
    atomadd_d r7, r4, 8192               # release the writer lock
    add r4, r3, 16
    atomadd_d r7, r4, 1                  # now_serving++
CLONE_REG_DONE:
    intena 32
    intena 33
    intena 34
    intena 35
    intena 36
    setctx 16
    relinquish true
    and r14, r14, 0                      # AI [115] (Alex): context 15 is a dedicated interrupt context: it only yields, so every
    and r2, r15, 0xF                     #   request on pipes 32/33/34 is answered within a round of context switches, even when all
    xor r2, r2, 15                       #   workers spin without yielding (run 84 stall). Workers keep 32/33 as before.
    beq r2, r14, IRQ_CTX, false
    intdis 34                            # AI [115]: clone requests (34) are served by context 15 only (context 0 enabled it above)
    and r14, r14, 0
    # ray_base = self.ray_array_base;
    add r1, r14, RAY_ARRAY
    and r2, r15, 0xF
    # ray_array_index = self.thread_id << 6;
    sll r2, r2, 6

    # ray = ray_base + index
    add r0, r1, r2
    sb r14, r0, 63 
    add r1, r14, LEAF_CORE_LOOKUP_TABLE
    lhu r1, r1, 256
    beq r15, r15, ray_done, true





JUMP_TO_RAY_EAT_INTERRUPT:
jmp r15, EAT_RAY_INTERRUPT
JUMP_TO_SWITCH_ROLES_INTERRUPT:
jmp r15, NOC_GEO_SEND_INTERRUPT  # AI [102]
NODE_ID_TABLE_HIGH:
.data 0
NODE_ID_TABLE_LOW:
.data 63070000
LEAF_SIZE_OF_GEO:
.data 32768
LEAF_START_OF_GEO:
.data 16128
leaf_start_of_code:
.data 44
SRAM_NODE_ALLOC_PTR:     
.data 19968          # AI [B1]: node base 0x4E00 (was 18432 = 0x4800): the image grew by the spine triangle code + RAY_TRIANGLE_REG_SPILL                  # AI [102]: was 16704 (17408 in [102]) (64KB SRAM; room for the NoC clone routines)                  # AI [53]/[61]: was 16128, then 16512; the firmware image has grown past both
BRANCH_START_OF_CODE:    
.data 44
BRANCH_NUM_INSTRUCTION_BYTES: 
.data 9000 #17284
BRANCH_START_OF_GEO:     
.data 19968          # AI [B1]: node base 0x4E00 (was 18432 = 0x4800): the image grew by the spine triangle code + RAY_TRIANGLE_REG_SPILL                  # AI [102]: was 16704 (17408 in [102])                  # AI [53]/[61]: node base moved
BRANCH_SIZE_OF_GEO:      
.data 32768
BRANCH_IDLE_THRESHOLD:    
.data 0x7FFFFFFF
IDLE_WINDOW:             
.data 50000                               # AI [59]: was 100000 (only the clone hook uses it now)
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
LOCAL_QUEUE_FLUSHING:   
.data 0
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
.data 62001000
PIXEL_DONE_HIGH:
.data 0
PIXEL_DONE_LOW:
.data 168000004
RAY_RESULT_HIGH: 
.data 0
RAY_RESULT_LOW: 
.data 170000000
RAYS_COMPLETED_HIGH: 
.data 0
RAYS_COMPLETED_LOW: 
.data 168000000
RAYS_ENTERED_HIGH:                       # AI [B4]: stack 2 (membits 1, low < 2^31)
.data 1
RAYS_ENTERED_LOW:                        # AI [74]: rays that started a traversal (primary + pooled). AI [B4]: stack 2, 50_000_016 (was stack 0 168000016)
.data 50000016
BR_GROW_FULL:                            # AI [B4]: in flight at which branch growth requests stop
.data 100000
BR_GROW_RETRY:                           # AI [B4]: cycles between growth tries per core (Alex: 100K, was 50K)
.data 100000
INFLIGHT_CAP:                            # AI [74]: max rays in flight before tile spawning pauses
.data 1000000000 # AI run 61: cap effectively OFF (was 2048; the run-42 deadlock was likely the WAW sim bug, not a cycle)
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
.data 2000100000                # AI [152]: per-stack copy (was 150000 on stack 0); bit 31 set at boot
DIV_TABLE_HIGH: 
.data 0
DIV_TABLE_LOW: 
.data 2000200000                # AI [152]: per-stack copy (was 61000000 on stack 0); bit 31 set at boot
INV_SQRT_TABLE_HIGH: 
.data 0
INV_SQRT_TABLE_LOW: 
.data 2000000000                # AI [152]: per-stack copy (was 100000 on stack 0); bit 31 set at boot
IDLE_QUEUE_HIGH: 
.data 0
CLONE_REQ_TABLE_LOW:                     # AI [53]: REASSIGN[core] words (stack 1, after the idle pool)
.data 2500100000
CLONE_IDLE_MAX_RAYS:                     # AI [53]: idle if fewer rays than this were started in an IDLE_WINDOW
.data 3          # AI [138] (Alex): 3 consecutive IDLE_WINDOW checks (~150K cycles) before joining the pool ([136]: 10; originally 2)
CLONE_IDLE_STREAK:                       # AI [59]: consecutive idle checks so far
.data 0
CLONE_DRAIN_LIMIT:                       # AI [63]: max drain iterations before giving up
.data 2048
CLONE_WARMUP:                            # AI [84]: cycles before any core may register as idle
.data 400000
EMERG_MIN_RAYS:                          # AI [95]: an ownerless queue goes on the emergency queue above this many rays
.data 0
EMERG_FLAG_LOW:                          # AI [95]: per-queue on-emergency-queue flags, stack 0, + q*4
.data 63500000
CLONE_MY_SLOT:                        # cached core_slots index of this core (O(1) leave fast path)
.data 65535                               # AI [125]: 65535 = unknown (positive, so the index < owner_count check rejects it)
NOC_GS_BUSY:                             # AI [102b]: a context of this core is streaming geometry to a clone
.data 0
NOC_MAGIC:                               # AI [102d]: handshake reply OFFER; +1 = REFUSE, +2 = BUSY (tag 0xE...)
.data 0xE0000001
NOC_GS_REPLY:                            # AI [102d]: GO/CANCEL word handed from the pipe-34 handler to the streaming context
.data 0
NOC_RX_TIMEOUT:                          # AI [102]: cycles a NoC clone waits for its source's offer before downloading from DRAM
.data 100000
NOC_GO_TIMEOUT:                          # AI [102c]: cycles a source waits for the clone's GO after offering (GO comes back within a few hundred)
.data 20000
CLONE_SRC_LOW:                           # AI [102]: per-core NoC clone source (core + 1), stack 0, + core*4
.data 64000000
CLONE_REQ_CD_LOW:                        # AI [100]: per-node clone request cooldown table, stack 0, + q*8
.data 63800000
CLONE_REQ_COOLDOWN:                      # AI [100]: cycles between clone requests from one node (run 70: 100000 starved hot nodes)
.data 200000          # AI [137] (Alex): per core now, so a node with N owners asks ~N times per cooldown (growth ~exponential); was 10000 per node
CLONE_RESIDENCY:                         # AI [100]: cycles after a clone reboot before the core may register as idle
.data 500000          # AI [136]: was 300000 (memory model: slower ops; fewer join/leave cycles)
CLONE_MIN_OWNERS:                        # AI [72]: minimum owners a node keeps when a core donates itself
.data 1
CLONE_BUSY_PULLS:                        # AI [53]: request a copy after this many pulls from a full queue
.data -1          # AI [139] (Alex): off (unsigned compare never exceeds); busy = NoC rejects now. Was 8
IDLE_QUEUE_LOW: 
.data 2500000000
RANDOM_TABLE_HIGH: 
.data 0
RANDOM_TABLE_LOW: 
.data 60000000
CAM_X: 
.data 0x440E4000
CAM_Y: 
.data 0x431F0000
CAM_Z: 
.data 0xC451C000
GRAB_FROM_TILE_ATOMADDER:
.data 0
# https://stackoverflow.com/questions/78072261/how-to-find-cameras-intrinsic-matrix-from-focal-length

CAM_CX:
.data 0x44A00000
CAM_CY: 
.data 0x44340000
CAM_INV_FOCAL: 
.data 0x3A4CCCCD
RAY_SEND_PENDING: 
.data 0
PULLED_FROM_FULL_QUEUE_CNT: 
.data 0
CORE_ID_TO_SWITCH_TO: 
.data -1
TILE_DATA_COUNT: 
.data 0 #count
TILE_IS_ACTIVE: 
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
.data 0x44228000            # LIGHT0_X
LIGHT0_Y: 
.data 0x430C0000
LIGHT0_Z: 
.data 0xC42F0000
LIGHT0_R: 
.data 0x3F800000
LIGHT0_G: 
.data 0x00000000
LIGHT0_B: 
.data 0x00000000
LIGHT1_X: 
.data 0x43FA0000
LIGHT1_Y: 
.data 0x430C0000
LIGHT1_Z: 
.data 0xC4480000
LIGHT1_R: 
.data 0x00000000
LIGHT1_G: 
.data 0x3F800000
LIGHT1_B: 
.data 0x00000000
LIGHT2_X: 
.data 0x444D0000
LIGHT2_Y: 
.data 0x430C0000
LIGHT2_Z: 
.data 0xC4160000
LIGHT2_R: 
.data 0x00000000
LIGHT2_G: 
.data 0x00000000
LIGHT2_B: 
.data 0x3F800000
SPINE_GEO_HIGH:                         # AI [B1]: DRAM spine geometry (stack 0), written by the simulator
.data 0
SPINE_GEO_LOW:
.data 66000000
SRAM_ALLOC_COUNT:       
.data 16384
ROOT_NODE_ADDRESS: 
.data 16384 # 0x000022C4
CAM_DX:
.data 0x3F211D9C
CAM_DY:
.data 0xBF11B30F
CAM_DZ:
.data 0x3F0780C3
CAM_RIGHT_X:
.data 0x3F24CB85
CAM_RIGHT_Y:
.data 0x00000000
CAM_RIGHT_Z:
.data 0xBF43E1FB
CAM_UP_X:
.data 0x3EDF0BC5
CAM_UP_Y:
.data 0x3F527375
CAM_UP_Z:
.data 0x3EBB9B7C            # DO NOT INCLUDE LINES BELOW THIS AS PULLED FROM DRAM 
RAY_ARRAY: 
.data(256) 0
LEAF_CORE_LOOKUP_TABLE: 
.data(65) 0                 # AI fix: was 64 words; entry 128 (root ptr, byte 256) overlapped LOCAL_RAY_QUEUE head
LOCAL_RAY_QUEUE: 
.data(1048) 0
DFS_STACK: 
.data(256) 0
SAVED_BRANCH_HIGH:       
.data -1
SAVED_BRANCH_LOW:        
.data -1
SEARCH_FOR_IDLE_CORES_STORAGE: 
.data -1
DONE_POLL_CNT:                           # AI [135]: idle passes since the last RAYS_COMPLETED poll
.data 0
CLONE_WARMUP_DONE:                       # AI [136c]: 1 once this core has seen 1000 completed rays (not downloaded: 0 at power-up)
.data 0
CLONE_NEXT_REQ:                          # AI [137]: cycle of this core's next allowed clone request (not downloaded: 0 at power-up)
.data 0
REJ_LAST_TS:                             # AI [143]: cycle of this core's last NoC full-reject (not downloaded: 0 at power-up)
.data 0
REJ_CNT:                                 # AI [143]: rejects in the current streak (each within IDLE_WINDOW of the previous)
.data 0
RAY_TRIANGLE_REG_SPILL:                  # AI [B1]: 64 B per context for BR_triangle_intersect (not downloaded)
.data(256) 0
INDEX_ARRAY_BASE:                        # AI [B1]: spine index list in SRAM, set by BR_SPINE_GEO_COPY or the NoC clone stream
.data 0
VERTEX_ARRAY_BASE:                       # AI [B1]: spine vertices in SRAM
.data 0
BR_GEO_END:                              # AI [B1]: end of nodes + spine geometry (what a NoC clone source streams)
.data 0
BR_GROW_NEXT:                            # AI [B4]: this core's next allowed growth try (not downloaded: 0 at power-up)
.data 0
