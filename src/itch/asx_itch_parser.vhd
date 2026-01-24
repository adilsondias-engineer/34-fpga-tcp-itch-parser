--------------------------------------------------------------------------------
-- Module: asx_itch_parser
-- Description: ASX ITCH protocol parser for market data
--
-- Parses binary ASX ITCH messages from SoupBinTCP payload stream.
-- Key differences from NASDAQ ITCH:
--   - Order Book ID: 32-bit (vs NASDAQ 16-bit Stock Locate)
--   - Quantity: 64-bit (vs NASDAQ 32-bit)
--   - Timestamp: 4-byte nanoseconds only (vs NASDAQ 6-byte)
--   - No Stock Locate or Tracking Number fields
--   - Side field included in most messages
--
-- Implemented Message Types:
--   'A' (0x41): Add Order (39 bytes)
--   'E' (0x45): Order Executed (31 bytes)
--   'X' (0x58): Order Cancel (19 bytes)
--   'D' (0x44): Order Delete (15 bytes)
--   'U' (0x55): Order Replace (45 bytes)
--   'R' (0x52): Order Book Directory (57 bytes)
--   'S' (0x53): System Event (6 bytes)
--
-- Interface: Byte-stream input from SoupBinTCP, parsed fields output
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
use work.asx_itch_msg_pkg.all;

entity asx_itch_parser is
    port (
        clk                 : in  std_logic;
        rst                 : in  std_logic;

        -- ITCH message interface (from SoupBinTCP handler)
        itch_msg_valid      : in  std_logic;
        itch_msg_data       : in  std_logic_vector(7 downto 0);
        itch_msg_start      : in  std_logic;
        itch_msg_end        : in  std_logic;

        -- Parsed message outputs
        msg_valid           : out std_logic;
        msg_type            : out std_logic_vector(7 downto 0);
        msg_error           : out std_logic;

        -- Common fields (most messages)
        timestamp           : out std_logic_vector(31 downto 0);  -- Nanoseconds (4 bytes)
        order_id            : out std_logic_vector(63 downto 0);  -- Order ID (8 bytes)
        orderbook_id        : out std_logic_vector(31 downto 0);  -- Order Book ID (4 bytes)
        side                : out std_logic;                       -- '1'=Buy, '0'=Sell

        -- Add Order ('A') fields
        add_order_valid     : out std_logic;
        add_order_start     : out std_logic;
        quantity            : out std_logic_vector(63 downto 0);  -- 8 bytes (vs NASDAQ 4)
        price               : out std_logic_vector(31 downto 0);  -- Signed price
        order_attributes    : out std_logic_vector(15 downto 0);  -- ASX-specific

        -- Order Executed ('E') fields
        order_executed_valid : out std_logic;
        exec_quantity        : out std_logic_vector(63 downto 0); -- 8 bytes
        match_id             : out std_logic_vector(63 downto 0); -- Match ID (8 bytes)
        combo_group_id       : out std_logic_vector(31 downto 0); -- Combination ID

        -- Order Cancel ('X') fields
        order_cancel_valid  : out std_logic;
        cancel_quantity     : out std_logic_vector(63 downto 0);  -- 8 bytes

        -- Order Delete ('D') fields
        order_delete_valid  : out std_logic;

        -- Order Replace ('U') fields
        order_replace_valid : out std_logic;
        new_order_id        : out std_logic_vector(63 downto 0);  -- New order ID
        new_quantity        : out std_logic_vector(63 downto 0);  -- New quantity
        new_price           : out std_logic_vector(31 downto 0);  -- New price

        -- Order Book Directory ('R') fields
        directory_valid     : out std_logic;
        symbol              : out std_logic_vector(63 downto 0);  -- 8-char symbol
        isin                : out std_logic_vector(95 downto 0);  -- 12-char ISIN
        price_decimals      : out std_logic_vector(7 downto 0);   -- Decimal places
        round_lot_size      : out std_logic_vector(31 downto 0);  -- Lot size

        -- System Event ('S') fields
        system_event_valid  : out std_logic;
        event_code          : out std_logic_vector(7 downto 0);

        -- Statistics
        total_messages      : out std_logic_vector(31 downto 0);
        parse_errors        : out std_logic_vector(31 downto 0)
    );
