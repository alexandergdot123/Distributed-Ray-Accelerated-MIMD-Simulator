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
    bne r10, r9, WAIT_FOR_FLUSH_READY_SWITCH_DRAM_QUEUE, true #beq to bne (VALIDATED)
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


#RYAN VALIDATION START

#LEAF CORE MAIN LOOP START

START_RAY_TRAVERSAL:
    lw r1, ROOT_NODE_ADDRESS         # r1 = node
    and r8, r8, 0                    # AI [53]: count rays started (was never incremented)
    add r8, r8, RAYS_PROCESSED
    atomadd r8, r8, 1
START_SEARCHING:
    # AI [SL] stackless traversal (STACKLESS_TRAVERSAL_PLAN.md): ray byte 62 = entry direction into node r1:
    #   0 = from the parent (test this node), 1 = back from the left child (go right), 2 = back from the right child (go up).
    #   Words 44 and 48 (old visited bitfields) are no longer used.
    yield r8                         # clobber r8
    lbu r2, r0, 62                    # r2 = entry direction (byte 62, was the depth byte)
    and r7, r7, 0
    beq r2, r7, SL_TEST, true        # from the parent: test this node
    add r3, r7, 1
    bne r2, r3, SL_ASCEND, true      # from the right child: both subtrees done, go up
    sb r7, r0, 62                    # from the left child: enter the right child from its parent
    lhu r1, r1, 26                   # r1 = node->right_child
    beq r15, r15, START_SEARCHING, true
SL_ASCEND:                           # leave node r1 upward (miss, leaf done, or both children done). Clobbers r6-r8.
    lbu r6, r1, 30                   # r6 = node->is_right
    add r6, r6, 1                    # 1 = back from the left child, 2 = back from the right child
    sb r6, r0, 62
    lhu r6, r1, 28                   # r6 = node->parent
    and r7, r7, 0
    or r8, r7, 0xFFFF
    srl r8, r8, 16                   # r8 = 0x0000FFFF
    beq r6, r8, SEND_RAY_UP, true    # top of my copy of the tree: hand the ray to its owner (r1 = top node, r7 = 0)
    add r1, r6, 0
    beq r15, r15, START_SEARCHING, true
SL_TEST:
    jmp r8, AABB_INTERSECT           # r0 = ray, r1 = node, r7 = 0

#UNCONDITIONAL BRANCH

AABB_INTERSECT_RETURN: #r11 = 1 (hit), 0 (miss), r7 = 0
    # if (hit)
    beq r11, r7, AABB_MISS, true        #if result == 0 (miss) then AABB_MISS

    # if result == hit)
    # if (node->tri_count == 0) <- ASSUME RAY -> TRI_INDEX
    lbu r6, r1, 31                      #r6 = node->tri_count   
    bne r6, r7, IS_LEAF_NODE, true      # if (node->tri_count != 0) then IS_LEAF_NODE

# if (node->tri_count == 0)
IS_INTERNAL_NODE:
    # AI fix: ray_depth++ moved to TRAVERSE_OWN_CHILD so forwarded rays carry the node's own depth

# RYAN VALIDATED TRHOUGH HERE

    # if (node->node_id != 0xFFFF)
    lw r6, r1, 44                          # r6 = node->node_id 
    or r9, r9, 0xFFFF                      # r9 = 0xFFFFFFFF
    beq r6, r9, TRAVERSE_OWN_CHILD, true   # if node->node_id == 0xFFFFFFFF then TRAVERSE_OWN_CHILD
    # owner == 0xFFFF means we own it

    lw r7, ROOT_NODE_ID                    # r7 = root_node_id (value)
    beq r6, r7, TRAVERSE_OWN_CHILD, true   # if node->node_id == root_node_id then TRAVERSE_OWN_CHILD
    and r7, r7, 0                          # r7 = 0

    # if node->node_id != root_node_id AND if node->node_id != 0xFFFFFFFF
    # AI fix: core_owner == 0xFFFF -> REJECT_PATH check moved below SEND_RAY_UP setup

# if core_owner != 0x0000FFFF:
    # uint16_t ray_send_pending_addr = self.ray_send_pending_addr;
SEND_RAY_UP:
    add r8, r7, RAY_SEND_PENDING_ADDR    # r8 = self.ray_send_pending_addr
    # atomic_add(ray_send_pending_addr, 1)
    atomadd r15, r8, 1               # r9 = clobber

    # standalone slot sentinel init
    # slot = 0xFFFFFFFF  //NEEDS FIX HERE! confirm r4 vs r13 as slot register
    and r4, r4, 0
    add r4, r4, -1
    # uint32_t sent = 0;
    and r3, r3, 0                   # r3 = sent = 0
    # AI fix: unknown owner -> spill to the node's DRAM queue (was checked before this setup, and SEND_RAY_UP sent to core 0xFFFF)
    lhu r9, r1, 34                  # r9 = node->core_owner
    or r11, r7, 0xFFFF              # r11 = 0xFFFFFFFF (r7 = 0)
    srl r11, r11, 16                # r11 = 0x0000FFFF
    beq r9, r11, REJECT_PATH, false
    srl r11, r15, 4                 # AI [154] (Alex): r11 = my core id. A stale cached owner equal to this core (copied by a NoC clone
    beq r9, r11, REJECT_PATH, false #   from its donor) would make the router panic on a self-addressed request: take the DRAM path instead

    # disable_interrupts(32)  -- leaf core uses only mailbox 32 for interrupts
    lw r6, r1, 44                  # r6 = node->node_id
    srl r11, r6, 13                 # AI fix [116] (Alex): a leaf sends to a branch core's mailbox 33 (receiver side), to a leaf's 32.
    and r11, r11, 1                 #   Imported branch stubs carry node_id + 8192, so bit 13 marks a branch target. Was always 32,
    add r11, r11, 32                #   so branch cores got every leaf request on 32.
    sll r6, r6, 17
    or r6, r6, r15                # r12 = request_word
    and r3, r3, 0

    # send_packet(request_word, node->core_owner, 32 or 33);
    lhu r9, r1, 34                  # r6 = node->core_owner
    sll r12, r9, 6                  # AI [116]: core << 6 | pipe (r9 stays the owner for the SENDWAIT dump)
    or r11, r12, r11
    sendflit r6, r11
