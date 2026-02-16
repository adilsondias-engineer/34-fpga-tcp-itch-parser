--------------------------------------------------------------------------------
-- Module: itch_echo_tx
-- Description: Echoes parsed ITCH fields back as UDP packets for debug
--
-- When nasdaq_itch_parser outputs a parsed message (msg_valid pulse), this
-- module builds a UDP packet containing the parsed fields and transmits it
-- via XGMII TX. This allows Wireshark to verify correct ITCH parsing without
-- needing BBO/CDC FIFO infrastructure.
--
-- UDP Payload (36 bytes):
--   Byte 0:     msg_type (1 byte, ASCII: 'A','D','E','X','U')
--   Byte 1:     buy_sell (1 byte, 'B' or 'S')
--   Bytes 2-3:  stock_locate (2 bytes, big-endian)
--   Bytes 4-7:  price (4 bytes, big-endian)
--   Bytes 8-11: shares (4 bytes, big-endian)
--   Bytes 12-19: stock_symbol (8 bytes, ASCII)
--   Bytes 20-27: order_ref (8 bytes, big-endian)
--   Bytes 28-29: tracking_number (2 bytes, big-endian) ** DEBUG **
--   Bytes 30-35: timestamp (6 bytes, big-endian) ** DEBUG **
--
-- Frame: 14 Eth + 20 IP + 8 UDP + 36 payload = 78 bytes + 4 CRC = 82 bytes
--
-- Ethernet: broadcast, src MAC 00:0A:35:01:FE:C0
-- IP: 192.168.0.215 -> 192.168.0.144, TTL=64, UDP
-- UDP: src 12345, dst 5000
--
-- ==============================================================================
-- Copyright 2026 Adilson Dias
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- ==============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity itch_echo_tx is
    generic (
        CLK_FREQ : integer := 161_130_000
    );
    port (
        clk               : in  std_logic;
        rst               : in  std_logic;

        -- ITCH parser inputs (directly from nasdaq_itch_parser)
        itch_msg_valid    : in  std_logic;
        itch_msg_type     : in  std_logic_vector(7 downto 0);
        itch_stock_locate : in  std_logic_vector(15 downto 0);
        itch_tracking_number : in  std_logic_vector(15 downto 0);
        itch_timestamp    : in  std_logic_vector(47 downto 0);
        itch_order_ref    : in  std_logic_vector(63 downto 0);
        itch_buy_sell     : in  std_logic;
        itch_shares       : in  std_logic_vector(31 downto 0);
        itch_stock_symbol : in  std_logic_vector(63 downto 0);
        itch_price        : in  std_logic_vector(31 downto 0);

        -- XGMII TX output
        xgmii_txd         : out std_logic_vector(63 downto 0);
        xgmii_txc         : out std_logic_vector(7 downto 0);

        -- Debug
        tx_active          : out std_logic;
        tx_count           : out std_logic_vector(31 downto 0)
    );
end itch_echo_tx;

