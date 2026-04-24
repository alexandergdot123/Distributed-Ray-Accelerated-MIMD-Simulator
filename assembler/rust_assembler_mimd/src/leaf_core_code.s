.org IDK //TODO

    lw r2, ROOT_NODE_ID

triangle_intersect:
    #void Triangle_Intersect(Triangle *tri, Ray *ray, Vertex *vertices)
    # tri in r14, ray is in r0, verticies needs to be found
    lw r13, VERTEX_ARRAY_BASE                   # r13 = Vertex * vertices



    



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
LOCAL_RAY_QUEUE:        .data 0
LOCAL_RAY_QUEUE_HEAD:   .data 0
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
REGISTER_SPILL_1: .data(32) 0
REGISTER_SPILL_2: .data(32) 0
REGISTER_SPILL_3: .data(32) 0
REGISTER_SPILL_4: .data(32) 0
//DO NOT INCLUDE LINES BELOW THIS AS PULLED FROM DRAM
RAY_ARRAY: .data(256) 0
LEAF_CORE_LOOKUP_TABLE: .data(64) 0
SENDER_RAY_QUEUE: .data(1036) 0
RECEIVER_RAY_QUEUE: .data(1036) 0
DFS_STACK: .data(256) 0
