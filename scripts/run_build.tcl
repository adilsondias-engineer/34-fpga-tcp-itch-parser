# ==============================================================================
# Vivado Build Script for FPGA1 Network Ingress (TCP ITCH Parser)
# Target: ALINX AX7325B (Kintex-7 XC7K325T-2FFG900)
# Role: FPGA1 in 3-FPGA Trading Appliance Architecture
# ==============================================================================

set project_name "fpga1_network_ingress"
set project_dir  "[file dirname [info script]]/../vivado"
set src_dir      "[file dirname [info script]]/../src"
set constr_dir   "[file dirname [info script]]/../constraints"

# Project 33 PHY sources (10GBASE-R PHY layer)
set phy_src_dir  "[file dirname [info script]]/../../33-10gbe-phy-custom/src"

# Target part (Kintex-7 325T on ALINX AX7325B)
set part_number "xc7k325tffg900-2"

# ==============================================================================
# Create Project
# ==============================================================================

puts "=============================================="
puts "FPGA1 Network Ingress Build"
puts "Target: $part_number"
puts "=============================================="

file mkdir $project_dir
file mkdir $project_dir/reports
create_project $project_name $project_dir -part $part_number -force

set_property target_language VHDL [current_project]

# ==============================================================================
# Add Sources - Project 34 (TCP ITCH Parser)
# ==============================================================================

puts "Adding Project 34 sources..."

# Common packages
add_files -norecurse $src_dir/common/symbol_filter_pkg.vhd
add_files -norecurse $src_dir/common/itch_msg_common_pkg.vhd
add_files -norecurse $src_dir/common/protocol_demux.vhd

# TCP parser
add_files -norecurse $src_dir/tcp/tcp_parser.vhd

# Transport layer handlers
add_files -norecurse $src_dir/transport/soupbintcp_handler.vhd
add_files -norecurse $src_dir/transport/moldudp64_handler.vhd

# ITCH parsers
add_files -norecurse $src_dir/itch/asx_itch_msg_pkg.vhd
add_files -norecurse $src_dir/itch/asx_itch_parser.vhd
add_files -norecurse $src_dir/itch/nasdaq/nasdaq_itch_parser.vhd

# XGMII MAC/IP parser and TX generator
add_files -norecurse $src_dir/xgmii/mac_parser_xgmii.vhd
add_files -norecurse $src_dir/xgmii/simple_udp_tx.vhd

# Aurora TX - COMMENTED OUT (needs custom PCB for inter-FPGA testing)
# add_files -norecurse $src_dir/aurora/aurora_tx_wrapper.vhd

# Integration
# itch_message_mux.vhd - COMMENTED OUT (needs Aurora for output)
# add_files -norecurse $src_dir/integration/itch_message_mux.vhd
add_files -norecurse $src_dir/integration/fpga1_network_top.vhd

# Debug UART (Verilog)
add_files -norecurse $src_dir/debug/uart_tx_simple.v
add_files -norecurse $src_dir/debug/gtx_debug_reporter.v  ;# Keep-alive for tx_clk domain

# ==============================================================================
# Add Sources - Project 33 (10GBASE-R PHY)
# ==============================================================================
# NOTE: PHY integration is now enabled - fpga1_network_top instantiates
# gtx_10g_wrapper and pcs_10gbase_r from Project 33.
# Set PHY_INTEGRATION to false for standalone parser verification without GTX.

set PHY_INTEGRATION true

if {$PHY_INTEGRATION} {
    puts "Adding Project 33 PHY sources (PHY_INTEGRATION=true)..."

    # GTX wrapper
    if {[file exists $phy_src_dir/gtx/gtx_10g_wrapper.vhd]} {
        add_files -norecurse $phy_src_dir/gtx/gtx_10g_wrapper.vhd
    }

    # PCS sources (10GBASE-R Physical Coding Sublayer)
    if {[file exists $phy_src_dir/pcs/pcs_10gbase_r.vhd]} {
        add_files -norecurse $phy_src_dir/pcs/pcs_10gbase_r.vhd
        add_files -norecurse $phy_src_dir/pcs/encoder_64b66b.vhd
        add_files -norecurse $phy_src_dir/pcs/decoder_64b66b.vhd
        add_files -norecurse $phy_src_dir/pcs/block_lock_fsm.vhd
    }

    # Scrambler sources
    if {[file exists $phy_src_dir/scrambler/scrambler_tx.vhd]} {
        add_files -norecurse $phy_src_dir/scrambler/scrambler_tx.vhd
        add_files -norecurse $phy_src_dir/scrambler/descrambler_rx.vhd
    }
} else {
    puts "Standalone build (PHY_INTEGRATION=false) - GTX sources not included"
    puts "Parser logic will be verified without actual 10GbE PHY"
}

# ==============================================================================
# Set Top Module and File Properties
# ==============================================================================

