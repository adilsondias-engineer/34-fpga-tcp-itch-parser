--------------------------------------------------------------------------------
-- Module: raw_udp_echo_tx
-- Description: Echoes raw XGMII payload directly back as UDP packets on port 5001
--
-- Purpose: Debug tool to verify XGMII RX data integrity.
--          Captures 58 bytes of MoldUDP64+ITCH payload DIRECTLY from XGMII RX
--          words, bypassing mac_parser_xgmii entirely (no FIFO, no serializer).
--          This isolates whether corruption is in mac_parser or in the XGMII data.
--
-- Assumptions (fixed format from itch_live_feed2.py):
--   - IHL = 5 (no IP options), EtherType = 0x0800
--   - Protocol = 17 (UDP), UDP dst_port = 12345 (0x3039)
--   - MoldUDP64 + ITCH payload = 58 bytes starting at frame byte 42
--
-- XGMII word layout (after Start word):
--   Word 0: DstMAC[0:5] + SrcMAC[0:1]       (bytes 0-7)
--   Word 1: SrcMAC[2:5] + EtherType + IP[0:1](bytes 8-15)
--   Word 2: IP[2:9] (TotLen,ID,Flags,TTL,Proto)
--   Word 3: IP[10:17] (Cksum,SrcIP,DstIP[0:1])
--   Word 4: DstIP[2:3]+UDPSrc+UDPDst+UDPLen  (bytes 32-39)
--   Word 5: UDPCksum + Payload[0:5]           (bytes 40-47)
--   Words 6-11: Payload[6:53]                 (48 bytes)
--   Word 12: Payload[54:57] + CRC[0:3]        (bytes 96-103)
--
-- Frame: 14 Eth + 20 IP + 8 UDP + 58 payload = 100 bytes + 4 CRC = 104 bytes
--        = 13 XGMII data words
--
-- Ethernet: broadcast, src MAC 00:0A:35:01:FE:C0
-- IP: 192.168.0.215 -> 192.168.0.144, TTL=64, UDP
-- UDP: src 12345, dst 5001
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity raw_udp_echo_tx is
    port (
        clk               : in  std_logic;
        rst               : in  std_logic;

        -- XGMII RX interface (direct from PCS)
        xgmii_rxd         : in  std_logic_vector(63 downto 0);
        xgmii_rxc         : in  std_logic_vector(7 downto 0);
        xgmii_rx_valid    : in  std_logic;  -- '1' when PCS has new block (gearbox valid)

        -- XGMII TX output
        xgmii_txd         : out std_logic_vector(63 downto 0);
        xgmii_txc         : out std_logic_vector(7 downto 0);

        -- Debug
        tx_active          : out std_logic;
        tx_count           : out std_logic_vector(31 downto 0)
    );
end entity;

