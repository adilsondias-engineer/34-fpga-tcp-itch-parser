--------------------------------------------------------------------------------
-- Module: fpga1_network_top
-- Description: FPGA1 Network Ingress Top Module
--
-- Integrates all components for the 3-FPGA trading appliance FPGA1 role:
--   - 10GBASE-R PHY (from Project 33)
--   - Ethernet MAC/IP parsing (XGMII)
--   - Protocol demux (UDP/TCP routing)
--   - NASDAQ ITCH parser (UDP path)
--   - ASX ITCH parser (TCP path)
--   - Message multiplexer
--   - Aurora TX to FPGA2
--
-- Architecture per ARCHITECTURE-STANDALONE-APPLIANCE-v2.md:
--   Market Data -> 10GbE SFP+ -> FPGA1 -> Aurora -> FPGA2 (Order Book)
--
-- Latency Budget: ~120ns (MAC + Parse + Filter + Aurora TX)
--
-- ==============================================================================
-- Copyright 2026 Adilson Dias
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Author: Adilson Dias
-- GitHub: https://github.com/adilsondias-engineer/fpga-trading-systems
-- Date: January 2026
-- ==============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library UNISIM;
use UNISIM.VCOMPONENTS.ALL;

entity fpga1_network_top is
    generic (
        -- Symbol filtering (8 symbols max)
        ENABLE_SYMBOL_FILTER : boolean := true;
        NUM_SYMBOLS         : integer := 8
    );
    port (
        -- System (200 MHz differential clock from on-board oscillator)
        sys_clk_p           : in  std_logic;
        sys_clk_n           : in  std_logic;
        sys_rst_n           : in  std_logic;  -- Active-low reset

        -- 10GbE SFP+ interface (Market Data IN)
        sfp_refclk_p        : in  std_logic;  -- 156.25 MHz reference
        sfp_refclk_n        : in  std_logic;
        sfp_rx_p            : in  std_logic;
        sfp_rx_n            : in  std_logic;
        sfp_tx_p            : out std_logic;
        sfp_tx_n            : out std_logic;
        sfp_tx_disable      : out std_logic;

        -- Aurora interface COMMENTED OUT - needs custom PCB for testing
        -- aurora_refclk_p     : in  std_logic;
        -- aurora_refclk_n     : in  std_logic;
        -- aurora_tx_p         : out std_logic;
        -- aurora_tx_n         : out std_logic;
        -- aurora_rx_p         : in  std_logic;
        -- aurora_rx_n         : in  std_logic;

        -- Status LEDs
        led_qpll_lock       : out std_logic;
        led_gtx_ready       : out std_logic;
        led_pcs_lock        : out std_logic;
        led_aurora_up       : out std_logic;  -- Directly indicates parser activity for now

        -- Debug UART (115200 baud, 8N1)
        uart_tx             : out std_logic;
        fan_pwm             : out std_logic
    );
end fpga1_network_top;

