.org  40    # TODO Double check
.data 40        # TODO Double check

    # uint32_t dram_queue_array_address = self.dram_queue_array_low + (self.core_id << 3);
    beq r15, r15, INITIALIZE_CORE, true
    
    RAY_QUEUE_HIGH: 
    .data 0xA5A5A5A5
    RAY_QUEUE_LOW: 
    .data 0xDEADBEEF
    IS_BRANCH_CORE: 
    .data 0x69696969
    ROOT_NODE_ID:           
    .data 0x67676767
    NODE_INDEX_OF_ROOT:
    .data 0xCAFEBABE
INITIALIZE_CORE:
    lw r0, dram_queue_array_high    

    setmembits r0   
    srl r14, r15, 4
    sll r14, r14, 3

    # uint32_t upper_addr = self.dram_queue_array_high;
    lw r1, dram_queue_array_low      # r1 = upper_addr
    add r1, r1, r14

    # uint32_t dram_queue_high = load_dram_word(dram_queue_array_address);
    lw_d r2, r1, 0                       # r2 = node_id
    lw_d r3, r1, 4 #r3 = is_branch_core
    srl r4, r3, 31

    sw r2, ROOT_NODE_ID
    # uint32_t dram_queue_low = load_dram_word(dram_queue_array_address + 4);
    sw r4, IS_BRANCH_CORE
    lw r4, AND_MASK
    and r4, r4, r3
    sw r4, NODE_INDEX_OF_ROOT
    lw r0, dram_queue_addresses_high    

    setmembits r0   
    sll r14, r2, 3

    # uint32_t upper_addr = self.dram_queue_array_high;
    lw r1, dram_queue_addresses_low      # r1 = upper_addr
    add r1, r1, r14

    # uint32_t dram_queue_high = load_dram_word(dram_queue_array_address);
    lw_d r2, r1, 0                       # r2 = RAY_QUEUE_HIGH
    lw_d r3, r1, 4                       # r3 = RAY_QUEUE_LOW
    sw r2, RAY_QUEUE_HIGH
    sw r3, RAY_QUEUE_LOW
    setmembits r2
    add r3, r3, 12
    atomadd_d r4, r3, 1
MY_TICKET_HAS_NOT_ARRIVED:
    lw_d r5, r3, 4
    bne r4, r5, MY_TICKET_HAS_NOT_ARRIVED, true
    add r3, r3, 8
    atomadd_d r5, r3, -8192
    and r4, r4, 0
    add r4, r4, -8192
WAIT_FOR_WRITER_LOCK:
    lw_d r5, r3, 0
    bne r5, r4, WAIT_FOR_WRITER_LOCK, false
    add r3, r3, 4
    atomadd_d r4, r3, 1
    sll r4, r4, 1
    add r4, r3, r4
    srl r6, r15, 4
    sh_d r6, r4, 4
    add r3, r3, -4
    atomadd_d r15, r3, 8192
    add r3, r3, -4
    atomadd_d r15, r3, 1


    lw r4, IS_BRANCH_CORE
    and r0, r0, 0
    beq r4, r0, download_leaf_core_code, true

    # uint32_t r1 = self.num_instructions_branch;
    lw r1, num_instructions_branch

    # uint32_t r2 = self.branch_addr_high;
    lw r2, branch_addr_high      # r2 = branch_addr_high

    # set_address_bits(r2);
    setmembits r2

    # uint32_t r2 = self.branch_addr_low;
    lw r2, branch_addr_low

    # goto bootloader_reuse;
    beq r15, r15, bootloader_reuse, true

    # uint32_t r1 = self.num_instructions_leaf;
download_leaf_core_code:
    lw r1, num_instructions_leaf     # r1 = num_instructions_leaf

    # uint32_t r2 = self.leaf_addr_high;
    lw r2, leaf_addr_high

    # set_address_bits(r2);
    setmembits r2

    # uint32_t r2 = self.leaf_addr_low;
    lw r2, leaf_addr_low             # r2 = leaf_addr_low

    # uint32_t r3 = self.start_of_code_in_sram;
bootloader_reuse:
    lw r3, START_OF_DOWNLOADING_MORE_CODE
    # goto bootloader_loop;
    beq r15, r15, 20, true   # unconditional jump to bootloader
    
dram_queue_array_low:
    .data 20000   
dram_queue_array_high:
    .data 0  
dram_queue_addresses_high:
    .data 0  
dram_queue_addresses_low:
    .data 63070000  
num_instructions_branch:
    .data 2750   
branch_addr_high:
    .data 0   
branch_addr_low:
    .data 424 
num_instructions_leaf:
    .data 2350  
leaf_addr_high:
    .data 0   
leaf_addr_low:
    .data 61010024   
AND_MASK:
    .data 0x7FFFFFFF
START_OF_DOWNLOADING_MORE_CODE:
    .data 0x44