architecture rtl of raw_udp_echo_tx is

    -- XGMII control codes
    constant XGMII_START   : std_logic_vector(7 downto 0) := x"FB";
    constant XGMII_TERM    : std_logic_vector(7 downto 0) := x"FD";

    -- Payload buffer: captures MoldUDP64 + ITCH (58 bytes)
    constant MAX_PAYLOAD : integer := 58;

    type byte_array_t is array(natural range <>) of std_logic_vector(7 downto 0);

    signal payload_buf : byte_array_t(0 to MAX_PAYLOAD-1) := (others => (others => '0'));
    signal pay_idx     : unsigned(6 downto 0) := (others => '0');

    -- XGMII RX word counter (after Start detection)
    signal rx_word_cnt : unsigned(3 downto 0) := (others => '0');

    ----------------------------------------------------------------------------
    -- Static Ethernet + IP + UDP header (42 bytes)
    --   IP Total Length = 86 (20 IP + 8 UDP + 58 payload)
    --   UDP Dst Port    = 5001
    --   UDP Length       = 66 (8 + 58)
    --   IP Checksum      = 0xB7DE (precomputed)
    ----------------------------------------------------------------------------
    constant HDR_DATA : byte_array_t(0 to 41) := (
        -- Dst MAC: FF:FF:FF:FF:FF:FF (broadcast)
        x"FF", x"FF", x"FF", x"FF", x"FF", x"FF",
        -- Src MAC: 00:0A:35:01:FE:C0
        x"00", x"0A", x"35", x"01", x"FE", x"C0",
        -- EtherType: 0x0800 (IPv4)
        x"08", x"00",
        -- IP Header (20 bytes)
        x"45", x"00",       -- Version/IHL=5, DSCP/ECN=0
        x"00", x"56",       -- Total Length = 86
        x"00", x"01",       -- Identification
        x"40", x"00",       -- Flags: Don't Fragment
        x"40", x"11",       -- TTL=64, Protocol=17 (UDP)
        x"B7", x"DE",       -- Header Checksum
        x"C0", x"A8", x"00", x"D7",  -- Src IP: 192.168.0.215
        x"C0", x"A8", x"00", x"90",  -- Dst IP: 192.168.0.144
        -- UDP Header (8 bytes)
        x"30", x"39",       -- Src Port: 12345
        x"13", x"89",       -- Dst Port: 5001
        x"00", x"42",       -- Length: 66 (8 + 58)
        x"00", x"00"        -- Checksum: 0 (disabled)
    );

    ----------------------------------------------------------------------------
    -- Frame data: header(42) + payload(58) + CRC(4) + padding = 112 bytes
    -- Padded to 112 = 14 x 8 to allow clean XGMII word indexing
    ----------------------------------------------------------------------------
    signal frame_data : byte_array_t(0 to 111) := (others => (others => '0'));

    ----------------------------------------------------------------------------
    -- CRC-32 (reflected polynomial 0xEDB88320)
    ----------------------------------------------------------------------------
    signal crc_reg      : std_logic_vector(31 downto 0) := (others => '1');
    signal crc_byte_idx : unsigned(6 downto 0) := (others => '0');

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

    -- TX word counter (0-12 = 13 data words)
    signal tx_word : unsigned(3 downto 0) := (others => '0');

    ----------------------------------------------------------------------------
    -- State machine
    ----------------------------------------------------------------------------
    type state_t is (
        S_IDLE,          -- Wait for XGMII Start
        S_HEADER,        -- Count words 0-4, check IPv4/UDP/port
        S_CAPTURE,       -- Words 5-12: capture payload bytes from XGMII
        S_BUILD,         -- Copy header + payload into frame_data
        S_CRC,           -- Compute CRC-32 over 100-byte frame
        S_TX_START,      -- XGMII: preamble + SFD
        S_TX_DATA,       -- XGMII: 13 data words (104 bytes)
        S_TX_CRC_TERM    -- XGMII: TERMINATE + IDLE
    );
    signal state : state_t := S_IDLE;

    -- Packet counter
    signal pkt_cnt : unsigned(31 downto 0) := (others => '0');

    -- XGMII idle
    constant XGMII_IDLE_D : std_logic_vector(63 downto 0) := x"0707070707070707";
    constant XGMII_IDLE_C : std_logic_vector(7 downto 0)  := x"FF";

