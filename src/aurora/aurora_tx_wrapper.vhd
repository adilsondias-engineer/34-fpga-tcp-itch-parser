--------------------------------------------------------------------------------
-- Module: aurora_tx_wrapper
-- Description: Aurora 64B/66B TX wrapper for FPGA1 -> FPGA2 communication
--
-- Provides a simple interface for transmitting parsed ITCH messages to FPGA2
-- where the order book engine resides.
--
-- Message Format (64-bit words):
--   Word 0: [msg_type(8) | market(8) | reserved(16) | length(16) | seq_num(16)]
--   Word 1-N: Message payload (variable, depends on message type)
--
-- Uses GTX transceiver with 64B/66B encoding at 10.3125 Gbps line rate.
-- Same PHY layer as 10GBASE-R but simpler framing (no MAC/IP overhead).
--
-- Latency: ~40ns (serialization + channel)
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

entity aurora_tx_wrapper is
    port (
        -- Clock and Reset
        clk                 : in  std_logic;  -- User clock (156.25 MHz)
        rst                 : in  std_logic;

        -- Message input interface (from ITCH parser)
        msg_valid           : in  std_logic;
        msg_type            : in  std_logic_vector(7 downto 0);   -- ITCH message type
        msg_market          : in  std_logic_vector(7 downto 0);   -- 0=NASDAQ, 1=ASX
        msg_data            : in  std_logic_vector(63 downto 0);  -- Message payload word
        msg_data_valid      : in  std_logic;
        msg_last            : in  std_logic;  -- Last word of message
        msg_ready           : out std_logic;  -- Ready for next word

        -- GTX TX interface (directly to GTX transceiver)
        gtx_tx_data         : out std_logic_vector(63 downto 0);
        gtx_tx_header       : out std_logic_vector(1 downto 0);
        gtx_tx_valid        : out std_logic;

        -- Status
        tx_active           : out std_logic;
        tx_sequence         : out std_logic_vector(15 downto 0);
        tx_msg_count        : out std_logic_vector(31 downto 0);

        -- Link status (from GTX)
        gtx_tx_ready        : in  std_logic
    );
end aurora_tx_wrapper;

architecture rtl of aurora_tx_wrapper is

    -- Aurora frame types (sync header)
    constant AURORA_DATA    : std_logic_vector(1 downto 0) := "01";  -- Data block
    constant AURORA_CTRL    : std_logic_vector(1 downto 0) := "10";  -- Control block

    -- Control block types (first byte of control block)
    constant CTRL_IDLE      : std_logic_vector(7 downto 0) := x"1E";  -- All idle
    constant CTRL_SOF       : std_logic_vector(7 downto 0) := x"78";  -- Start of frame
    constant CTRL_EOF       : std_logic_vector(7 downto 0) := x"FF";  -- End of frame

    -- State machine
    type state_type is (
        IDLE,
        SEND_HEADER,
        SEND_PAYLOAD,
        SEND_EOF
    );
    signal state : state_type := IDLE;

    -- Message framing
    signal msg_seq_num      : unsigned(15 downto 0) := (others => '0');
    signal word_count       : unsigned(7 downto 0) := (others => '0');
    signal msg_count        : unsigned(31 downto 0) := (others => '0');

    -- TX data registers
    signal tx_data_reg      : std_logic_vector(63 downto 0) := (others => '0');
    signal tx_header_reg    : std_logic_vector(1 downto 0) := "01";
    signal tx_valid_reg     : std_logic := '0';

    -- Message header construction
    signal header_word      : std_logic_vector(63 downto 0);

    -- Internal ready signal
    signal ready_int        : std_logic := '1';

begin

    -- Construct header word
    -- [msg_type(8) | market(8) | reserved(16) | length(16) | seq_num(16)]
    header_word <= msg_type & msg_market & x"0000" & x"0000" & std_logic_vector(msg_seq_num);

    -- Main TX state machine
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= IDLE;
                msg_seq_num <= (others => '0');
                word_count <= (others => '0');
                msg_count <= (others => '0');
                tx_valid_reg <= '0';
                ready_int <= '1';
            else
                -- Default: maintain valid for pipelining
                tx_valid_reg <= '0';

                case state is
                    when IDLE =>
                        ready_int <= '1';

                        if msg_valid = '1' and gtx_tx_ready = '1' then
                            -- Start new message
                            state <= SEND_HEADER;
                            ready_int <= '0';
                        else
                            -- Send idle pattern when no message
                            tx_data_reg <= x"0707070707070707";  -- All idles
                            tx_header_reg <= AURORA_CTRL;
                            tx_valid_reg <= '1';
                        end if;

                    when SEND_HEADER =>
                        -- Send SOF + header word
                        tx_data_reg <= header_word;
                        tx_header_reg <= AURORA_DATA;
                        tx_valid_reg <= '1';
                        word_count <= (others => '0');
                        state <= SEND_PAYLOAD;
                        ready_int <= '1';  -- Ready for payload data

                    when SEND_PAYLOAD =>
                        if msg_data_valid = '1' then
                            tx_data_reg <= msg_data;
                            tx_header_reg <= AURORA_DATA;
                            tx_valid_reg <= '1';
                            word_count <= word_count + 1;

                            if msg_last = '1' then
                                state <= SEND_EOF;
                                ready_int <= '0';
                            end if;
                        end if;

                    when SEND_EOF =>
                        -- Send end of frame control
                        tx_data_reg <= x"FD07070707070707";  -- Terminate + idles
                        tx_header_reg <= AURORA_CTRL;
                        tx_valid_reg <= '1';

                        msg_seq_num <= msg_seq_num + 1;
                        msg_count <= msg_count + 1;
                        state <= IDLE;
                        ready_int <= '1';
                end case;
            end if;
        end if;
    end process;

    -- Output assignments
    gtx_tx_data <= tx_data_reg;
    gtx_tx_header <= tx_header_reg;
    gtx_tx_valid <= tx_valid_reg;

    msg_ready <= ready_int and gtx_tx_ready;
    tx_active <= '1' when state /= IDLE else '0';
    tx_sequence <= std_logic_vector(msg_seq_num);
    tx_msg_count <= std_logic_vector(msg_count);

end rtl;
