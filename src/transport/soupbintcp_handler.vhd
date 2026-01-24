--------------------------------------------------------------------------------
-- Module: soupbintcp_handler
-- Description: SoupBinTCP session layer handler for ASX ITCH/OUCH
--
-- SoupBinTCP is a simple framing protocol used by Nasdaq-based exchanges (ASX)
-- for market data (ITCH) and order entry (OUCH) over TCP.
--
-- Packet Format:
--   [Packet Length: 2 bytes, big-endian] [Packet Type: 1 byte] [Payload: N bytes]
--   Note: Packet Length includes Packet Type but excludes the length field itself
--
-- Server -> Client Message Types:
--   '+' (0x2B): Debug Packet (variable length)
--   'A' (0x41): Login Accepted (30 bytes payload)
--   'H' (0x48): Server Heartbeat (0 bytes payload)
--   'J' (0x4A): Login Rejected (1 byte payload: reason code)
--   'S' (0x53): Sequenced Data (variable: ITCH message)
--   'U' (0x55): Unsequenced Data (variable)
--   'Z' (0x5A): End of Session (0 bytes payload)
--
-- Client -> Server Message Types (for TX path):
--   'L' (0x4C): Login Request
--   'O' (0x4F): Logout Request
--   'R' (0x52): Client Heartbeat
--   'U' (0x55): Unsequenced Data (OUCH orders)
--
-- This module handles RX path: parses incoming SoupBinTCP packets and
-- extracts ITCH messages from Sequenced Data packets.
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

entity soupbintcp_handler is
    port (
        clk                 : in  std_logic;
        rst                 : in  std_logic;

        -- TCP payload interface (from tcp_parser)
        tcp_payload_valid   : in  std_logic;
        tcp_payload_data    : in  std_logic_vector(7 downto 0);
        tcp_payload_start   : in  std_logic;
        tcp_payload_end     : in  std_logic;

        -- ITCH message interface (to asx_itch_parser)
        itch_msg_valid      : out std_logic;
        itch_msg_data       : out std_logic_vector(7 downto 0);
        itch_msg_start      : out std_logic;  -- First byte of ITCH message
        itch_msg_end        : out std_logic;  -- Last byte of ITCH message

        -- Session status
        session_active      : out std_logic;  -- Login accepted
        session_sequence    : out std_logic_vector(63 downto 0);  -- Message sequence

        -- Packet type outputs (for monitoring/debug)
        pkt_type            : out std_logic_vector(7 downto 0);
        pkt_type_valid      : out std_logic;
        pkt_heartbeat       : out std_logic;  -- Server heartbeat received
        pkt_login_accepted  : out std_logic;  -- Login accepted
        pkt_login_rejected  : out std_logic;  -- Login rejected
        pkt_end_session     : out std_logic;  -- Session ended

        -- Statistics
        seq_data_count      : out std_logic_vector(31 downto 0);  -- Sequenced data packets
        heartbeat_count     : out std_logic_vector(31 downto 0);  -- Heartbeats received

        -- Error status
        parse_error         : out std_logic
    );
end soupbintcp_handler;

