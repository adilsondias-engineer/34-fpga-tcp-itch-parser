--------------------------------------------------------------------------------
-- Module: protocol_demux
-- Description: IP protocol demultiplexer for UDP/TCP routing
--
-- Routes incoming IP packets based on protocol field:
--   - Protocol 6 (TCP): Routes to TCP parser (SoupBinTCP -> ASX ITCH)
--   - Protocol 17 (UDP): Routes to UDP parser (MoldUDP64 -> NASDAQ ITCH)
--
-- This enables dual-market support (NASDAQ + ASX) on a single 10GbE interface.
--
-- Interface: IP payload from IP parser, separate outputs for TCP and UDP paths
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

entity protocol_demux is
    generic (
        -- UDP destination port filter (0 = disabled, accept all)
        UDP_DST_PORT_FILTER : std_logic_vector(15 downto 0) := x"3039"  -- 12345 default
    );
    port (
        clk                 : in  std_logic;
        rst                 : in  std_logic;

        -- IP payload interface (from IP parser)
        ip_payload_valid    : in  std_logic;
        ip_payload_data     : in  std_logic_vector(7 downto 0);
        ip_payload_start    : in  std_logic;
        ip_payload_end      : in  std_logic;
        ip_protocol         : in  std_logic_vector(7 downto 0);  -- From IP header

        -- TCP output (to tcp_parser)
        tcp_payload_valid   : out std_logic;
        tcp_payload_data    : out std_logic_vector(7 downto 0);
        tcp_payload_start   : out std_logic;
        tcp_payload_end     : out std_logic;

        -- UDP output (to existing udp_parser)
        udp_payload_valid   : out std_logic;
        udp_payload_data    : out std_logic_vector(7 downto 0);
        udp_payload_start   : out std_logic;
        udp_payload_end     : out std_logic;

        -- Statistics
        tcp_packet_count    : out std_logic_vector(31 downto 0);
        udp_packet_count    : out std_logic_vector(31 downto 0);
        other_packet_count  : out std_logic_vector(31 downto 0)
    );
end protocol_demux;

architecture rtl of protocol_demux is

    -- Protocol constants
    constant PROTO_TCP : std_logic_vector(7 downto 0) := x"06";  -- 6
    constant PROTO_UDP : std_logic_vector(7 downto 0) := x"11";  -- 17

    -- State
    type route_type is (ROUTE_NONE, ROUTE_TCP, ROUTE_UDP, ROUTE_OTHER);
    signal current_route : route_type := ROUTE_NONE;

    -- UDP header stripping (8 bytes: src port, dst port, length, checksum)
    constant UDP_HEADER_LEN : integer := 8;
    signal udp_hdr_cnt      : unsigned(3 downto 0) := (others => '0');
    signal udp_hdr_done     : std_logic := '0';

    -- UDP destination port capture (bytes 2-3 of UDP header)
    signal udp_dst_port_reg : std_logic_vector(15 downto 0) := (others => '0');
    signal udp_port_match   : std_logic := '0';

    -- Statistics counters
    signal tcp_cnt   : unsigned(31 downto 0) := (others => '0');
    signal udp_cnt   : unsigned(31 downto 0) := (others => '0');
    signal other_cnt : unsigned(31 downto 0) := (others => '0');