send_ray_loop:
    switchctx
    # uint32_t msg_available = nb_recv(self.thread_id + 16);
    and r10, r15, 0xF               # r10 = thread_id
    add r11, r10, 16                # r11 = thread_id + 16 (shallow mailbox)
    nonblock r12, r11               # r12 = msg_available
    beq r12, r7, CHECK_DATA_MAILBOX, true   # r7=0, nothing on shallow mailbox

    # uint32_t msg = blocking_receive(self.thread_id + 16);
    block r12, r11                  # r12 = msg
    srl r13, r12, 31                # AI [113]: a late NoC-clone handshake word (bit 31) in my response mailbox: skip it
    bne r13, r7, CHECK_DATA_MAILBOX, true

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
    add r11, r11, 0                 # AI fix: data goes to the 16-deep data mailbox (thread_id), not 16+thread_id (1-deep response mailbox)
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
    lw r7, r0, 40                   # AI fix: send word 40 as-is (marker | node_id); was LEAF_CORE_INDEX_FOR_BRANCH (positional, mismatched branch DFS order)
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


    and r7, r7, 0                   # AI fix: r7 held ray word 60 here, so active_ray was not cleared and every later `beq ..., r7` zero test in the send loop misfired
    sb r7, r0, 63                   # ray->active_ray = 0  (r7=0)
    and r3, r3, 0
    add r3, r3, 1                   # r3 = sent = 1
    beq r15, r15, CHECK_DATA_MAILBOX, true

#UNCONDITIONAL BRANCH

REJECT_PATH:
    # push ray to DRAM queue
    lhu r8, r1, 40                  # r8 = node->queue_high_bit_addr
    setmembits r8                   # set address bits to reach node's DRAM stack
    lw r9, r1, 36                   # r9 = node->queue_low_bit_addr

    add r9, r9, 8
ENSURE_SPACE_IN_QUEUE:
    add r11, r7, 255               # r11 = 255
    lw_d r10, r9, 0                # AI fix: peek the count first (test-and-test-and-set), see branch ENSURE_SPACE_IN_QUEUE
    bgt r10, r11, ENSURE_SPACE_IN_QUEUE, true
    atomadd_d r10, r9, 1               # r10 = cur_ray_count (count field is -12 from here)
    blte r10, r11, THERE_EXISTS_SPACE_IN_DRAM_RAY_QUEUE, true   # spin while count > 255
    atomadd_d r15, r9, -1
    beq r15, r15, ENSURE_SPACE_IN_QUEUE, true
THERE_EXISTS_SPACE_IN_DRAM_RAY_QUEUE:
    add r9, r9, -4                 # r9 = queue base (tail field)
    atomadd_d r10, r9, 64           # r10 = old tail, advance tail by 64 bytes
    and r10, r10, 0x3FFF            # r10 = tail & 0x3FFF (ring mask)
    add r9, r9, 16224                # r11 = queue base + 540 (start of ray slots)
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
    lw_d r10, r9, 0                 # AI fix [66]: peek first while a writer holds the lock (see branch ENSURE_NO_WRITERS); r7 = 0 here
    bgt r7, r10, ENSURE_NO_WRITERS, true
    atomadd_d r10, r9, 1            # r10 = old lock value, increment
    blte r7, r10, SKIP_UNDO_LOCK, true  # AI fix: proceed if old >= 0 (no writer), like the branch. Was `beq` (old == 0 only), so concurrent readers
                                        #   kept retrying, and any leaked reader blocked all leaf spills to that queue
    atomadd_d r11, r9, -1           # undo our increment
    beq r15, r15, ENSURE_NO_WRITERS, true        # retry claim

SKIP_UNDO_LOCK:
    lw r11, r1, 44                  # AI [140] (Alex): an imported branch stub (node_id + 8192, bit 13) points at the branch's receiver
    srl r11, r11, 13                #   queue, whose header has no owner list (the owners live in the main queue header, 32612 bytes
    beq r11, r7, OWNER_LIST_OK, true #   below). Reading the receiver header gave owner_count 0 -> NO_OWNER -> core_owner = 0xFFFF on
    add r9, r9, -32612              #   every push, so a leaf never learned a branch owner and every leaf->branch ray skipped the NoC.
OWNER_LIST_OK:                      #   r9 is only used to read the owner list below; the lock release reloads the queue address.
    lw_d r10, r9, 4                 # r10 = core_owner_count
    beq r10, r7, NO_OWNER, true     # r7=0, no owners

    # pick owner round-robin: idx = (core_id ^ clock) % core_owner_count
    getclk r11                      # r11 = clock
    srl r12, r15, 4                 # r12 = core_id
    #Adjusted because self was selected, so now cannot pick self
    xor r13, r12, r11               # r12 = core_id ^ clock = raw idx
    lhu r11, r1, 42                 # r13 = node->prev_index
    bne r13, r11, SKIP_BUMP, true    # if idx == prev_idx, bump to avoid repeat
BUMP_IDX:
    add r13, r13, 1                 # r12 = idx + 1
SKIP_BUMP:
    mod r13, r13, r10               # r12 = idx % core_owner_count
    sh r13, r1, 42                  # node->prev_index = idx
    sll r13, r13, 1                 # r12 = idx * 2 (uint16 slots)
    add r9, r9, r13                 # r9 = &core_slots[idx]
    lh_d r11, r9, 8                # r10 = core_to_cache (core_slots at +28 from lock field)
    beq r11, r12, NO_OWNER, true
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
    lw r11, r1, 44                  # AI fix [118]: no emergency for an imported branch stub (node_id + 8192). Its queue address is the
    srl r11, r11, 13                #   branch's receiver queue, whose header has no owner list (owners live in the main queue header),
    bne r11, r7, SKIP_EMERGENCY_ENQUEUE, true   #   so owner_count read 0 every time, and q = node_id + 8192 indexed past the template table:
                                    #   donors booted an all-zero entry (leaf firmware, node 0) and looped forever in FIND_BRANCH_NODE
                                    #   holding getowner (run 86: 358 frozen cores, run 84 ~470).
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
    #add r10, r10, 16
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
    and r4, r4, 0
    add r4, r4, -1
CHECK_INTERRUPT_MAILBOX:
    beq r15, r15, SKIP_INTERRUPT_MAILBOX, true   # AI [146] (Alex): a sending context no longer polls 32 (it rejected every request it took).
                                    #   Context 15 (IRQ_CTX) and yielding workers serve 32/33 through EAT_RAY_INTERRUPT, so two contexts can both send.
    nonblock r11, 32
    beq r11, r7, SKIP_INTERRUPT_MAILBOX, true
    block r11, 32
    srl r12, r11, 17
    lw r6, ROOT_NODE_ID
    bne r12, r12, CORRECT_NODE_ID, true     # AI fix: never taken -> always reject while in the send loop (its space check was inverted and accepted rays skipped the word-40 setup)
SEND_REJECT_RAY_MSG:
    add r12, r7, 8
    sll r12, r12, 24 
    srl r13, r11, 4
    sll r13, r13, 19
    srl r13, r13, 13
    and r11, r11, 0xF
    add r11, r11, 16
    or r13, r13, r11
    sendflit r12, r13
    beq r15, r15, SKIP_INTERRUPT_MAILBOX, true

