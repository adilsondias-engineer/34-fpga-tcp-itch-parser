--------------------------------------------------------------------------------
-- Module: mac_parser_xgmii
-- Description: Ethernet MAC frame parser for 10GbE XGMII interface
--
-- Word-based architecture: processes all 8 bytes per clock cycle.
-- Uses a payload FIFO to convert 64-bit parallel data to byte-stream output.
--
-- Pipeline:
--   XGMII (64b/clk) -> [Word Parser] -> [Payload FIFO] -> [Byte Serializer] -> output
--
-- XGMII byte ordering (matching encoder/decoder_64b66b):
--   Lane 0 = rxd[7:0]   = first byte on wire, rxc(0)
--   Lane 7 = rxd[63:56] = last byte on wire,  rxc(7)
--
-- Frame byte layout in XGMII words (after Start word):
--   Word 0: DstMAC[0:5] + SrcMAC[0:1]     (lanes 0-7)
--   Word 1: SrcMAC[2:5] + EtherType + IP[0:1]
--   Word 2: IP[2:9] (TotalLen, ID, Flags, TTL, Protocol)
--   Word 3: IP[10:17] (Checksum, SrcIP, DstIP[0:1])
--   Word 4: DstIP[2:3] + IP Payload start  (if IHL=5, payload at lane 2)
--   Word 5+: IP Payload continuation
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

entity mac_parser_xgmii is
    generic (
        -- Expected destination MAC (for filtering)
        LOCAL_MAC       : std_logic_vector(47 downto 0) := x"FFFFFFFFFFFF"  -- Broadcast default
    );
    port (
        clk                 : in  std_logic;  -- 161.13 MHz XGMII clock
        rst                 : in  std_logic;

        -- XGMII RX interface (from PCS)
        xgmii_rxd           : in  std_logic_vector(63 downto 0);
        xgmii_rxc           : in  std_logic_vector(7 downto 0);
        xgmii_rx_valid      : in  std_logic;  -- '1' when PCS has new block (gearbox valid)

        -- Parsed frame output (byte stream)
        ip_payload_valid    : out std_logic;
        ip_payload_data     : out std_logic_vector(7 downto 0);
        ip_payload_start    : out std_logic;
        ip_payload_end      : out std_logic;

        -- IP header info (extracted during parsing)
        ip_protocol         : out std_logic_vector(7 downto 0);  -- Protocol field
        ip_src_addr         : out std_logic_vector(31 downto 0);
        ip_dst_addr         : out std_logic_vector(31 downto 0);

        -- Ethernet header info
        eth_dst_mac         : out std_logic_vector(47 downto 0);
        eth_src_mac         : out std_logic_vector(47 downto 0);
        eth_type            : out std_logic_vector(15 downto 0);

        -- Status
        frame_valid         : out std_logic;
        frame_error         : out std_logic;
        crc_error           : out std_logic;

        -- Statistics
        frame_count         : out std_logic_vector(31 downto 0);
        error_count         : out std_logic_vector(31 downto 0);

        -- Debug: counts XGMII Start detections
        start_detect_count  : out std_logic_vector(31 downto 0)
    );
end mac_parser_xgmii;