begin

    -- Routing logic
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                current_route <= ROUTE_NONE;
                tcp_cnt <= (others => '0');
                udp_cnt <= (others => '0');
                other_cnt <= (others => '0');
                udp_hdr_cnt <= (others => '0');
                udp_hdr_done <= '0';

                tcp_payload_valid <= '0';
                tcp_payload_start <= '0';
                tcp_payload_end <= '0';
                udp_payload_valid <= '0';
                udp_payload_start <= '0';
                udp_payload_end <= '0';
            else
                -- Default: clear pulse signals
                tcp_payload_valid <= '0';
                tcp_payload_start <= '0';
                tcp_payload_end <= '0';
                udp_payload_valid <= '0';
                udp_payload_start <= '0';
                udp_payload_end <= '0';

                -- Determine routing on packet start
                if ip_payload_start = '1' then
                    case ip_protocol is
                        when PROTO_TCP =>
                            current_route <= ROUTE_TCP;
                            tcp_cnt <= tcp_cnt + 1;
                            tcp_payload_start <= '1';
                            tcp_payload_valid <= ip_payload_valid;
                            tcp_payload_data <= ip_payload_data;

                        when PROTO_UDP =>
                            current_route <= ROUTE_UDP;
                            udp_cnt <= udp_cnt + 1;
                            -- Don't emit start yet; skip 8-byte UDP header first
                            -- First byte (ip_payload_start) is UDP src port MSB
                            udp_hdr_cnt <= to_unsigned(1, 4);
                            udp_hdr_done <= '0';

                        when others =>
                            current_route <= ROUTE_OTHER;
                            other_cnt <= other_cnt + 1;
                    end case;

                -- Continue routing for remaining bytes
                elsif ip_payload_valid = '1' then
                    case current_route is
                        when ROUTE_TCP =>
                            tcp_payload_valid <= '1';
                            tcp_payload_data <= ip_payload_data;
                            if ip_payload_end = '1' then
                                tcp_payload_end <= '1';
                                current_route <= ROUTE_NONE;
                            end if;

                        when ROUTE_UDP =>
                            if udp_hdr_done = '0' then
                                -- Still parsing/skipping UDP header bytes
                                -- Capture destination port (bytes 2-3 of UDP header)
                                case to_integer(udp_hdr_cnt) is
                                    when 2 => udp_dst_port_reg(15 downto 8) <= ip_payload_data;
                                    when 3 =>
                                        udp_dst_port_reg(7 downto 0) <= ip_payload_data;
                                        -- Check port match after capturing both bytes
                                        if UDP_DST_PORT_FILTER = x"0000" then
                                            udp_port_match <= '1';  -- Filter disabled
                                        elsif (udp_dst_port_reg(15 downto 8) & ip_payload_data) = UDP_DST_PORT_FILTER then
                                            udp_port_match <= '1';
                                        else
                                            udp_port_match <= '0';
                                        end if;
                                    when others => null;
                                end case;

                                if udp_hdr_cnt >= UDP_HEADER_LEN - 1 then
                                    -- This is the last header byte; next byte is payload
                                    udp_hdr_done <= '1';
                                else
                                    udp_hdr_cnt <= udp_hdr_cnt + 1;
                                end if;
                                -- Check for premature end during header
                                if ip_payload_end = '1' then
                                    current_route <= ROUTE_NONE;
                                end if;
                            else
                                -- UDP header stripped; forward payload only if port matches
                                if udp_port_match = '1' then
                                    udp_payload_valid <= '1';
                                    udp_payload_data <= ip_payload_data;
                                    -- First payload byte gets start pulse
                                    if udp_hdr_cnt = UDP_HEADER_LEN - 1 then
                                        udp_payload_start <= '1';
                                        udp_hdr_cnt <= udp_hdr_cnt + 1;  -- Move past to prevent re-fire
                                    end if;
                                    if ip_payload_end = '1' then
                                        udp_payload_end <= '1';
                                        current_route <= ROUTE_NONE;
                                    end if;
                                else
                                    -- Port doesn't match; discard payload
                                    if ip_payload_end = '1' then
                                        current_route <= ROUTE_NONE;
                                    end if;
                                end if;
                            end if;

                        when ROUTE_OTHER =>
                            -- Discard non-TCP/UDP packets
                            if ip_payload_end = '1' then
                                current_route <= ROUTE_NONE;
                            end if;

                        when ROUTE_NONE =>
                            null;
                    end case;
                end if;
            end if;
        end if;
    end process;

    -- Statistics outputs
    tcp_packet_count <= std_logic_vector(tcp_cnt);
    udp_packet_count <= std_logic_vector(udp_cnt);
    other_packet_count <= std_logic_vector(other_cnt);

end rtl;
