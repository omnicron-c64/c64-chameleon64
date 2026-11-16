# C64 guest timing constraints for Turbo Chameleon V1.
# Adapted from the MiST C64 project's C64_mist.sdc; loaded after the
# DeMiSTify board constraints (which create clk8, the host PLL clocks and spiclk).

set c64pll  {guest|c64_mist|pll|altpll_component|auto_generated|pll1}
set drvpll  {guest|c64_mist|pll_2|altpll_component|auto_generated|pll1}
set hostpll {clocks|altpll_component|auto_generated|pll1}

# Controller (host PLL + SPI), C64 (31.5/63 MHz) and 1541 (32 MHz) are
# unrelated clock domains; every crossing between them is synchronised.
set_clock_groups -asynchronous \
	-group [get_clocks [list clk8 spiclk spiclkfast "${hostpll}|clk[*]"]] \
	-group [get_clocks "${c64pll}|clk[*]"] \
	-group [get_clocks "${drvpll}|clk[0]"]

# SDRAM: SDRAM_CLK is c64 PLL clk[0], the controller runs on clk[2] (same 63 MHz).
set ram_out [get_ports {ram_data[*] ram_addr[*] ram_ba_* ram_ras_n ram_cas_n ram_we_n ram_ldqm ram_udqm}]
set_input_delay  -clock [get_clocks "${c64pll}|clk[0]"] -reference_pin [get_ports {ram_clk}] -max 6.4 [get_ports {ram_data[*]}]
set_input_delay  -clock [get_clocks "${c64pll}|clk[0]"] -reference_pin [get_ports {ram_clk}] -min 3.2 [get_ports {ram_data[*]}]
set_output_delay -clock [get_clocks "${c64pll}|clk[0]"] -reference_pin [get_ports {ram_clk}] -max 1.5 $ram_out
set_output_delay -clock [get_clocks "${c64pll}|clk[0]"] -reference_pin [get_ports {ram_clk}] -min -0.8 $ram_out
set_multicycle_path -from [get_clocks "${c64pll}|clk[0]"] -to [get_clocks "${c64pll}|clk[2]"] -setup 2
set_multicycle_path -from [get_clocks "${c64pll}|clk[0]"] -to [get_clocks "${c64pll}|clk[2]"] -hold 2

# VGA: signals only need to arrive together.
set_multicycle_path -to [get_ports {red[*] grn[*] blu[*] hsync_n vsync_n}] -setup 2
set_multicycle_path -to [get_ports {red[*] grn[*] blu[*] hsync_n vsync_n}] -hold 1

# Audio is a 1-bit sigma-delta stream.
set_false_path -to [get_ports {sigma_l sigma_r}]
