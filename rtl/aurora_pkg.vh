// ============================================================================
// AURORA GPU - global parameters & ISA encoding
// Flagship-architecture SIMT GPU, chiplet-partitioned for ASAP7 2.5D.
// All scale knobs live here: a "flagship" build raises NUM_CHIPLETS/SMS/WARPS.
// ============================================================================
`ifndef AURORA_PKG_VH
`define AURORA_PKG_VH

// ---------------- scale knobs ----------------
`define LANES        32          // SIMD width (threads/warp)
`define WARPS         8          // resident warps / SM
`define SMS_PER_CHIP  4          // SMs per compute chiplet
`define NUM_CCHIP     4          // compute chiplets
`define NUM_REGS     32          // architectural regs / thread
`define SMEM_KB       4          // shared memory per SM (KB)
`define IMEM_WORDS  1024         // kernel instruction store / SM
`define D2D_W        64          // die-to-die parallel payload bits (4:1 serialized)

// ---------------- derived ----------------
`define LANE_W       32          // datapath width
`define WARP_ID_W     3          // log2(WARPS)
`define REG_AW        5          // log2(NUM_REGS)
`define SMEM_AW      10          // log2(SMEM_KB*1024/4)

// ---------------- ISA: 32-bit instruction ----------------
// [31:27] opcode | [26:22] rd | [21:17] ra | [16:12] rb | [11:0] imm12 (signed)
`define OP_NOP   5'd0
`define OP_MOVI  5'd1   // rd = simm12 (sign-extended)
`define OP_ADD   5'd2   // rd = ra + rb
`define OP_SUB   5'd3
`define OP_MUL   5'd4   // rd = ra * rb (lo 32)
`define OP_MAD   5'd5   // rd = ra * rb + rd
`define OP_AND   5'd6
`define OP_OR    5'd7
`define OP_XOR   5'd8
`define OP_SHL   5'd9
`define OP_SHR   5'd10
`define OP_LDG   5'd11  // rd = GMEM[ra + simm12]   (per-lane address)
`define OP_STG   5'd12  // GMEM[ra + simm12] = rb
`define OP_LDS   5'd13  // rd = SMEM[ra + simm12]
`define OP_STS   5'd14  // SMEM[ra + simm12] = rb
`define OP_SETP  5'd15  // pred = (ra < rb) per-lane -> active-mask AND
`define OP_BRA   5'd16  // pc = pc + simm12 if any-active (uniform branch)
`define OP_TID   5'd17  // rd = global thread id (chip<<14|sm<<11|warp<<5|lane)
`define OP_BAR   5'd18  // block barrier (all warps in SM)
`define OP_EXIT  5'd19  // warp done

`endif