#UNCONDITIONAL JUMP

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
    sll r12, r12, 24
    or r12, r12, r15
    srl r13, r11, 4
    sll r13, r13, 19
    srl r13, r13, 13
    and r11, r11, 0xF
    add r11, r11, 16
    or r13, r13, r11
    sendflit r12, r13
 
#UNCONDITIONAL JMP

SKIP_INTERRUPT_MAILBOX:
    or r12, r12, 0xFFFF
    bne r12, r4, send_ray_loop, false
    beq r3, r7, send_ray_loop, false
    intena 32
    add r3, r7, RAY_SEND_PENDING 
    atomadd r15, r3, -1
    beq r15, r15, ray_done, true
TRAVERSE_OWN_CHILD:
    and r2, r2, 0                   # AI [SL]: enter the left child from its parent
    sb r2, r0, 62
    lhu r1, r1, 24                  # r1 = node->left_child
    beq r15, r15, START_SEARCHING, true
IS_LEAF_NODE:
    and r7, r7, 0                   # AI [SL]: (the parent-bit update that was here is gone)
    lhu r2, r1, 32              # r2 - tri_index
    lbu r3, r1, 31              # r3 = tri_count
TRIANGLE_INTERSECT_LOOP:
    beq r15, r15, triangle_intersect, true
TRIANGLE_INTERSECT_RETURN:
    add r2, r2, 12                  # AI fix: index records are 12 bytes (u32 tri id + 3 x u16 vertex offsets + pad); was 6
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

    beq r15, r15, SL_ASCEND, true   # AI [SL]: leaf finished: leave it upward (SL_ASCEND restores r7 = 0 for SEND_RAY_UP)

AABB_MISS:
    beq r15, r15, SL_ASCEND, true    # AI [SL]: was: set the parent's visited bit, depth--, go to the parent

#UNCONDITIONAL BRANCH

#RYAN VALIDATED STARTS

# if (left_bitfield_check | right_bitfield_check) != 0

#UNCONDITIONAL BRANCH

SHADOW_RAY_OCCLUDED:
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

#RYAN VALIDATED ENDS

ray_done:                                # AI [115]: removed `intena 34` here ([102b]): context 15 serves NoC clone requests
    # ; if (ray->active_ray == 1) { goto start_ray_traversal; }
    and r7, r7, 0
    lb r8, r0, 63
    bne r8, r7, START_RAY_TRAVERSAL, true

    # yield();
    yield r8
    and r7, r7, 0  # AI fix: re-zero after yield (EAT_RAY_INTERRUPT may run at any yield and clobbers r4, r6-r14)
    getclk r9                            # AI [143] (Alex): a ray just left this context (sent or finished): busy = a reject within the
    lw r10, REJ_LAST_TS                  #   last IDLE_WINDOW and >= 2 rejects in the current streak. Cooldown checked here in SRAM first
    sub r10, r9, r10                     #   (CLONE_REQUEST starts with a DRAM read), and REJ_CNT is cleared so one streak asks once.
    lw r11, IDLE_WINDOW
    blte r11, r10, RD_REJ_DONE, true
    lw r10, REJ_CNT
    add r11, r7, 1
    blte r10, r11, RD_REJ_DONE, true
    lw r10, CLONE_NEXT_REQ
    bgt r10, r9, RD_REJ_DONE, true
    sw r7, REJ_CNT
    jmp r8, CLONE_REQUEST                # uses r9-r14 and the link (r8) only; r7 stays 0; returns with membits = RAY_QUEUE_HIGH
RD_REJ_DONE:

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
    add r8, r7, RAY_QUEUE_HEAD   # AI fix: r8 = &RAY_QUEUE_HEAD (was `lw r8, RAY_QUEUE_HEAD`, the head VALUE used as an address -> atomadd on SRAM 0)
    add r7, r7, 64
    atomadd r10, r8, r7          # r10 = head, advance head by 64 bytes
    and r7, r7, 0
    # head = head & 0x000007FF; // 32 slots * 64 bytes = 1024
    and r10, r10, 0x3FF          # r10 = head & 0x3FF  AI fix: 16-slot ring to match EAT_RAY_INTERRUPT's insertion mask/capacity (was 0x7FF)
    # uint32_t ray_src = local_queue_addr + 12 + head;
    add r10, r10, 12             # r10 = local_queue_addr + 12 + head (ray slot address)
    add r10, r10, r8
    add r3, r10, 0                  # AI fix [83]: wait until the intake handler has written the whole slot (byte 63 = 1); r3 survives yields (the leaf handler clobbers r5)
LOCAL_SLOT_WAIT:
    lbu r12, r3, 63
    and r7, r7, 0
    bne r12, r7, LOCAL_SLOT_OK, true
    yield r8
    beq r15, r15, LOCAL_SLOT_WAIT, true
LOCAL_SLOT_OK:
    add r10, r3, 0
    and r7, r7, 0
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
    sb r7, r10, -1
    add r8, r7, RAY_QUEUE_HEAD      # AI fix [124]: only now give the slot back to producers (used--), after the copy
    add r8, r8, 2072
    atomadd r8, r8, -1
    # ray->leaf_node_starting_point = self.branch_local_leaf_index;
    lw r8, ROOT_NODE_ID             # AI fix: word 40 = 0x80000000 | node_id marks a ray that will return to the parent branch's
    or r12, r12, 0xFFFF             #   receiver half, which resumes above its treelet. Was BRANCH_LOCAL_LEAF_INDEX (never computed, -1).
    sll r12, r12, 31
    or r8, r8, r12
    sw r8, r0, 40
    # ray->active_ray = 1;
    add r7, r7, 1
    sb r7, r0, 63           # ray->active_ray = 1 (r7=0)
    lw r1, ROOT_NODE_ADDRESS
    add r1, r1, 0
    # goto start_ray_traversal;
    beq r15, r15, START_RAY_TRAVERSAL, true
