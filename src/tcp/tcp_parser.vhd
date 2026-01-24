--------------------------------------------------------------------------------
-- Module: tcp_parser
-- Description: TCP segment parser for 10GbE ITCH feed processing
--
-- Parses TCP header from IP payload stream and extracts:
--   - Source/Destination ports
--   - Sequence number
--   - Acknowledgment number
--   - Flags (SYN, ACK, FIN, RST, PSH)
--   - Window size
--   - TCP payload
--
-- TCP Header Format (20 bytes minimum, up to 60 with options):
--   Offset 0-1:   Source Port (16-bit)
--   Offset 2-3:   Destination Port (16-bit)
--   Offset 4-7:   Sequence Number (32-bit)
--   Offset 8-11:  Acknowledgment Number (32-bit)
--   Offset 12:    Data Offset (4-bit, upper nibble) + Reserved (4-bit)
--   Offset 13:    Flags (8-bit: CWR,ECE,URG,ACK,PSH,RST,SYN,FIN)
--   Offset 14-15: Window Size (16-bit)
--   Offset 16-17: Checksum (16-bit)
--   Offset 18-19: Urgent Pointer (16-bit)
--   Offset 20+:   Options (variable, if Data Offset > 5)
--
-- Interface: Byte-stream input from IP parser, byte-stream output for payload
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

entity tcp_parser is
    port (
        clk                 : in  std_logic;
        rst                 : in  std_logic;

        -- IP payload interface (from IP parser)
        ip_payload_valid    : in  std_logic;
        ip_payload_data     : in  std_logic_vector(7 downto 0);
        ip_payload_start    : in  std_logic;  -- First byte of TCP segment
        ip_payload_end      : in  std_logic;  -- Last byte of TCP segment

        -- TCP header fields
        tcp_src_port        : out std_logic_vector(15 downto 0);
        tcp_dst_port        : out std_logic_vector(15 downto 0);
        tcp_seq_num         : out std_logic_vector(31 downto 0);
        tcp_ack_num         : out std_logic_vector(31 downto 0);
        tcp_data_offset     : out std_logic_vector(3 downto 0);  -- Header length in 32-bit words
        tcp_flags           : out std_logic_vector(7 downto 0);  -- CWR,ECE,URG,ACK,PSH,RST,SYN,FIN
        tcp_window          : out std_logic_vector(15 downto 0);

        -- TCP flag convenience outputs
        tcp_flag_syn        : out std_logic;
        tcp_flag_ack        : out std_logic;
        tcp_flag_fin        : out std_logic;
        tcp_flag_rst        : out std_logic;
        tcp_flag_psh        : out std_logic;

        -- TCP payload interface (to session handler)
        tcp_payload_valid   : out std_logic;
        tcp_payload_data    : out std_logic_vector(7 downto 0);
        tcp_payload_start   : out std_logic;  -- First byte of TCP payload
        tcp_payload_end     : out std_logic;  -- Last byte of TCP payload

        -- Status
        tcp_header_valid    : out std_logic;  -- Header fully parsed
        tcp_parse_error     : out std_logic   -- Parse error occurred
    );
end tcp_parser;

architecture rtl of tcp_parser is

    -- State machine
    type state_type is (
        IDLE,
        PARSE_HEADER,
        SKIP_OPTIONS,
        PAYLOAD,
        ERROR_STATE
    );
    signal state : state_type := IDLE;

    -- Byte counter
    signal byte_cnt : unsigned(5 downto 0) := (others => '0');  -- 0-63 (max TCP header)

    -- Header field registers
    signal src_port_reg     : std_logic_vector(15 downto 0) := (others => '0');
    signal dst_port_reg     : std_logic_vector(15 downto 0) := (others => '0');
    signal seq_num_reg      : std_logic_vector(31 downto 0) := (others => '0');
    signal ack_num_reg      : std_logic_vector(31 downto 0) := (others => '0');
    signal data_offset_reg  : std_logic_vector(3 downto 0) := (others => '0');
    signal flags_reg        : std_logic_vector(7 downto 0) := (others => '0');
    signal window_reg       : std_logic_vector(15 downto 0) := (others => '0');

    -- Header length in bytes (data_offset * 4)
    signal header_len       : unsigned(5 downto 0) := (others => '0');

    -- Internal signals
    signal header_done      : std_logic := '0';
    signal payload_active   : std_logic := '0';

