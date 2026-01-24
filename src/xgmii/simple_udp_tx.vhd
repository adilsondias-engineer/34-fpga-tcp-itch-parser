--------------------------------------------------------------------------------
-- Module: simple_udp_tx
-- Description: Generates periodic broadcast UDP packets on XGMII TX interface
--
-- Sends a fixed "FPGA_HELLO" UDP packet every ~1 second:
--   Dst MAC: FF:FF:FF:FF:FF:FF (broadcast)
--   Src MAC: 00:0A:35:01:FE:C0
--   Src IP:  192.168.0.215
--   Dst IP:  192.168.0.144
--   UDP port: 12345 -> 12345
--   Payload: "FPGA_HELLO"
--
-- XGMII convention (matching encoder_64b66b / decoder_64b66b):
--   txd[7:0]   = lane 0 (first byte), txc[0] = control for lane 0
--   txd[63:56] = lane 7 (last byte),  txc[7] = control for lane 7
--
-- CRC-32 is computed at runtime from the stored frame bytes.
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

entity simple_udp_tx is
    generic (
        CLK_FREQ        : integer := 161_130_000;  -- tx_clk frequency
        SEND_INTERVAL_MS: integer := 1000          -- Send every N ms
    );
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;

        -- XGMII TX output
        xgmii_txd       : out std_logic_vector(63 downto 0);
        xgmii_txc       : out std_logic_vector(7 downto 0);

        -- Debug
        tx_count        : out std_logic_vector(31 downto 0)  -- Packets sent
    );
end simple_udp_tx;

architecture rtl of simple_udp_tx is

    -- Interval counter
    constant SEND_INTERVAL : integer := (CLK_FREQ / 1000) * SEND_INTERVAL_MS;
    signal interval_cnt    : unsigned(27 downto 0) := (others => '0');
    signal send_trigger    : std_logic := '0';

    -- Packet counter
    signal pkt_cnt         : unsigned(31 downto 0) := (others => '0');

    -- Frame data: 60 bytes (minimum Ethernet frame, no CRC yet)
    -- Stored as an array of bytes for clarity
    type byte_array_t is array (0 to 59) of std_logic_vector(7 downto 0);
    constant FRAME_DATA : byte_array_t := (
        -- Dst MAC: FF:FF:FF:FF:FF:FF (broadcast)
        x"FF", x"FF", x"FF", x"FF", x"FF", x"FF",
        -- Src MAC: 00:0A:35:01:FE:C0
        x"00", x"0A", x"35", x"01", x"FE", x"C0",
        -- EtherType: 0x0800 (IPv4)
        x"08", x"00",
        -- IP Header (20 bytes)
        x"45", x"00",       -- Version/IHL=5, DSCP/ECN=0
        x"00", x"26",       -- Total Length = 38 (20 IP + 8 UDP + 10 payload)
        x"00", x"01",       -- Identification
        x"40", x"00",       -- Flags: Don't Fragment, Fragment Offset: 0
        x"40", x"11",       -- TTL=64, Protocol=17 (UDP)
        x"B8", x"0E",       -- Header Checksum (precomputed)
        x"C0", x"A8", x"00", x"D7",  -- Src IP: 192.168.0.215
        x"C0", x"A8", x"00", x"90",  -- Dst IP: 192.168.0.144
        -- UDP Header (8 bytes)
        x"30", x"39",       -- Src Port: 12345
        x"30", x"39",       -- Dst Port: 12345
        x"00", x"12",       -- Length: 18 (8 header + 10 payload)
        x"00", x"00",       -- Checksum: 0 (disabled)
        -- Payload: "FPGA_HELLO" (10 bytes)
        x"46", x"50", x"47", x"41", x"5F",  -- "FPGA_"
        x"48", x"45", x"4C", x"4C", x"4F",  -- "HELLO"
        -- Padding to 60 bytes (8 zero bytes)
        x"00", x"00", x"00", x"00",
        x"00", x"00", x"00", x"00"
    );

    -- CRC-32 computation
    signal crc_reg         : std_logic_vector(31 downto 0) := (others => '1');
    signal crc_byte_idx    : unsigned(5 downto 0) := (others => '0');
    signal crc_done        : std_logic := '0';
    signal crc_final       : std_logic_vector(31 downto 0) := (others => '0');

    -- CRC-32 byte-at-a-time function (reflected polynomial 0xEDB88320)
    function crc32_byte(crc_in : std_logic_vector(31 downto 0);
                        data   : std_logic_vector(7 downto 0))
        return std_logic_vector is
        variable crc : std_logic_vector(31 downto 0);
    begin
        crc := crc_in;
        crc(7 downto 0) := crc(7 downto 0) xor data;
        for i in 0 to 7 loop
            if crc(0) = '1' then
                crc := ('0' & crc(31 downto 1)) xor x"EDB88320";
            else
                crc := '0' & crc(31 downto 1);
            end if;
        end loop;
        return crc;
    end function;

    -- TX state machine
    type tx_state_t is (
        TX_IDLE,
        TX_CRC_COMPUTE,
        TX_START,
        TX_DATA_1, TX_DATA_2, TX_DATA_3, TX_DATA_4,
        TX_DATA_5, TX_DATA_6, TX_DATA_7, TX_DATA_8,
        TX_TERM
    );
    signal tx_state : tx_state_t := TX_IDLE;

    -- XGMII idle constant
    constant XGMII_IDLE_D : std_logic_vector(63 downto 0) := x"0707070707070707";
    constant XGMII_IDLE_C : std_logic_vector(7 downto 0)  := x"FF";