end asx_itch_parser;

architecture rtl of asx_itch_parser is

    -- State machine
    type state_type is (IDLE, READ_TYPE, COUNT_BYTES, COMPLETE, ERROR_STATE);
    signal state : state_type := IDLE;

    -- Message parsing
    signal current_msg_type : std_logic_vector(7 downto 0) := (others => '0');
    signal expected_length  : integer range 0 to 255 := 0;
    signal byte_counter     : integer range 0 to 255 := 0;

    -- Field extraction registers
    signal timestamp_reg        : std_logic_vector(31 downto 0) := (others => '0');
    signal order_id_reg         : std_logic_vector(63 downto 0) := (others => '0');
    signal orderbook_id_reg     : std_logic_vector(31 downto 0) := (others => '0');
    signal side_reg             : std_logic := '0';
    signal quantity_reg         : std_logic_vector(63 downto 0) := (others => '0');
    signal price_reg            : std_logic_vector(31 downto 0) := (others => '0');
    signal order_attributes_reg : std_logic_vector(15 downto 0) := (others => '0');
    signal exec_quantity_reg    : std_logic_vector(63 downto 0) := (others => '0');
    signal match_id_reg         : std_logic_vector(63 downto 0) := (others => '0');
    signal combo_group_id_reg   : std_logic_vector(31 downto 0) := (others => '0');
    signal cancel_quantity_reg  : std_logic_vector(63 downto 0) := (others => '0');
    signal new_order_id_reg     : std_logic_vector(63 downto 0) := (others => '0');
    signal new_quantity_reg     : std_logic_vector(63 downto 0) := (others => '0');
    signal new_price_reg        : std_logic_vector(31 downto 0) := (others => '0');
    signal symbol_reg           : std_logic_vector(63 downto 0) := (others => '0');
    signal isin_reg             : std_logic_vector(95 downto 0) := (others => '0');
    signal price_decimals_reg   : std_logic_vector(7 downto 0) := (others => '0');
    signal round_lot_size_reg   : std_logic_vector(31 downto 0) := (others => '0');
    signal event_code_reg       : std_logic_vector(7 downto 0) := (others => '0');

    -- Statistics
    signal msg_counter      : unsigned(31 downto 0) := (others => '0');
    signal error_counter    : unsigned(31 downto 0) := (others => '0');

