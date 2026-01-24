# ==============================================================================
# Vivado Synthesis-Only Test Script for FPGA1 Network Ingress
# Quick syntax and elaboration check without full implementation
# ==============================================================================

set project_name "fpga1_synth_test"
set project_dir  "[file dirname [info script]]/../vivado_test"
set src_dir      "[file dirname [info script]]/../src"
set constr_dir   "[file dirname [info script]]/../constraints"

# Target part (Kintex-7 325T on ALINX AX7325B)
set part_number "xc7k325tffg900-2"

# ==============================================================================
# Create Project
# ==============================================================================

puts "=============================================="
puts "FPGA1 Synthesis Test (No PHY - standalone)"
puts "=============================================="

file mkdir $project_dir
file mkdir $project_dir/reports
create_project $project_name $project_dir -part $part_number -force

set_property target_language VHDL [current_project]

# ==============================================================================
# Add Sources - Project 34 only (no PHY dependency)
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

# XGMII MAC/IP parser
add_files -norecurse $src_dir/xgmii/mac_parser_xgmii.vhd

# Aurora TX
add_files -norecurse $src_dir/aurora/aurora_tx_wrapper.vhd

# Integration
add_files -norecurse $src_dir/integration/itch_message_mux.vhd
add_files -norecurse $src_dir/integration/fpga1_network_top.vhd

# ==============================================================================
# Set Top Module
# ==============================================================================

set_property top fpga1_network_top [current_fileset]
set_property file_type {VHDL 2008} [get_files *.vhd]

# ==============================================================================
# Add Constraints (timing only for synthesis check)
# ==============================================================================

add_files -fileset constrs_1 -norecurse $constr_dir/fpga1_network_timing.xdc

# Relax constraints for standalone synthesis
set_property used_in_synthesis false [get_files $constr_dir/fpga1_network_pins.xdc -quiet]

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
    puts "ERROR: Synthesis failed!"
    puts ""
    puts "Check for:"
    puts "  - VHDL syntax errors"
    puts "  - Missing component declarations"
    puts "  - Port mismatches"
    puts ""
    exit 1
}

# ==============================================================================
# Report
# ==============================================================================

open_run synth_1

report_utilization -file $project_dir/reports/utilization_synth.rpt
report_timing_summary -file $project_dir/reports/timing_synth.rpt

# Print utilization summary
puts ""
puts "=============================================="
puts "Synthesis Complete"
puts "=============================================="
puts ""

# Get utilization info
set luts [get_property STATS.LUT [get_runs synth_1]]
set ffs  [get_property STATS.FF [get_runs synth_1]]
set bram [get_property STATS.BRAM [get_runs synth_1]]

puts "Resource Utilization (estimated):"
puts "  LUTs: $luts"
puts "  FFs:  $ffs"
puts "  BRAM: $bram"
puts ""
puts "Reports: $project_dir/reports/"
puts ""
puts "SUCCESS: All VHDL files synthesize correctly!"
puts ""