NEGATIVE_RAY_COUNT:
    # uint8_t flushing_queue = *(self.local_queue_flushing);
    lw r8, LOCAL_QUEUE_FLUSHING # r8 = local_queue_flushing (AI [62]: the value; the old `lbu r8, r8, 0` then read SRAM[value])
    # if (flushing_queue != 0){ goto inf_loop; }
    and r7, r7, 0
    bne r8, r7, FLUSH_PARK, true      # AI [63]: was INF_LOOP (never resumed)
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
    add r7, r7, 192                 # AI [55]: was 256 (see branch)
    blte r11, r7, CHECK_CUR_RAY_COUNT, true   # AI [56]: below the threshold just pull (was: reset the streak at DONT_ASK_FOR_HELP)
    # uint32_t num_times_pulled_from_full_queue = atomic_add(pulled_from_full_queue_address, 1);
    and r9, r9, 0
    add r9, r9, PULLED_FROM_FULL_QUEUE_CNT
    atomadd r9, r9, 1           # r9 = old count, increment
    # if (num_times_pulled_from_full_queue > BRANCH_BUSY_THRESHOLD)
    lw r7, CLONE_BUSY_PULLS         # AI [53]: busy threshold (was -1 = disabled)
    blteu r9, r7, CHECK_CUR_RAY_COUNT, true  # AI: unsigned compare so the 0xFFFFFFFF threshold is never exceeded
    jmp r8, CLONE_REQUEST           # AI [53]: was `jmp r15, SEARCH_FOR_IDLE_CORES` (no link). Returns to DONT_ASK_FOR_HELP.
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
    and r7, r7, 0           # AI fix: r7 was 16 (loop counter), so the slot's ready byte was set to 16 instead of cleared
    # write_dram_byte(queue_address_low - 1, 0); // mark consumed
    add r9, r9, -1          # r9 = queue_address_low - 1
    sb_d r7, r9, 0           # write 0 to ready byte to mark consumed
    add r9, r9, 1           # restore r9 to point to start of ray slot
    # ray->leaf_node_starting_point = self.branch_local_leaf_index;
    lw r8, ROOT_NODE_ID             # AI fix: word 40 = 0x80000000 | node_id marks a ray that will return to the parent branch's
    or r12, r12, 0xFFFF             #   receiver half, which resumes above its treelet. Was BRANCH_LOCAL_LEAF_INDEX (never computed, -1).
    sll r12, r12, 31
    or r8, r8, r12
    sw r8, r0, 40          # ray->leaf_node_starting_point = branch_local_leaf_index
    # goto start_ray_traversal;   
    beq r15, r15, START_RAY_TRAVERSAL, true 
NO_DRAM_RAYS:
    beq r15, r15, CHECK_DONE, true  # AI [95]: original in-place emergency switch disabled (count +1 never undone, no drain or owner-list
                                    #   handoff). Emergency entries are taken by idle cores through the clone-reboot path (CLONE_POLL_REQUEST).
    # uint32_t emergency_queue_high = self.emergency_queue_high;
#AI[100]     lw r10, EMERGENCY_QUEUE_HIGH # r10 = emergency_queue_high
#AI[100]     # set_address_bits(emergency_queue_high);
#AI[100]     setmembits r10
#AI[100]     # uint32_t emergency_queue_low = self.emergency_queue_low;
#AI[100]     lw r9, EMERGENCY_QUEUE_LOW # r9 = emergency_queue_low
#AI[100]     # uint32_t count = load_dram_word(emergency_queue_low + 8);
#AI[100]     add r9, r9, 8           # r9 = &count field
#AI[100]     lw_d r11, r9, 0       # r11 = count
#AI[100]     add r9, r9, -8
#AI[100]     # if (count <= 0)
#AI[100]     # {
#AI[100]     #     goto check_done;
#AI[100]     # }
#AI[100]     and r7, r7, 0
#AI[100]     blte r11, r7, CHECK_DONE, true
#AI[100]     # emergency_queue_low += 8;
#AI[100]     add r9, r9, 8
#AI[100]     # uint32_t old_cnt = atomic_add_dram(emergency_queue_low, 1);
#AI[100]     atomadd_d r11, r9, 1       # r11 = old_cnt, increment count
#AI[100]     # if (old_cnt <= 0)
#AI[100]     # {
#AI[100]     #     atomic_add_dram(emergency_queue_low, -1);
#AI[100]     #     goto check_done;
#AI[100]     # }
#AI[100]     and r7, r7, 0
#AI[100]     bgt r11, r7, EMERGANCY_QUEUE_CONTINUE, true
#AI[100]     atomadd_d r11, r9, -1      # undo increment
#AI[100]     beq r15, r15, CHECK_DONE, true
#AI[100] EMERGANCY_QUEUE_CONTINUE:
#AI[100]     # emergency_queue_low -= 8;
#AI[100]     add r9, r9, -8
#AI[100]     # uint32_t byte_index = atomic_add_dram(emergency_queue_low, 4);
#AI[100]     atomadd_d r10, r9, 4 
#AI[100]     # byte_index &= 0x000000FF;
#AI[100]     and r10, r10, 0xFF
#AI[100]     # emergency_queue_low += byte_index;
#AI[100]     add r9, r9, r10
#AI[100]     # emergency_queue_low += 12;
#AI[100]     add r9, r9, 12
#AI[100]     # ensure_emergency_slot_ready:
#AI[100] ENSURE_EMERGENCY_SLOT_READY_TWO:
#AI[100]     # uint16_t is_ready = load_dram_byte(emergency_queue_low + 2);
#AI[100]     add r10, r9, 2           # r10 = emergency_queue_low + 2
#AI[100]     lbu_d r10, r10, 0          # r10 = is_ready
#AI[100]     # if (is_ready == 1)
#AI[100]     # {
#AI[100]     #     goto ensure_emergency_slot_ready_TWO;
#AI[100]     # }
#AI[100]     and r7, r7, 0
#AI[100]     add r7, r7, 1
#AI[100]     beq r10, r7, ENSURE_EMERGENCY_SLOT_READY_TWO, true
#AI[100]     # uint32_t new_node_id = load_dram_half(emergency_queue_low);
#AI[100]     lw_d r11, r9, 0           # r11 = new_node_id (uint32 loaded from slot)
#AI[100]     # store_dram_byte(emergency_queue_low + 2, 0);
#AI[100]     add r10, r9, 2           # r10 = emergency_queue_low + 2
#AI[100]     and r7, r7, 0
#AI[100]     sb_d r7, r10, 0          # mark slot as empty by writing 0 to is_ready
#AI[100]     # goto switch_dram_queue;
#AI[100]     #TODO
#AI[100]     beq r15, r15, SWITCH_DRAM_QUEUE, true

    # yield();
    yield r8
CHECK_DONE:
    # is_idle_leaf();
    jmp r2, CLONE_IDLE_HOOK              # AI [53]: was is_idle_leaf (threshold test inverted, ray counter never incremented)
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