architecture rtl of fpga1_network_top is

    ----------------------------------------------------------------------------
    -- Signal Declarations
    ----------------------------------------------------------------------------

    -- System clock (buffered from differential input)
    signal sys_clk          : std_logic;  -- 200 MHz from IBUFGDS

    -- Clock and Reset
    signal tx_clk           : std_logic;  -- 161.13 MHz from GTX MMCM (TXUSRCLK2)
    signal rx_clk           : std_logic;
    signal pcs_rst          : std_logic;
    signal reset_sync       : std_logic;
    signal reset_pipe       : std_logic_vector(2 downto 0) := "111";  -- Sync reset pipeline

    -- PHY Status
    signal qpll_lock        : std_logic;
    signal gtx_ready        : std_logic;
    signal pcs_block_lock   : std_logic;

    -- XGMII interface (from PHY)
    signal xgmii_rxd        : std_logic_vector(63 downto 0);
    signal xgmii_rxc        : std_logic_vector(7 downto 0);
    signal xgmii_rx_valid   : std_logic;  -- PCS decoder valid (gearbox has new block)
    signal xgmii_txd        : std_logic_vector(63 downto 0);
    signal xgmii_txc        : std_logic_vector(7 downto 0);

    -- MAC/IP parser output
    signal ip_payload_valid : std_logic;
    signal ip_payload_data  : std_logic_vector(7 downto 0);
    signal ip_payload_start : std_logic;
    signal ip_payload_end   : std_logic;
    signal ip_protocol      : std_logic_vector(7 downto 0);

    -- Protocol demux outputs
    signal tcp_valid        : std_logic;
    signal tcp_data         : std_logic_vector(7 downto 0);
    signal tcp_start        : std_logic;
    signal tcp_end          : std_logic;

    signal udp_valid        : std_logic;
    signal udp_data         : std_logic_vector(7 downto 0);
    signal udp_start        : std_logic;
    signal udp_end          : std_logic;

    -- TCP parser outputs
    signal tcp_payload_valid : std_logic;
    signal tcp_payload_data  : std_logic_vector(7 downto 0);
    signal tcp_payload_start : std_logic;
    signal tcp_payload_end   : std_logic;

    -- SoupBinTCP outputs
    signal itch_tcp_valid   : std_logic;
    signal itch_tcp_data    : std_logic_vector(7 downto 0);
    signal itch_tcp_start   : std_logic;
    signal itch_tcp_end     : std_logic;

    -- MoldUDP64 outputs (NASDAQ session layer)
    signal mold_itch_valid  : std_logic;
    signal mold_itch_data   : std_logic_vector(7 downto 0);
    signal mold_itch_start  : std_logic;
    signal mold_itch_end    : std_logic;

    -- NASDAQ ITCH parser outputs
    signal nasdaq_msg_valid : std_logic;
    signal nasdaq_msg_type  : std_logic_vector(7 downto 0);
    signal nasdaq_timestamp : std_logic_vector(47 downto 0);
    signal nasdaq_order_ref : std_logic_vector(63 downto 0);
    signal nasdaq_stock_locate : std_logic_vector(15 downto 0);
    signal nasdaq_tracking_number : std_logic_vector(15 downto 0);
    signal nasdaq_buy_sell  : std_logic;
    signal nasdaq_shares    : std_logic_vector(31 downto 0);
    signal nasdaq_price     : std_logic_vector(31 downto 0);
    signal nasdaq_stock_symbol : std_logic_vector(63 downto 0);
    signal nasdaq_exec_shares : std_logic_vector(31 downto 0);
    signal nasdaq_cancel_shares : std_logic_vector(31 downto 0);

    -- ASX ITCH parser outputs
    signal asx_msg_valid    : std_logic;
    signal asx_msg_type     : std_logic_vector(7 downto 0);
    signal asx_timestamp    : std_logic_vector(31 downto 0);
    signal asx_order_id     : std_logic_vector(63 downto 0);
    signal asx_orderbook_id : std_logic_vector(31 downto 0);
    signal asx_side         : std_logic;
    signal asx_quantity     : std_logic_vector(63 downto 0);
    signal asx_price        : std_logic_vector(31 downto 0);
    signal asx_exec_quantity : std_logic_vector(63 downto 0);
    signal asx_cancel_quantity : std_logic_vector(63 downto 0);

    -- Parser message counters (for debug)
    signal msg_count        : unsigned(31 downto 0) := (others => '0');
    signal parser_active    : std_logic := '0';

    -- GTX RX activity indicator for LED3 (debug: shows raw PCS data arriving)
    signal gtx_rx_activity  : std_logic := '0';
    signal gtx_rx_activity_cnt : unsigned(23 downto 0) := (others => '0');  -- ~100ms at 156MHz

    -- Debug counters from parser pipeline
    signal mac_frame_count       : std_logic_vector(31 downto 0);
    signal mac_start_detect_count: std_logic_vector(31 downto 0);  -- XGMII Start detections
    signal mac_frame_valid       : std_logic;
    signal demux_udp_count       : std_logic_vector(31 downto 0);
    signal mold_packet_count     : std_logic_vector(31 downto 0);
    signal mold_msg_extracted    : std_logic_vector(31 downto 0);
    signal nasdaq_total_messages : std_logic_vector(31 downto 0);

    -- ITCH field latches (last parsed message, for debug reporter)
    signal last_itch_msg_type    : std_logic_vector(7 downto 0) := (others => '0');
    signal last_itch_stock_locate: std_logic_vector(15 downto 0) := (others => '0');
    signal last_itch_price       : std_logic_vector(31 downto 0) := (others => '0');

    -- PCS debug: block type tracking
    signal pcs_ctrl_block_cnt    : std_logic_vector(15 downto 0);  -- Control blocks (hdr=10)
    signal pcs_data_block_cnt    : std_logic_vector(15 downto 0);  -- Data blocks (hdr=01)
    signal pcs_last_block_type   : std_logic_vector(7 downto 0);   -- Last ctrl block type

    -- Raw XGMII activity counter - REMOVED (caused PCS lock issues)
    -- Debugging will use MAC frame_count instead

    -- UART Debug handled by parser_debug_reporter

    -- Aurora TX - COMMENTED OUT (needs custom PCB for testing)
    -- signal aurora_tx_data   : std_logic_vector(63 downto 0);
    -- signal aurora_tx_header : std_logic_vector(1 downto 0);
    -- signal aurora_tx_valid  : std_logic;
    -- signal aurora_tx_ready  : std_logic;

    ----------------------------------------------------------------------------
    -- GTX <-> PCS Interface Signals
    ----------------------------------------------------------------------------
    -- GTX TX to PCS
    signal gtx_tx_data_int  : std_logic_vector(63 downto 0);
    signal gtx_tx_header_int: std_logic_vector(1 downto 0);
    signal gtx_tx_valid_int : std_logic;

    -- GTX RX from PCS
    signal gtx_rx_data_int  : std_logic_vector(63 downto 0);
    signal gtx_rx_header_int: std_logic_vector(1 downto 0);
    signal gtx_rx_valid_int : std_logic;
    signal gtx_rx_header_valid_int : std_logic;
    signal gtx_rx_slip_int  : std_logic;

    -- GTX Status
    signal tx_resetdone     : std_logic;
    signal rx_resetdone     : std_logic;
    signal phy_ready        : std_logic;
    signal qpll_refclk_lost : std_logic;

    -- GTX Debug signals (for gtx_debug_reporter)
    signal debug_por_done       : std_logic;
    signal debug_qpll_reset     : std_logic;
    signal debug_gtx_reset      : std_logic;
    signal debug_tx_userrdy     : std_logic;
    signal debug_rx_userrdy     : std_logic;
    signal debug_refclk_present : std_logic;
    signal debug_rx_cdrlock     : std_logic;
    signal debug_rx_elecidle    : std_logic;

    -- PCS Debug signals
    signal pcs_block_state      : std_logic_vector(2 downto 0);

    -- TX clock heartbeat (for debug - verifies tx_clk is running)
    signal tx_clk_counter       : unsigned(27 downto 0) := (others => '0');
    signal tx_clk_heartbeat     : std_logic := '0';

    -- Reset synchronizer output (for debug)
    signal reset_int            : std_logic;

    -- CDC synchronizer for phy_ready (drp_clk -> tx_clk domain)
    signal phy_ready_sync       : std_logic_vector(2 downto 0) := (others => '0');
    signal phy_ready_tx         : std_logic := '0';  -- phy_ready synchronized to tx_clk

    -- Note: sys_rst_n passed directly to GTX wrapper (which inverts internally)


    -- Message Mux and Aurora TX - COMMENTED OUT (needs custom PCB for testing)
    -- Aurora will be re-enabled when custom FPGA interconnect board is available
    -- For now, parser results are output via UART debug

    -- Fan PWM: 200 MHz / 8192 = 24.4 kHz PWM frequency
    signal pwm_counter : unsigned(12 downto 0) := (others => '0');  -- 13-bit for ~25 kHz
    -- 25% duty: fan ON (low) for 2048/8192 counts
    constant FAN_DUTY_THRESHOLD : unsigned(12 downto 0) := to_unsigned(1024, 13);  -- 1024=12.5% ON -- to_unsigned(2048, 13);  -- 25% ON

    -- Link Init TX (sends startup packets to establish link with switch)
    signal link_init_txd      : std_logic_vector(63 downto 0);
    signal link_init_txc      : std_logic_vector(7 downto 0);
    signal link_init_done_int : std_logic;
    signal link_init_active   : std_logic;

    -- ITCH Echo TX (echoes parsed ITCH fields as UDP for debug)
    signal itch_echo_txd      : std_logic_vector(63 downto 0);
    signal itch_echo_txc      : std_logic_vector(7 downto 0);

    -- Raw UDP Echo TX (echoes raw mac_parser bytes as UDP on port 5001)
    signal raw_echo_txd       : std_logic_vector(63 downto 0);
    signal raw_echo_txc       : std_logic_vector(7 downto 0);
    signal raw_echo_active    : std_logic;
    signal raw_echo_tx_count  : std_logic_vector(31 downto 0);

    signal debug_uart_tx        : std_logic;   -- from gtx_debug_reporter