architecture rtl of mac_parser_xgmii is

    -- XGMII control codes
    constant XGMII_IDLE     : std_logic_vector(7 downto 0) := x"07";
    constant XGMII_START    : std_logic_vector(7 downto 0) := x"FB";
    constant XGMII_TERM     : std_logic_vector(7 downto 0) := x"FD";
    constant XGMII_ERROR    : std_logic_vector(7 downto 0) := x"FE";

    -- EtherType for IPv4
    constant ETHERTYPE_IPV4 : std_logic_vector(15 downto 0) := x"0800";

    ----------------------------------------------------------------------------
    -- Word FIFO: hand-coded with registered reads for BRAM inference
    -- Registered read (Xilinx SDP BRAM template) enables block RAM inference.
    -- Serializer uses SS_LOAD state to absorb 1-cycle read latency.
    -- Bit mapping: [73:10] = data(64), [9:2] = keep(8), [1] = first, [0] = last
    ----------------------------------------------------------------------------
    constant FIFO_DEPTH     : integer := 256;
    constant FIFO_AW        : integer := 8;
    constant FIFO_WORD_W    : integer := 74;  -- 64 data + 8 keep + 1 first + 1 last

    type fifo_mem_t is array(0 to FIFO_DEPTH-1) of std_logic_vector(FIFO_WORD_W-1 downto 0);
    signal fifo_mem : fifo_mem_t;

    attribute ram_style : string;
    attribute ram_style of fifo_mem : signal is "block";

    signal fifo_wr_ptr      : unsigned(FIFO_AW-1 downto 0) := (others => '0');
    signal fifo_rd_ptr      : unsigned(FIFO_AW-1 downto 0) := (others => '0');
    signal fifo_count       : unsigned(FIFO_AW downto 0) := (others => '0');
    signal fifo_wr_en       : std_logic := '0';
    signal fifo_rd_en       : std_logic := '0';
    signal fifo_empty       : std_logic;
    signal fifo_full        : std_logic;

    -- FIFO write data (from parser)
    signal wr_data          : std_logic_vector(63 downto 0) := (others => '0');
    signal wr_keep          : std_logic_vector(7 downto 0) := (others => '0');
    signal wr_first         : std_logic := '0';
    signal wr_last          : std_logic := '0';

    -- FIFO registered read output (1-cycle latency, valid in SS_LOAD)
    signal rd_word          : std_logic_vector(FIFO_WORD_W-1 downto 0) := (others => '0');
    signal rd_data          : std_logic_vector(63 downto 0);
    signal rd_keep          : std_logic_vector(7 downto 0);
    signal rd_first         : std_logic;
    signal rd_last          : std_logic;

    ----------------------------------------------------------------------------
    -- Word-based parser
    ----------------------------------------------------------------------------
    type parse_state_t is (
        PS_IDLE,            -- Waiting for Start
        PS_HEADER,          -- Processing header words (word counter tracks position)
        PS_PAYLOAD,         -- Writing payload words to FIFO
        PS_DONE             -- Frame complete (non-IPv4 or payload written)
    );
    signal parse_state      : parse_state_t := PS_IDLE;
    signal word_cnt         : unsigned(7 downto 0) := (others => '0');

    -- Header registers
    signal dst_mac_reg      : std_logic_vector(47 downto 0) := (others => '0');
    signal src_mac_reg      : std_logic_vector(47 downto 0) := (others => '0');
    signal ethertype_reg    : std_logic_vector(15 downto 0) := (others => '0');
    signal ip_ihl_reg       : unsigned(3 downto 0) := (others => '0');
    signal ip_total_len_reg : unsigned(15 downto 0) := (others => '0');
    signal ip_protocol_reg  : std_logic_vector(7 downto 0) := (others => '0');
    signal ip_src_reg       : std_logic_vector(31 downto 0) := (others => '0');
    signal ip_dst_reg       : std_logic_vector(31 downto 0) := (others => '0');

    -- Payload tracking
    signal payload_start_byte : unsigned(7 downto 0) := (others => '0');  -- 14 + IHL*4
    signal payload_total      : unsigned(15 downto 0) := (others => '0'); -- ip_total_len - IHL*4
    signal payload_written    : unsigned(15 downto 0) := (others => '0');
    signal remaining_r        : unsigned(15 downto 0) := (others => '0');  -- Pre-registered payload_total - payload_written
    signal frame_is_ipv4      : std_logic := '0';
    signal frame_active       : std_logic := '0';
    signal headers_valid      : std_logic := '0';  -- Set when IHL + total_len available

    -- Terminate detection
    signal terminate_in_word  : std_logic;
    signal terminate_lane     : integer range 0 to 7;

    ----------------------------------------------------------------------------
    -- Byte serializer (reads from FIFO, outputs 1 byte/clock)
    ----------------------------------------------------------------------------
    type serial_state_t is (SS_IDLE, SS_LOAD, SS_OUTPUT);
    signal serial_state     : serial_state_t := SS_IDLE;
    signal sr_data          : std_logic_vector(63 downto 0) := (others => '0');
    signal sr_keep          : std_logic_vector(7 downto 0) := (others => '0');
    signal sr_first         : std_logic := '0';
    signal sr_last          : std_logic := '0';
    signal sr_lane          : integer range 0 to 8 := 0;  -- 8 = no valid lane
    signal sr_first_byte    : std_logic := '0';  -- First byte of first word

    -- Output signals
    signal out_valid        : std_logic := '0';
    signal out_data         : std_logic_vector(7 downto 0) := (others => '0');
    signal out_start        : std_logic := '0';
    signal out_end          : std_logic := '0';

    ----------------------------------------------------------------------------
    -- Statistics (independent counters)
    ----------------------------------------------------------------------------
    signal frame_cnt        : unsigned(31 downto 0) := (others => '0');
    signal frame_in_progress: std_logic := '0';
    signal error_cnt        : unsigned(31 downto 0) := (others => '0');
    signal start_det_cnt    : unsigned(31 downto 0) := (others => '0');

    ----------------------------------------------------------------------------
    -- Helper: find next valid lane from current position
    ----------------------------------------------------------------------------
    function next_valid_lane(keep : std_logic_vector(7 downto 0);
                             from_lane : integer) return integer is
    begin
        for i in 0 to 7 loop
            if i >= from_lane and keep(i) = '1' then
                return i;
            end if;
        end loop;
        return 8;  -- No more valid lanes
    end function;

    -- Helper: find last valid lane
    function last_valid_lane(keep : std_logic_vector(7 downto 0)) return integer is
    begin
        for i in 7 downto 0 loop
            if keep(i) = '1' then
                return i;
            end if;
        end loop;
        return -1;  -- No valid lanes
    end function;