begin

    tx_count  <= std_logic_vector(pkt_cnt);
    tx_active <= '1' when state = S_BUILD or state = S_CRC
                       or state = S_TX_START or state = S_TX_DATA
                       or state = S_TX_CRC_TERM
                 else '0';

    process(clk)
        variable v_base : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state       <= S_IDLE;
                pkt_cnt     <= (others => '0');
                crc_reg     <= (others => '1');
                xgmii_txd   <= XGMII_IDLE_D;
                xgmii_txc   <= XGMII_IDLE_C;
                pay_idx     <= (others => '0');
                rx_word_cnt <= (others => '0');
            else
                -- Default: IDLE on XGMII TX
                xgmii_txd <= XGMII_IDLE_D;
                xgmii_txc <= XGMII_IDLE_C;

                case state is

                    --------------------------------------------------------
                    -- IDLE: wait for XGMII Start control character
                    -- Only process when xgmii_rx_valid='1' (new block from
                    -- PCS gearbox). Stale data is held when valid='0'.
                    --------------------------------------------------------
                    when S_IDLE =>
                        if xgmii_rx_valid = '1' and
                           xgmii_rxc(0) = '1' and
                           xgmii_rxd(7 downto 0) = XGMII_START then
                            rx_word_cnt <= (others => '0');
                            state <= S_HEADER;
                        end if;

                    --------------------------------------------------------
                    -- HEADER: count words 0-4, check EtherType/Protocol/DstPort
                    -- Word 1 lanes 4-5: EtherType = 0x0800
                    -- Word 2 lane 7:    Protocol = 0x11
                    -- Word 4 lanes 4-5: UDP DstPort = 0x3039
                    -- CRITICAL: only advance on xgmii_rx_valid to skip
                    -- stale gearbox words (prevents 8-byte word duplication)
                    --------------------------------------------------------
                    when S_HEADER =>
                        if xgmii_rx_valid = '1' then
                            case to_integer(rx_word_cnt) is
                                when 1 =>
                                    -- Check EtherType at lanes 4-5 (bytes 12-13)
                                    if xgmii_rxd(39 downto 32) /= x"08" or
                                       xgmii_rxd(47 downto 40) /= x"00" then
                                        state <= S_IDLE;  -- Not IPv4
                                    end if;

                                when 2 =>
                                    -- Check Protocol at lane 7 (byte 23)
                                    if xgmii_rxd(63 downto 56) /= x"11" then
                                        state <= S_IDLE;  -- Not UDP
                                    end if;

                                when 4 =>
                                    -- Check UDP Dst Port at lanes 4-5 (bytes 36-37)
                                    if xgmii_rxd(39 downto 32) /= x"30" or
                                       xgmii_rxd(47 downto 40) /= x"39" then
                                        state <= S_IDLE;  -- Not port 12345
                                    else
                                        -- Port matches, start capture on next word
                                        pay_idx <= (others => '0');
                                        state <= S_CAPTURE;
                                    end if;

                                when others =>
                                    null;
                            end case;

                            -- Detect terminate during header (runt frame)
                            for i in 0 to 7 loop
                                if xgmii_rxc(i) = '1' and
                                   xgmii_rxd(i*8+7 downto i*8) = XGMII_TERM then
                                    state <= S_IDLE;
                                end if;
                            end loop;

                            rx_word_cnt <= rx_word_cnt + 1;
                        end if;

                    --------------------------------------------------------
                    -- CAPTURE: grab payload bytes from XGMII RX words
                    -- rx_word_cnt=5: lanes 2-7 → payload[0:5]  (skip UDP checksum)
                    -- rx_word_cnt=6..11: all lanes → payload[6:53]
                    -- rx_word_cnt=12: lanes 0-3 → payload[54:57]
                    -- CRITICAL: only advance on xgmii_rx_valid
                    --------------------------------------------------------
                    when S_CAPTURE =>
                        if xgmii_rx_valid = '1' then
                            case to_integer(rx_word_cnt) is
                                when 5 =>
                                    -- Skip lanes 0-1 (UDP checksum), capture lanes 2-7
                                    payload_buf(0) <= xgmii_rxd(23 downto 16);  -- lane 2
                                    payload_buf(1) <= xgmii_rxd(31 downto 24);  -- lane 3
                                    payload_buf(2) <= xgmii_rxd(39 downto 32);  -- lane 4
                                    payload_buf(3) <= xgmii_rxd(47 downto 40);  -- lane 5
                                    payload_buf(4) <= xgmii_rxd(55 downto 48);  -- lane 6
                                    payload_buf(5) <= xgmii_rxd(63 downto 56);  -- lane 7
                                    pay_idx <= to_unsigned(6, 7);

                                when 6 | 7 | 8 | 9 | 10 | 11 =>
                                    -- Full 8-byte words → payload[pay_idx : pay_idx+7]
                                    payload_buf(to_integer(pay_idx) + 0) <= xgmii_rxd(7 downto 0);
                                    payload_buf(to_integer(pay_idx) + 1) <= xgmii_rxd(15 downto 8);
                                    payload_buf(to_integer(pay_idx) + 2) <= xgmii_rxd(23 downto 16);
                                    payload_buf(to_integer(pay_idx) + 3) <= xgmii_rxd(31 downto 24);
                                    payload_buf(to_integer(pay_idx) + 4) <= xgmii_rxd(39 downto 32);
                                    payload_buf(to_integer(pay_idx) + 5) <= xgmii_rxd(47 downto 40);
                                    payload_buf(to_integer(pay_idx) + 6) <= xgmii_rxd(55 downto 48);
                                    payload_buf(to_integer(pay_idx) + 7) <= xgmii_rxd(63 downto 56);
                                    pay_idx <= pay_idx + 8;

                                when 12 =>
                                    -- Last 4 bytes: lanes 0-3
                                    payload_buf(54) <= xgmii_rxd(7 downto 0);
                                    payload_buf(55) <= xgmii_rxd(15 downto 8);
                                    payload_buf(56) <= xgmii_rxd(23 downto 16);
                                    payload_buf(57) <= xgmii_rxd(31 downto 24);
                                    state <= S_BUILD;

                                when others =>
                                    -- Beyond expected range, abort
                                    state <= S_IDLE;
                            end case;

                            -- Detect premature terminate
                            for i in 0 to 7 loop
                                if xgmii_rxc(i) = '1' and
                                   xgmii_rxd(i*8+7 downto i*8) = XGMII_TERM then
                                    if rx_word_cnt /= 12 then
                                        state <= S_IDLE;  -- Too short
                                    end if;
                                end if;
                            end loop;

                            rx_word_cnt <= rx_word_cnt + 1;
                        end if;

                    --------------------------------------------------------
                    -- BUILD: assemble frame_data from header + payload
                    --------------------------------------------------------
                    when S_BUILD =>
                        -- Static header
                        for i in 0 to 41 loop
                            frame_data(i) <= HDR_DATA(i);
                        end loop;
                        -- Captured payload
                        for i in 0 to MAX_PAYLOAD-1 loop
                            frame_data(42 + i) <= payload_buf(i);
                        end loop;
                        -- Initialize CRC
                        crc_reg      <= (others => '1');
                        crc_byte_idx <= (others => '0');
                        state        <= S_CRC;

                    --------------------------------------------------------
                    -- CRC: compute CRC-32 over 100-byte frame (1 byte/clk)
                    --------------------------------------------------------
                    when S_CRC =>
                        if crc_byte_idx < 100 then
                            crc_reg      <= crc32_byte(crc_reg,
                                            frame_data(to_integer(crc_byte_idx)));
                            crc_byte_idx <= crc_byte_idx + 1;
                        else
                            -- Store CRC in frame_data (Ethernet: LSB first)
                            frame_data(100) <= not crc_reg(7 downto 0);
                            frame_data(101) <= not crc_reg(15 downto 8);
                            frame_data(102) <= not crc_reg(23 downto 16);
                            frame_data(103) <= not crc_reg(31 downto 24);
                            state <= S_TX_START;
                        end if;

                    --------------------------------------------------------
                    -- TX_START: XGMII preamble + SFD
                    --------------------------------------------------------
                    when S_TX_START =>
                        xgmii_txd <= x"D5" & x"55" & x"55" & x"55" &
                                     x"55" & x"55" & x"55" & x"FB";
                        xgmii_txc <= "00000001";
                        tx_word   <= (others => '0');
                        state     <= S_TX_DATA;

                    --------------------------------------------------------
                    -- TX_DATA: send 13 words (104 bytes = frame + CRC)
                    -- Lane 0 = LSB = first byte on wire
                    --------------------------------------------------------
                    when S_TX_DATA =>
                        v_base := to_integer(tx_word) * 8;
                        xgmii_txd <= frame_data(v_base+7) & frame_data(v_base+6) &
                                     frame_data(v_base+5) & frame_data(v_base+4) &
                                     frame_data(v_base+3) & frame_data(v_base+2) &
                                     frame_data(v_base+1) & frame_data(v_base+0);
                        xgmii_txc <= "00000000";
                        if tx_word = 12 then
                            state <= S_TX_CRC_TERM;
                        else
                            tx_word <= tx_word + 1;
                        end if;

                    --------------------------------------------------------
                    -- TX_CRC_TERM: TERMINATE + IDLE
                    --------------------------------------------------------
                    when S_TX_CRC_TERM =>
                        xgmii_txd <= x"07" & x"07" & x"07" & x"07" &
                                     x"07" & x"07" & x"07" & x"FD";
                        xgmii_txc <= x"FF";
                        pkt_cnt   <= pkt_cnt + 1;
                        state     <= S_IDLE;

                end case;
            end if;
        end if;
    end process;

end rtl;