begin

    ----------------------------------------------------------------------------
    -- System Clock Buffer (200 MHz differential to single-ended)
    -- Uses DIFF_SSTL15 matching working Project 33 configuration
    ----------------------------------------------------------------------------
    sys_clk_ibuf : IBUFDS
        generic map (
            DIFF_TERM    => FALSE,
            IBUF_LOW_PWR => FALSE,
            IOSTANDARD   => "DIFF_SSTL15"
        )
        port map (
            I  => sys_clk_p,
            IB => sys_clk_n,
            O  => sys_clk
        );

    ----------------------------------------------------------------------------
    -- Reset Logic
    ----------------------------------------------------------------------------
    -- Note: sys_rst_n passed directly to GTX wrapper (which inverts internally)

    -- Reset synchronizer: 3-stage SYNCHRONOUS pipeline (no async set/reset)
    -- CRITICAL: async preset on registers driving BRAM enables causes DRC REQP #1
    -- warning and can corrupt FIFO BRAM contents. Using purely synchronous reset
    -- eliminates async path to BRAM ENARDEN pin.
    -- Initial value "111" ensures FPGA starts in reset after GSR.
    process(tx_clk)
    begin
        if rising_edge(tx_clk) then
            reset_pipe(0) <= not sys_rst_n;  -- Stage 1: may be metastable
            reset_pipe(1) <= reset_pipe(0);  -- Stage 2: resolves metastability
            reset_pipe(2) <= reset_pipe(1);  -- Stage 3: stable output
        end if;
    end process;
    reset_sync <= reset_pipe(2);
    reset_int <= reset_sync;  -- For debug reporter

    -- CDC synchronizer: phy_ready is in drp_clk domain, need to sync to tx_clk
    -- CRITICAL FIX: phy_ready was being used across clock domains without sync!
    process(tx_clk)
    begin
        if rising_edge(tx_clk) then
            phy_ready_sync <= phy_ready_sync(1 downto 0) & phy_ready;
            phy_ready_tx <= phy_ready_sync(2);
        end if;
    end process;

    -- PCS reset: sync reset OR PHY not ready (now using synced phy_ready)
    pcs_rst <= reset_sync or not phy_ready_tx;

    -- GTX ready when both TX and RX reset done
    gtx_ready <= tx_resetdone and rx_resetdone;

    ----------------------------------------------------------------------------
    -- TX Clock Heartbeat (for debug - verifies tx_clk is running)
    -- 161.13 MHz / 2^27 = ~1.2 Hz blink rate
    ----------------------------------------------------------------------------
    process(tx_clk)
    begin
        if rising_edge(tx_clk) then
            tx_clk_counter <= tx_clk_counter + 1;
            tx_clk_heartbeat <= tx_clk_counter(27);
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- 10GBASE-R PHY - GTX Transceiver (Project 33)
    ----------------------------------------------------------------------------
    sfp_gtx_inst : entity work.gtx_10g_wrapper
        generic map (
            SIM_MODE    => false,
            GTX_CHANNEL => 0
        )
        port map (
            -- Reference clock
            refclk_p        => sfp_refclk_p,
            refclk_n        => sfp_refclk_n,
            drp_clk         => sys_clk,
            sys_reset       => sys_rst_n,  -- Pass active-low directly, wrapper inverts internally

            -- Serial interface (directly to SFP+ cage)
            gtx_txp         => sfp_tx_p,
            gtx_txn         => sfp_tx_n,
            gtx_rxp         => sfp_rx_p,
            gtx_rxn         => sfp_rx_n,

            -- TX interface (from PCS)
            tx_clk          => tx_clk,
            tx_data         => gtx_tx_data_int,
            tx_header       => gtx_tx_header_int,
            tx_valid        => gtx_tx_valid_int,
            tx_sequence     => open,

            -- RX interface (to PCS)
            rx_clk          => rx_clk,
            rx_data         => gtx_rx_data_int,
            rx_header       => gtx_rx_header_int,
            rx_header_valid => gtx_rx_header_valid_int,
            rx_datavalid    => gtx_rx_valid_int,

            -- Gearbox slip (from PCS block lock)
            rx_gearbox_slip => gtx_rx_slip_int,

            -- Status
            qpll_lock       => qpll_lock,
            qpll_refclk_lost=> qpll_refclk_lost,
            tx_resetdone    => tx_resetdone,
            rx_resetdone    => rx_resetdone,
            phy_ready       => phy_ready,

            -- Debug outputs (for gtx_debug_reporter)
            debug_por_done  => debug_por_done,
            debug_qpll_reset=> debug_qpll_reset,
            debug_gtx_reset => debug_gtx_reset,
            debug_tx_userrdy=> debug_tx_userrdy,
            debug_rx_userrdy=> debug_rx_userrdy,
            debug_refclk_present => debug_refclk_present,
            debug_rx_cdrlock=> debug_rx_cdrlock,
            debug_rx_elecidle => debug_rx_elecidle,
            debug_rx_startofseq => open,
            debug_tx_gearbox_ready => open
        );

    ----------------------------------------------------------------------------
    -- Link Init TX (sends 5 startup packets to establish link with switch)
    -- After init completes, ITCH Echo TX takes over the XGMII TX bus
    ----------------------------------------------------------------------------
    link_init_inst : entity work.link_init_tx
        generic map (
            CLK_FREQ         => 161_130_000,
            STARTUP_DELAY_MS => 100,
            STARTUP_PACKETS  => 5,
            PACKET_GAP_MS    => 50
        )
        port map (
            clk         => tx_clk,
            rst         => pcs_rst,
            phy_ready   => phy_ready_tx,
            xgmii_txd   => link_init_txd,
            xgmii_txc   => link_init_txc,
            init_done   => link_init_done_int,
            init_active => link_init_active,
            tx_count    => open
        );

    ----------------------------------------------------------------------------
    -- ITCH Echo TX (echoes parsed ITCH fields back as UDP packets)
    -- Sends parsed msg_type, symbol, price, shares, order_ref to port 5000
    -- for Wireshark verification of ITCH parser correctness
    ----------------------------------------------------------------------------
    itch_echo_inst : entity work.itch_echo_tx
        port map (
            clk               => tx_clk,
            rst               => pcs_rst,
            itch_msg_valid    => nasdaq_msg_valid,
            itch_msg_type     => nasdaq_msg_type,
            itch_stock_locate => nasdaq_stock_locate,
            itch_tracking_number => nasdaq_tracking_number,
            itch_timestamp    => nasdaq_timestamp,
            itch_order_ref    => nasdaq_order_ref,
            itch_buy_sell     => nasdaq_buy_sell,
            itch_shares       => nasdaq_shares,
            itch_stock_symbol => nasdaq_stock_symbol,
            itch_price        => nasdaq_price,
            xgmii_txd         => itch_echo_txd,
            xgmii_txc         => itch_echo_txc,
            tx_active          => open,
            tx_count           => open
        );

    ----------------------------------------------------------------------------
    -- Raw UDP Echo TX (captures directly from XGMII RX, bypasses mac_parser)
    -- Tests XGMII data integrity without FIFO/serializer in the path
    ----------------------------------------------------------------------------
    raw_echo_inst : entity work.raw_udp_echo_tx
        port map (
            clk              => tx_clk,
            rst              => pcs_rst,
            xgmii_rxd        => xgmii_rxd,
            xgmii_rxc        => xgmii_rxc,
            xgmii_rx_valid   => xgmii_rx_valid,
            xgmii_txd        => raw_echo_txd,
            xgmii_txc        => raw_echo_txc,
            tx_active         => raw_echo_active,
            tx_count          => raw_echo_tx_count
        );

    -- TX Mux: Link init > ITCH Echo (full parser pipeline)
    xgmii_txd <= link_init_txd when link_init_done_int = '0' else
                 itch_echo_txd;
    xgmii_txc <= link_init_txc when link_init_done_int = '0' else
                 itch_echo_txc;

    ----------------------------------------------------------------------------
    -- 10GBASE-R PCS - 64B/66B Encoding/Decoding (Project 33)
    ----------------------------------------------------------------------------
    pcs_inst :  entity work.pcs_10gbase_r
        port map (
            clk             => tx_clk,
            reset           => pcs_rst,

            -- XGMII TX interface (from UDP TX generator)
            xgmii_txd       => xgmii_txd,
            xgmii_txc       => xgmii_txc,

            -- XGMII RX interface (to MAC parser)
            xgmii_rxd       => xgmii_rxd,
            xgmii_rxc       => xgmii_rxc,
            xgmii_rx_valid  => xgmii_rx_valid,

            -- GTX TX interface (to GTX transceiver)
            gtx_tx_data     => gtx_tx_data_int,
            gtx_tx_header   => gtx_tx_header_int,
            gtx_tx_valid    => gtx_tx_valid_int,

            -- GTX RX interface (from GTX transceiver)
            gtx_rx_data     => gtx_rx_data_int,
            gtx_rx_header   => gtx_rx_header_int,
            gtx_rx_valid    => gtx_rx_valid_int,
            gtx_rx_header_valid => gtx_rx_header_valid_int,

            -- Gearbox slip (to GTX for block alignment)
            gtx_rx_slip     => gtx_rx_slip_int,

            -- Status
            pcs_block_lock  => pcs_block_lock,
            pcs_rx_sync     => open,
            pcs_tx_error    => open,
            pcs_rx_error    => open,

            -- Debug
            debug_tx_enc_error  => open,
            debug_rx_dec_error  => open,
            debug_header_errors => open,
            debug_block_state   => pcs_block_state,

            -- Additional debug: block type tracking
            debug_ctrl_block_cnt => pcs_ctrl_block_cnt,
            debug_data_block_cnt => pcs_data_block_cnt,
            debug_last_block_type => pcs_last_block_type
        );

    ----------------------------------------------------------------------------
    -- MAC/IP Parser
    ----------------------------------------------------------------------------
    mac_parser_inst :  entity work.mac_parser_xgmii
        generic map (
            LOCAL_MAC => x"000a3501fec0"  -- FPGA MAC: 00:0a:35:01:fe:c0 (IP: 192.168.0.215)
        )
        port map (
            clk => tx_clk,
            rst => pcs_rst,
            xgmii_rxd => xgmii_rxd,
            xgmii_rxc => xgmii_rxc,
            xgmii_rx_valid => xgmii_rx_valid,
            ip_payload_valid => ip_payload_valid,
            ip_payload_data => ip_payload_data,
            ip_payload_start => ip_payload_start,
            ip_payload_end => ip_payload_end,
            ip_protocol => ip_protocol,
            ip_src_addr => open,
            ip_dst_addr => open,
            eth_dst_mac => open,
            eth_src_mac => open,
            eth_type => open,
            frame_valid => mac_frame_valid,  -- Debug: frame valid pulse
            frame_error => open,
            crc_error => open,
            frame_count => mac_frame_count,  -- Debug: frame count
            error_count => open,
            start_detect_count => mac_start_detect_count  -- Debug: XGMII Start detections
        );

    ----------------------------------------------------------------------------
    -- Protocol Demux (UDP/TCP routing)
    ----------------------------------------------------------------------------
    protocol_demux_inst :  entity work.protocol_demux
        port map (
            clk => tx_clk,
            rst => pcs_rst,
            ip_payload_valid => ip_payload_valid,
            ip_payload_data => ip_payload_data,
            ip_payload_start => ip_payload_start,
            ip_payload_end => ip_payload_end,
            ip_protocol => ip_protocol,
            tcp_payload_valid => tcp_valid,
            tcp_payload_data => tcp_data,
            tcp_payload_start => tcp_start,
            tcp_payload_end => tcp_end,
            udp_payload_valid => udp_valid,
            udp_payload_data => udp_data,
            udp_payload_start => udp_start,
            udp_payload_end => udp_end,
            tcp_packet_count => open,
            udp_packet_count => demux_udp_count,  -- Debug: UDP packet count
            other_packet_count => open
        );

    ----------------------------------------------------------------------------
    -- TCP Path: TCP Parser -> SoupBinTCP -> ASX ITCH
    ----------------------------------------------------------------------------
    tcp_parser_inst :  entity work.tcp_parser
        port map (
            clk => tx_clk,
            rst => pcs_rst,
            ip_payload_valid => tcp_valid,
            ip_payload_data => tcp_data,
            ip_payload_start => tcp_start,
            ip_payload_end => tcp_end,
            tcp_src_port => open,
            tcp_dst_port => open,
            tcp_seq_num => open,
            tcp_ack_num => open,
            tcp_data_offset => open,
            tcp_flags => open,
            tcp_window => open,
            tcp_flag_syn => open,
            tcp_flag_ack => open,
            tcp_flag_fin => open,
            tcp_flag_rst => open,
            tcp_flag_psh => open,
            tcp_payload_valid => tcp_payload_valid,
            tcp_payload_data => tcp_payload_data,
            tcp_payload_start => tcp_payload_start,
            tcp_payload_end => tcp_payload_end,
            tcp_header_valid => open,
            tcp_parse_error => open
        );

    soupbintcp_inst :  entity work.soupbintcp_handler
        port map (
            clk => tx_clk,
            rst => pcs_rst,
            tcp_payload_valid => tcp_payload_valid,
            tcp_payload_data => tcp_payload_data,
            tcp_payload_start => tcp_payload_start,
            tcp_payload_end => tcp_payload_end,
            itch_msg_valid => itch_tcp_valid,
            itch_msg_data => itch_tcp_data,
            itch_msg_start => itch_tcp_start,
            itch_msg_end => itch_tcp_end,
            session_active => open,
            session_sequence => open,
            pkt_type => open,
            pkt_type_valid => open,
            pkt_heartbeat => open,
            pkt_login_accepted => open,
            pkt_login_rejected => open,
            pkt_end_session => open,
            seq_data_count => open,
            heartbeat_count => open,
            parse_error => open
        );

    asx_itch_inst :  entity work.asx_itch_parser
        port map (
            clk => tx_clk,
            rst => pcs_rst,
            itch_msg_valid => itch_tcp_valid,
            itch_msg_data => itch_tcp_data,
            itch_msg_start => itch_tcp_start,
            itch_msg_end => itch_tcp_end,
            msg_valid => asx_msg_valid,
            msg_type => asx_msg_type,
            msg_error => open,
            timestamp => asx_timestamp,
            order_id => asx_order_id,
            orderbook_id => asx_orderbook_id,
            side => asx_side,
            add_order_valid => open,
            add_order_start => open,
            quantity => asx_quantity,
            price => asx_price,
            order_attributes => open,
            order_executed_valid => open,
            exec_quantity => asx_exec_quantity,
            match_id => open,
            combo_group_id => open,
            order_cancel_valid => open,
            cancel_quantity => asx_cancel_quantity,
            order_delete_valid => open,
            order_replace_valid => open,
            new_order_id => open,
            new_quantity => open,
            new_price => open,
            directory_valid => open,
            symbol => open,
            isin => open,
            price_decimals => open,
            round_lot_size => open,
            system_event_valid => open,
            event_code => open,
            total_messages => open,
            parse_errors => open
        );

    ----------------------------------------------------------------------------
    -- UDP Path: MoldUDP64 -> NASDAQ ITCH
    ----------------------------------------------------------------------------
    moldudp64_inst :  entity work.moldudp64_handler
        port map (
            clk => tx_clk,
            rst => pcs_rst,
            udp_payload_valid => udp_valid,
            udp_payload_data => udp_data,
            udp_payload_start => udp_start,
            udp_payload_end => udp_end,
            itch_msg_valid => mold_itch_valid,
            itch_msg_data => mold_itch_data,
            itch_msg_start => mold_itch_start,
            itch_msg_end => mold_itch_end,
            session_id => open,
            sequence_number => open,
            message_count => open,
            session_valid => open,
            sequence_gap => open,
            gap_count => open,
            packet_count => mold_packet_count,      -- Debug: MoldUDP64 packet count
            msg_extracted => mold_msg_extracted     -- Debug: MoldUDP64 messages extracted
        );

    nasdaq_itch_inst :  entity work.nasdaq_itch_parser
        port map (
            clk => tx_clk,
            rst => pcs_rst,
            itch_msg_valid => mold_itch_valid,
            itch_msg_data => mold_itch_data,
            itch_msg_start => mold_itch_start,
            itch_msg_end => mold_itch_end,
            msg_valid => nasdaq_msg_valid,
            msg_type => nasdaq_msg_type,
            msg_error => open,
            add_order_valid => open,
            stock_locate => nasdaq_stock_locate,
            tracking_number => nasdaq_tracking_number,
            timestamp => nasdaq_timestamp,
            order_ref => nasdaq_order_ref,
            buy_sell => nasdaq_buy_sell,
            shares => nasdaq_shares,
            stock_symbol => nasdaq_stock_symbol,
            price => nasdaq_price,
            order_executed_valid => open,
            exec_shares => nasdaq_exec_shares,
            match_number => open,
            order_cancel_valid => open,
            cancel_shares => nasdaq_cancel_shares,
            order_delete_valid => open,
            order_replace_valid => open,
            original_order_ref => open,
            new_order_ref => open,
            new_shares => open,
            new_price => open,
            total_messages => nasdaq_total_messages,  -- Debug: NASDAQ total messages
            filtered_messages => open
        );

    ----------------------------------------------------------------------------
    -- Message Mux (combines NASDAQ + ASX) - COMMENTED OUT (needs custom PCB)
    -- Aurora TX (to FPGA2) - COMMENTED OUT (needs custom PCB)
    -- For now, parser results are monitored via LED activity and UART debug
    ----------------------------------------------------------------------------
    -- msg_mux_inst :  entity work.itch_message_mux
    --     port map (
    --         clk => tx_clk,
    --         rst => pcs_rst,
    --         nasdaq_msg_valid => nasdaq_msg_valid,
    --         nasdaq_msg_type => nasdaq_msg_type,
    --         nasdaq_timestamp => nasdaq_timestamp,
    --         nasdaq_order_ref => nasdaq_order_ref,
    --         nasdaq_stock_locate => nasdaq_stock_locate,
    --         nasdaq_buy_sell => nasdaq_buy_sell,
    --         nasdaq_shares => nasdaq_shares,
    --         nasdaq_price => nasdaq_price,
    --         nasdaq_stock_symbol => nasdaq_stock_symbol,
    --         nasdaq_exec_shares => nasdaq_exec_shares,
    --         nasdaq_cancel_shares => nasdaq_cancel_shares,
    --         asx_msg_valid => asx_msg_valid,
    --         asx_msg_type => asx_msg_type,
    --         asx_timestamp => asx_timestamp,
    --         asx_order_id => asx_order_id,
    --         asx_orderbook_id => asx_orderbook_id,
    --         asx_side => asx_side,
    --         asx_quantity => asx_quantity,
    --         asx_price => asx_price,
    --         asx_exec_quantity => asx_exec_quantity,
    --         asx_cancel_quantity => asx_cancel_quantity,
    --         out_msg_valid => mux_msg_valid,
    --         out_msg_type => mux_msg_type,
    --         out_msg_market => mux_msg_market,
    --         out_msg_data => mux_msg_data,
    --         out_msg_data_valid => mux_msg_data_valid,
    --         out_msg_last => mux_msg_last,
    --         out_msg_ready => mux_msg_ready,
    --         nasdaq_msg_count => open,
    --         asx_msg_count => open
    --     );

    -- aurora_tx_inst :  entity work.aurora_tx_wrapper
    --     port map (
    --         clk => tx_clk,
    --         rst => pcs_rst,
    --         msg_valid => mux_msg_valid,
    --         msg_type => mux_msg_type,
    --         msg_market => mux_msg_market,
    --         msg_data => mux_msg_data,
    --         msg_data_valid => mux_msg_data_valid,
    --         msg_last => mux_msg_last,
    --         msg_ready => mux_msg_ready,
    --         gtx_tx_data => aurora_tx_data,
    --         gtx_tx_header => aurora_tx_header,
    --         gtx_tx_valid => aurora_tx_valid,
    --         tx_active => open,
    --         tx_sequence => open,
    --         tx_msg_count => open,
    --         gtx_tx_ready => '1'
    --     );

    ----------------------------------------------------------------------------
    -- Parser Activity Monitor (replaces Aurora for debugging)
    ----------------------------------------------------------------------------
    -- Count parsed messages and toggle LED / send to UART
    process(tx_clk)
    begin
        if rising_edge(tx_clk) then
            if pcs_rst = '1' then
                msg_count <= (others => '0');
                parser_active <= '0';
            else
                -- Count messages from either parser
                if nasdaq_msg_valid = '1' or asx_msg_valid = '1' then
                    msg_count <= msg_count + 1;
                end if;

                -- Toggle activity flag on any message
                if nasdaq_msg_valid = '1' or asx_msg_valid = '1' then
                    parser_active <= '1';
                else
                    parser_active <= '0';
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- ITCH Field Latch (capture last parsed message fields for debug)
    ----------------------------------------------------------------------------
    process(tx_clk)
    begin
        if rising_edge(tx_clk) then
            if pcs_rst = '1' then
                last_itch_msg_type <= (others => '0');
                last_itch_stock_locate <= (others => '0');
                last_itch_price <= (others => '0');
            elsif nasdaq_msg_valid = '1' then
                last_itch_msg_type <= nasdaq_msg_type;
                last_itch_stock_locate <= nasdaq_stock_locate;
                last_itch_price <= nasdaq_price;
            end if;
        end if;
    end process;

    -- Corruption detector and itch_debug_uart removed -- not needed for raw echo debug

    ----------------------------------------------------------------------------
    -- GTX RX Activity Detector (for LED3 debug)
    -- LED3 lights when raw 66-bit blocks arrive from GTX (before descrambler)
    -- Stays lit ~100ms after last activity for visibility
    ----------------------------------------------------------------------------
    process(tx_clk)
    begin
        if rising_edge(tx_clk) then
            if reset_int = '1' then
                gtx_rx_activity <= '0';
                gtx_rx_activity_cnt <= (others => '0');
            elsif gtx_rx_valid_int = '1' then
                -- Activity detected - light LED and reset timeout
                gtx_rx_activity <= '1';
                gtx_rx_activity_cnt <= (others => '1');  -- ~100ms timeout
            elsif gtx_rx_activity_cnt > 0 then
                -- Count down timeout
                gtx_rx_activity_cnt <= gtx_rx_activity_cnt - 1;
            else
                -- Timeout expired - turn off LED
                gtx_rx_activity <= '0';
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Status LEDs
    ----------------------------------------------------------------------------
    led_qpll_lock <= qpll_lock;
    led_gtx_ready <= gtx_ready;
    led_pcs_lock <= pcs_block_lock;
    led_aurora_up <= gtx_rx_activity;  -- DEBUG: Shows raw GTX RX data arriving (before PCS)

    -- SFP TX disable (active low to enable)
    sfp_tx_disable <= '0';

    ----------------------------------------------------------------------------
    -- GTX Debug Reporter with Parser Counters
    -- Samples GTX debug signals (prevents optimization that affects QPLL/PCS)
    -- Also outputs parser pipeline counters for debugging
    -- Output format: "Q:X L:X T:X R:X BL:X ST:X FC:XXXX UC:XXXX MC:XXXX MX:XXXX NM:XXXX [OK]\r\n"
    --   Q  = QPLL lock, L = REFCLK lost, T = TX done, R = RX done
    --   BL = PCS block lock, ST = block lock FSM state (7=LOCKED)
    --   FC = MAC frames, UC = UDP packets, MC = MoldUDP64 packets
    --   MX = ITCH msgs extracted, NM = NASDAQ total messages
    ----------------------------------------------------------------------------
    gtx_debug_keepalive :  entity work.gtx_debug_reporter
        generic map (
            CLK_FREQ    => 200_000_000,  -- sys_clk is 200 MHz
            BAUD_RATE   => 115200,
            REPORT_MS   => 500
        )
        port map (
            clk                   => sys_clk,
            rst                   => '0',
            -- GTX status
            qpll_lock             => qpll_lock,
            qpll_refclk_lost      => qpll_refclk_lost,
            tx_resetdone          => tx_resetdone,
            rx_resetdone          => rx_resetdone,
            -- Extended debug (sampled to prevent optimization)
            debug_por_done        => debug_por_done,
            debug_qpll_reset      => debug_qpll_reset,
            debug_gtx_reset       => debug_gtx_reset,
            debug_tx_userrdy      => debug_tx_userrdy,
            debug_rx_userrdy      => debug_rx_userrdy,
            debug_refclk_present  => debug_refclk_present,
            -- PCS status
            pcs_block_lock        => pcs_block_lock,
            rx_header_valid       => gtx_rx_header_valid_int,
            rx_datavalid          => gtx_rx_valid_int,
            block_lock_state      => pcs_block_state,
            rx_cdrlock            => debug_rx_cdrlock,
            rx_elecidle           => debug_rx_elecidle,
            tx_clk_heartbeat      => tx_clk_heartbeat,
            pcs_reset             => pcs_rst,
            reset_int_dbg         => reset_int,
            gtx_ready_dbg         => gtx_ready,
            -- Parser pipeline counters
            start_detect_count    => mac_start_detect_count,
            frame_count           => mac_frame_count,
            udp_packet_count      => demux_udp_count,
            mold_packet_count     => mold_packet_count,
            mold_msg_extracted    => mold_msg_extracted,
            nasdaq_total_messages => nasdaq_total_messages,
            -- ITCH parsed fields (last message)
            itch_msg_type         => last_itch_msg_type,
            itch_stock_locate     => last_itch_stock_locate,
            itch_price            => last_itch_price,
            -- UART output
            uart_tx               => debug_uart_tx
        );

    uart_tx <= debug_uart_tx;

       -- =========================================================================
        -- FAN PWM: 24.4 kHz, 25% duty (low = ON)
        -- =========================================================================
        process(sys_clk)
        begin
            if rising_edge(sys_clk) then
                pwm_counter <= pwm_counter + 1;
            end if;
        end process;

        -- Active-low: '0' = fan ON, '1' = fan OFF
        -- ON for first 2048 counts (25%), OFF for remaining 6144 counts (75%)
        fan_pwm <= '0' when pwm_counter < FAN_DUTY_THRESHOLD else '1';

end rtl;