architecture rtl of soupbintcp_handler is

    -- SoupBinTCP packet types (server -> client)
    -- Using SOUP_ prefix to avoid conflict with output port names (VHDL is case-insensitive)
    constant SOUP_DEBUG          : std_logic_vector(7 downto 0) := x"2B";  -- '+'
    constant SOUP_LOGIN_ACCEPTED : std_logic_vector(7 downto 0) := x"41";  -- 'A'
    constant SOUP_HEARTBEAT      : std_logic_vector(7 downto 0) := x"48";  -- 'H'
    constant SOUP_LOGIN_REJECTED : std_logic_vector(7 downto 0) := x"4A";  -- 'J'
    constant SOUP_SEQ_DATA       : std_logic_vector(7 downto 0) := x"53";  -- 'S'
    constant SOUP_UNSEQ_DATA     : std_logic_vector(7 downto 0) := x"55";  -- 'U'
    constant SOUP_END_SESSION    : std_logic_vector(7 downto 0) := x"5A";  -- 'Z'

    -- State machine
    type state_type is (
        IDLE,
        READ_LENGTH_MSB,
        READ_LENGTH_LSB,
        READ_TYPE,
        READ_PAYLOAD,
        SKIP_PAYLOAD,
        ERROR_STATE
    );
    signal state : state_type := IDLE;

    -- Packet parsing
    signal pkt_length       : unsigned(15 downto 0) := (others => '0');
    signal pkt_type_reg     : std_logic_vector(7 downto 0) := (others => '0');
    signal payload_cnt      : unsigned(15 downto 0) := (others => '0');
    signal payload_len      : unsigned(15 downto 0) := (others => '0');  -- pkt_length - 1 (excluding type)

    -- Session state
    signal session_active_reg   : std_logic := '0';
    signal session_seq_reg      : unsigned(63 downto 0) := (others => '0');

    -- Statistics
    signal seq_data_cnt     : unsigned(31 downto 0) := (others => '0');
    signal heartbeat_cnt    : unsigned(31 downto 0) := (others => '0');

    -- Internal flags
    signal is_seq_data      : std_logic := '0';
    signal first_payload    : std_logic := '0';