architecture rtl of itch_echo_tx is

    -- Latched ITCH fields
    signal lat_msg_type     : std_logic_vector(7 downto 0);
    signal lat_buy_sell     : std_logic_vector(7 downto 0);
    signal lat_stock_locate : std_logic_vector(15 downto 0);
    signal lat_tracking_number : std_logic_vector(15 downto 0);
    signal lat_timestamp    : std_logic_vector(47 downto 0);
    signal lat_price        : std_logic_vector(31 downto 0);
    signal lat_shares       : std_logic_vector(31 downto 0);
    signal lat_symbol       : std_logic_vector(63 downto 0);
    signal lat_order_ref    : std_logic_vector(63 downto 0);

    -- Frame data: 78 bytes
    type byte_array_t is array (natural range <>) of std_logic_vector(7 downto 0);

    -- Static header (bytes 0-41): Ethernet + IP + UDP
    constant HDR_DATA : byte_array_t(0 to 41) := (
        -- Dst MAC: FF:FF:FF:FF:FF:FF (broadcast)
        x"FF", x"FF", x"FF", x"FF", x"FF", x"FF",
        -- Src MAC: 00:0A:35:01:FE:C0
        x"00", x"0A", x"35", x"01", x"FE", x"C0",
        -- EtherType: 0x0800 (IPv4)
        x"08", x"00",
        -- IP Header (20 bytes)
        x"45", x"00",       -- Version/IHL=5, DSCP/ECN=0
        x"00", x"40",       -- Total Length = 64 (20 IP + 8 UDP + 36 payload)
        x"00", x"01",       -- Identification
        x"40", x"00",       -- Flags: Don't Fragment
        x"40", x"11",       -- TTL=64, Protocol=17 (UDP)
        x"B7", x"F4",       -- Header Checksum (precomputed for TotalLen=64)
        x"C0", x"A8", x"00", x"D7",  -- Src IP: 192.168.0.215
        x"C0", x"A8", x"00", x"90",  -- Dst IP: 192.168.0.144
        -- UDP Header (8 bytes)
        x"30", x"39",       -- Src Port: 12345
        x"13", x"88",       -- Dst Port: 5000
        x"00", x"2C",       -- Length: 44 (8 header + 36 payload)
        x"00", x"00"        -- Checksum: 0 (disabled)
    );

    -- Complete frame for CRC computation (78 bytes)
    signal frame_data : byte_array_t(0 to 77);

    -- CRC-32 computation
    signal crc_reg      : std_logic_vector(31 downto 0) := (others => '1');
    signal crc_byte_idx : unsigned(6 downto 0) := (others => '0');
    signal crc_final    : std_logic_vector(31 downto 0) := (others => '0');

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
        TX_BUILD_FRAME,
        TX_CRC_COMPUTE,
        TX_START,
        TX_DATA_1, TX_DATA_2, TX_DATA_3, TX_DATA_4,
        TX_DATA_5, TX_DATA_6, TX_DATA_7, TX_DATA_8,
        TX_DATA_9, TX_DATA_10,
        TX_CRC_TERM
    );
    signal tx_state : tx_state_t := TX_IDLE;

    -- Packet counter
    signal pkt_cnt : unsigned(31 downto 0) := (others => '0');

    -- XGMII idle constant
    constant XGMII_IDLE_D : std_logic_vector(63 downto 0) := x"0707070707070707";
    constant XGMII_IDLE_C : std_logic_vector(7 downto 0)  := x"FF";