begin

    -- Main parsing state machine
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= IDLE;
                byte_cnt <= (others => '0');
                src_port_reg <= (others => '0');
                dst_port_reg <= (others => '0');
                seq_num_reg <= (others => '0');
                ack_num_reg <= (others => '0');
                data_offset_reg <= (others => '0');
                flags_reg <= (others => '0');
                window_reg <= (others => '0');
                header_len <= (others => '0');
                header_done <= '0';
                payload_active <= '0';
            else
                -- Default pulse signals
                tcp_header_valid <= '0';
                tcp_parse_error <= '0';
                tcp_payload_start <= '0';
                tcp_payload_end <= '0';
                tcp_payload_valid <= '0';

                case state is
                    when IDLE =>
                        header_done <= '0';
                        payload_active <= '0';

                        if ip_payload_start = '1' and ip_payload_valid = '1' then
                            -- First byte: Source Port MSB
                            src_port_reg(15 downto 8) <= ip_payload_data;
                            byte_cnt <= to_unsigned(1, 6);
                            state <= PARSE_HEADER;
                        end if;

                    when PARSE_HEADER =>
                        if ip_payload_valid = '1' then
                            case to_integer(byte_cnt) is
                                -- Source Port LSB
                                when 1 =>
                                    src_port_reg(7 downto 0) <= ip_payload_data;

                                -- Destination Port
                                when 2 =>
                                    dst_port_reg(15 downto 8) <= ip_payload_data;
                                when 3 =>
                                    dst_port_reg(7 downto 0) <= ip_payload_data;

                                -- Sequence Number
                                when 4 =>
                                    seq_num_reg(31 downto 24) <= ip_payload_data;
                                when 5 =>
                                    seq_num_reg(23 downto 16) <= ip_payload_data;
                                when 6 =>
                                    seq_num_reg(15 downto 8) <= ip_payload_data;
                                when 7 =>
                                    seq_num_reg(7 downto 0) <= ip_payload_data;

                                -- Acknowledgment Number
                                when 8 =>
                                    ack_num_reg(31 downto 24) <= ip_payload_data;
                                when 9 =>
                                    ack_num_reg(23 downto 16) <= ip_payload_data;
                                when 10 =>
                                    ack_num_reg(15 downto 8) <= ip_payload_data;
                                when 11 =>
                                    ack_num_reg(7 downto 0) <= ip_payload_data;

                                -- Data Offset (upper 4 bits) + Reserved
                                when 12 =>
                                    data_offset_reg <= ip_payload_data(7 downto 4);
                                    -- Calculate header length in bytes (data_offset * 4)
                                    header_len <= unsigned(ip_payload_data(7 downto 4)) & "00";

                                -- Flags
                                when 13 =>
                                    flags_reg <= ip_payload_data;

                                -- Window Size
                                when 14 =>
                                    window_reg(15 downto 8) <= ip_payload_data;
                                when 15 =>
                                    window_reg(7 downto 0) <= ip_payload_data;

                                -- Checksum (bytes 16-17) - skip for now
                                -- Urgent Pointer (bytes 18-19) - skip for now

                                when 19 =>
                                    -- End of minimum header
                                    -- Check if there are options
                                    if header_len > 20 then
                                        state <= SKIP_OPTIONS;
                                    else
                                        -- No options, header complete
                                        header_done <= '1';
                                        tcp_header_valid <= '1';
                                        state <= PAYLOAD;
                                    end if;

                                when others =>
                                    null;
                            end case;

                            byte_cnt <= byte_cnt + 1;

                            -- Check for premature end
                            if ip_payload_end = '1' and byte_cnt < 19 then
                                tcp_parse_error <= '1';
                                state <= ERROR_STATE;
                            end if;
                        end if;

                    when SKIP_OPTIONS =>
                        -- Skip TCP options until header_len reached
                        if ip_payload_valid = '1' then
                            byte_cnt <= byte_cnt + 1;

                            if byte_cnt >= header_len - 1 then
                                -- Options complete, header done
                                header_done <= '1';
                                tcp_header_valid <= '1';
                                state <= PAYLOAD;
                            end if;

                            -- Check for premature end
                            if ip_payload_end = '1' and byte_cnt < header_len - 1 then
                                tcp_parse_error <= '1';
                                state <= ERROR_STATE;
                            end if;
                        end if;

                    when PAYLOAD =>
                        -- Pass through TCP payload
                        if ip_payload_valid = '1' then
                            tcp_payload_valid <= '1';
                            tcp_payload_data <= ip_payload_data;

                            -- First payload byte
                            if payload_active = '0' then
                                tcp_payload_start <= '1';
                                payload_active <= '1';
                            end if;

                            -- Last payload byte
                            if ip_payload_end = '1' then
                                tcp_payload_end <= '1';
                                payload_active <= '0';
                                state <= IDLE;
                            end if;
                        end if;

                    when ERROR_STATE =>
                        -- Wait for end of packet
                        if ip_payload_end = '1' then
                            state <= IDLE;
                        end if;
                end case;

                -- Handle unexpected end of packet
                if ip_payload_end = '1' and state /= IDLE and state /= PAYLOAD then
                    tcp_parse_error <= '1';
                    state <= IDLE;
                end if;
            end if;
        end if;
    end process;

    -- Output assignments
    tcp_src_port <= src_port_reg;
    tcp_dst_port <= dst_port_reg;
    tcp_seq_num <= seq_num_reg;
    tcp_ack_num <= ack_num_reg;
    tcp_data_offset <= data_offset_reg;
    tcp_flags <= flags_reg;
    tcp_window <= window_reg;

    -- Flag convenience outputs
    tcp_flag_fin <= flags_reg(0);
    tcp_flag_syn <= flags_reg(1);
    tcp_flag_rst <= flags_reg(2);
    tcp_flag_psh <= flags_reg(3);
    tcp_flag_ack <= flags_reg(4);

end rtl;
