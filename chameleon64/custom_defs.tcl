# Area settings copied from the MiST C64 project (C64_mist.qsf).
set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_RETIMING OFF
set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION OFF
set_global_assignment -name PHYSICAL_SYNTHESIS_ASYNCHRONOUS_SIGNAL_PIPELINING OFF
set_global_assignment -name PHYSICAL_SYNTHESIS_COMBO_LOGIC_FOR_AREA ON
set_global_assignment -name PHYSICAL_SYNTHESIS_MAP_LOGIC_TO_MEMORY_FOR_AREA ON
set_global_assignment -name AUTO_SHIFT_REGISTER_RECOGNITION OFF
set_global_assignment -name ALLOW_ANY_RAM_SIZE_FOR_RECOGNITION ON
set_global_assignment -name ALLOW_ANY_ROM_SIZE_FOR_RECOGNITION ON
set_global_assignment -name DSP_BLOCK_BALANCING "DSP BLOCKS"
set_global_assignment -name FITTER_EFFORT "AUTO FIT"
set_global_assignment -name ON_CHIP_BITSTREAM_DECOMPRESSION ON
# Keep the CPLD mux outputs in I/O registers (placement-independent pin timing)
set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to mux[*]
set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to mux_clk
