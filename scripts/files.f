# ==============================================================================
# File List for FPGA1 Network Ingress (TCP ITCH Parser)
# For use with simulators (ModelSim, GHDL, etc.) and documentation
# ==============================================================================

# Common packages (compile first)
src/common/symbol_filter_pkg.vhd
src/common/itch_msg_common_pkg.vhd

# Protocol packages
src/itch/asx_itch_msg_pkg.vhd

# TCP/UDP layer
src/tcp/tcp_parser.vhd
src/common/protocol_demux.vhd

# Transport layer (session handlers)
src/transport/soupbintcp_handler.vhd
src/transport/moldudp64_handler.vhd

# ITCH parsers
src/itch/asx_itch_parser.vhd
src/itch/nasdaq/nasdaq_itch_parser.vhd

# MAC/IP layer
src/xgmii/mac_parser_xgmii.vhd

# Output stage
src/integration/itch_message_mux.vhd
src/aurora/aurora_tx_wrapper.vhd

# Top level integration
src/integration/fpga1_network_top.vhd

# ==============================================================================
# External dependencies (Project 33 - 10GBASE-R PHY)
# ==============================================================================
# ../33-10gbe-phy-custom/src/gtx/gtx_10g_wrapper.vhd
# ../33-10gbe-phy-custom/src/pcs/pcs_10gbase_r.vhd
# ../33-10gbe-phy-custom/src/pcs/encoder_64b66b.vhd
# ../33-10gbe-phy-custom/src/pcs/decoder_64b66b.vhd
# ../33-10gbe-phy-custom/src/pcs/block_lock_fsm.vhd
# ../33-10gbe-phy-custom/src/scrambler/scrambler_tx.vhd
# ../33-10gbe-phy-custom/src/scrambler/descrambler_rx.vhd

# ==============================================================================
# Testbenches (simulation only)
# ==============================================================================
# test/tb_tcp_parser.vhd
# test/tb_soupbintcp_handler.vhd
# test/tb_asx_itch_parser.vhd
# test/tb_nasdaq_itch_parser.vhd
# test/tb_fpga1_network_top.vhd