begin

    -- FIFO status
    fifo_empty <= '1' when fifo_count = 0 else '0';
    fifo_full  <= '1' when fifo_count >= FIFO_DEPTH else '0';

    -- Registered read output extraction (rd_word set in FIFO process)
    rd_data  <= rd_word(73 downto 10);
    rd_keep  <= rd_word(9 downto 2);
    rd_first <= rd_word(1);
    rd_last  <= rd_word(0);

    -- Terminate detection in current XGMII word
    process(xgmii_rxd, xgmii_rxc)
    begin
        terminate_in_word <= '0';
        terminate_lane <= 0;
        for i in 0 to 7 loop
            if xgmii_rxc(i) = '1' and xgmii_rxd(i*8+7 downto i*8) = XGMII_TERM then
                terminate_in_word <= '1';
                terminate_lane <= i;
            end if;
        end loop;
    end process;

    ----------------------------------------------------------------------------
    -- XGMII Start detection counter (independent)
    ----------------------------------------------------------------------------
    process(clk)
        variable start_found : boolean;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                start_det_cnt <= (others => '0');
            elsif xgmii_rx_valid = '1' then
                start_found := false;
                for i in 0 to 7 loop
                    if xgmii_rxc(i) = '1' and
                       xgmii_rxd(i*8+7 downto i*8) = XGMII_START then
                        start_found := true;
                    end if;
                end loop;
                if start_found then
                    start_det_cnt <= start_det_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Frame counter: counts Start->Terminate pairs (independent)
    ----------------------------------------------------------------------------
    process(clk)
        variable saw_start : boolean;
        variable saw_term  : boolean;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                frame_cnt <= (others => '0');
                frame_in_progress <= '0';
            elsif xgmii_rx_valid = '1' then
                saw_start := false;
                saw_term := false;
                for i in 0 to 7 loop
                    if xgmii_rxc(i) = '1' then
                        if xgmii_rxd(i*8+7 downto i*8) = XGMII_START then
                            saw_start := true;
                        elsif xgmii_rxd(i*8+7 downto i*8) = XGMII_TERM then
                            saw_term := true;
                        end if;
                    end if;
                end loop;

                if saw_start then
                    frame_in_progress <= '1';
                end if;
                if saw_term and frame_in_progress = '1' then
                    frame_cnt <= frame_cnt + 1;
                    frame_in_progress <= '0';
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Payload FIFO: hand-coded Simple Dual-Port BRAM
    -- Write + registered read in single process = Xilinx SDP BRAM template.
    -- Registered read: rd_word gets fifo_mem(fifo_rd_ptr) on each clock edge.
    -- After asserting fifo_rd_en, data is available in rd_word on the NEXT cycle.
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            -- Registered read (BRAM output register, outside reset for inference)
            rd_word <= fifo_mem(to_integer(fifo_rd_ptr));

            if rst = '1' then
                fifo_wr_ptr <= (others => '0');
                fifo_rd_ptr <= (others => '0');
                fifo_count  <= (others => '0');
            else
                -- Write
                if fifo_wr_en = '1' and fifo_full = '0' then
                    fifo_mem(to_integer(fifo_wr_ptr)) <= wr_data & wr_keep & wr_first & wr_last;
                    fifo_wr_ptr <= fifo_wr_ptr + 1;
                end if;

                -- Read pointer advance
                if fifo_rd_en = '1' and fifo_empty = '0' then
                    fifo_rd_ptr <= fifo_rd_ptr + 1;
                end if;

                -- Count
                if fifo_wr_en = '1' and fifo_full = '0' and
                   not (fifo_rd_en = '1' and fifo_empty = '0') then
                    fifo_count <= fifo_count + 1;
                elsif fifo_rd_en = '1' and fifo_empty = '0' and
                      not (fifo_wr_en = '1' and fifo_full = '0') then
                    fifo_count <= fifo_count - 1;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Word-based parser process
    ----------------------------------------------------------------------------
    process(clk)
        variable v_keep         : std_logic_vector(7 downto 0);
        variable v_bytes_this   : unsigned(15 downto 0);  -- Count of valid bytes (max 8)
        variable v_start_lane   : integer range 0 to 7;
        variable v_word_start   : unsigned(15 downto 0);  -- First byte offset of this word
        -- Pre-decoded from remaining_r (shared across all states, eliminates duplicate logic)
        variable v_rem_full     : std_logic;  -- '1' when remaining_r >= 8
        variable v_rem_keep     : std_logic_vector(7 downto 0);  -- Keep mask from remaining_r
        variable v_rem_bytes    : unsigned(3 downto 0);  -- Byte count (0-7 when partial, 8 when full)
        variable v_term_keep    : std_logic_vector(7 downto 0);  -- Keep mask from terminate_lane
    begin
        if rising_edge(clk) then
            if rst = '1' then
                parse_state <= PS_IDLE;
                word_cnt <= (others => '0');
                frame_active <= '0';
                frame_is_ipv4 <= '0';
                headers_valid <= '0';
                payload_written <= (others => '0');
                fifo_wr_en <= '0';
                error_cnt <= (others => '0');
                dst_mac_reg <= (others => '0');
                src_mac_reg <= (others => '0');
                ethertype_reg <= (others => '0');
                ip_ihl_reg <= (others => '0');
                ip_total_len_reg <= (others => '0');
                ip_protocol_reg <= (others => '0');
                ip_src_reg <= (others => '0');
                ip_dst_reg <= (others => '0');
                payload_start_byte <= (others => '0');
                payload_total <= (others => '0');
                remaining_r <= (others => '0');
            else
                -- Default
                fifo_wr_en <= '0';
                wr_first <= '0';
                wr_last <= '0';

                -- Pre-decode remaining_r (shared across all states)
                if remaining_r(15 downto 3) /= "0000000000000" then
                    v_rem_full := '1';
                    v_rem_keep := "11111111";
                    v_rem_bytes := to_unsigned(8, 4);
                else
                    v_rem_full := '0';
                    v_rem_bytes := resize(remaining_r(2 downto 0), 4);
                    case to_integer(remaining_r(2 downto 0)) is
                        when 0 => v_rem_keep := "00000000";
                        when 1 => v_rem_keep := "00000001";
                        when 2 => v_rem_keep := "00000011";
                        when 3 => v_rem_keep := "00000111";
                        when 4 => v_rem_keep := "00001111";
                        when 5 => v_rem_keep := "00011111";
                        when 6 => v_rem_keep := "00111111";
                        when 7 => v_rem_keep := "01111111";
                        when others => v_rem_keep := "00000000";
                    end case;
                end if;

                -- Pre-decode terminate keep mask
                v_term_keep := (others => '0');
                for i in 0 to 7 loop
                    if i < terminate_lane then
                        v_term_keep(i) := '1';
                    end if;
                end loop;

                -- CRITICAL: Only process XGMII data when PCS has a new block.
                -- The 64b66b gearbox drops valid ~1 in 33 clocks (66/64 ratio).
                -- During gaps, the decoder holds stale data on xgmii_rxd/rxc.
                -- Without this guard, stale words get processed as new data,
                -- causing 8-byte word duplication (~30% of packets).
                if xgmii_rx_valid = '1' then
                case parse_state is
                    when PS_IDLE =>
                        frame_active <= '0';
                        frame_is_ipv4 <= '0';
                        headers_valid <= '0';

                        -- Look for Start in lane 0 (10GbE: Start always in lane 0)
                        if xgmii_rxc(0) = '1' and
                           xgmii_rxd(7 downto 0) = XGMII_START then
                            parse_state <= PS_HEADER;
                            word_cnt <= (others => '0');
                            frame_active <= '1';
                            payload_written <= (others => '0');
                            remaining_r <= (others => '0');
                        end if;

                    when PS_HEADER =>
                        -- Extract header fields based on word counter
                        -- Each clock = one 8-byte XGMII word

                        case to_integer(word_cnt) is
                            when 0 =>
                                -- Bytes 0-7: DstMAC[0:5], SrcMAC[0:1]
                                -- Lane i = rxd(i*8+7 downto i*8)
                                dst_mac_reg(47 downto 40) <= xgmii_rxd(7 downto 0);
                                dst_mac_reg(39 downto 32) <= xgmii_rxd(15 downto 8);
                                dst_mac_reg(31 downto 24) <= xgmii_rxd(23 downto 16);
                                dst_mac_reg(23 downto 16) <= xgmii_rxd(31 downto 24);
                                dst_mac_reg(15 downto 8)  <= xgmii_rxd(39 downto 32);
                                dst_mac_reg(7 downto 0)   <= xgmii_rxd(47 downto 40);
                                src_mac_reg(47 downto 40) <= xgmii_rxd(55 downto 48);
                                src_mac_reg(39 downto 32) <= xgmii_rxd(63 downto 56);

                            when 1 =>
                                -- Bytes 8-15: SrcMAC[2:5], EtherType[0:1], IP[0:1]
                                src_mac_reg(31 downto 24) <= xgmii_rxd(7 downto 0);
                                src_mac_reg(23 downto 16) <= xgmii_rxd(15 downto 8);
                                src_mac_reg(15 downto 8)  <= xgmii_rxd(23 downto 16);
                                src_mac_reg(7 downto 0)   <= xgmii_rxd(31 downto 24);
                                -- EtherType (big-endian: MSB first on wire)
                                ethertype_reg(15 downto 8) <= xgmii_rxd(39 downto 32);
                                ethertype_reg(7 downto 0)  <= xgmii_rxd(47 downto 40);
                                -- IP byte 0: Version(4) + IHL(4) at lane 6
                                ip_ihl_reg <= unsigned(xgmii_rxd(51 downto 48));

                            when 2 =>
                                -- Bytes 16-23: IP TotalLen, ID, Flags, TTL, Protocol
                                -- IP Total Length at bytes 16-17 (lanes 0-1, big-endian)
                                ip_total_len_reg <= unsigned(std_logic_vector'(xgmii_rxd(7 downto 0) & xgmii_rxd(15 downto 8)));
                                -- IP Protocol at byte 23 (lane 7)
                                ip_protocol_reg <= xgmii_rxd(63 downto 56);

                                -- Sufficient info available to compute payload bounds
                                -- payload_start_byte = 14 + IHL*4
                                payload_start_byte <= to_unsigned(14, 8) +
                                    resize(unsigned(std_logic_vector'(std_logic_vector(ip_ihl_reg) & "00")), 8);
                                -- payload_total = ip_total_len - IHL*4
                                payload_total <= unsigned(std_logic_vector'(xgmii_rxd(7 downto 0) & xgmii_rxd(15 downto 8))) -
                                    resize(unsigned(std_logic_vector'(std_logic_vector(ip_ihl_reg) & "00")), 16);
                                -- remaining_r = payload_total (since payload_written = 0 at this point)
                                remaining_r <= unsigned(std_logic_vector'(xgmii_rxd(7 downto 0) & xgmii_rxd(15 downto 8))) -
                                    resize(unsigned(std_logic_vector'(std_logic_vector(ip_ihl_reg) & "00")), 16);

                                -- Check EtherType
                                if ethertype_reg = ETHERTYPE_IPV4 then
                                    frame_is_ipv4 <= '1';
                                    headers_valid <= '1';
                                else
                                    -- Not IPv4, skip this frame
                                    parse_state <= PS_DONE;
                                end if;

                            when 3 =>
                                -- Bytes 24-31: Checksum, SrcIP[0:3], DstIP[0:1]
                                -- SrcIP at bytes 26-29 (lanes 2-5)
                                ip_src_reg(31 downto 24) <= xgmii_rxd(23 downto 16);
                                ip_src_reg(23 downto 16) <= xgmii_rxd(31 downto 24);
                                ip_src_reg(15 downto 8)  <= xgmii_rxd(39 downto 32);
                                ip_src_reg(7 downto 0)   <= xgmii_rxd(47 downto 40);
                                -- DstIP bytes 30-31 (lanes 6-7)
                                ip_dst_reg(31 downto 24) <= xgmii_rxd(55 downto 48);
                                ip_dst_reg(23 downto 16) <= xgmii_rxd(63 downto 56);

                            when 4 =>
                                -- Bytes 32-39: DstIP[2:3] at lanes 0-1, then payload
                                ip_dst_reg(15 downto 8)  <= xgmii_rxd(7 downto 0);
                                ip_dst_reg(7 downto 0)   <= xgmii_rxd(15 downto 8);

                                -- For IHL=5: payload starts at byte 34 (lane 2)
                                -- For IHL=6: payload starts at byte 38 (lane 6)
                                -- For IHL>=7: payload not in this word
                                if frame_is_ipv4 = '1' and
                                   payload_start_byte >= 32 and payload_start_byte <= 39 then
                                    -- Payload starts in this word
                                    v_start_lane := to_integer(payload_start_byte(2 downto 0));

                                    -- Build keep mask using pre-decoded remaining
                                    v_keep := (others => '0');
                                    if v_rem_full = '1' then
                                        -- remaining >= 8: all lanes from start valid
                                        for i in 0 to 7 loop
                                            if i >= v_start_lane then
                                                v_keep(i) := '1';
                                            end if;
                                        end loop;
                                    else
                                        -- remaining < 8: 4-bit comparison (not 16-bit)
                                        for i in 0 to 7 loop
                                            if i >= v_start_lane then
                                                if to_unsigned(i - v_start_lane, 4) < v_rem_bytes then
                                                    v_keep(i) := '1';
                                                end if;
                                            end if;
                                        end loop;
                                    end if;
                                    -- Bound by terminate
                                    if terminate_in_word = '1' then
                                        v_keep := v_keep and v_term_keep;
                                    end if;

                                    -- Popcount (tree, not serial)
                                    v_bytes_this := (others => '0');
                                    for i in 0 to 7 loop
                                        if v_keep(i) = '1' then
                                            v_bytes_this := v_bytes_this + 1;
                                        end if;
                                    end loop;

                                    if v_keep /= "00000000" then
                                        wr_data <= xgmii_rxd;
                                        wr_keep <= v_keep;
                                        wr_first <= '1';
                                        if terminate_in_word = '1' or v_rem_full = '0' then
                                            wr_last <= '1';
                                            parse_state <= PS_DONE;
                                        else
                                            parse_state <= PS_PAYLOAD;
                                        end if;
                                        fifo_wr_en <= '1';
                                        payload_written <= payload_written + v_bytes_this;
                                        remaining_r <= remaining_r - v_bytes_this;
                                    else
                                        -- No valid payload bytes (frame too short or early terminate)
                                        parse_state <= PS_DONE;
                                    end if;

                                elsif frame_is_ipv4 = '1' and payload_start_byte >= 40 then
                                    -- IHL > 6: payload hasn't started yet, stay in HEADER
                                    null;
                                end if;

                            when others =>
                                -- Words 5+: either still in IP options or in payload
                                v_word_start := shift_left(resize(word_cnt, 16), 3);  -- word_cnt * 8

                                if frame_is_ipv4 = '1' then
                                    if v_word_start + 7 < resize(payload_start_byte, 16) then
                                        -- Still in IP options (IHL > 5), skip
                                        null;
                                    elsif v_word_start >= resize(payload_start_byte, 16) then
                                        -- Full payload word
                                        parse_state <= PS_PAYLOAD;

                                        -- Full payload word (uses pre-decoded remaining variables)
                                        if terminate_in_word = '1' then
                                            v_keep := v_term_keep and v_rem_keep;
                                            v_bytes_this := (others => '0');
                                            for i in 0 to 7 loop
                                                if v_keep(i) = '1' then
                                                    v_bytes_this := v_bytes_this + 1;
                                                end if;
                                            end loop;
                                        elsif v_rem_full = '1' then
                                            v_keep := "11111111";
                                            v_bytes_this := to_unsigned(8, 16);
                                        else
                                            v_keep := v_rem_keep;
                                            v_bytes_this := resize(v_rem_bytes, 16);
                                        end if;

                                        if v_keep /= "00000000" then
                                            wr_data <= xgmii_rxd;
                                            wr_keep <= v_keep;
                                            wr_first <= '1';  -- First payload write
                                            if v_rem_full = '0' or
                                               terminate_in_word = '1' then
                                                wr_last <= '1';
                                                parse_state <= PS_DONE;
                                            end if;
                                            fifo_wr_en <= '1';
                                            payload_written <= payload_written + v_bytes_this;
                                            remaining_r <= remaining_r - v_bytes_this;
                                        else
                                            parse_state <= PS_DONE;
                                        end if;
                                    else
                                        -- Partial: payload starts mid-word
                                        v_start_lane := to_integer(payload_start_byte(2 downto 0));
                                        -- Build keep mask using pre-decoded remaining
                                        v_keep := (others => '0');
                                        if v_rem_full = '1' then
                                            -- remaining >= 8: all lanes from start valid
                                            for i in 0 to 7 loop
                                                if i >= v_start_lane then
                                                    v_keep(i) := '1';
                                                end if;
                                            end loop;
                                        else
                                            -- remaining < 8: 4-bit comparison (not 16-bit)
                                            for i in 0 to 7 loop
                                                if i >= v_start_lane then
                                                    if to_unsigned(i - v_start_lane, 4) < v_rem_bytes then
                                                        v_keep(i) := '1';
                                                    end if;
                                                end if;
                                            end loop;
                                        end if;
                                        -- Bound by terminate
                                        if terminate_in_word = '1' then
                                            v_keep := v_keep and v_term_keep;
                                        end if;

                                        -- Popcount (tree)
                                        v_bytes_this := (others => '0');
                                        for i in 0 to 7 loop
                                            if v_keep(i) = '1' then
                                                v_bytes_this := v_bytes_this + 1;
                                            end if;
                                        end loop;

                                        if v_keep /= "00000000" then
                                            wr_data <= xgmii_rxd;
                                            wr_keep <= v_keep;
                                            wr_first <= '1';
                                            if terminate_in_word = '1' or v_rem_full = '0' then
                                                wr_last <= '1';
                                                parse_state <= PS_DONE;
                                            else
                                                parse_state <= PS_PAYLOAD;
                                            end if;
                                            fifo_wr_en <= '1';
                                            payload_written <= payload_written + v_bytes_this;
                                            remaining_r <= remaining_r - v_bytes_this;
                                        else
                                            parse_state <= PS_DONE;
                                        end if;
                                    end if;
                                else
                                    parse_state <= PS_DONE;
                                end if;
                        end case;

                        -- Abort on terminate during header (too short)
                        if terminate_in_word = '1' and parse_state = PS_HEADER then
                            if word_cnt < 4 or (word_cnt = 4 and frame_is_ipv4 = '0') then
                                error_cnt <= error_cnt + 1;
                                parse_state <= PS_IDLE;
                            end if;
                        end if;

                        word_cnt <= word_cnt + 1;

                    when PS_PAYLOAD =>
                        -- Full payload words: write to FIFO
                        -- Uses pre-decoded remaining_r variables (shared with header states)

                        if terminate_in_word = '1' then
                            -- Terminate: AND terminate mask with remaining mask
                            v_keep := v_term_keep and v_rem_keep;
                            -- Popcount for intersection
                            v_bytes_this := (others => '0');
                            for i in 0 to 7 loop
                                if v_keep(i) = '1' then
                                    v_bytes_this := v_bytes_this + 1;
                                end if;
                            end loop;
                        elsif v_rem_full = '1' then
                            -- Full word: remaining >= 8
                            v_keep := "11111111";
                            v_bytes_this := to_unsigned(8, 16);
                        else
                            -- Last partial word: use pre-decoded keep mask
                            v_keep := v_rem_keep;
                            v_bytes_this := resize(v_rem_bytes, 16);
                        end if;

                        if v_keep /= "00000000" then
                            wr_data <= xgmii_rxd;
                            wr_keep <= v_keep;
                            wr_first <= '0';
                            if v_rem_full = '0' or
                               terminate_in_word = '1' then
                                wr_last <= '1';
                                parse_state <= PS_DONE;
                            end if;
                            fifo_wr_en <= '1';
                            payload_written <= payload_written + v_bytes_this;
                            remaining_r <= remaining_r - v_bytes_this;
                        else
                            -- No more payload bytes
                            parse_state <= PS_DONE;
                        end if;

                        word_cnt <= word_cnt + 1;

                    when PS_DONE =>
                        -- Wait for next Start (Terminate already handled or will appear)
                        frame_active <= '0';
                        if xgmii_rxc(0) = '1' and
                           xgmii_rxd(7 downto 0) = XGMII_START then
                            -- Back-to-back frame
                            parse_state <= PS_HEADER;
                            word_cnt <= (others => '0');
                            frame_active <= '1';
                            frame_is_ipv4 <= '0';
                            headers_valid <= '0';
                            payload_written <= (others => '0');
                            remaining_r <= (others => '0');
                        else
                            parse_state <= PS_IDLE;
                        end if;
                end case;

                -- Error detection
                for i in 0 to 7 loop
                    if xgmii_rxc(i) = '1' and
                       xgmii_rxd(i*8+7 downto i*8) = XGMII_ERROR and
                       parse_state /= PS_IDLE then
                        error_cnt <= error_cnt + 1;
                        parse_state <= PS_IDLE;
                        frame_active <= '0';
                    end if;
                end loop;
                end if;  -- xgmii_rx_valid
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Byte serializer: reads from FIFO, outputs 1 byte/clock
    ----------------------------------------------------------------------------
    process(clk)
        variable v_next_lane : integer range 0 to 8;
        variable v_last_lane : integer range -1 to 7;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                serial_state <= SS_IDLE;
                sr_lane <= 0;
                out_valid <= '0';
                out_start <= '0';
                out_end <= '0';
                fifo_rd_en <= '0';
                sr_first_byte <= '0';
            else
                -- Defaults
                out_valid <= '0';
                out_start <= '0';
                out_end <= '0';
                fifo_rd_en <= '0';

                case serial_state is
                    when SS_IDLE =>
                        if fifo_empty = '0' then
                            -- Initiate BRAM read (data available next cycle)
                            fifo_rd_en <= '1';
                            serial_state <= SS_LOAD;
                        end if;

                    when SS_LOAD =>
                        -- rd_word now has valid data (registered BRAM output)
                        sr_data <= rd_data;
                        sr_keep <= rd_keep;
                        sr_first <= rd_first;
                        sr_last <= rd_last;
                        sr_lane <= next_valid_lane(rd_keep, 0);
                        sr_first_byte <= rd_first;
                        serial_state <= SS_OUTPUT;

                    when SS_OUTPUT =>
                        if sr_lane <= 7 then
                            if sr_keep(sr_lane) = '1' then
                                -- Output this byte
                                out_valid <= '1';
                                case sr_lane is
                                    when 0 => out_data <= sr_data(7 downto 0);
                                    when 1 => out_data <= sr_data(15 downto 8);
                                    when 2 => out_data <= sr_data(23 downto 16);
                                    when 3 => out_data <= sr_data(31 downto 24);
                                    when 4 => out_data <= sr_data(39 downto 32);
                                    when 5 => out_data <= sr_data(47 downto 40);
                                    when 6 => out_data <= sr_data(55 downto 48);
                                    when 7 => out_data <= sr_data(63 downto 56);
                                    when others => out_data <= (others => '0');
                                end case;

                                -- Start pulse on first byte of first word
                                if sr_first_byte = '1' then
                                    out_start <= '1';
                                    sr_first_byte <= '0';
                                end if;

                                -- Find next valid lane
                                v_next_lane := next_valid_lane(sr_keep, sr_lane + 1);

                                if v_next_lane > 7 then
                                    -- No more valid bytes in this word
                                    if sr_last = '1' then
                                        -- End of payload
                                        out_end <= '1';
                                        serial_state <= SS_IDLE;
                                    else
                                        -- Need next word: initiate BRAM read
                                        if fifo_empty = '0' then
                                            fifo_rd_en <= '1';
                                            serial_state <= SS_LOAD;
                                        else
                                            -- FIFO empty, wait
                                            serial_state <= SS_IDLE;
                                        end if;
                                    end if;
                                else
                                    sr_lane <= v_next_lane;
                                end if;
                            else
                                -- Current lane not valid, find next
                                v_next_lane := next_valid_lane(sr_keep, sr_lane + 1);
                                if v_next_lane > 7 then
                                    serial_state <= SS_IDLE;
                                else
                                    sr_lane <= v_next_lane;
                                end if;
                            end if;
                        else
                            -- sr_lane = 8 (no valid lane found), go idle
                            serial_state <= SS_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Output assignments
    ----------------------------------------------------------------------------
    ip_payload_valid <= out_valid;
    ip_payload_data  <= out_data;
    ip_payload_start <= out_start;
    ip_payload_end   <= out_end;

    ip_protocol <= ip_protocol_reg;
    ip_src_addr <= ip_src_reg;
    ip_dst_addr <= ip_dst_reg;

    eth_dst_mac <= dst_mac_reg;
    eth_src_mac <= src_mac_reg;
    eth_type    <= ethertype_reg;

    frame_valid <= frame_active;
    frame_error <= '1' when parse_state = PS_DONE and error_cnt > 0 else '0';
    crc_error   <= '0';  -- CRC check not implemented

    frame_count        <= std_logic_vector(frame_cnt);
    error_count        <= std_logic_vector(error_cnt);
    start_detect_count <= std_logic_vector(start_det_cnt);

end rtl;
