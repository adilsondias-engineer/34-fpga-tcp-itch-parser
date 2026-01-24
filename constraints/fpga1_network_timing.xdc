# ==============================================================================
# Timing Constraints for FPGA1 Network Ingress (TCP ITCH Parser)
# Target: ALINX AX7325B (Kintex-7 XC7K325T-2FFG900)
#
# Updated to match Project 33 Build 8 working MMCM clock architecture
# ==============================================================================

# ==============================================================================
# Primary Clocks
# ==============================================================================

# System clock (200 MHz) - already defined in pins.xdc via create_clock
# create_clock -period 5.000 -name sys_clk [get_ports sys_clk_p]

# SFP+ Reference Clock (156.25 MHz)
create_clock -period 6.400 -name sfp_refclk [get_ports sfp_refclk_p]

# ==============================================================================
# GTX / MMCM Generated Clocks
# ==============================================================================

# TXOUTCLK (322.27 MHz) is auto-derived by Vivado from the GT primitive.
# The MMCM outputs (tx_usrclk @ 322.27 MHz, tx_usrclk2 @ 161.13 MHz) are
# auto-propagated by Vivado through the MMCME2_BASE. No manual create_clock
# needed for these — Vivado derives them from the refclk -> QPLL -> TXOUTCLK chain.

# ==============================================================================
# Clock Domain Crossings
# ==============================================================================

# System clock (200 MHz) is asynchronous to GT/MMCM-generated clocks
set_clock_groups -asynchronous -quiet \
    -group [get_clocks -of_objects [get_pins -quiet sfp_gtx_inst/tx_usrclk_bufg/O]] \
    -group [get_clocks -of_objects [get_pins -quiet sfp_gtx_inst/tx_usrclk2_bufg/O]] \
    -group [get_clocks sys_clk]

# Reference clock to MMCM-generated clocks
# (refclk feeds QPLL which feeds TXOUTCLK which feeds MMCM - related but
#  treated as async for CDC paths through reset synchronizers)
set_clock_groups -asynchronous -quiet \
    -group [get_clocks sfp_refclk] \
    -group [get_clocks -of_objects [get_pins -quiet sfp_gtx_inst/tx_usrclk2_bufg/O]]

# ==============================================================================
# False Paths
# ==============================================================================

# Reset is asynchronous
set_false_path -from [get_ports sys_rst_n]

# Status outputs are slow/diagnostic
set_false_path -to [get_ports led_*]
set_false_path -to [get_ports sfp_tx_disable]
set_false_path -to [get_ports uart_tx]
