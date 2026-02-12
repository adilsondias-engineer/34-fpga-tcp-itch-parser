--------------------------------------------------------------------------------
-- Module: moldudp64_handler
-- Description: MoldUDP64 session layer handler for NASDAQ ITCH
--
-- MoldUDP64 Packet Format:
--   Session ID:      10 bytes (ASCII)
--   Sequence Number:  8 bytes (big-endian uint64)
--   Message Count:    2 bytes (big-endian uint16)
--   Messages:        variable
--     - Message Length: 2 bytes (big-endian uint16)
--     - Message Data:   variable
--
-- This handler:
--   - Parses MoldUDP64 header (session, sequence, count)
--   - Extracts individual ITCH messages
--   - Outputs messages to NASDAQ ITCH parser
--   - Tracks sequence numbers for gap detection
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

entity moldudp64_handler is
    port (
        clk                 : in  std_logic;  -- 156.25 MHz XGMII clock
        rst                 : in  std_logic;

        -- UDP payload input (from protocol demux)
        udp_payload_valid   : in  std_logic;
        udp_payload_data    : in  std_logic_vector(7 downto 0);
        udp_payload_start   : in  std_logic;
        udp_payload_end     : in  std_logic;

        -- ITCH message output (to NASDAQ ITCH parser)
        itch_msg_valid      : out std_logic;
        itch_msg_data       : out std_logic_vector(7 downto 0);
        itch_msg_start      : out std_logic;
        itch_msg_end        : out std_logic;

        -- Session information
        session_id          : out std_logic_vector(79 downto 0);  -- 10 bytes
        sequence_number     : out std_logic_vector(63 downto 0);
        message_count       : out std_logic_vector(15 downto 0);

        -- Status
        session_valid       : out std_logic;
        sequence_gap        : out std_logic;  -- Gap detected
        gap_count           : out std_logic_vector(31 downto 0);

        -- Statistics
        packet_count        : out std_logic_vector(31 downto 0);
        msg_extracted       : out std_logic_vector(31 downto 0)
    );
end moldudp64_handler;

architecture rtl of moldudp64_handler is

    -- MoldUDP64 header offsets
    constant SESSION_ID_LEN     : integer := 10;
    constant SEQUENCE_NUM_LEN   : integer := 8;
    constant MSG_COUNT_LEN      : integer := 2;
    constant HEADER_LEN         : integer := SESSION_ID_LEN + SEQUENCE_NUM_LEN + MSG_COUNT_LEN;  -- 20 bytes
    constant MSG_LEN_FIELD      : integer := 2;  -- 2-byte message length prefix

    -- State machine
    type state_type is (
        IDLE,
        PARSE_SESSION_ID,
        PARSE_SEQUENCE_NUM,
        PARSE_MSG_COUNT,
        PARSE_MSG_LEN,
        FORWARD_MSG_DATA,
        PACKET_END,
        ERROR_STATE
    );
    signal state : state_type := IDLE;

    -- Header parsing registers
    signal session_id_reg       : std_logic_vector(79 downto 0) := (others => '0');
    signal sequence_num_reg     : std_logic_vector(63 downto 0) := (others => '0');
    signal msg_count_reg        : std_logic_vector(15 downto 0) := (others => '0');
    signal expected_seq         : std_logic_vector(63 downto 0) := (others => '0');
    signal seq_initialized      : std_logic := '0';

    -- Message extraction
    signal current_msg_len      : unsigned(15 downto 0) := (others => '0');
    signal msg_byte_cnt         : unsigned(15 downto 0) := (others => '0');
    signal msgs_remaining       : unsigned(15 downto 0) := (others => '0');
    signal header_byte_cnt      : unsigned(7 downto 0) := (others => '0');

    -- Statistics
    signal pkt_count            : unsigned(31 downto 0) := (others => '0');
    signal msg_count_stat       : unsigned(31 downto 0) := (others => '0');
    signal gap_cnt              : unsigned(31 downto 0) := (others => '0');

    -- Output signals
    signal out_valid            : std_logic := '0';
    signal out_data             : std_logic_vector(7 downto 0) := (others => '0');
    signal out_start            : std_logic := '0';
    signal out_end              : std_logic := '0';
    signal gap_detected         : std_logic := '0';
    signal msg_first_byte       : std_logic := '0';  -- Flag: next data byte gets start pulse
    
     -- Force replication
    attribute MAX_FANOUT : integer;
    attribute MAX_FANOUT of out_data: signal is 16;
    attribute MAX_FANOUT of out_start: signal is 16;
    attribute MAX_FANOUT of out_end: signal is 16;
    attribute MAX_FANOUT of out_valid: signal is 16;
    attribute MAX_FANOUT of itch_msg_valid: signal is 16;
    attribute MAX_FANOUT of itch_msg_data: signal is 16;
    attribute MAX_FANOUT of itch_msg_start: signal is 16;
    attribute MAX_FANOUT of itch_msg_end: signal is 16;
    attribute MAX_FANOUT of session_id: signal is 16;
    attribute MAX_FANOUT of sequence_number: signal is 16;
    attribute MAX_FANOUT of message_count: signal is 16;
    attribute MAX_FANOUT of session_valid: signal is 16;
    attribute MAX_FANOUT of sequence_gap: signal is 16;
         