# ---------------------------------------------------------------------------------------------
# AI [53] CORE CLONING (static-copy donation). See AI_AUTOMATED_CHANGES.txt [53] for the protocol.
# CLONE_IDLE_HOOK: called from the idle path with link r2. Context 0 only. Returns with r14 = 0.
#   Clobbers r3-r13 and membits.
# ---------------------------------------------------------------------------------------------
CLONE_IDLE_HOOK:
    and r14, r14, 0
    and r3, r15, 0xF
    bne r3, r14, CLONE_HOOK_RET2, true   # context 0 only. AI fix [121]: was CLONE_HOOK_RET, whose [97] give-back let every idle context
                                         #   hand back context 0's emergency claim (CLONE_EMERG) while context 0 was draining for it; the
                                         #   donation then reloaded REASSIGN = 0 and CLONE_EMERG = 0, so r5 = -1 = emergency q 0xFFFF,
                                         #   booted the all-zero template and froze in FIND_BRANCH_NODE (run 90: 1211 cores).
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
    lw r5, CLONE_IDLE_STREAK
    add r5, r5, 1
    sw r5, CLONE_IDLE_STREAK
    lw r4, CLONE_IDLE_MAX_RAYS           # (now: consecutive idle checks required)
    bgt r4, r5, CLONE_HOOK_RET, true     # not idle long enough yet
                                         # AI [95]: sole-owner check removed: a leaf may go to zero owners (emergency queue refills it)
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
    bne r5, r14, CLONE_HAVE_TARGET, false
    lw r5, CLONE_EMERG                   # AI [95]: emergency node claimed earlier (drain gave up): retry it
    bne r5, r14, CLONE_HAVE_TARGET, false
    jmp r13, EMERG_CLAIM_TRY             # r5 = (0x80000000 | q) + 1, or 0
    beq r5, r14, CLONE_HOOK_RET, true    # no request and no ownerless node
    sw r5, CLONE_EMERG
CLONE_HAVE_TARGET:
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
    sw_d r14, r4, 0                      # consume the request
    lw r6, CLONE_EMERG                   # AI [95]: an emergency target takes priority over a pool request
    beq r6, r14, CLONE_REQ_TARGET, true
    add r5, r6, 0
CLONE_REQ_TARGET:
    bne r5, r14, CLONE_REQ_HAVE, true    # AI fix [121]: no target left (r9 = 1: we own the core): abort instead of booting garbage,
    sw r14, PREVIOUSLY_IDLE              #   and leave the idle pool flag clear so the core can register again (its pool slot was taken)
    beq r15, r15, CLONE_BUSY_ABORT, true
CLONE_REQ_HAVE:
    add r5, r5, -1                       # r5 = requester core id, or 0x80000000 | q
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
    add r12, r14, 1                      # AI [95]: the last owner leaves only with an empty DRAM queue. Checked under the writer lock;
    bne r9, r12, CLONE_NOT_LAST, true    #   senders push before taking the reader lock, so any later ray sees 0 owners -> emergency queue.
    lw_d r12, r3, 8
    bne r12, r14, CLONE_LAST_OWNER, false
CLONE_NOT_LAST:
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
    beq r15, r15, CLONE_HOOK_RET, true
CLONE_SLOT_DONE:
    add r12, r3, 20
    atomadd_d r8, r12, 8192              # release the writer lock
    add r12, r3, 16
    atomadd_d r8, r12, 1                 # now_serving++
    lw r3, EMERGENCY_QUEUE_HIGH          # stack 0: boot table (20000 + core*8) and the emergency template table
    setmembits r3
    sw r14, CLONE_EMERG
    srl r6, r5, 31
    beq r6, r14, CLONE_COPY_CORE, true
    and r5, r5, 0xFFFF                   # AI [95]: emergency target: copy the node's boot template (main.rs, + q*8)
    sll r5, r5, 3
    lw r6, EMERG_TEMPLATE_LOW
    add r5, r5, r6
    beq r15, r15, CLONE_COPY_LOAD, true
CLONE_COPY_CORE:
    srl r8, r15, 4                       # AI [102]: CLONE_SRC[me] = requester + 1: my boot asks it for its geometry over the NoC
    sll r8, r8, 2
    lw r9, CLONE_SRC_LOW
    add r8, r8, r9
    add r9, r5, 1
    sw_d r9, r8, 0
    sll r5, r5, 3
    add r5, r5, 20000
CLONE_COPY_LOAD:
    lw_d r6, r5, 0                       # node_id (queue index)
    lw_d r7, r5, 4                       # is_branch | index
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
    lw r7, RAY_QUEUE_CNT                 # leaf local SRAM ray queue count
    bne r7, r14, CLONE_BUSY_ABORT_RET, false
    jmp r15, r13
EMERG_CLAIM_TRY:                         # AI [95]: link r13. r5 = (0x80000000 | q) + 1 for a claimed emergency entry, else 0. Uses r5-r8.
    and r5, r5, 0
    lw r6, EMERGENCY_QUEUE_HIGH
    setmembits r6
    lw r6, EMERGENCY_QUEUE_LOW
    lw_d r7, r6, 8                       # peek count
    blte r7, r14, EMERG_TRY_RET, true
    add r8, r6, 8
    atomadd_d r7, r8, -1                 # old count
    bgt r7, r14, EMERG_TRY_TAKE, true
    atomadd_d r7, r8, 1                  # lost the race: undo
    beq r15, r15, EMERG_TRY_RET, true
EMERG_TRY_TAKE:
    atomadd_d r7, r6, 4                  # old head
    and r7, r7, 0xFF
    add r7, r7, r6
    add r7, r7, 12                       # slot
EMERG_TRY_WAIT:
    lbu_d r8, r7, 2
    beq r8, r14, EMERG_TRY_WAIT, false   # producer still writing the slot
    lhu_d r5, r7, 0                      # q
    sb_d r14, r7, 2                      # free the slot
    add r6, r14, 1
    sll r6, r6, 31
    or r5, r5, r6
    add r5, r5, 1
EMERG_TRY_RET:
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
    lw r7, RAY_QUEUE_CNT
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
CLONE_HOOK_RET:
    and r14, r14, 0
    lw r5, CLONE_EMERG                   # AI fix [97]: a donation that did not happen gives its emergency target back. Run 67: claimants that
    beq r5, r14, CLONE_HOOK_RET2, true   #   could not drain (busy again) kept the claim forever; ~250 nodes stayed flagged, never re-queued,
    sw r14, CLONE_EMERG                  #   and their rays sat in ownerless queues (throughput collapsed after ~1.65M).
    lw r6, EMERGENCY_QUEUE_HIGH
    setmembits r6
    lw r6, EMERGENCY_QUEUE_LOW
    add r7, r6, 8
    atomadd_d r8, r7, 1                  # old count
    add r9, r14, 64
    bgt r9, r8, EMERG_REQ_SLOT, true
    atomadd_d r8, r7, -1                 # full: undo and clear the flag, so the next spill to that node re-queues it
    add r5, r5, -1
    and r5, r5, 0xFFFF
    sll r5, r5, 2
    lw r9, EMERG_FLAG_LOW
    add r9, r9, r5
    sw_d r14, r9, 0
    beq r15, r15, CLONE_HOOK_RET2, true
