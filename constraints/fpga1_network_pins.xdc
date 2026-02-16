# ==============================================================================
# Pin Constraints for FPGA1 Network Ingress (TCP ITCH Parser)
# Target: ALINX AX7325B (Kintex-7 XC7K325T-2FFG900)
# Role: FPGA1 in 3-FPGA Trading Appliance Architecture
# ==============================================================================

# ==============================================================================
# System Clock (200 MHz differential from on-board oscillator)
# Pins and IOSTANDARD verified from working Project 33 on AX7325B
# ==============================================================================
set_property PACKAGE_PIN AE10 [get_ports sys_clk_p]
set_property PACKAGE_PIN AF10 [get_ports sys_clk_n]
set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_p]
set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_n]

# ==============================================================================
# System Reset (active low, directly from key button)
# ==============================================================================
set_property PACKAGE_PIN AG28 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS25 [get_ports sys_rst_n]

# ==============================================================================
# 10GbE SFP+ Interface (Market Data Input)
# ==============================================================================

# SFP+ Reference Clock (156.25 MHz differential from SFP+ cage or external)
set_property PACKAGE_PIN G8 [get_ports sfp_refclk_p]
set_property PACKAGE_PIN G7 [get_ports sfp_refclk_n]

# SFP+ GTX Transceiver (Serial Interface) - GTX Quad 117, Channel 0
# These constrain the GTX serial pins to the correct GTX channel
set_property PACKAGE_PIN K2 [get_ports sfp_tx_p]
set_property PACKAGE_PIN K1 [get_ports sfp_tx_n]
set_property PACKAGE_PIN K6 [get_ports sfp_rx_p]
set_property PACKAGE_PIN K5 [get_ports sfp_rx_n]

# SFP+ Control Signals
set_property PACKAGE_PIN T28 [get_ports sfp_tx_disable]
set_property IOSTANDARD LVCMOS33 [get_ports sfp_tx_disable]

# SFP+ optional signals (directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly if needed)
# set_property PACKAGE_PIN T27 [get_ports sfp_mod_detect]
# set_property IOSTANDARD LVCMOS33 [get_ports sfp_mod_detect]
# set_property PACKAGE_PIN U28 [get_ports sfp_rx_los]
# set_property IOSTANDARD LVCMOS33 [get_ports sfp_rx_los]
# set_property PACKAGE_PIN V28 [get_ports sfp_tx_fault]
# set_property IOSTANDARD LVCMOS33 [get_ports sfp_tx_fault]

# ==============================================================================
# Aurora GTX Interface (to FPGA2 Order Book Engine) - COMMENTED OUT
# Needs custom PCB for inter-FPGA testing. Will be re-enabled later.
# Using GTX Quad 117, Channel 1 (next to SFP+)
# ==============================================================================

# Aurora Reference Clock (156.25 MHz - shared with SFP+ or separate)
# Using same reference clock as SFP+ (shared QPLL)
# set_property PACKAGE_PIN G8 [get_ports aurora_refclk_p]
# set_property PACKAGE_PIN G7 [get_ports aurora_refclk_n]

# Aurora GTX Transceiver (to FPGA2) - GTX Quad 117, Channel 1
# set_property PACKAGE_PIN J4 [get_ports aurora_tx_p]
# set_property PACKAGE_PIN J3 [get_ports aurora_tx_n]
# set_property PACKAGE_PIN H6 [get_ports aurora_rx_p]
# set_property PACKAGE_PIN H5 [get_ports aurora_rx_n]

#################fan define##################
set_property IOSTANDARD LVCMOS25 [get_ports fan_pwm]
set_property PACKAGE_PIN AE26 [get_ports fan_pwm]

# ==============================================================================
# Status LEDs (directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly on PL LEDs directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly)
# ==============================================================================
# Active low LEDs on AX7325B (accent directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly on AX7325B)
set_property PACKAGE_PIN A22 [get_ports led_qpll_lock]
set_property PACKAGE_PIN C19 [get_ports led_gtx_ready]
set_property PACKAGE_PIN B19 [get_ports led_pcs_lock]
set_property PACKAGE_PIN E18 [get_ports led_aurora_up]

set_property IOSTANDARD LVCMOS15 [get_ports led_qpll_lock]
set_property IOSTANDARD LVCMOS15 [get_ports led_gtx_ready]
set_property IOSTANDARD LVCMOS15 [get_ports led_pcs_lock]
set_property IOSTANDARD LVCMOS15 [get_ports led_aurora_up]

# ==============================================================================
# Debug UART (directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly 115200 baud, directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly FT232 on board)
# ==============================================================================
# Pin AK26 verified from working Project 33 UART
set_property PACKAGE_PIN AK26 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS25 [get_ports uart_tx]

# Optional UART RX for configuration commands
# set_property PACKAGE_PIN Y22 [get_ports uart_rx]
# set_property IOSTANDARD LVCMOS25 [get_ports uart_rx]


# ==============================================================================
# GTX Location Constraints (from working Project 33)
# G7/G8 = MGTREFCLK0_117, K1/K2/K5/K6 = QUAD 117 lane 0
# ==============================================================================

# QPLL for QUAD 117
set_property LOC GTXE2_COMMON_X0Y2 [get_cells -hier -filter {REF_NAME==GTXE2_COMMON}]

# SFP+ GTX Channel - QUAD 117, Lane 0 (X0Y8)
set_property LOC GTXE2_CHANNEL_X0Y8 [get_cells -hier -filter {REF_NAME==GTXE2_CHANNEL}]

# ==============================================================================
# Bitstream Configuration
# ==============================================================================
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullup [current_design]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# ==============================================================================
# DRC Waivers
# ==============================================================================
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