set_property top fpga1_network_top [current_fileset]
set_property file_type {VHDL 2008} [get_files *.vhd]

# ==============================================================================
# Add Constraints
# ==============================================================================

puts "Adding constraints..."
add_files -fileset constrs_1 -norecurse $constr_dir/fpga1_network_pins.xdc
add_files -fileset constrs_1 -norecurse $constr_dir/fpga1_network_timing.xdc

# For standalone builds, disable pin constraints (use timing only)
if {!$PHY_INTEGRATION} {
    puts "Standalone mode: disabling pin constraints for unconnected GTX ports"
    set_property used_in_synthesis false [get_files $constr_dir/fpga1_network_pins.xdc]
    set_property used_in_implementation false [get_files $constr_dir/fpga1_network_pins.xdc]
}

# ==============================================================================
# Synthesis Settings
# ==============================================================================

# Use default synthesis strategy (compatible with Vivado 2025)
# set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.FSM_EXTRACTION one_hot [get_runs synth_1]

# ==============================================================================
# Run Synthesis
# ==============================================================================

puts ""
puts "Starting synthesis..."
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1

set synth_progress [get_property PROGRESS [get_runs synth_1]]
puts "Synthesis progress: $synth_progress"
if {$synth_progress != "100%"} {
    puts "ERROR: Synthesis failed! Progress: $synth_progress"
    report_drc -file $project_dir/reports/drc_synth.rpt
    exit 1
}

puts "Synthesis completed successfully."

# ==============================================================================
# Open Synthesized Design and Report
# ==============================================================================

open_run synth_1

report_utilization -file $project_dir/reports/utilization_synth.rpt
report_timing_summary -file $project_dir/reports/timing_synth.rpt
report_clocks -file $project_dir/reports/clocks_synth.rpt

puts ""
puts "Synthesis reports generated in: $project_dir/reports/"

# ==============================================================================
# Implementation Settings
# ==============================================================================

# Use default implementation strategy (compatible with Vivado 2025)
# set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]

# ==============================================================================
# Run Implementation
# ==============================================================================

puts ""
puts "Starting implementation..."
launch_runs impl_1 -jobs 4
wait_on_run impl_1

set impl_progress [get_property PROGRESS [get_runs impl_1]]
puts "Implementation progress: $impl_progress"
if {$impl_progress != "100%"} {
    puts "ERROR: Implementation failed! Progress: $impl_progress"
    exit 1
}

puts "Implementation completed successfully."

# Open implemented design
open_run impl_1

# Generate post-implementation reports
report_utilization -file $project_dir/reports/utilization_impl.rpt
report_timing_summary -file $project_dir/reports/timing_impl.rpt -max_paths 20
report_timing -file $project_dir/reports/timing_paths.rpt -max_paths 50 -slack_lesser_than 0
report_power -file $project_dir/reports/power_impl.rpt

# Check timing
set wns [get_property STATS.WNS [get_runs impl_1]]
set tns [get_property STATS.TNS [get_runs impl_1]]

puts ""
puts "=============================================="
puts "Implementation Complete"
puts "=============================================="
puts "Worst Negative Slack (WNS): $wns ns"
puts "Total Negative Slack (TNS): $tns ns"
puts ""

if {$wns < 0} {
    puts "WARNING: Timing not met! WNS = $wns ns"
    puts "Review timing_paths.rpt for failing paths."
} else {
    puts "SUCCESS: All timing constraints met!"
}

# ==============================================================================
# Generate Bitstream
# ==============================================================================

puts ""
puts "Generating bitstream..."
write_bitstream -force $project_dir/fpga1_network_ingress.bit
puts "Bitstream generated: $project_dir/fpga1_network_ingress.bit"

# ==============================================================================
# Summary
# ==============================================================================

puts ""
puts "=============================================="
puts "BUILD COMPLETE - FPGA1 Network Ingress"
puts "=============================================="
puts ""
puts "FPGA1 Role: Network Ingress in 3-FPGA Trading Appliance"
puts ""
puts "Data Flow:"
puts "  10GbE SFP+ -> MAC/IP Parser -> Protocol Demux"
puts "       |"
puts "       +-- UDP -> MoldUDP64 -> NASDAQ ITCH Parser"
puts "       |"
puts "       +-- TCP -> SoupBinTCP -> ASX ITCH Parser"
puts ""
puts "  NOTE: Aurora TX to FPGA2 currently disabled (needs custom PCB)"
puts "        Parser results shown via LED activity pulse"
puts ""
puts "LED Status when programmed:"
puts "  LED0: QPLL locked (ON = locked)"
puts "  LED1: GTX ready (TX+RX reset done)"
puts "  LED2: PCS block lock (10GbE link up)"
puts "  LED3: Parser activity (pulses on ITCH messages)"
puts ""
puts "Bitstream: $project_dir/fpga1_network_ingress.bit"
puts "Reports:   $project_dir/reports/"
puts ""
