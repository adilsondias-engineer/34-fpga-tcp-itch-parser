--------------------------------------------------------------------------------
-- Module: itch_debug_uart
-- Description: Captures MAC parser serializer byte stream in a circular buffer.
--              On corruption detection, freezes buffer and dumps via UART.
--
-- Operation:
--   1. RECORD: stores each valid serializer byte (data + start/end flags)
--      into a 256-entry circular buffer
--   2. FREEZE: when corruption_trigger fires, buffer freezes
--   3. DUMP: outputs buffer contents as hex via UART at 115200 baud
--      Format: "=COR=\r\n" + hex dump with [start] ]end] markers + "=END=\r\n"
--   4. DONE: stays frozen until reset
--
-- Buffer format per entry (10 bits):
--   [9]   = byte_end   (last byte of IP payload)
--   [8]   = byte_start (first byte of IP payload)
--   [7:0] = byte_data
--
-- Hex dump output example:
--   =COR=
--   [08 00 55 D5 41 53 00 0D 00 04 F1 A0 00 00 00 64
--   41 41 50 4C 20 20 20 20 00 00 00 00 00 01 23 45]
--   [08 00 55 D5 41 53 00 0D 41 41 50 4C ...
--   =END=
--
-- The [/] markers show IP payload boundaries. Count bytes between [ and ]
-- to verify packet length. Expected: 66 bytes for ITCH-over-MoldUDP64.
-- If 67 = duplicated byte. If 65 = skipped byte.
--
-- Design: FSM and UART TX are in a SINGLE process to avoid cross-process
-- handshake races. The FSM directly loads the shift register when tx_busy='0'.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity itch_debug_uart is
    generic (
        CLK_FREQ  : integer := 161_130_000;  -- tx_clk frequency (Hz)
        BAUD_RATE : integer := 115200;
        BUF_AW    : integer := 8             -- log2(buffer depth), 8 = 256 entries
    );
    port (
        clk                : in  std_logic;
        rst                : in  std_logic;

        -- Serializer byte stream to monitor (from mac_parser_xgmii)
        byte_valid         : in  std_logic;
        byte_data          : in  std_logic_vector(7 downto 0);
        byte_start         : in  std_logic;   -- first byte of IP payload
        byte_end           : in  std_logic;   -- last byte of IP payload

        -- Corruption trigger (pulse high for 1 cycle when corruption detected)
        corruption_trigger : in  std_logic;

        -- UART TX output
        uart_tx            : out std_logic;

        -- Status: '1' while dump is active (used to mux UART at top level)
        dump_active        : out std_logic
    );
end entity;

architecture rtl of itch_debug_uart is

    constant BUF_DEPTH : integer := 2**BUF_AW;
    constant BAUD_DIV  : integer := CLK_FREQ / BAUD_RATE;

    ----------------------------------------------------------------------------
    -- Circular buffer (distributed RAM, 256 x 10 bits)
    ----------------------------------------------------------------------------
    type buf_t is array(0 to BUF_DEPTH-1) of std_logic_vector(9 downto 0);
    signal buf    : buf_t := (others => (others => '0'));
    signal wr_ptr : unsigned(BUF_AW-1 downto 0) := (others => '0');
    signal frozen : std_logic := '0';

    -- Dump read pointer
    signal rd_ptr   : unsigned(BUF_AW-1 downto 0) := (others => '0');
    signal rd_count : unsigned(BUF_AW downto 0) := (others => '0');

    -- Current buffer entry (async read from distributed RAM)
    signal cur_data  : std_logic_vector(7 downto 0);
    signal cur_start : std_logic;
    signal cur_end   : std_logic;

    ----------------------------------------------------------------------------
    -- UART TX shift register (8N1, LSB first)
    ----------------------------------------------------------------------------
    signal tx_shift : std_logic_vector(9 downto 0) := "1111111111";
    signal tx_busy  : std_logic := '0';
    signal tx_bit   : integer range 0 to 9 := 0;
    signal tx_baud  : unsigned(13 downto 0) := (others => '0');  -- max 16383

    ----------------------------------------------------------------------------
    -- Dump FSM
    ----------------------------------------------------------------------------
    type state_t is (
        S_RECORD,         -- Normal: recording bytes to circular buffer
        S_HDR,            -- Sending header string
        S_ENTRY,          -- Read buffer entry, check start marker
        S_HI_NIB,         -- Send high hex nibble
        S_LO_NIB,         -- Send low hex nibble
        S_END_MARK,       -- Send ']' end marker
        S_SEP,            -- Send separator (space or \r)
        S_LF,             -- Send \n after \r
        S_FTR,            -- Send footer string
        S_DONE            -- Dump complete, stay frozen
    );
    signal state : state_t := S_RECORD;

    -- String index for header/footer
    signal str_idx : integer range 0 to 15 := 0;

    -- Line position counter (newline every 16 bytes)
    signal line_pos : unsigned(3 downto 0) := (others => '0');

    -- dump_active register
    signal dump_active_r : std_logic := '0';

    ----------------------------------------------------------------------------
    -- Header: "\r\n=COR=\r\n" (9 characters)
    ----------------------------------------------------------------------------
    type str_rom_t is array(natural range <>) of std_logic_vector(7 downto 0);
    constant HDR : str_rom_t(0 to 8) := (
        x"0D", x"0A",          -- \r\n
        x"3D", x"43", x"4F", x"52", x"3D",  -- =COR=
        x"0D", x"0A"           -- \r\n
    );

    -- Footer: "\r\n=END=\r\n" (9 characters)
    constant FTR : str_rom_t(0 to 8) := (
        x"0D", x"0A",          -- \r\n
        x"3D", x"45", x"4E", x"44", x"3D",  -- =END=
        x"0D", x"0A"           -- \r\n
    );

    ----------------------------------------------------------------------------
    -- Nibble to ASCII hex ('0'-'9', 'A'-'F')
    ----------------------------------------------------------------------------
    function hex(n : std_logic_vector(3 downto 0))
        return std_logic_vector is
        variable result : std_logic_vector(7 downto 0);
    begin
        case n is
            when "0000" => result := x"30";
            when "0001" => result := x"31";
            when "0010" => result := x"32";
            when "0011" => result := x"33";
            when "0100" => result := x"34";
            when "0101" => result := x"35";
            when "0110" => result := x"36";
            when "0111" => result := x"37";
            when "1000" => result := x"38";
            when "1001" => result := x"39";
            when "1010" => result := x"41";
            when "1011" => result := x"42";
            when "1100" => result := x"43";
            when "1101" => result := x"44";
            when "1110" => result := x"45";
            when "1111" => result := x"46";
            when others => result := x"3F";  -- '?'
        end case;
        return result;
    end function;

    ----------------------------------------------------------------------------
    -- Procedure: load UART shift register with a byte
    -- Called from within the main process (single process design)
    ----------------------------------------------------------------------------
    procedure uart_load(
        signal   sr   : out std_logic_vector(9 downto 0);
        signal   busy : out std_logic;
        signal   bit_cnt : out integer range 0 to 9;
        signal   baud : out unsigned(13 downto 0);
        constant data : in  std_logic_vector(7 downto 0)
    ) is
    begin
        sr   <= '1' & data & '0';  -- stop + data + start
        busy <= '1';
        bit_cnt <= 0;
        baud <= (others => '0');
    end procedure;

begin

    -- Async read from circular buffer (distributed RAM)
    cur_data  <= buf(to_integer(rd_ptr))(7 downto 0);
    cur_start <= buf(to_integer(rd_ptr))(8);
    cur_end   <= buf(to_integer(rd_ptr))(9);

    dump_active <= dump_active_r;

    ----------------------------------------------------------------------------
    -- Circular buffer write process
    -- Records valid serializer bytes. Freezes on corruption trigger.
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                wr_ptr <= (others => '0');
                frozen <= '0';
            elsif frozen = '0' then
                if byte_valid = '1' then
                    buf(to_integer(wr_ptr)) <= byte_end & byte_start & byte_data;
                    wr_ptr <= wr_ptr + 1;
                end if;
                if corruption_trigger = '1' then
                    frozen <= '1';
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Combined UART TX + Dump FSM (SINGLE PROCESS)
    --
    -- When tx_busy='1': shift register runs (UART bit output)
    -- When tx_busy='0': FSM advances and directly loads next byte
    --
    -- Single-process design eliminates cross-process handshake races that
    -- caused every other character to be skipped in the two-process version.
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state    <= S_RECORD;
                dump_active_r <= '0';
                str_idx  <= 0;
                rd_ptr   <= (others => '0');
                rd_count <= (others => '0');
                line_pos <= (others => '0');
                tx_shift <= "1111111111";
                tx_busy  <= '0';
                tx_bit   <= 0;
                tx_baud  <= (others => '0');
            elsif tx_busy = '1' then
                --------------------------------------------------------
                -- UART TX: shift register running (8N1, LSB first)
                --------------------------------------------------------
                if tx_baud = BAUD_DIV - 1 then
                    tx_baud <= (others => '0');
                    if tx_bit = 9 then
                        -- All 10 bits sent (start + 8 data + stop)
                        tx_busy  <= '0';
                        tx_shift <= "1111111111";
                    else
                        -- Shift right, fill MSB with idle ('1')
                        tx_shift <= '1' & tx_shift(9 downto 1);
                        tx_bit   <= tx_bit + 1;
                    end if;
                else
                    tx_baud <= tx_baud + 1;
                end if;
            else
                --------------------------------------------------------
                -- tx_busy = '0': FSM runs, can load next byte
                --------------------------------------------------------
                case state is

                    ----------------------------------------------------
                    -- RECORD: wait for corruption trigger
                    ----------------------------------------------------
                    when S_RECORD =>
                        dump_active_r <= '0';
                        if frozen = '1' then
                            dump_active_r <= '1';
                            state    <= S_HDR;
                            str_idx  <= 0;
                            rd_ptr   <= wr_ptr;  -- start from oldest entry
                            rd_count <= (others => '0');
                            line_pos <= (others => '0');
                        end if;

                    ----------------------------------------------------
                    -- HDR: send header string character by character
                    ----------------------------------------------------
                    when S_HDR =>
                        if str_idx = HDR'length then
                            state <= S_ENTRY;
                        else
                            uart_load(tx_shift, tx_busy, tx_bit, tx_baud,
                                      HDR(str_idx));
                            str_idx <= str_idx + 1;
                        end if;

                    ----------------------------------------------------
                    -- ENTRY: read buffer entry, handle start marker
                    ----------------------------------------------------
                    when S_ENTRY =>
                        if rd_count = BUF_DEPTH then
                            -- All entries dumped
                            state   <= S_FTR;
                            str_idx <= 0;
                        elsif cur_start = '1' then
                            -- Send '[' marker first
                            uart_load(tx_shift, tx_busy, tx_bit, tx_baud,
                                      x"5B");  -- '['
                            state <= S_HI_NIB;
                        else
                            -- No start marker, go straight to hex
                            state <= S_HI_NIB;
                        end if;

                    ----------------------------------------------------
                    -- HI_NIB: send high hex nibble of data byte
                    ----------------------------------------------------
                    when S_HI_NIB =>
                        uart_load(tx_shift, tx_busy, tx_bit, tx_baud,
                                  hex(cur_data(7 downto 4)));
                        state <= S_LO_NIB;

                    ----------------------------------------------------
                    -- LO_NIB: send low hex nibble, check end marker
                    ----------------------------------------------------
                    when S_LO_NIB =>
                        uart_load(tx_shift, tx_busy, tx_bit, tx_baud,
                                  hex(cur_data(3 downto 0)));
                        if cur_end = '1' then
                            state <= S_END_MARK;
                        else
                            state <= S_SEP;
                        end if;

                    ----------------------------------------------------
                    -- END_MARK: send ']' end marker
                    ----------------------------------------------------
                    when S_END_MARK =>
                        uart_load(tx_shift, tx_busy, tx_bit, tx_baud,
                                  x"5D");  -- ']'
                        state <= S_SEP;

                    ----------------------------------------------------
                    -- SEP: send separator, advance read pointer
                    ----------------------------------------------------
                    when S_SEP =>
                        -- Advance to next buffer entry
                        rd_ptr   <= rd_ptr + 1;
                        rd_count <= rd_count + 1;

                        if cur_end = '1' or line_pos = 15 then
                            -- End of packet or line: send \r\n
                            uart_load(tx_shift, tx_busy, tx_bit, tx_baud,
                                      x"0D");  -- \r
                            line_pos <= (others => '0');
                            state    <= S_LF;
                        else
                            -- Normal separator: space
                            uart_load(tx_shift, tx_busy, tx_bit, tx_baud,
                                      x"20");  -- ' '
                            line_pos <= line_pos + 1;
                            state    <= S_ENTRY;
                        end if;

                    ----------------------------------------------------
                    -- LF: send \n (second half of \r\n)
                    ----------------------------------------------------
                    when S_LF =>
                        uart_load(tx_shift, tx_busy, tx_bit, tx_baud,
                                  x"0A");  -- \n
                        state <= S_ENTRY;

                    ----------------------------------------------------
                    -- FTR: send footer string
                    ----------------------------------------------------
                    when S_FTR =>
                        if str_idx = FTR'length then
                            state <= S_DONE;
                        else
                            uart_load(tx_shift, tx_busy, tx_bit, tx_baud,
                                      FTR(str_idx));
                            str_idx <= str_idx + 1;
                        end if;

                    ----------------------------------------------------
                    -- DONE: stay frozen until reset
                    ----------------------------------------------------
                    when S_DONE =>
                        null;

                end case;
            end if;
        end if;
    end process;

    uart_tx <= tx_shift(0);

end rtl;
