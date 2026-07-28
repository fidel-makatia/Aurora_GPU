<div align="center">

# ⚡ AURORA

### A chiplet SIMT GPU, built end-to-end in the open — RTL → synthesis → 2.5D/3D physical design

[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![RTL](https://img.shields.io/badge/RTL-Verilog--2001-orange.svg)](rtl/)
[![PDK](https://img.shields.io/badge/PDK-ASAP7%20(open)-purple.svg)](https://asap.asu.edu/)
[![timing](https://img.shields.io/badge/sm__core%20v2-1.0%20GHz%20MET-brightgreen.svg)](#-synthesis-results-asap7-genus)
[![threads](https://img.shields.io/badge/SIMT-512%20lanes%20%2F%204096%20threads-blue.svg)](rtl/aurora_pkg.vh)
[![host](https://img.shields.io/badge/host%20CPU-RV32IM%20on--die-gold.svg)](rtl/riscv_core.v)

*Flagship architecture, academic scale: every count is a knob in one header.*

[Architecture](#-architecture) •
[ISA](#-isa-20-ops-32-bit) •
[Results](#-synthesis-results-asap7-genus) •
[D2D study](#-die-to-die-interconnect-ansys-q3d-field-solved) •
[vs Flagships](#-how-it-compares-to-flagship-gpus) •
[Build & run](#-build--run)

</div>

---

Aurora is a **complete GPU SoC partitioned into chiplets**: 4 compute
chiplets (4 SMs each) around an IO/hub die that carries an **on-die RV32IM
host CPU** — Aurora boots from its own firmware, uploads kernels, launches,
and verifies results with no external host. Integration is 2.5D (interposer
RDL) with a field-solved **3D face-to-face hybrid-bond** option. The default
build is
**512 SIMT lanes / 4,096 resident threads**; every scale knob
(`NUM_CCHIP`, `SMS_PER_CHIP`, `WARPS`, `LANES`) lives in
[`rtl/aurora_pkg.vh`](rtl/aurora_pkg.vh) — a flagship-instance build is a
header edit, not an RTL rewrite.

Everything here is reproducible on open technology: ASAP7 predictive PDK,
plain Verilog-2001, one Genus script.

## 🏗 Architecture

### System — 4 + 1 chiplets on an interposer

```
        ┌────────────────────── interposer (2.5D RDL, or 3D F2F) ──────────┐
        │  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐       │
        │  │ compute0 │   │ compute1 │   │ compute2 │   │ compute3 │       │
        │  │  4 × SM  │   │  4 × SM  │   │  4 × SM  │   │  4 × SM  │       │
        │  │ L2 slice │   │ L2 slice │   │ L2 slice │   │ L2 slice │       │
        │  └────┬─────┘   └────┬─────┘   └────┬─────┘   └────┬─────┘       │
        │       │    D2D link: 64b payload, 4:1 serialized,  │             │
        │       │    16b/dir (5-beat request / 2-beat resp)  │             │
        │  ┌────┴──────────────┴───────────────┴─────────────┴──────────┐  │
        │  │  IO/hub chiplet                                             │  │
        │  │  ┌──────────────────┐  ┌───────────────────────────────┐   │  │
        │  │  │ RV32IM host CPU  │  │ command processor registers   │   │  │
        │  │  │ + 16 KB boot RAM │──│ (kernel upload · launch ·     │   │  │
        │  │  │ (the GPU driver, │  │  idle status)                 │   │  │
        │  │  │  on-die)         │  └───────────────────────────────┘   │  │
        │  │  └──────────────────┘  global memory controller (HBM PHY  │  │
        │  │  Wishbone debug port    boundary = gmem bank)              │  │
        │  └────────────────────────────────────────────────────────────┘  │
        └──────────────────────────────────────────────────────────────────┘
```

**Memory system — HBM3**: one L2 slice per compute chiplet (SM round-robin
arbiter, local scratch bank, remote window forwarded over D2D); the hub
round-robins the 4 D2D endpoints plus the host window into an **HBM3
pseudo-channel controller** ([`rtl/hbm_ctrl.v`](rtl/hbm_ctrl.v)) — real,
synthesizable bank-state logic: 16 word-interleaved banks, per-bank open-row
tracking, open-page policy, HBM3-class timing (tRCD/tRP/tCL = 14 controller
cycles @ 1 GHz, BL8 bursts). The PHY ([`rtl/hbm3_phy.v`](rtl/hbm3_phy.v)) is
a hard-IP boundary: behavioral in simulation, interface-only for synthesis,
with area/energy carried as declared literature bounds (an HBM PHY is vendor
IP, and pretending otherwise would corrupt the PPA story). One pseudo-channel
(64b DQ @ 6.4 Gbps = **51.2 GB/s**) matches Aurora's serialized demand
(~16 SMs × 4 B/cycle ≈ 64 GB/s worst case); scaling to a full stack's 16
pseudo-channels is gated on L2 coalescing (roadmap). LSU latency is hidden by
warp switching, which is the whole point of SIMT.

Declared capacity caveat: the behavioral store behind the PHY is 64 KB — a
capacity-model boundary. Bank/row *behavior* is modeled from the full
address, so access timing is HBM-shaped even though the store wraps. Note
also that Aurora is architecturally a 32-bit machine end-to-end (GPU lane
addresses and the RV32 host are both 32-bit), so ≤4 GB is addressable by
design — one pseudo-channel's worth, consistently.

### SM core — 3-stage SIMT pipeline (v2, SRAM register file)

```
                 ┌────────────────────────────────────────────────────┐
                 │                     sm_core                        │
   8 warps       │  ┌───────────┐   ┌─────────┐   ┌───────────────┐  │
   round-robin ─▶│  │  ISSUE    ├──▶│   EX    ├──▶│      WB       │  │
   per-warp PC   │  │ imem read │   │ 32-lane │   │ lane-merge    │  │
   + active mask │  │ RF sync   │   │ SIMD ALU│   │ (mask?new:old)│  │
                 │  │ read      │   │ MAD/SHF │   │ RF write      │  │
                 │  └─────┬─────┘   └────┬────┘   └───────┬───────┘  │
                 │        │              │                │          │
                 │  ┌─────┴──────────────┴────────────────┴───────┐  │
                 │  │ register file: 12 × 1R1W SRAM (272×256)     │  │
                 │  │ = 3 read copies (ra / rb / rd-old) × 4 banks│  │
                 │  │ issue-stage sync reads; 3-deep same-warp    │  │
                 │  │ interlock kills RAW hazards                 │  │
                 │  └─────────────────────────────────────────────┘  │
                 │  4 KB shared mem · LSU old-value latch · barrier  │
                 └────────────────────────────────────────────────────┘
```

- **Warp scheduler**: round-robin over 8 resident warps, per-warp PC and
  active mask; `SETP` folds per-lane predicates into the mask, `BRA` is a
  uniform any-active branch; `BAR` is an SM-wide block barrier.
- **32×32b registers/thread**, 4 KB shared memory per SM.
- **v1 → v2**: the v1 flop register file was 1.49M instances — 46% of the SM.
  v2 swaps it for banked 1R1W SRAM macros with issue-stage synchronous reads,
  a write-back lane-merge that replaces per-bit write masking, and a 3-deep
  same-warp interlock (which also fixed a latent v1 single-warp RAW hazard).
  Functionally verified: `AURORA_SMOKE_PASS`.
- The flop RF is retained at [`rtl/legacy/regfile_flops.v`](rtl/legacy/regfile_flops.v)
  for FPGA targets or macro-less flows.

### RV32 host CPU — the GPU driver, on-die

[`rtl/riscv_core.v`](rtl/riscv_core.v): RV32I + M-multiply (Zmmul),
multi-cycle (FETCH→EXEC→MEM→WB) — a command processor is latency-, not
throughput-critical, so the core stays tiny and closes 1 GHz trivially.
Firmware ([`fw/cmd_proc.S`](fw/cmd_proc.S), assembled by the self-contained
[`tools/rvasm.py`](tools/rvasm.py)) does what the external testbench host
used to do: write test vectors to gmem, upload the SIMT kernel to all 16 SMs,
launch, poll idle, **verify results on-die**, and report to a result mmio.
Verified end-to-end: `AURORA_RISCV_PASS` (self-boot, zero external bus
activity).

| CPU address | Region |
|---|---|
| `0x0000_0000` | 16 KB boot RAM (code + data) |
| `0x1000_0000` | global memory window |
| `0x4000_0000` | SM instruction upload (broadcast) |
| `0x8000_0000` | launch / idle status |
| `0xF000_0000` | result mmio |

The external Wishbone port remains as a bring-up/debug path (firmware load at
`0xC000_0000`, full v1 host map preserved); a `cpu_en` strap selects
self-boot vs external-host mode. Unimplemented by design: DIV/REM, CSRs,
interrupts (roadmap).

**Why RV32 and not RV64?** Because nothing in the machine is 64-bit: the
command registers, the GPU's kernel words, the SIMT lane data, and the lane
*addresses* are all 32-bit — the GPU ISA itself can only form 32-bit
addresses, so the whole SoC is a 4 GB machine end-to-end. RV64 would double
the datapath, register file, and adder/mul width of a core whose job is to
poke registers and poll a status bit, and buy zero reach until the *GPU*
ISA goes 64-bit too. (Industry does the same: GPU management/command cores
are routinely 32-bit even on chips with RV64 application cores.) The day
Aurora wants >4 GB HBM visible or an MMU-backed driver stack, RV64 + a
64-bit LDG/STG format is one coherent upgrade — tracked on the roadmap.

## 📜 ISA (20 ops, 32-bit)

`[31:27] opcode | [26:22] rd | [21:17] ra | [16:12] rb | [11:0] simm12`

| Class | Ops |
|---|---|
| ALU | `ADD SUB MUL MAD AND OR XOR SHL SHR MOVI` |
| Memory | `LDG STG` (global, per-lane address) · `LDS STS` (4 KB shared) |
| Control | `SETP` (predicate→mask) · `BRA` (uniform) · `BAR` (SM barrier) · `EXIT` |
| Special | `TID` (global thread id: chip‹‹14 \| sm‹‹11 \| warp‹‹5 \| lane) · `NOP` |

## 📊 Synthesis results (ASAP7, Genus)

### sm_core: v1 (flop RF) vs v2 (SRAM RF) — 1 GHz target, TT corner

| Metric | v1 | **v2** | Δ |
|---|---|---|---|
| Leaf cells | 3,637,886 | **2,102,408** | **−42%** |
| Area | 0.365 mm² | **0.229 mm²** (incl. 12 SRAM macros, 0.035 mm²) | **−37%** |
| Worst slack @ 1 GHz | −65 ps (Fmax ≈ 940 MHz) | **0 ps — MET, 1.0 GHz** | closes timing |
| Power @ 1 GHz | 0.882 W (≈50% in the flop RF) | **0.229 W** * | −74% * |
| Critical path | `ex_ir_reg → SIMD ALU → wb_data_reg[383]` (996 ps) | balanced | — |

\* v2 macro power comes from a fakeram-derived liberty (crude model): the
logic split is reliable, the macro contribution approximate. Either way the
removed 1.49M-instance flop RF dominates the delta.

### All blocks (v1 baseline)

| Block | Cells | Area | Timing | Power |
|---|---|---|---|---|
| sm_core (1 SM) | 3,637,886 | 0.365 mm² | −65 ps → 940 MHz | 0.882 W |
| — register file | 1,486,744 | 0.168 mm² (46% of SM) | — | — |
| — SIMD ALU | 129,145 | 0.010 mm² | — | — |
| L2 slice + glue | 366,350 (131k DFF) | 0.059 mm² | **+82 ps MET** | 25.5 mW |
| io_chiplet (hub, v1: WB host only) | 2,996,200 | 0.477 mm² | **MET (0 ps wc)** | — |
| **io_chiplet (v3: +RV32 CPU +HBM ctrl)** | **771,146** | **0.120 mm²** | **MET (0 ps @ 1 GHz)** | 0.360 W * |

\* v3 hub is **4× smaller** than v1: the 524k-flop gmem bank became the HBM
PHY boundary, while *adding* the RV32 CPU (9,774 cells / 0.0011 mm²) and the
HBM controller (869 cells). Power is boot-RAM-flop dominated (93% internal);
the SRAM-macro boot RAM on the roadmap addresses it.

### Full-GPU rollup

| | |
|---|---|
| compute_chiplet (4×SM + L2) | ≈ 14.9M cells / 1.52 mm² |
| **Aurora total (4 compute + 1 hub)** | ≈ **62.6M cells / ~6.6 mm² logic / ~14 W** |
| Clock | 940 MHz (v1) → **1.0 GHz (v2)** |
| Peak throughput | 0.48 TOPS int32 (0.96 TOPS counting MAD as 2 ops) |

## 🔬 Die-to-die interconnect (Ansys Q3D, field-solved)

Raw capacitance matrices in [`docs/ansys/`](docs/ansys/). Energy = ½CV² at
0.7 V, wire/channel only (no PHY):

| Link | C_self | C_mutual | Crosstalk | **Energy/bit** |
|---|---|---|---|---|
| **3D F2F hybrid bond** (5 µm pad, 10 µm pitch) | 10.96 fF | 0.0001 fF | **0.001%** | **2.69 fJ** |
| 2.5D RDL, 200 µm | 15.54 fF | 4.01 fF | 25.8% | 3.81 fJ |
| 2.5D RDL, 500 µm | 38.50 fF | 9.98 fF | 25.9% | 9.43 fJ |
| 2.5D RDL, 1 mm | 75.92 fF | 18.76 fF | 24.7% | 18.6 fJ |
| 2.5D RDL, 2 mm | 149.11 fF | 36.25 fF | 24.3% | 36.5 fJ |

The 3D face-to-face option is **~7–14× lower energy** than same-package 2.5D
routing at practical reaches, with crosstalk four orders of magnitude lower —
field-solved evidence for why vertical integration wins the D2D game.

## 🥊 How it compares to flagship GPUs

Full analysis with caveats: [`docs/FLAGSHIP_COMPARISON.md`](docs/FLAGSHIP_COMPARISON.md).
Headline (v1 numbers, normalized — Aurora is ~2,500× smaller in absolute silicon):

| Metric | Aurora | H100 FP32 | Ratio |
|---|---|---|---|
| Throughput / area | 73 GOPS/mm² (146 w/ MAD) | 82 GFLOPS/mm² | **0.9–1.8×** |
| Throughput / power | 34 GOPS/W (69 w/ MAD) | 96 GFLOPS/W | 0.36–0.72× |

Declared caveats: predictive PDK, post-synthesis power, int32 ops vs IEEE
FP32, and no HBM subsystem in Aurora's budget. The v2 area gain (−37%)
improves the normalized ratios by ~1.6× before any P&R optimization.

## 🚀 Build & run

```bash
# Self-boot SoC test: RV32 firmware drives the GPU, no external host
python3 tools/rvasm.py fw/cmd_proc.S fw/cmd_proc.hex
xrun -sv -incdir rtl -define AURORA_SIM tb/tb_aurora_riscv.v rtl/*.v rtl/legacy/regfile_flops.v
# expect: FW_RESULT 600d0000 / AURORA_RISCV_PASS

# External-host smoke test (Wishbone testbench drives the same map)
xrun -sv -incdir rtl -define AURORA_SIM tb/tb_aurora_smoke.v rtl/*.v rtl/legacy/regfile_flops.v
# expect: AURORA_SMOKE_PASS

# Synthesis (Cadence Genus + ASAP7 CCS libs; edit the two paths at the top)
genus -batch -files flow/genus_aurora_asap7.tcl
```

The smoke test uploads a vector-add kernel over Wishbone, launches 2 warps/SM
on all 16 SMs, polls idle, and checks `c[i] = a[i] + b[i]` through the full
SM → L2 → D2D → hub round-trip.

`AURORA_SIM` selects the behavioral SRAM model in
[`rtl/sram_1r1w_272_256_asap7.v`](rtl/sram_1r1w_272_256_asap7.v); without it
the macro is a synthesis black box.

## 📦 Repository

```
rtl/
├── aurora_pkg.vh          every scale knob + the ISA encoding
├── riscv_core.v           RV32IM host CPU (multi-cycle, ~200 lines)
├── hbm_ctrl.v             HBM3 pseudo-channel controller (bank FSM, open-page)
├── hbm3_phy.v             PHY hard-IP boundary (behavioral sim / bb synth)
├── sm_core.v              3-stage SIMT SM (warp sched · issue · EX · WB)
├── simd_alu.v             32-lane int32 ALU (MAD, shifts, compares)
├── warp_sched.v           round-robin scheduler, per-warp PC/mask
├── regfile_sram.v         v2 RF: 3 read copies × 4 banks, 1R1W SRAMs
├── sram_1r1w_272_256_asap7.v  behavioral model / black box
├── l2_slice.v             per-chiplet L2 + request arbitration
├── d2d_link.v             64b payload, 4:1 serialized die-to-die link
├── compute_chiplet.v      4 × SM + L2 slice + D2D endpoint
├── io_chiplet.v           Wishbone host IF, command proc, gmem controller
├── aurora_top_2p5d.v      full 4+1 assembly
└── legacy/regfile_flops.v v1 flop RF (FPGA-friendly)
tb/tb_aurora_riscv.v       self-boot SoC test (firmware drives everything)
tb/tb_aurora_smoke.v       external-host smoke test (Wishbone map)
fw/cmd_proc.S              command-processor firmware (the on-die GPU driver)
tools/rvasm.py             self-contained two-pass RV32 assembler
flow/genus_aurora_asap7.tcl  synthesis recipe (CCS libs, ps units)
docs/FLAGSHIP_COMPARISON.md  normalized PPA vs H100/B200/MI300X
docs/ansys/                Q3D capacitance matrices + summary CSV
```

## 🗺 Roadmap

- [x] RTL + self-checking smoke test
- [x] Synthesis: all blocks, ASAP7 CCS (v1)
- [x] Ansys Q3D 2.5D-vs-3D D2D study
- [x] v2 SRAM register file — **1 GHz closed, −37% area**
- [x] **RV32IM host CPU on-die** — self-boot firmware verified (`AURORA_RISCV_PASS`)
- [x] **HBM3 pseudo-channel memory controller** — bank-state FSM, open-page
      policy, PHY as declared hard-IP boundary; both testbenches pass through it
- [x] hub v3 (CPU + HBM ctrl) synthesis — **1 GHz MET, 0.120 mm², 4× smaller than v1 hub**
- [x] Innovus P&R: io_chiplet die — **941×941 µm, GDS/LEF/SPEF out, hold clean,
      setup WNS −0.126 ns (≈888 MHz)**; v1 sm_core die timed out at 48 h
      fighting the flop RF → superseded by v2 (needs SRAM LEF)
- [ ] SRAM macro LEF → v2 P&R
- [ ] compute_chiplet assembly (4 SM macros + L2)
- [ ] 2.5D interposer + 3D F2F stacked layouts
- [ ] FP32 lane option; tensor-style MMA unit
- [ ] RV32: interrupts + CSRs; boot RAM → SRAM macro; multi-kernel scheduler firmware
- [ ] L2 memory coalescing → full HBM stack (16 pseudo-channels); FR-FCFS scheduling
- [ ] 64-bit path (RV64 + 64-bit LDG/STG) when >4 GB becomes reachable

## 📄 License

[MIT](LICENSE) © 2026 Fidel Makatia