begin

    -- Main parsing state machine
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= IDLE;
                pkt_length <= (others => '0');
                pkt_type_reg <= (others => '0');
                payload_cnt <= (others => '0');
                payload_len <= (others => '0');
                session_active_reg <= '0';
                session_seq_reg <= (others => '0');
                seq_data_cnt <= (others => '0');
                heartbeat_cnt <= (others => '0');
                is_seq_data <= '0';
                first_payload <= '0';
            else
                -- Default pulse signals
                itch_msg_valid <= '0';
                itch_msg_start <= '0';
                itch_msg_end <= '0';
                pkt_type_valid <= '0';
                pkt_heartbeat <= '0';
                pkt_login_accepted <= '0';
                pkt_login_rejected <= '0';
                pkt_end_session <= '0';
                parse_error <= '0';

                case state is
                    when IDLE =>
                        is_seq_data <= '0';
                        first_payload <= '0';

                        -- Wait for TCP payload start
                        if tcp_payload_start = '1' and tcp_payload_valid = '1' then
                            -- First byte is Length MSB
                            pkt_length(15 downto 8) <= unsigned(tcp_payload_data);
                            state <= READ_LENGTH_LSB;
                        elsif tcp_payload_valid = '1' then
                            -- Continue from previous packet (multiple SoupBinTCP in one TCP segment)
                            pkt_length(15 downto 8) <= unsigned(tcp_payload_data);
                            state <= READ_LENGTH_LSB;
                        end if;

                    when READ_LENGTH_MSB =>
                        if tcp_payload_valid = '1' then
                            pkt_length(15 downto 8) <= unsigned(tcp_payload_data);
                            state <= READ_LENGTH_LSB;
                        end if;

                    when READ_LENGTH_LSB =>
                        if tcp_payload_valid = '1' then
                            pkt_length(7 downto 0) <= unsigned(tcp_payload_data);
                            state <= READ_TYPE;
                        end if;

                    when READ_TYPE =>
                        if tcp_payload_valid = '1' then
                            pkt_type_reg <= tcp_payload_data;
                            pkt_type_valid <= '1';

                            -- Calculate payload length (packet length - 1 for type byte)
                            payload_len <= pkt_length - 1;
                            payload_cnt <= (others => '0');

                            -- Handle different packet types
                            case tcp_payload_data is
                                when SOUP_HEARTBEAT =>
                                    -- Heartbeat has no payload
                                    pkt_heartbeat <= '1';
                                    heartbeat_cnt <= heartbeat_cnt + 1;
                                    state <= IDLE;

                                when SOUP_LOGIN_ACCEPTED =>
                                    -- Login accepted (30 byte payload with session info)
                                    pkt_login_accepted <= '1';
                                    session_active_reg <= '1';
                                    if pkt_length > 1 then
                                        state <= SKIP_PAYLOAD;  -- Skip session info for now
                                    else
                                        state <= IDLE;
                                    end if;

                                when SOUP_LOGIN_REJECTED =>
                                    -- Login rejected (1 byte reason code)
                                    pkt_login_rejected <= '1';
                                    session_active_reg <= '0';
                                    if pkt_length > 1 then
                                        state <= SKIP_PAYLOAD;
                                    else
                                        state <= IDLE;
                                    end if;

                                when SOUP_END_SESSION =>
                                    -- Session ended
                                    pkt_end_session <= '1';
                                    session_active_reg <= '0';
                                    state <= IDLE;

                                when SOUP_SEQ_DATA =>
                                    -- Sequenced Data contains ITCH message
                                    is_seq_data <= '1';
                                    first_payload <= '1';
                                    seq_data_cnt <= seq_data_cnt + 1;
                                    session_seq_reg <= session_seq_reg + 1;
                                    if pkt_length > 1 then
                                        state <= READ_PAYLOAD;
                                    else
                                        state <= IDLE;  -- Empty payload (shouldn't happen)
                                    end if;

                                when SOUP_UNSEQ_DATA =>
                                    -- Unsequenced data (ignore for market data)
                                    if pkt_length > 1 then
                                        state <= SKIP_PAYLOAD;
                                    else
                                        state <= IDLE;
                                    end if;

                                when SOUP_DEBUG =>
                                    -- Debug message (skip)
                                    if pkt_length > 1 then
                                        state <= SKIP_PAYLOAD;
                                    else
                                        state <= IDLE;
                                    end if;

                                when others =>
                                    -- Unknown packet type
                                    parse_error <= '1';
                                    if pkt_length > 1 then
                                        state <= SKIP_PAYLOAD;
                                    else
                                        state <= IDLE;
                                    end if;
                            end case;
                        end if;

                    when READ_PAYLOAD =>
                        -- Pass through ITCH message data
                        if tcp_payload_valid = '1' then
                            itch_msg_valid <= '1';
                            itch_msg_data <= tcp_payload_data;

                            -- First byte of ITCH message
                            if first_payload = '1' then
                                itch_msg_start <= '1';
                                first_payload <= '0';
                            end if;

                            payload_cnt <= payload_cnt + 1;

                            -- Check for last byte
                            if payload_cnt >= payload_len - 1 then
                                itch_msg_end <= '1';
                                state <= IDLE;
                            end if;

                            -- Handle TCP segment end during payload
                            if tcp_payload_end = '1' then
                                if payload_cnt < payload_len - 1 then
                                    -- Payload spans multiple TCP segments (shouldn't happen normally)
                                    -- For now, treat as end of message
                                    itch_msg_end <= '1';
                                end if;
                                state <= IDLE;
                            end if;
                        end if;

                    when SKIP_PAYLOAD =>
                        -- Skip unwanted payload bytes
                        if tcp_payload_valid = '1' then
                            payload_cnt <= payload_cnt + 1;

                            if payload_cnt >= payload_len - 1 then
                                state <= IDLE;
                            end if;

                            if tcp_payload_end = '1' then
                                state <= IDLE;
                            end if;
                        end if;

                    when ERROR_STATE =>
                        -- Wait for end of TCP segment
                        if tcp_payload_end = '1' then
                            state <= IDLE;
                        end if;
                end case;

                -- Handle unexpected end
                if tcp_payload_end = '1' and state /= IDLE then
                    if state = READ_PAYLOAD and is_seq_data = '1' then
                        -- End ITCH message at TCP segment boundary
                        itch_msg_end <= '1';
                    end if;
                    state <= IDLE;
                end if;
            end if;
        end if;
    end process;

    -- Output assignments
    session_active <= session_active_reg;
    session_sequence <= std_logic_vector(session_seq_reg);
    pkt_type <= pkt_type_reg;
    seq_data_count <= std_logic_vector(seq_data_cnt);
    heartbeat_count <= std_logic_vector(heartbeat_cnt);

end rtl;