EMERG_REQ_SLOT:
    add r7, r6, 4
    atomadd_d r8, r7, 4                  # old tail
    and r8, r8, 0xFF
    add r8, r8, r6
    add r8, r8, 12
EMERG_REQ_WAIT:
    lbu_d r9, r8, 2
    bne r9, r14, EMERG_REQ_WAIT, false
    add r5, r5, -1                       # 0x80000000 | q: sh keeps q
    sh_d r5, r8, 0
    add r9, r14, 1
    sb_d r9, r8, 2
CLONE_HOOK_RET2:
    and r14, r14, 0
    jmp r15, r2
# CLONE_REQUEST: busy side. Link r8. Uses r9-r14 only (r14 returns 0); restores membits to RAY_QUEUE_HIGH.
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
    jmp r15, r8

# AI [64]: the routines below were replaced by CLONE_IDLE_HOOK / CLONE_REQUEST ([53]) and are commented out to free SRAM (unchanged text, prefixed '#AI[64] ')
#AI[64] is_idle_leaf:
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
#AI[64]     add r6, r2, 0
#AI[64]     jmp r2, ADD_IDLE_CORE
#AI[64]     and r3, r3, 0
#AI[64]     add r3, r3, PREVIOUSLY_IDLE
#AI[64]     atomadd r3, r3, 1    
#AI[64]     and r14, r14, 0                         # r14 = 0 (zero register)
#AI[64]     add r14, r14, 1
#AI[64]     jmp r15, r6                             # return 0 (already marked idle, nothing to do)




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
    beq r6, r10, TRIANGLE_INTERSECT_ELSE_BLOCK_1, false   # AI fix [87]: was bne, so det > 0 got the det < 0 test (reject u > 0) and vice versa:
                                                          #   every triangle was rejected (run 53: 1301 det checks, 0 past the u/v tests)
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
    beq r5, r11, TRIANGLE_INTERSECT_END_IF_BLOCK_2, true  # AI fix [87]: was bne (continued when the v test FAILED, returned when it passed)
    beq r15, r15, TRIANGLE_INTERSECT_RETURN, true
TRIANGLE_INTERSECT_ELSE_BLOCK_2:
    fplt.32 r5, r11, r7
    fplt.32 r6, r12, r8
    or r5, r5, r6
    beq r5, r11, TRIANGLE_INTERSECT_END_IF_BLOCK_2, true  # AI fix [87]: was bne (continued when the v test FAILED, returned when it passed)
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
    lw r6, INDEX_ARRAY_BASE         # AI fix: tri id is at INDEX_ARRAY_BASE + r2 (was `lw r6, r2, 0`, an absolute SRAM read into code)
    add r6, r6, r2
    lw r6, r6, 0
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

#UNCONDITIONAL BRANCH

EAT_RAY_INTERRUPT: #working with r6-r14
    add r4, r8, 0                           # r4 = return address (saved from r8 by caller convention)
    intdis 32                               # disable_interrupts(channel)
    nonblock r7, 32                             # r7 = nb_recv(channel) (0 if no message waiting)
    and r14, r14, 0                         # r14 = 0 (zero register)
    bne r14, r7, CONTINUE_WITH_EAT_RAY_INTERRUPT, true  # if message waiting goto CONTINUE_WITH_EAT_RAY_INTERRUPT
    nonblock r7, 33                         # AI fix [122b]: also take pipe 33. Interrupt enables survive a clone reboot, so a former
    bne r14, r7, EAT_RAY_FROM_33, true      #   branch core can have 33 enabled; a request left there made that context re-enter
    intena 32                               #   this handler forever. It now gets the normal wrong-core reject below.
    jmp r15, r4                             # return
EAT_RAY_FROM_33:
    block r7, 33
    beq r15, r15, EAT_RAY_GOT, true
CONTINUE_WITH_EAT_RAY_INTERRUPT:
    block r7, 32                                # r7 = blocking_recv(channel) (full flit value)
EAT_RAY_GOT:
    add r5, r7, 0                           # save full message
    and r6, r15, 0xF                        # save return address to per-thread SRAM slot
    sll r6, r6, 2
    add r6, r6, EAT_RAY_RETURN_ADDR
    sw r4, r6, 0
    lw r8, EAT_RAY_MASK                     # r8 = EAT_RAY_MASK (isolates core_id field)
    and r8, r7, r8                          # r8 = core_id = flit & EAT_RAY_MASK
    srl r13, r7, 17                         # r13 = node_id = flit >> 17
    lw r9, ROOT_NODE_ID              # r9 = self.node_id (sender side)
    beq r13, r9, NODE_IDS_MATCH, true      # if node_id == sender_node_id goto NODE_IDS_MATCH
reject_ray_interrupt:
    and r6, r15, 0xF                        # reset saved return addr (not reaching SEND_ACK_PACKET)
    sll r6, r6, 2
    add r6, r6, EAT_RAY_RETURN_ADDR
    and r9, r9, 0
    add r9, r9, -1
    sw r9, r6, 0
    add r10, r14, 8                         # r10 = wrong_core = 8 (reject code)
    sll r10, r10, 24                        # r10 = wrong_core << 24
    and r11, r5, 0xF                       # r11 = self.thread_id (low 4 bits)
    srl r12, r5, 4                          # AI fix [47]: full 13-bit core id (was `and r12, r5, 0xFFF0`, 12 bits: cores >= 4096 misrouted)
    sll r12, r12, 19
    srl r12, r12, 13                        # r12 = core_id << 6 (channel position)
    add r11, r11, 16                        # r11 = self.thread_id + 16 (send channel)
    or r11, r12, r11                        # r11 = destination flit (channel | thread_id)
    sendflit r10, r11                       # send_flit(wrong_core << 24, dest) (reject: wrong node)
    intena 32                               # enable_interrupts(channel)
    jmp r15, r4                             # return
NODE_IDS_MATCH:
    lw r7, LOCAL_QUEUE_FLUSHING             # r7 = *(self.local_queue_flushing)
    bne r14, r7, reject_ray_interrupt, false # if flushing_queue != 0 goto reject_ray_interrupt
    lbu r9, r0, 63                          # r7 = ray->active_ray (byte at ray+63)
    add r7, r0, 0                           # r9 = local_queue = ray base address
    bne r14, r14, RECEIVE_RAY_DATA, false   # AI fix: never taken (see branch EAT_RAY_INTERRUPT): direct deposit skipped r1 = ROOT_NODE_ADDRESS and word40 = BRANCH_LOCAL_LEAF_INDEX
    add r9, r14, RAY_QUEUE_CNT                # r9 = sender ray queue base address
    add r10, r9, 2064                       # AI fix [124]: r10 = &used (RAY_QUEUE_HEAD + 2072, spare part of RAY_QUEUE_ENTRIES):
    atomadd r7, r10, 1                      #   slots taken and not yet freed by their consumer (see branch [124])
    add r12, r14, 16                        # r12 = 16 (max queue entries)
    bgt r12, r7, SPACE_COUNT_UP, true     # if old_used < 16: reserve
    atomadd r7, r10, -1                     # full: undo
    add r7, r14, 7                          # r7 = reject_ray = 7 (reject code)
    sll r7, r7, 24                          # r7 = reject_ray << 24
    srl r9, r8, 4 # was and r9, r8, 0xF0    # r9 = core_id high nibble
    sll r9, r9, 19                          # r9 = high nibble shifted to channel position
    srl r9, r9, 13
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
    intena 32                               # enable_interrupts(channel)
    jmp r15, r4                             # return
