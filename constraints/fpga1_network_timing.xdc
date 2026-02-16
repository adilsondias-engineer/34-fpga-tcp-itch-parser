# ==============================================================================
# Timing Constraints for FPGA1 Network Ingress (TCP ITCH Parser)
# Target: ALINX AX7325B (Kintex-7 XC7K325T-2FFG900)
#
# Updated to match Project 33 Build 8 working MMCM clock architecture
# ==============================================================================

# ==============================================================================
# Primary Clocks
# ==============================================================================

# System clock (200 MHz) 
create_clock -period 5.000 -name sys_clk [get_ports sys_clk_p]

# SFP+ Reference Clock (156.25 MHz)
create_clock -period 6.400 -name sfp_refclk [get_ports sfp_refclk_p]

# ==============================================================================
# GTX TXOUTCLK
# ==============================================================================

# GTX TXOUTCLK: 322.27 MHz (10.3125 Gbps / 32)
# Must be explicitly constrained because GTXE2_CHANNEL is manually instantiated.
# Vivado cannot trace through the analog QPLL to auto-discover this clock.
# MMCM output clocks (tx_usrclk @ 322.27 MHz, tx_usrclk2 @ 161.13 MHz) are
# auto-derived by Vivado from this primary clock.
create_clock -period 3.103 -name gtx_txoutclk [get_pins sfp_gtx_inst/gtxe2_channel_inst/TXOUTCLK]

# ==============================================================================
# Clock Domain Crossings
# ==============================================================================

# All three clock domains are asynchronous to each other:
#   sys_clk (200 MHz) - board oscillator (defined in pins.xdc)
#   sfp_refclk (156.25 MHz) - SFP+ reference (QPLL input only)
#   gtx_txoutclk (322.27 MHz) + MMCM-derived clocks (tx_usrclk, tx_usrclk2)
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk] \
    -group [get_clocks -include_generated_clocks sfp_refclk] \
    -group [get_clocks -include_generated_clocks gtx_txoutclk]

# ==============================================================================
# False Paths
# ==============================================================================

# Reset is asynchronous
set_false_path -from [get_ports sys_rst_n]
# Status outputs are slow/diagnostic
set_false_path -to [get_ports led_*]
set_false_path -to [get_ports sfp_tx_disable]
set_false_path -to [get_ports uart_tx]

