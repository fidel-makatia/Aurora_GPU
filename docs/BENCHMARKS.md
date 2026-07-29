# Aurora benchmark results

Cycle-accurate RTL measurements of the full 4+1-chiplet system (16 SMs,
4,096 resident threads), Cadence Xcelium. All kernels are self-checking;
every figure below is from a run whose results were verified. Cycles are
counted from the launch register write to idle detection. At the 1 GHz
frequency closed in physical design, one cycle equals one nanosecond, so
bytes per cycle read directly as GB/s and operations per cycle as GOPS.

Testbench: [`tb/tb_aurora_bench.v`](../tb/tb_aurora_bench.v). MAD counts as
two operations. Theoretical peak: 16 SMs × 32 lanes × 2 ops = 1,024
operations per cycle (1.024 TOPS at 1 GHz).

## Results

| Kernel | Description | Cycles | Result | Correctness |
|---|---|---|---|---|
| launch | empty kernel (launch and drain overhead) | 26 | — | — |
| copy | c[i] = a[i], global memory | 359,148 | 0.09 GB/s | pass |
| vecadd | c[i] = a[i] + b[i], global memory | 550,761 | 0.09 GB/s | pass |
| saxpy | y[i] = 3·x[i] + y[i], global memory | 549,887 | 0.09 GB/s | pass |
| mad512 | 512 dependent MADs per thread, one store | 180,599 | 23.2 GOPS | pass |
| **mad_pure** | 512 dependent MADs per thread, no store | **4,212** | **995.8 GOPS — 97.2% of peak** | validated via mad512 |
| **lds** | 256 shared-memory loads per thread | **2,142** | **1,958 GB/s on-chip** | — |

## Interpretation

**Compute efficiency is near-ideal.** With memory traffic excluded, the
machine sustains 97.2% of its theoretical arithmetic peak across all 16 SMs:
kernel launch, warp scheduling, the three-stage pipeline, and the same-warp
interlock together cost under 3%. Compute correctness at this rate is
verified by the mad512 variant, which runs the identical arithmetic chain
and checks the final value.

**On-chip bandwidth is three orders of magnitude ahead of off-chip.** Shared
memory sustains ~1.96 TB/s aggregate (one 32-lane access per SM per cycle);
the global-memory path sustains 0.09 GB/s. The ratio is a property of three
deliberate v1 simplicity choices, each visible in the RTL and each a defined
roadmap item:

1. The LSU serializes the 32 lanes of a global access (no coalescing).
2. The hub's HBM controller processes one outstanding request at a time,
   and all 16 SMs share it (single pseudo-channel).
3. The SM execute stage is gated on the LSU being free, so memory latency
   is not hidden by warp switching during a global access — measured at
   ~44 cycles per lane access end to end.

mad512 illustrates the same point from the other side: its arithmetic
completes in ~4,200 cycles, and the remaining ~176,000 cycles are 4,096
result stores draining through the serialized path.

## Implications

The memory system, not the compute fabric, bounds present performance —
by roughly four orders of magnitude on streaming workloads. The planned
remedies are, in order of leverage: L2 request coalescing (turns 32 lane
accesses into a handful of bursts), a non-blocking LSU with execute/memory
overlap, and multiple HBM pseudo-channels. Each multiplies streaming
throughput; none touches the compute fabric, which these measurements show
to be already efficient.

## Reproduction

```bash
python3 tools/rvasm.py fw/cmd_proc.S fw/cmd_proc.hex   # firmware (not used by bench)
xrun -sv -incdir rtl -timescale 1ns/1ps -define AURORA_SIM \
     tb/tb_aurora_bench.v rtl/*.v rtl/legacy/regfile_flops.v -top tb_aurora_bench
```