begin

    -- Main processing
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= IDLE;
                header_byte_cnt <= (others => '0');
                msg_byte_cnt <= (others => '0');
                current_msg_len <= (others => '0');
                msgs_remaining <= (others => '0');
                pkt_count <= (others => '0');
                msg_count_stat <= (others => '0');
                gap_cnt <= (others => '0');
                seq_initialized <= '0';
                out_valid <= '0';
                out_start <= '0';
                out_end <= '0';
                gap_detected <= '0';
                msg_first_byte <= '0';
            else
                -- Default: clear pulse signals
                out_start <= '0';
                out_end <= '0';
                out_valid <= '0';
                gap_detected <= '0';

                case state is
                    when IDLE =>
                        if udp_payload_start = '1' and udp_payload_valid = '1' then
                            -- Start of new MoldUDP64 packet
                            state <= PARSE_SESSION_ID;
                            header_byte_cnt <= to_unsigned(0, 8);
                            -- First byte is session ID byte 0
                            session_id_reg(79 downto 72) <= udp_payload_data;
                            header_byte_cnt <= to_unsigned(1, 8);
                        end if;

                    when PARSE_SESSION_ID =>
                        if udp_payload_valid = '1' then
                            -- Collect session ID bytes (10 total)
                            case to_integer(header_byte_cnt) is
                                when 1 => session_id_reg(71 downto 64) <= udp_payload_data;
                                when 2 => session_id_reg(63 downto 56) <= udp_payload_data;
                                when 3 => session_id_reg(55 downto 48) <= udp_payload_data;
                                when 4 => session_id_reg(47 downto 40) <= udp_payload_data;
                                when 5 => session_id_reg(39 downto 32) <= udp_payload_data;
                                when 6 => session_id_reg(31 downto 24) <= udp_payload_data;
                                when 7 => session_id_reg(23 downto 16) <= udp_payload_data;
                                when 8 => session_id_reg(15 downto 8) <= udp_payload_data;
                                when 9 =>
                                    session_id_reg(7 downto 0) <= udp_payload_data;
                                    state <= PARSE_SEQUENCE_NUM;
                                    header_byte_cnt <= (others => '0');
                                when others => null;
                            end case;

                            if header_byte_cnt < 9 then
                                header_byte_cnt <= header_byte_cnt + 1;
                            end if;
                        end if;

                        if udp_payload_end = '1' then
                            state <= ERROR_STATE;
                        end if;

                    when PARSE_SEQUENCE_NUM =>
                        if udp_payload_valid = '1' then
                            -- Collect sequence number (8 bytes, big-endian)
                            case to_integer(header_byte_cnt) is
                                when 0 => sequence_num_reg(63 downto 56) <= udp_payload_data;
                                when 1 => sequence_num_reg(55 downto 48) <= udp_payload_data;
                                when 2 => sequence_num_reg(47 downto 40) <= udp_payload_data;
                                when 3 => sequence_num_reg(39 downto 32) <= udp_payload_data;
                                when 4 => sequence_num_reg(31 downto 24) <= udp_payload_data;
                                when 5 => sequence_num_reg(23 downto 16) <= udp_payload_data;
                                when 6 => sequence_num_reg(15 downto 8) <= udp_payload_data;
                                when 7 =>
                                    sequence_num_reg(7 downto 0) <= udp_payload_data;
                                    state <= PARSE_MSG_COUNT;
                                    header_byte_cnt <= (others => '0');
                                when others => null;
                            end case;

                            if header_byte_cnt < 7 then
                                header_byte_cnt <= header_byte_cnt + 1;
                            end if;
                        end if;

                        if udp_payload_end = '1' then
                            state <= ERROR_STATE;
                        end if;

                    when PARSE_MSG_COUNT =>
                        if udp_payload_valid = '1' then
                            -- Collect message count (2 bytes, big-endian)
                            case to_integer(header_byte_cnt) is
                                when 0 => msg_count_reg(15 downto 8) <= udp_payload_data;
                                when 1 =>
                                    msg_count_reg(7 downto 0) <= udp_payload_data;

                                    -- Check for sequence gap
                                    if seq_initialized = '1' then
                                        if sequence_num_reg /= expected_seq then
                                            gap_detected <= '1';
                                            gap_cnt <= gap_cnt + 1;
                                        end if;
                                    end if;
                                    seq_initialized <= '1';

                                    -- Update expected sequence for next packet
                                    expected_seq <= std_logic_vector(unsigned(sequence_num_reg) +
                                                                     unsigned(msg_count_reg(15 downto 8) & udp_payload_data));

                                    -- Set messages remaining
                                    msgs_remaining <= unsigned(msg_count_reg(15 downto 8) & udp_payload_data);

                                    -- If no messages, wait for packet end
                                    if msg_count_reg(15 downto 8) = x"00" and udp_payload_data = x"00" then
                                        state <= PACKET_END;
                                    else
                                        state <= PARSE_MSG_LEN;
                                        header_byte_cnt <= (others => '0');
                                    end if;

                                    pkt_count <= pkt_count + 1;
                                when others => null;
                            end case;

                            if header_byte_cnt < 1 then
                                header_byte_cnt <= header_byte_cnt + 1;
                            end if;
                        end if;

                        if udp_payload_end = '1' then
                            state <= ERROR_STATE;
                        end if;

                    when PARSE_MSG_LEN =>
                        if udp_payload_valid = '1' then
                            -- Parse 2-byte message length
                            case to_integer(header_byte_cnt) is
                                when 0 => current_msg_len(15 downto 8) <= unsigned(udp_payload_data);
                                when 1 =>
                                    current_msg_len(7 downto 0) <= unsigned(udp_payload_data);
                                    -- Guard: zero-length messages are invalid, skip them
                                    if current_msg_len(15 downto 8) = x"00" and unsigned(udp_payload_data) = 0 then
                                        msgs_remaining <= msgs_remaining - 1;
                                        if msgs_remaining <= 1 then
                                            state <= PACKET_END;
                                        else
                                            header_byte_cnt <= (others => '0');
                                            -- Stay in PARSE_MSG_LEN for next message
                                        end if;
                                    else
                                        state <= FORWARD_MSG_DATA;
                                        msg_byte_cnt <= (others => '0');
                                        msg_first_byte <= '1';  -- Next data byte gets start pulse
                                    end if;
                                when others => null;
                            end case;

                            if header_byte_cnt < 1 then
                                header_byte_cnt <= header_byte_cnt + 1;
                            end if;
                        end if;

                        if udp_payload_end = '1' then
                            state <= ERROR_STATE;
                        end if;

                    when FORWARD_MSG_DATA =>
                        if udp_payload_valid = '1' then
                            -- Forward message data to ITCH parser
                            out_valid <= '1';
                            out_data <= udp_payload_data;
                            msg_byte_cnt <= msg_byte_cnt + 1;

                            -- Emit start pulse with first data byte
                            if msg_first_byte = '1' then
                                out_start <= '1';
                                msg_first_byte <= '0';
                            end if;

                            -- Check if message complete
                            if msg_byte_cnt >= current_msg_len - 1 then
                                out_end <= '1';
                                msgs_remaining <= msgs_remaining - 1;
                                msg_count_stat <= msg_count_stat + 1;

                                if msgs_remaining <= 1 then
                                    state <= PACKET_END;
                                else
                                    state <= PARSE_MSG_LEN;
                                    header_byte_cnt <= (others => '0');
                                end if;
                            end if;
                        end if;

                        if udp_payload_end = '1' then
                            -- Packet ended, go to idle
                            if msg_byte_cnt < current_msg_len - 1 then
                                -- Incomplete message
                                state <= ERROR_STATE;
                            else
                                state <= IDLE;
                            end if;
                        end if;

                    when PACKET_END =>
                        -- Wait for UDP payload end
                        if udp_payload_end = '1' or udp_payload_valid = '0' then
                            state <= IDLE;
                        end if;

                    when ERROR_STATE =>
                        -- Handle error, return to idle
                        state <= IDLE;

                end case;
            end if;
        end if;
    end process;

    -- Output assignments
    itch_msg_valid <= out_valid;
    itch_msg_data <= out_data;
    itch_msg_start <= out_start;
    itch_msg_end <= out_end;

    session_id <= session_id_reg;
    sequence_number <= sequence_num_reg;
    message_count <= msg_count_reg;

    session_valid <= '1' when seq_initialized = '1' else '0';
    sequence_gap <= gap_detected;
    gap_count <= std_logic_vector(gap_cnt);

    packet_count <= std_logic_vector(pkt_count);
    msg_extracted <= std_logic_vector(msg_count_stat);

end rtl;