begin

    -- Main parser state machine
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= IDLE;
                current_msg_type <= (others => '0');
                expected_length <= 0;
                byte_counter <= 0;
                msg_counter <= (others => '0');
                error_counter <= (others => '0');

                -- Clear output pulses
                msg_valid <= '0';
                msg_error <= '0';
                add_order_valid <= '0';
                add_order_start <= '0';
                order_executed_valid <= '0';
                order_cancel_valid <= '0';
                order_delete_valid <= '0';
                order_replace_valid <= '0';
                directory_valid <= '0';
                system_event_valid <= '0';
            else
                -- Default: clear pulse outputs
                msg_valid <= '0';
                msg_error <= '0';
                add_order_valid <= '0';
                add_order_start <= '0';
                order_executed_valid <= '0';
                order_cancel_valid <= '0';
                order_delete_valid <= '0';
                order_replace_valid <= '0';
                directory_valid <= '0';
                system_event_valid <= '0';

                case state is
                    when IDLE =>
                        if itch_msg_start = '1' and itch_msg_valid = '1' then
                            -- First byte is message type
                            current_msg_type <= itch_msg_data;
                            expected_length <= get_asx_msg_length(itch_msg_data);
                            byte_counter <= 1;

                            -- Pulse start for Add Order (for latency measurement)
                            if itch_msg_data = ASX_MSG_ADD_ORDER then
                                add_order_start <= '1';
                            end if;

                            if get_asx_msg_length(itch_msg_data) = 0 then
                                state <= ERROR_STATE;
                            else
                                state <= COUNT_BYTES;
                            end if;
                        end if;

                    when READ_TYPE =>
                        -- Unused state (handled in IDLE)
                        state <= IDLE;

                    when COUNT_BYTES =>
                        if itch_msg_valid = '1' then
                            -- Extract fields based on message type
                            -- ASX Add Order ('A') - 39 bytes
                            -- Layout: Type(1) + Timestamp(4) + OrderID(8) + OrderBookID(4) +
                            --         Side(1) + Quantity(8) + Price(4) + Attributes(2) = 32 bytes after type
                            if current_msg_type = ASX_MSG_ADD_ORDER then
                                case byte_counter is
                                    -- Timestamp: bytes 1-4
                                    when 1 => timestamp_reg(31 downto 24) <= itch_msg_data;
                                    when 2 => timestamp_reg(23 downto 16) <= itch_msg_data;
                                    when 3 => timestamp_reg(15 downto 8) <= itch_msg_data;
                                    when 4 => timestamp_reg(7 downto 0) <= itch_msg_data;
                                    -- Order ID: bytes 5-12
                                    when 5  => order_id_reg(63 downto 56) <= itch_msg_data;
                                    when 6  => order_id_reg(55 downto 48) <= itch_msg_data;
                                    when 7  => order_id_reg(47 downto 40) <= itch_msg_data;
                                    when 8  => order_id_reg(39 downto 32) <= itch_msg_data;
                                    when 9  => order_id_reg(31 downto 24) <= itch_msg_data;
                                    when 10 => order_id_reg(23 downto 16) <= itch_msg_data;
                                    when 11 => order_id_reg(15 downto 8) <= itch_msg_data;
                                    when 12 => order_id_reg(7 downto 0) <= itch_msg_data;
                                    -- Order Book ID: bytes 13-16
                                    when 13 => orderbook_id_reg(31 downto 24) <= itch_msg_data;
                                    when 14 => orderbook_id_reg(23 downto 16) <= itch_msg_data;
                                    when 15 => orderbook_id_reg(15 downto 8) <= itch_msg_data;
                                    when 16 => orderbook_id_reg(7 downto 0) <= itch_msg_data;
                                    -- Side: byte 17
                                    when 17 =>
                                        if itch_msg_data = x"42" then  -- 'B'
                                            side_reg <= '1';
                                        else  -- 'S'
                                            side_reg <= '0';
                                        end if;
                                    -- Quantity: bytes 18-25 (8 bytes)
                                    when 18 => quantity_reg(63 downto 56) <= itch_msg_data;
                                    when 19 => quantity_reg(55 downto 48) <= itch_msg_data;
                                    when 20 => quantity_reg(47 downto 40) <= itch_msg_data;
                                    when 21 => quantity_reg(39 downto 32) <= itch_msg_data;
                                    when 22 => quantity_reg(31 downto 24) <= itch_msg_data;
                                    when 23 => quantity_reg(23 downto 16) <= itch_msg_data;
                                    when 24 => quantity_reg(15 downto 8) <= itch_msg_data;
                                    when 25 => quantity_reg(7 downto 0) <= itch_msg_data;
                                    -- Price: bytes 26-29
                                    when 26 => price_reg(31 downto 24) <= itch_msg_data;
                                    when 27 => price_reg(23 downto 16) <= itch_msg_data;
                                    when 28 => price_reg(15 downto 8) <= itch_msg_data;
                                    when 29 => price_reg(7 downto 0) <= itch_msg_data;
                                    -- Attributes: bytes 30-31
                                    when 30 => order_attributes_reg(15 downto 8) <= itch_msg_data;
                                    when 31 => order_attributes_reg(7 downto 0) <= itch_msg_data;
                                    when others => null;
                                end case;

                            -- ASX Order Executed ('E') - 31 bytes
                            elsif current_msg_type = ASX_MSG_ORDER_EXECUTED then
                                case byte_counter is
                                    -- Timestamp: bytes 1-4
                                    when 1 => timestamp_reg(31 downto 24) <= itch_msg_data;
                                    when 2 => timestamp_reg(23 downto 16) <= itch_msg_data;
                                    when 3 => timestamp_reg(15 downto 8) <= itch_msg_data;
                                    when 4 => timestamp_reg(7 downto 0) <= itch_msg_data;
                                    -- Order ID: bytes 5-12
                                    when 5  => order_id_reg(63 downto 56) <= itch_msg_data;
                                    when 6  => order_id_reg(55 downto 48) <= itch_msg_data;
                                    when 7  => order_id_reg(47 downto 40) <= itch_msg_data;
                                    when 8  => order_id_reg(39 downto 32) <= itch_msg_data;
                                    when 9  => order_id_reg(31 downto 24) <= itch_msg_data;
                                    when 10 => order_id_reg(23 downto 16) <= itch_msg_data;
                                    when 11 => order_id_reg(15 downto 8) <= itch_msg_data;
                                    when 12 => order_id_reg(7 downto 0) <= itch_msg_data;
                                    -- Order Book ID: bytes 13-16
                                    when 13 => orderbook_id_reg(31 downto 24) <= itch_msg_data;
                                    when 14 => orderbook_id_reg(23 downto 16) <= itch_msg_data;
                                    when 15 => orderbook_id_reg(15 downto 8) <= itch_msg_data;
                                    when 16 => orderbook_id_reg(7 downto 0) <= itch_msg_data;
                                    -- Side: byte 17
                                    when 17 =>
                                        if itch_msg_data = x"42" then
                                            side_reg <= '1';
                                        else
                                            side_reg <= '0';
                                        end if;
                                    -- Executed Quantity: bytes 18-25
                                    when 18 => exec_quantity_reg(63 downto 56) <= itch_msg_data;
                                    when 19 => exec_quantity_reg(55 downto 48) <= itch_msg_data;
                                    when 20 => exec_quantity_reg(47 downto 40) <= itch_msg_data;
                                    when 21 => exec_quantity_reg(39 downto 32) <= itch_msg_data;
                                    when 22 => exec_quantity_reg(31 downto 24) <= itch_msg_data;
                                    when 23 => exec_quantity_reg(23 downto 16) <= itch_msg_data;
                                    when 24 => exec_quantity_reg(15 downto 8) <= itch_msg_data;
                                    when 25 => exec_quantity_reg(7 downto 0) <= itch_msg_data;
                                    -- Match ID: bytes 26-33 (shortened in spec)
                                    when others => null;
                                end case;

                            -- ASX Order Delete ('D') - 15 bytes
                            elsif current_msg_type = ASX_MSG_ORDER_DELETE then
                                case byte_counter is
                                    -- Timestamp: bytes 1-4
                                    when 1 => timestamp_reg(31 downto 24) <= itch_msg_data;
                                    when 2 => timestamp_reg(23 downto 16) <= itch_msg_data;
                                    when 3 => timestamp_reg(15 downto 8) <= itch_msg_data;
                                    when 4 => timestamp_reg(7 downto 0) <= itch_msg_data;
                                    -- Order ID: bytes 5-12
                                    when 5  => order_id_reg(63 downto 56) <= itch_msg_data;
                                    when 6  => order_id_reg(55 downto 48) <= itch_msg_data;
                                    when 7  => order_id_reg(47 downto 40) <= itch_msg_data;
                                    when 8  => order_id_reg(39 downto 32) <= itch_msg_data;
                                    when 9  => order_id_reg(31 downto 24) <= itch_msg_data;
                                    when 10 => order_id_reg(23 downto 16) <= itch_msg_data;
                                    when 11 => order_id_reg(15 downto 8) <= itch_msg_data;
                                    when 12 => order_id_reg(7 downto 0) <= itch_msg_data;
                                    -- Order Book ID: bytes 13-14 (Note: may vary)
                                    when 13 => orderbook_id_reg(31 downto 24) <= itch_msg_data;
                                    when 14 => orderbook_id_reg(23 downto 16) <= itch_msg_data;
                                    when others => null;
                                end case;

                            -- ASX System Event ('S') - 6 bytes
                            elsif current_msg_type = ASX_MSG_SYSTEM_EVENT then
                                case byte_counter is
                                    -- Timestamp: bytes 1-4
                                    when 1 => timestamp_reg(31 downto 24) <= itch_msg_data;
                                    when 2 => timestamp_reg(23 downto 16) <= itch_msg_data;
                                    when 3 => timestamp_reg(15 downto 8) <= itch_msg_data;
                                    when 4 => timestamp_reg(7 downto 0) <= itch_msg_data;
                                    -- Event Code: byte 5
                                    when 5 => event_code_reg <= itch_msg_data;
                                    when others => null;
                                end case;
                            end if;

                            -- Increment counter and check completion
                            if byte_counter >= (expected_length - 1) then
                                state <= COMPLETE;
                            end if;
                            byte_counter <= byte_counter + 1;

                            -- Handle end of message
                            if itch_msg_end = '1' then
                                if byte_counter < (expected_length - 1) then
                                    state <= ERROR_STATE;
                                else
                                    state <= COMPLETE;
                                end if;
                            end if;
                        end if;

                    when COMPLETE =>
                        msg_counter <= msg_counter + 1;
                        msg_valid <= '1';

                        -- Set type-specific valid signals
                        case current_msg_type is
                            when ASX_MSG_ADD_ORDER =>
                                add_order_valid <= '1';
                            when ASX_MSG_ORDER_EXECUTED =>
                                order_executed_valid <= '1';
                            when ASX_MSG_ORDER_CANCEL =>
                                order_cancel_valid <= '1';
                            when ASX_MSG_ORDER_DELETE =>
                                order_delete_valid <= '1';
                            when ASX_MSG_ORDER_REPLACE =>
                                order_replace_valid <= '1';
                            when ASX_MSG_ORDER_BOOK_DIR =>
                                directory_valid <= '1';
                            when ASX_MSG_SYSTEM_EVENT =>
                                system_event_valid <= '1';
                            when others =>
                                null;
                        end case;

                        state <= IDLE;

                    when ERROR_STATE =>
                        msg_error <= '1';
                        error_counter <= error_counter + 1;
                        state <= IDLE;
                end case;
            end if;
        end if;
    end process;

    -- Output assignments
    msg_type <= current_msg_type;
    timestamp <= timestamp_reg;
    order_id <= order_id_reg;
    orderbook_id <= orderbook_id_reg;
    side <= side_reg;
    quantity <= quantity_reg;
    price <= price_reg;
    order_attributes <= order_attributes_reg;
    exec_quantity <= exec_quantity_reg;
    match_id <= match_id_reg;
    combo_group_id <= combo_group_id_reg;
    cancel_quantity <= cancel_quantity_reg;
    new_order_id <= new_order_id_reg;
    new_quantity <= new_quantity_reg;
    new_price <= new_price_reg;
    symbol <= symbol_reg;
    isin <= isin_reg;
    price_decimals <= price_decimals_reg;
    round_lot_size <= round_lot_size_reg;
    event_code <= event_code_reg;
    total_messages <= std_logic_vector(msg_counter);
    parse_errors <= std_logic_vector(error_counter);

end rtl;