SPACE_COUNT_UP:
    atomadd r7, r9, 1                       # AI fix [124]: count = rays available to consumers
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
    srl r10, r8, 4
    #and r10, r8, 0xF0                       # r10 = core_id high nibble
    sll r10, r10, 19                         # r10 = high nibble shifted to channel position
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
    add r9, r14, 1                          # AI fix [83]: publish the slot only now. RAY_QUEUE_CNT was bumped before the 16 words arrived
    sb r9, r7, 63                           #   (the `block` receives switch contexts), so ray_done could copy a half-empty slot: zero rays
                                            #   (run 49: ~1800 leaf contexts stuck traversing all-zero rays). Consumers now wait for byte 63.
    and r9, r14, 0                          # reset EAT_RAY_RETURN_ADDR[tid] = -1
    add r9, r9, -1
    and r10, r15, 0xF
    sll r10, r10, 2
    add r10, r10, EAT_RAY_RETURN_ADDR
    sw r9, r10, 0
                                            # AI fix [52]: removed `lw r1, ROOT_NODE_ADDRESS` here. This handler runs inside whatever context yielded,
                                            #   and traversal yields at START_SEARCHING on every step, so it reset that context's current node (r1)
                                            #   to the leaf root mid-traversal (left over from the direct-deposit path disabled in [16]).
    intena 32                               # enable_interrupts(channel)
    jmp r15, r4                             # return





IRQ_CTX:                                 # AI [115]: dedicated interrupt context (15). Handlers return to the yield.
    intena 32
    intena 33                            # AI [122b]: back on (was off in [116b]): the leaf handler now takes 33 too, so a stray
    intena 34                            #   request there gets a reject instead of waiting forever.
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
    add r9, r14, 1
    sw r9, NOC_CLONED                    # leaf dfs_done skips the DRAM index/vertex copy
    lw r12, RAY_QUEUE_HIGH
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
    add r10, r14, FOUND_LEAF_CORE_INDEX_FOR_BRANCH
    add r11, r14, 1
    jmp r12, NOC_SEND_REGION
    add r10, r14, SRAM_NODE_ALLOC_PTR
    add r11, r14, 1
    jmp r12, NOC_SEND_REGION
    add r10, r14, INDEX_ARRAY_BASE
    add r11, r14, 1
    jmp r12, NOC_SEND_REGION
    add r10, r14, VERTEX_ARRAY_BASE
    add r11, r14, 1
    jmp r12, NOC_SEND_REGION
    add r10, r14, LEAF_GEO_END           # AI fix [118]: send LEAF_GEO_END too. It is set only by the DRAM copy, so a NoC clone kept the
    add r11, r14, 1                      #   image default 0, and when it later served as a source it streamed (0 - NODE_ARRAY_TOP) >> 2
    jmp r12, NOC_SEND_REGION             #   = ~1G words: run 86 had 184 clones and their sources stuck in that stream forever.
    lw r10, NODE_ARRAY_TOP               # nodes + triangle indices + vertices: [NODE_ARRAY_TOP, LEAF_GEO_END)
    lw r11, LEAF_GEO_END
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
    jmp r13, NOC_GEO_RECEIVE             # AI [102]: returns only when the geometry must come from DRAM (DFS below)

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
    and r14, r14, 0                          #r14 = 0
    add r11, r14, DFS_STACK                  #r11 = DFS_STACK address
    beq r2, r11, dfs_done, true              #If stack_top == self.dfs_stack address, go to dfs_done

    add r2, r2, -16                         #stack_top -= 16;
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
    lhu_d r10, r12, 32                       # tri_start (uint16) from DRAM
    sh r10, r13, 32                          # store at SRAM offset 32
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
    srl r14, r14, 16                         # AI fix [99]: the immediate sign-extends to 0xFFFFFFFF, never equal to the lhu parent_ptr 0xFFFF,
                                             #   so the root was "patched" through patch_left = 0: SRAM word 0 (reboot entry) = 16704. The next
                                             #   reboot of that core hit an invalid opcode (run 67 crash; run 68 BOOT_CLOBBER at this sh).
    beq r5, r14, SKIP_PATCH, true
    and r14, r14, 0
    bne r8, r14, PATCH_RIGHT_CHILD, true
    sh r13, r6, 0                            # *patch_left = node
    beq r15, r15, SKIP_PATCH, true
PATCH_RIGHT_CHILD:
    sh r13, r7, 0                            # *patch_right = node
SKIP_PATCH:
    lbu r10, r13, 30        #load is_right
    and r14, r14, 0         #r14 = 0
    bne r14, r14, dfs_loop, false       # AI fix: never taken. Was `bne r10, r14` (is_right != 0 -> dfs_loop): right children were never
                                        #   recursed, so the leaf missed half of the branch treelet and, when its own root is a right child,
                                        #   never set ROOT_NODE_ADDRESS (rays then started at SRAM 0). Full treelet + own subtree fits (worst 32700/32768 B).
    lw r10, r13, 36                #r10 == queue_low_bit_addr   
    bne r10, r11, CHECK_RECURSE, true
    sw r13, ROOT_NODE_ADDRESS          # store the SRAM node pointer
    #lw r10, r13, 44                    # node_id was just copied to SRAM at offset 44
    #sw r10, ROOT_NODE_ID 
    #sw r13, ROOT_NODE_ID
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

#UNCONDITIONAL JUMP

SET_NODE_ID:
    add r10, r14, 1
    sw r10, FOUND_LEAF_CORE_INDEX_FOR_BRANCH
    lw_d r10, r12, 44                        # node_id
    sw r10, ROOT_NODE_ID
    lw r10, SRAM_NODE_ALLOC_PTR
    add r10, r10, -48
    sw r10, ROOT_NODE_ADDRESS

#START RYAN VALIDATE

DO_RECURSE:
    # -- push right child first (so left is processed first) --
    and r14, r14, 0
    lw_d r11, r12, 24                        # left index
    srl r11, r11, 8
    add r10, r11, 1                          #right index
    add r12, r9, 1                           # child_depth = depth + 1


