.org  0x28    # TODO Double check
.data 40        # TODO Double check

    # uint32_t dram_queue_array_address = self.dram_queue_array_low + (self.core_id << 3);
    beq r15, r15, INITIALIZE_CORE, true
    
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
    lw r4, IS_BRANCH_CORE
    and r0, r0, 0
    bne r4, r0, download_branch_core_code, true

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
download_branch_core_code:
    lw r1, num_instructions_leaf     # r1 = num_instructions_leaf

    # uint32_t r2 = self.leaf_addr_high;
    lw r2, leaf_addr_high

    # set_address_bits(r2);
    setmembits r2

    # uint32_t r2 = self.leaf_addr_low;
    lw r2, leaf_addr_low             # r2 = leaf_addr_low

    # uint32_t r3 = self.start_of_code_in_sram;
bootloader_reuse:
    and r0, r0, 0
    # goto bootloader_loop;
    beq r15, r15, 16, true   # unconditional jump to bootloader
    
dram_queue_array_low:
    .data 20000   
dram_queue_array_high:
    .data 0  
dram_queue_addresses_high:
    .data 0  
dram_queue_addresses_low:
    .data 63070000  
num_instructions_branch:
    .data -1   
branch_addr_high:
    .data 0   
branch_addr_low:
    .data 400 
num_instructions_leaf:
    .data -1   
leaf_addr_high:
    .data 0   
leaf_addr_low:
    .data 10000   
AND_MASK:
    .data 0x7FFFFFFF
