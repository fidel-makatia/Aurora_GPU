# ============================================================================
# AURORA command-processor firmware: the GPU driver, on-die.
#   1. write a[i]=i, b[i]=1000+i, c[i]=0 into gmem (64 words each)
#   2. upload the vector-add SIMT kernel to every SM (broadcast window)
#   3. launch 2 warps/SM, poll all-idle
#   4. verify c[i] = a[i] + b[i]; report 0x600D0000 | errors to result mmio
# CPU map: gmem @ 0x1000_0000, imem @ 0x4000_3000 (broadcast), ctrl @
# 0x8000_0000, result mmio @ 0xF000_0000. Assemble with tools/rvasm.py.
# ============================================================================
_start:
  li   a0, 0x10000000      # gmem window
  li   t0, 0
  li   t1, 64
  li   t2, 1000
init:
  slli t3, t0, 2
  add  t4, a0, t3
  sw   t0, 0(t4)           # a[i] = i
  add  t5, t0, t2
  sw   t5, 0x100(t4)       # b[i] = 1000 + i
  sw   zero, 0x200(t4)     # c[i] = 0
  addi t0, t0, 1
  blt  t0, t1, init

  la   a1, ktab            # upload kernel (14 words, broadcast to all SMs)
  li   a2, 0x40003000
  li   t0, 0
  li   t1, 14
upload:
  slli t3, t0, 2
  add  t4, a1, t3
  lw   t5, 0(t4)
  add  t6, a2, t3
  sw   t5, 0(t6)
  addi t0, t0, 1
  blt  t0, t1, upload

  li   a3, 0x80000000      # launch 2 warps / SM
  li   t0, 2
  sw   t0, 0(a3)

  li   t5, 200             # let the launch propagate before polling
dly:
  addi t5, t5, -1
  bne  t5, zero, dly

poll:
  lw   t0, 4(a3)
  andi t0, t0, 1
  beq  t0, zero, poll

  li   t0, 0               # verify
  li   t1, 64
  li   s0, 0               # error count
check:
  slli t3, t0, 2
  add  t4, a0, t3
  lw   t5, 0x200(t4)
  add  t6, t0, t2
  add  t6, t6, t0          # expected = 1000 + 2*i
  beq  t5, t6, ok
  addi s0, s0, 1
ok:
  addi t0, t0, 1
  blt  t0, t1, check

  li   a4, 0xF0000000      # result mmio: 0x600D0000 | errors
  li   t6, 0x600D0000
  add  t6, t6, s0
  sw   t6, 0(a4)
hang:
  j hang

ktab:
  .word 0x88400000
  .word 0x094000ff
  .word 0x30425000
  .word 0x09800002
  .word 0x49c26000
  .word 0x0a000001
  .word 0x0a40001f
  .word 0x4a109000
  .word 0x11ce8000
  .word 0x588e0000
  .word 0x58ce0100
  .word 0x11043000
  .word 0x600e4200
  .word 0x98000000