#END RYAN VALIDATE

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

#UNCONDITIONAL BRANCH

dfs_done:
    # *(self.leaf_core_lookup_table + 256) = self->root_node;
    and r14, r14, 0
    lw r10, JUMP_TO_RAY_EAT_INTERRUPT
    sw r10, 65408
    sw r10, 65412
    lw r10, JUMP_TO_SWITCH_ROLES_INTERRUPT
    sw r10, 65416
    lw r10, NOC_CLONED                   # AI [102]: geometry already arrived over the NoC: skip the DRAM index/vertex copy
    bne r10, r14, vertex_copy_done, false
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
    sw r4, LEAF_GEO_END                  # AI [102]: end of this core's geometry (what a NoC clone source streams)
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
    add r1, r14, RAY_QUEUE_HEAD          # AI fix [148]: zero the [124] `used` counter (RAY_QUEUE_HEAD + 2072) too. Only head/tail/count
    add r1, r1, 2072                     #   were cleared, and this SRAM is not downloaded, so a clone kept its old role's data there.
    sw r14, r1, 0

    # *(self.local_queue_flushing) = 0;
    sw r14, LOCAL_QUEUE_FLUSHING

    # *(self.tile_data_sram + 4) = 0;
    add r1, r14, TILE_DATA_COUNT
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
    lw r2, EMERGENCY_QUEUE_HIGH          # AI [95]: node occupied again: clear its emergency flag
    setmembits r2
    lw r3, ROOT_NODE_ID
    sll r3, r3, 2
    lw r4, EMERG_FLAG_LOW
    add r4, r4, r3
    sw_d r14, r4, 0
    lw r2, RAY_QUEUE_HIGH
    setmembits r2
CLONE_REG_DONE:
    intena 32
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
    lw r1, ROOT_NODE_ADDRESS
    # *(ray + 63) = 0;
    add r1, r1, 0
    sb r14, r0, 63

    beq r15, r15, ray_done, true

   
# AI [64]: the routines below were replaced by CLONE_IDLE_HOOK / CLONE_REQUEST ([53]) and are commented out to free SRAM (unchanged text, prefixed '#AI[64] ')
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
#AI[64]     jmp r15, r2                             # return

#AI[64] SEARCH_FOR_IDLE_CORES: #There's no documentation of who uses this function
#AI[64] #I am going to assume that r3 has a return address
#AI[64]     and r14, r14, 0                     # r14 = 0 (zero register)
#AI[64]     lw r5, IDLE_QUEUE_HIGH      # r5 = self.idle_queue_address_high
#AI[64]     setmembits r15, r5                  # set_address_bits(idle_queue_high)  AI fix: was set to the DFS_STACK SRAM address
#AI[64]     add r5, r14, DFS_STACK              # r5 = &DFS_STACK (dfs stack pointer)  AI fix: moved below setmembits
#AI[64]     lw r6, IDLE_QUEUE_LOW       # r6 = current = self.idle_queue_address_low
#AI[64]     or r8, r8, 0xFFFF                   # r8 = 0xFFFFFFFF (found_core_id sentinel = not found)
#AI[64]     atomadd_d r9, r6, -1                # r9 = old_count = atomic_add_dram(current.count, -1)
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



JUMP_TO_RAY_EAT_INTERRUPT:
jmp r15, EAT_RAY_INTERRUPT
JUMP_TO_SWITCH_ROLES_INTERRUPT:
jmp r15, NOC_GEO_SEND_INTERRUPT  # AI [102]
LEAF_START_OF_GEO:
.data 1234
leaf_start_of_code:
.data 44
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
.data 17152                  # AI [102]: was 16128 (64KB SRAM; room for the NoC clone routines)
BRANCH_START_OF_CODE:    
.data 44
BRANCH_NUM_INSTRUCTION_BYTES: 
.data 9000 #17284
BRANCH_START_OF_GEO:     
.data 17152                  # AI fix [102]: must equal NODE_ARRAY_TOP (the leaf DFS always recurses the node at this address)
BRANCH_SIZE_OF_GEO:      
.data 32768
BRANCH_IDLE_THRESHOLD:    # TODO chenge this value
.data 1000000
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
.data 2000100000                # AI [152]: per-stack copy (was 150000 on stack 0); bit 31 set at boot
DIV_TABLE_HIGH: 
.data 0
DIV_TABLE_LOW: 
.data 2000200000                # AI [152]: per-stack copy (was 61000000 on stack 0); bit 31 set at boot
INV_SQRT_TABLE_HIGH: 
.data 0
INV_SQRT_TABLE_LOW: 
.data 2000000000                # AI [152]: per-stack copy (was 100000 on stack 0); bit 31 set at boot
IDLE_QUEUE_HIGH: #CALCULATED AT RUNTIME!!!!!! TODO
.data 0
CLONE_REQ_TABLE_LOW:                     # AI [53]
.data 2500100000
CLONE_IDLE_MAX_RAYS:
.data 3          # AI [138] (Alex): 3 consecutive IDLE_WINDOW checks (~150K cycles) before joining the pool ([136]: 10; originally 2)
CLONE_IDLE_STREAK:                       # AI [59]: consecutive idle checks so far
.data 0
CLONE_DRAIN_LIMIT:                       # AI [63]
.data 2048
CLONE_WARMUP:                            # AI [84]: cycles before any core may register as idle
.data 400000
EMERG_MIN_RAYS:                          # AI [95]: an ownerless queue goes on the emergency queue above this many rays
.data 0
EMERG_FLAG_LOW:                          # AI [95]: per-queue on-emergency-queue flags, stack 0, + q*4
.data 63500000
EMERG_TEMPLATE_LOW:                      # AI [95]: per-queue boot template {q, is_branch<<31 | node}, stack 0, + q*8 (main.rs)
.data 63600000
CLONE_EMERG:                             # AI [95]: claimed emergency target, (0x80000000 | q) + 1
.data 0
CLONE_MY_SLOT:                        # cached core_slots index of this core (O(1) leave fast path)
.data 65535                               # AI [125]: 65535 = unknown (positive, so the index < owner_count check rejects it)
LEAF_GEO_END:                            # AI [102]
.data 0
NOC_CLONED:                              # AI [102]: 1 = this boot received its geometry over the NoC
.data 0
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
CLONE_MIN_OWNERS:                        # AI [72]+[95]: minimum owners a leaf keeps when a core donates itself (0: leaves may empty)
.data 0
CLONE_BUSY_PULLS:
.data -1          # AI [139] (Alex): off (unsigned compare never exceeds); busy = NoC rejects now. Was 8
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
EAT_RAY_RETURN_ADDR:
.data(16) -1
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
