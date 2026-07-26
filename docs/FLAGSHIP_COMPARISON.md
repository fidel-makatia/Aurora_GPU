# Aurora vs. flagship GPUs — positioning for publication

## Scale context (absolute numbers, honesty first)

| | **Aurora (this work)** | NVIDIA H100 (SXM) | NVIDIA B200 | AMD MI300X |
|---|---|---|---|---|
| Process | ASAP7 (7nm **predictive/academic**) | TSMC 4N | TSMC 4NP (dual-die) | 5nm+6nm chiplets |
| Transistors | ~0.3B (62.6M cells est. ×5) | 80B | 208B | 153B |
| Logic area | **6.6 mm²** (5 chiplets) | 814 mm² | ~2×800 mm² | 1017 mm² total |
| Parallel lanes | 512 (4,096 threads) | 16,896 FP32 cores | ~2× H100 class | 304 CU (19,456 lanes) |
| Clock | 0.94 GHz (post-syn TT) | ~1.98 GHz boost | ~1.8+ GHz | 2.1 GHz |
| Power | ~14 W (synthesis est.) | 700 W | 1,000 W | 750 W |
| Peak throughput | 0.48 TOPS (1 op/lane/cyc; 0.96 if FMA) | 67 TFLOPS FP32 | 9,000 TFLOPS dense FP8 | 163 TFLOPS FP32 |
| Integration | 2.5D interposer + **3D F2F option** | monolithic | 2-die NV-HBI (10 TB/s) | 2.5D+3D hybrid (8 XCD + 4 IOD) |

Aurora is ~2,500× smaller than a flagship in silicon — the meaningful comparison is **normalized** and **architectural**:

## Normalized efficiency (the fair fight)

| Metric | Aurora | H100 FP32 | ratio |
|---|---|---|---|
| Throughput / area | 73 GOPS/mm² (146 if FMA) | 82 GFLOPS/mm² | **0.9–1.8×** of H100 |
| Throughput / power | 34 GOPS/W (69 if FMA) | 96 GFLOPS/W | 0.36–0.72× of H100 |
| Threads / mm² | 620 | 25 (SM-thread capacity ~253k/814) | — |

At synthesis stage on a predictive PDK, an academic 20-op SIMT core lands **within ~1–2× of H100-class area efficiency** and within ~1.4–3× of its power efficiency — before any P&R optimization, clock gating tuning, or the FP-vs-int caveat below.

## Die-to-die interconnect (the headline)

| Link technology | Energy/bit | Crosstalk | Note |
|---|---|---|---|
| **Aurora 3D F2F hybrid bond (this work)** | **2.69 fJ/bit** (wire-limited, Q3D field-solved) | 0.001% | 10 µm pitch |
| **Aurora 2.5D RDL 1 mm (this work)** | 18.6 fJ/bit (wire-limited) | ~25% | 73 fF/mm |
| UCIe advanced package (spec class) | ~250–500 fJ/bit (full PHY) | — | industry standard |
| NVLink-C2C (Grace-Hopper class) | ~1,300 fJ/bit (full PHY) | — | organic substrate |
| B200 NV-HBI | 10 TB/s aggregate (energy N/A public) | — | dual-die bridge |

**Apples-to-apples caveat (state in the paper):** our fJ/bit figures are the field-solved *wire/channel* energy only; published UCIe/NVLink numbers include the full PHY (driver, clocking, SerDes). Even granting a generous 10–20 fJ/bit PHY overhead for the F2F case (near-zero channel needs no SerDes at 10 µm reach), hybrid-bond 3D retains **an order of magnitude** under 2.5D standards — consistent with why the industry (MI300's 3D V-Cache lineage, HBM stacking) is moving vertical.

## Caveats to declare
1. ASAP7 is a predictive academic PDK — no silicon calibration.
2. Power/PPA are post-synthesis (Genus, default switching activity); post-route numbers pending (Innovus jobs in flight).
3. Aurora lanes are 32-bit integer SIMT (20-op ISA), not IEEE FP32 — throughput comparisons are ops-vs-FLOPs.
4. No memory subsystem (HBM PHY/controllers) in Aurora's area/power; flagships carry it on-die/package.