begin

    tx_count <= std_logic_vector(pkt_cnt);

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                tx_state <= TX_IDLE;
                interval_cnt <= (others => '0');
                send_trigger <= '0';
                pkt_cnt <= (others => '0');
                crc_reg <= (others => '1');
                crc_byte_idx <= (others => '0');
                crc_done <= '0';
                xgmii_txd <= XGMII_IDLE_D;
                xgmii_txc <= XGMII_IDLE_C;
            else
                -- Default: idle
                xgmii_txd <= XGMII_IDLE_D;
                xgmii_txc <= XGMII_IDLE_C;

                case tx_state is

                    when TX_IDLE =>
                        -- Count to send interval
                        if interval_cnt >= to_unsigned(SEND_INTERVAL, 28) then
                            interval_cnt <= (others => '0');
                            -- Start CRC computation
                            tx_state <= TX_CRC_COMPUTE;
                            crc_reg <= (others => '1');  -- Init CRC
                            crc_byte_idx <= (others => '0');
                            crc_done <= '0';
                        else
                            interval_cnt <= interval_cnt + 1;
                        end if;

                    when TX_CRC_COMPUTE =>
                        -- Compute CRC one byte per clock (60 clocks)
                        if crc_byte_idx < 60 then
                            crc_reg <= crc32_byte(crc_reg, FRAME_DATA(to_integer(crc_byte_idx)));
                            crc_byte_idx <= crc_byte_idx + 1;
                        else
                            -- CRC done: complement and store
                            crc_final <= not crc_reg;
                            crc_done <= '1';
                            tx_state <= TX_START;
                        end if;

                    when TX_START =>
                        -- XGMII Start word: Lane 0=FB(Start), Lanes 1-6=55(preamble), Lane 7=D5(SFD)
                        -- Lane 0 = txd[7:0], Lane 7 = txd[63:56]
                        xgmii_txd <= x"D5" & x"55" & x"55" & x"55" &
                                     x"55" & x"55" & x"55" & x"FB";
                        xgmii_txc <= "00000001";
                        tx_state <= TX_DATA_1;

                    when TX_DATA_1 =>
                        -- Bytes 0-7: dst MAC (6) + src MAC (2)
                        -- Lane 0 = txd[7:0] = FRAME_DATA(0), Lane 7 = txd[63:56] = FRAME_DATA(7)
                        xgmii_txd <= FRAME_DATA(7) & FRAME_DATA(6) & FRAME_DATA(5) & FRAME_DATA(4) &
                                     FRAME_DATA(3) & FRAME_DATA(2) & FRAME_DATA(1) & FRAME_DATA(0);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_2;

                    when TX_DATA_2 =>
                        -- Bytes 8-15: src MAC (4) + EtherType (2) + IP hdr (2)
                        xgmii_txd <= FRAME_DATA(15) & FRAME_DATA(14) & FRAME_DATA(13) & FRAME_DATA(12) &
                                     FRAME_DATA(11) & FRAME_DATA(10) & FRAME_DATA(9) & FRAME_DATA(8);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_3;

                    when TX_DATA_3 =>
                        -- Bytes 16-23: IP header continued
                        xgmii_txd <= FRAME_DATA(23) & FRAME_DATA(22) & FRAME_DATA(21) & FRAME_DATA(20) &
                                     FRAME_DATA(19) & FRAME_DATA(18) & FRAME_DATA(17) & FRAME_DATA(16);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_4;

                    when TX_DATA_4 =>
                        -- Bytes 24-31: IP checksum + src IP + dst IP start
                        xgmii_txd <= FRAME_DATA(31) & FRAME_DATA(30) & FRAME_DATA(29) & FRAME_DATA(28) &
                                     FRAME_DATA(27) & FRAME_DATA(26) & FRAME_DATA(25) & FRAME_DATA(24);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_5;

                    when TX_DATA_5 =>
                        -- Bytes 32-39: dst IP end + UDP header
                        xgmii_txd <= FRAME_DATA(39) & FRAME_DATA(38) & FRAME_DATA(37) & FRAME_DATA(36) &
                                     FRAME_DATA(35) & FRAME_DATA(34) & FRAME_DATA(33) & FRAME_DATA(32);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_6;

                    when TX_DATA_6 =>
                        -- Bytes 40-47: UDP checksum + payload "FPGA_H"
                        xgmii_txd <= FRAME_DATA(47) & FRAME_DATA(46) & FRAME_DATA(45) & FRAME_DATA(44) &
                                     FRAME_DATA(43) & FRAME_DATA(42) & FRAME_DATA(41) & FRAME_DATA(40);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_7;

                    when TX_DATA_7 =>
                        -- Bytes 48-55: payload "ELLO" + padding
                        xgmii_txd <= FRAME_DATA(55) & FRAME_DATA(54) & FRAME_DATA(53) & FRAME_DATA(52) &
                                     FRAME_DATA(51) & FRAME_DATA(50) & FRAME_DATA(49) & FRAME_DATA(48);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_8;

                    when TX_DATA_8 =>
                        -- Bytes 56-59 (padding) + 4 CRC bytes
                        -- CRC LSByte first: lane 4 = CRC[7:0], lane 7 = CRC[31:24]
                        xgmii_txd <= crc_final(31 downto 24) & crc_final(23 downto 16) &
                                     crc_final(15 downto 8) & crc_final(7 downto 0) &
                                     FRAME_DATA(59) & FRAME_DATA(58) & FRAME_DATA(57) & FRAME_DATA(56);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_TERM;

                    when TX_TERM =>
                        -- Terminate in lane 0 (txd[7:0]=FD), rest idle
                        xgmii_txd <= x"07" & x"07" & x"07" & x"07" &
                                     x"07" & x"07" & x"07" & x"FD";
                        xgmii_txc <= "11111111";
                        pkt_cnt <= pkt_cnt + 1;
                        tx_state <= TX_IDLE;

                end case;
            end if;
        end if;
    end process;

end rtl;
