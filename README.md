# AURORA — Chiplet SIMT GPU on ASAP7 (2.5D)

Flagship-**architecture** GPU, instance-scaled for academic ASAP7 implementation.
All scale knobs in `rtl/aurora_pkg.vh` — the default build is 1 hub + 4 compute
chiplets × 4 SMs × 8 warps × 32 lanes = **512 SIMT lanes, 4096 resident threads**.
Raising `NUM_CCHIP/SMS_PER_CHIP/WARPS` scales toward flagship instance counts
without RTL changes.

```
              ┌─────────────────────── interposer (2.5D, F2F ubumps) ──┐
              │  ┌─────────┐   ┌─────────┐   ┌─────────┐  ┌─────────┐  │
              │  │ compute │   │ compute │   │ compute │  │ compute │  │
              │  │ chiplet0│   │ chiplet1│   │ chiplet2│  │ chiplet3│  │
              │  │ 4×SM    │   │ 4×SM    │   │ 4×SM    │  │ 4×SM    │  │
              │  │ L2 slice│   │ L2 slice│   │ L2 slice│  │ L2 slice│  │
              │  └───┬─────┘   └───┬─────┘   └────┬────┘  └────┬────┘  │
              │      │ D2D 16b/dir serdes-lite (5-beat req/2-beat rsp) │
              │  ┌───┴───────────┴──────────────┴────────────┴─────┐  │
              │  │        IO/hub chiplet: WB host, command         │  │
              │  │   processor, global memory controller (HBM      │  │
              │  │   PHY boundary = gmem bank in this build)       │  │
              │  └──────────────────────────────────────────────────┘ │
              └────────────────────────────────────────────────────────┘
```

## SM microarchitecture
- 3-stage warp pipeline (ISSUE → EX → WB), round-robin warp scheduler
- 8 resident warps × 32 lanes; per-warp PC + active mask (SETP folds predicate
  into the mask; BRA is uniform any-active)
- 32×32b regs/thread, banked flop RF with SRAM-macro drop-in boundary
- 4 KB shared memory + block barrier (`BAR`)
- LSU serialises per-lane global accesses through the chiplet L2 slice
  (latency hidden by warp switching — the whole point of SIMT)
- 20-op ISA: `MOVI ADD SUB MUL MAD AND OR XOR SHL SHR LDG STG LDS STS SETP BRA
  TID BAR EXIT`

## Memory system
- L2 slice per compute chiplet: SM round-robin arbiter, local scratch bank,
  remote window (bit31) forwarded over D2D
- Hub memory controller: round-robin over 4 D2D endpoints → gmem bank
  (replace with HBM controller/PHY IP for silicon)

## Physical (matches the SenseEdge ASAP7 chiplet methodology)
- Each chiplet = separate Genus+Innovus block; D2D pins → F2F ubump arrays
- `flow/genus_aurora_asap7.tcl` — per-chiplet synthesis @ 1 GHz RVT TT
- Same interposer/F2F flow as the SenseEdge chiplet study (Innovus + QRC)

## Verify
`tb/tb_aurora_smoke.v`: host uploads a vector-add kernel via Wishbone,
launches 2 warps/SM on all 16 SMs, polls idle, checks `c[i]=a[i]+b[i]`
through the full SM→L2→D2D→hub round-trip. Prints `AURORA_SMOKE_PASS`.

## Honest scaling notes
- FP32 units are the next datapath drop-in (`simd_alu.v` lane slot); current
  lanes are INT32+MAD which is sufficient for PPA-accurate area/timing studies
- gmem/RF/smem are flop arrays with macro-boundary interfaces — SRAM/HBM
  swap in without RTL surgery
- No texture/raster/tensor pipes: this is the compute (GPGPU) slice of a
  flagship, which dominates die area anyway
