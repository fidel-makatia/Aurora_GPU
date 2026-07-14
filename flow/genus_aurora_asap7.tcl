# =============================================================================
# AURORA GPU - Genus synthesis on ASAP7 (per-chiplet, matching SenseEdge flow)
# Usage: genus -batch -files genus_aurora_asap7.tcl
#   set TOP to compute_chiplet (the volume die) or io_chiplet (hub die),
#   or aurora_top_2p5d for the monolithic reference.
# Reuses the ASAP7 CCS .lib setup from the senseedge_asap7 workdir.
# =============================================================================
set TOP   compute_chiplet
set W     /work/aurora_gpu
set ASAP7 /work/asap7_ccs/libs

set_db init_lib_search_path [list $ASAP7/lib]
# RVT TT libs (same set the SenseEdge SoC closed 1 GHz with)
set_db library [list \
  asap7sc7p5t_AO_RVT_TT_nldm_211120.lib \
  asap7sc7p5t_INVBUF_RVT_TT_nldm_220122.lib \
  asap7sc7p5t_OA_RVT_TT_nldm_211120.lib \
  asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib \
  asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120.lib ]

read_hdl -define SYNTHESIS [list \
  $W/rtl/warp_sched.v $W/rtl/simd_alu.v $W/rtl/regfile.v $W/rtl/sm_core.v \
  $W/rtl/l2_slice.v $W/rtl/d2d_link.v $W/rtl/compute_chiplet.v \
  $W/rtl/io_chiplet.v $W/rtl/aurora_top_2p5d.v ]
elaborate $TOP
current_design $TOP

# 1 GHz target, same as SenseEdge ASAP7 closure
create_clock -name clk -period 1.0 [get_ports clk]
set_input_delay  0.2 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 0.2 -clock clk [all_outputs]

syn_generic
syn_map
syn_opt

file mkdir $W/syn_$TOP
write_hdl > $W/syn_$TOP/${TOP}_netlist.v
write_sdc > $W/syn_$TOP/${TOP}.sdc
report_area   > $W/syn_$TOP/area.rpt
report_gates  > $W/syn_$TOP/gates.rpt
report_timing > $W/syn_$TOP/timing.rpt
report_power  > $W/syn_$TOP/power.rpt
puts "AURORA_GENUS_DONE ${TOP}"
exit