begin

    tx_count <= std_logic_vector(pkt_cnt);
    tx_active <= '0' when tx_state = TX_IDLE else '1';

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                tx_state <= TX_IDLE;
                pkt_cnt <= (others => '0');
                crc_reg <= (others => '1');
                crc_byte_idx <= (others => '0');
                xgmii_txd <= XGMII_IDLE_D;
                xgmii_txc <= XGMII_IDLE_C;
                lat_msg_type <= (others => '0');
                lat_buy_sell <= (others => '0');
                lat_stock_locate <= (others => '0');
                lat_tracking_number <= (others => '0');
                lat_timestamp <= (others => '0');
                lat_price <= (others => '0');
                lat_shares <= (others => '0');
                lat_symbol <= (others => '0');
                lat_order_ref <= (others => '0');
            else
                -- Default: idle on XGMII
                xgmii_txd <= XGMII_IDLE_D;
                xgmii_txc <= XGMII_IDLE_C;

                case tx_state is

                    when TX_IDLE =>
                        -- Wait for parsed ITCH message
                        if itch_msg_valid = '1' then
                            -- Latch all fields immediately
                            lat_msg_type <= itch_msg_type;
                            if itch_buy_sell = '1' then
                                lat_buy_sell <= x"42";  -- 'B'
                            else
                                lat_buy_sell <= x"53";  -- 'S'
                            end if;
                            lat_stock_locate <= itch_stock_locate;
                            lat_tracking_number <= itch_tracking_number;
                            lat_timestamp <= itch_timestamp;
                            lat_price <= itch_price;
                            lat_shares <= itch_shares;
                            lat_symbol <= itch_stock_symbol;
                            lat_order_ref <= itch_order_ref;
                            tx_state <= TX_BUILD_FRAME;
                        end if;

                    when TX_BUILD_FRAME =>
                        -- Build frame array: static header + dynamic payload
                        -- Header bytes 0-41
                        for i in 0 to 41 loop
                            frame_data(i) <= HDR_DATA(i);
                        end loop;
                        -- Payload bytes 42-77
                        frame_data(42) <= lat_msg_type;
                        frame_data(43) <= lat_buy_sell;
                        frame_data(44) <= lat_stock_locate(15 downto 8);
                        frame_data(45) <= lat_stock_locate(7 downto 0);
                        frame_data(46) <= lat_price(31 downto 24);
                        frame_data(47) <= lat_price(23 downto 16);
                        frame_data(48) <= lat_price(15 downto 8);
                        frame_data(49) <= lat_price(7 downto 0);
                        frame_data(50) <= lat_shares(31 downto 24);
                        frame_data(51) <= lat_shares(23 downto 16);
                        frame_data(52) <= lat_shares(15 downto 8);
                        frame_data(53) <= lat_shares(7 downto 0);
                        frame_data(54) <= lat_symbol(63 downto 56);
                        frame_data(55) <= lat_symbol(55 downto 48);
                        frame_data(56) <= lat_symbol(47 downto 40);
                        frame_data(57) <= lat_symbol(39 downto 32);
                        frame_data(58) <= lat_symbol(31 downto 24);
                        frame_data(59) <= lat_symbol(23 downto 16);
                        frame_data(60) <= lat_symbol(15 downto 8);
                        frame_data(61) <= lat_symbol(7 downto 0);
                        frame_data(62) <= lat_order_ref(63 downto 56);
                        frame_data(63) <= lat_order_ref(55 downto 48);
                        frame_data(64) <= lat_order_ref(47 downto 40);
                        frame_data(65) <= lat_order_ref(39 downto 32);
                        frame_data(66) <= lat_order_ref(31 downto 24);
                        frame_data(67) <= lat_order_ref(23 downto 16);
                        frame_data(68) <= lat_order_ref(15 downto 8);
                        frame_data(69) <= lat_order_ref(7 downto 0);
                        -- Tracking number (2 bytes, big-endian) - DEBUG
                        frame_data(70) <= lat_tracking_number(15 downto 8);
                        frame_data(71) <= lat_tracking_number(7 downto 0);
                        -- Timestamp (6 bytes, big-endian) - DEBUG
                        frame_data(72) <= lat_timestamp(47 downto 40);
                        frame_data(73) <= lat_timestamp(39 downto 32);
                        frame_data(74) <= lat_timestamp(31 downto 24);
                        frame_data(75) <= lat_timestamp(23 downto 16);
                        frame_data(76) <= lat_timestamp(15 downto 8);
                        frame_data(77) <= lat_timestamp(7 downto 0);
                        -- Start CRC computation
                        crc_reg <= (others => '1');
                        crc_byte_idx <= (others => '0');
                        tx_state <= TX_CRC_COMPUTE;

                    when TX_CRC_COMPUTE =>
                        -- Compute CRC one byte per clock (78 clocks)
                        if crc_byte_idx < 78 then
                            crc_reg <= crc32_byte(crc_reg, frame_data(to_integer(crc_byte_idx)));
                            crc_byte_idx <= crc_byte_idx + 1;
                        else
                            crc_final <= not crc_reg;
                            tx_state <= TX_START;
                        end if;

                    when TX_START =>
                        -- Preamble + SFD
                        -- Lane 0=FB(Start), Lanes 1-6=55(preamble), Lane 7=D5(SFD)
                        xgmii_txd <= x"D5" & x"55" & x"55" & x"55" &
                                     x"55" & x"55" & x"55" & x"FB";
                        xgmii_txc <= "00000001";
                        tx_state <= TX_DATA_1;

                    when TX_DATA_1 =>
                        -- Bytes 0-7: Dst MAC[0:5] + Src MAC[0:1]
                        xgmii_txd <= frame_data(7) & frame_data(6) & frame_data(5) & frame_data(4) &
                                     frame_data(3) & frame_data(2) & frame_data(1) & frame_data(0);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_2;

                    when TX_DATA_2 =>
                        -- Bytes 8-15: Src MAC[2:5] + EtherType + IP[0:1]
                        xgmii_txd <= frame_data(15) & frame_data(14) & frame_data(13) & frame_data(12) &
                                     frame_data(11) & frame_data(10) & frame_data(9) & frame_data(8);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_3;

                    when TX_DATA_3 =>
                        -- Bytes 16-23: IP header
                        xgmii_txd <= frame_data(23) & frame_data(22) & frame_data(21) & frame_data(20) &
                                     frame_data(19) & frame_data(18) & frame_data(17) & frame_data(16);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_4;

                    when TX_DATA_4 =>
                        -- Bytes 24-31: IP checksum + Src IP + Dst IP start
                        xgmii_txd <= frame_data(31) & frame_data(30) & frame_data(29) & frame_data(28) &
                                     frame_data(27) & frame_data(26) & frame_data(25) & frame_data(24);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_5;

                    when TX_DATA_5 =>
                        -- Bytes 32-39: Dst IP end + UDP header
                        xgmii_txd <= frame_data(39) & frame_data(38) & frame_data(37) & frame_data(36) &
                                     frame_data(35) & frame_data(34) & frame_data(33) & frame_data(32);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_6;

                    when TX_DATA_6 =>
                        -- Bytes 40-47: UDP checksum + payload[0:5]
                        xgmii_txd <= frame_data(47) & frame_data(46) & frame_data(45) & frame_data(44) &
                                     frame_data(43) & frame_data(42) & frame_data(41) & frame_data(40);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_7;

                    when TX_DATA_7 =>
                        -- Bytes 48-55: payload[6:13]
                        xgmii_txd <= frame_data(55) & frame_data(54) & frame_data(53) & frame_data(52) &
                                     frame_data(51) & frame_data(50) & frame_data(49) & frame_data(48);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_8;

                    when TX_DATA_8 =>
                        -- Bytes 56-63: payload[14:21] (symbol)
                        xgmii_txd <= frame_data(63) & frame_data(62) & frame_data(61) & frame_data(60) &
                                     frame_data(59) & frame_data(58) & frame_data(57) & frame_data(56);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_9;

                    when TX_DATA_9 =>
                        -- Bytes 64-71 (order_ref[2:7] + tracking_number)
                        xgmii_txd <= frame_data(71) & frame_data(70) & frame_data(69) & frame_data(68) &
                                     frame_data(67) & frame_data(66) & frame_data(65) & frame_data(64);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_10;

                    when TX_DATA_10 =>
                        -- Bytes 72-77 (timestamp) + CRC[0:1]
                        xgmii_txd <= crc_final(15 downto 8) & crc_final(7 downto 0) &
                                     frame_data(77) & frame_data(76) & frame_data(75) &
                                     frame_data(74) & frame_data(73) & frame_data(72);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_CRC_TERM;

                    when TX_CRC_TERM =>
                        -- CRC[2:3] + terminate + idle
                        -- Lane 0: CRC[23:16], Lane 1: CRC[31:24], Lane 2: FD, Lanes 3-7: idle
                        xgmii_txd <= x"07" & x"07" & x"07" & x"07" & x"07" &
                                     x"FD" & crc_final(31 downto 24) & crc_final(23 downto 16);
                        xgmii_txc <= "11111100";
                        pkt_cnt <= pkt_cnt + 1;
                        tx_state <= TX_IDLE;

                end case;
            end if;
        end if;
    end process;

end rtl;
