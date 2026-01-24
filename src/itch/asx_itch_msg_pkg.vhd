--------------------------------------------------------------------------------
-- Package: asx_itch_msg_pkg
-- Description: ASX ITCH message type definitions and encoding functions
--
-- ASX ITCH is based on Nasdaq Genium INET platform with key differences:
--   - Order Book ID: 32-bit (vs NASDAQ 16-bit Stock Locate)
--   - Quantity: 64-bit (vs NASDAQ 32-bit)
--   - Price: Signed 32-bit with dynamic decimals (from Directory message)
--   - No Stock Locate/Tracking Number fields
--   - Timestamp: 4-byte nanoseconds (vs NASDAQ 6-byte)
--
-- Message Types:
--   Reference Data: T (Timestamp), S (System Event), R (Order Book Directory),
--                   M (Combination Leg), L (Tick Size), O (Order Book State)
--   Order Messages: A (Add Order), F (Add Order Attributed), E (Executed),
--                   C (Executed with Price), X (Cancel), D (Delete), U (Replace)
--   Trade Messages: P (Trade), Q (Cross Trade), B (Broken Trade)
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

package asx_itch_msg_pkg is

    ----------------------------------------------------------------------------
    -- Message type enumeration (superset of NASDAQ + ASX)
    ----------------------------------------------------------------------------
    type asx_msg_type_t is (
        MSG_NONE,
        -- Reference Data
        MSG_TIMESTAMP,           -- T
        MSG_SYSTEM_EVENT,        -- S
        MSG_ORDER_BOOK_DIR,      -- R (Order Book Directory)
        MSG_COMBINATION_LEG,     -- M
        MSG_TICK_SIZE,           -- L
        MSG_ORDER_BOOK_STATE,    -- O
        -- Order Messages
        MSG_ADD_ORDER,           -- A
        MSG_ADD_ORDER_ATTRIB,    -- F (with attribution/broker ID)
        MSG_ORDER_EXECUTED,      -- E
        MSG_ORDER_EXECUTED_PRICE,-- C (executed with different price)
        MSG_ORDER_CANCEL,        -- X
        MSG_ORDER_DELETE,        -- D
        MSG_ORDER_REPLACE,       -- U
        -- Trade Messages
        MSG_TRADE,               -- P (non-cross)
        MSG_CROSS_TRADE,         -- Q
        MSG_BROKEN_TRADE,        -- B
        -- Statistics/Debug
        MSG_STATS
    );

    ----------------------------------------------------------------------------
    -- ASX-specific field widths
    ----------------------------------------------------------------------------
    constant ASX_ORDER_BOOK_ID_WIDTH : integer := 32;  -- vs NASDAQ 16-bit locate
    constant ASX_ORDER_ID_WIDTH      : integer := 64;  -- Same as NASDAQ
    constant ASX_QUANTITY_WIDTH      : integer := 64;  -- vs NASDAQ 32-bit
    constant ASX_PRICE_WIDTH         : integer := 32;  -- Same, but signed
    constant ASX_TIMESTAMP_WIDTH     : integer := 32;  -- 4 bytes (nanos only)

    ----------------------------------------------------------------------------
    -- Message sizes (bytes, including type byte)
    ----------------------------------------------------------------------------
    constant SIZE_ASX_TIMESTAMP         : integer := 5;   -- T
    constant SIZE_ASX_SYSTEM_EVENT      : integer := 6;   -- S
    constant SIZE_ASX_ORDER_BOOK_DIR    : integer := 57;  -- R
    constant SIZE_ASX_COMBINATION_LEG   : integer := 21;  -- M
    constant SIZE_ASX_TICK_SIZE         : integer := 22;  -- L
    constant SIZE_ASX_ORDER_BOOK_STATE  : integer := 10;  -- O
    constant SIZE_ASX_ADD_ORDER         : integer := 39;  -- A
    constant SIZE_ASX_ADD_ORDER_ATTRIB  : integer := 40;  -- F
    constant SIZE_ASX_ORDER_EXECUTED    : integer := 31;  -- E
    constant SIZE_ASX_ORDER_EXEC_PRICE  : integer := 40;  -- C
    constant SIZE_ASX_ORDER_CANCEL      : integer := 19;  -- X
    constant SIZE_ASX_ORDER_DELETE      : integer := 15;  -- D
    constant SIZE_ASX_ORDER_REPLACE     : integer := 45;  -- U
    constant SIZE_ASX_TRADE             : integer := 37;  -- P
    constant SIZE_ASX_CROSS_TRADE       : integer := 41;  -- Q
    constant SIZE_ASX_BROKEN_TRADE      : integer := 15;  -- B

    ----------------------------------------------------------------------------
    -- Message type constants (ASCII)
    ----------------------------------------------------------------------------
    constant ASX_MSG_TIMESTAMP          : std_logic_vector(7 downto 0) := x"54";  -- 'T'
    constant ASX_MSG_SYSTEM_EVENT       : std_logic_vector(7 downto 0) := x"53";  -- 'S'
    constant ASX_MSG_ORDER_BOOK_DIR     : std_logic_vector(7 downto 0) := x"52";  -- 'R'
    constant ASX_MSG_COMBINATION_LEG    : std_logic_vector(7 downto 0) := x"4D";  -- 'M'
    constant ASX_MSG_TICK_SIZE          : std_logic_vector(7 downto 0) := x"4C";  -- 'L'
    constant ASX_MSG_ORDER_BOOK_STATE   : std_logic_vector(7 downto 0) := x"4F";  -- 'O'
    constant ASX_MSG_ADD_ORDER          : std_logic_vector(7 downto 0) := x"41";  -- 'A'
    constant ASX_MSG_ADD_ORDER_ATTRIB   : std_logic_vector(7 downto 0) := x"46";  -- 'F'
    constant ASX_MSG_ORDER_EXECUTED     : std_logic_vector(7 downto 0) := x"45";  -- 'E'
    constant ASX_MSG_ORDER_EXEC_PRICE   : std_logic_vector(7 downto 0) := x"43";  -- 'C'
    constant ASX_MSG_ORDER_CANCEL       : std_logic_vector(7 downto 0) := x"58";  -- 'X'
    constant ASX_MSG_ORDER_DELETE       : std_logic_vector(7 downto 0) := x"44";  -- 'D'
    constant ASX_MSG_ORDER_REPLACE      : std_logic_vector(7 downto 0) := x"55";  -- 'U'
    constant ASX_MSG_TRADE              : std_logic_vector(7 downto 0) := x"50";  -- 'P'
    constant ASX_MSG_CROSS_TRADE        : std_logic_vector(7 downto 0) := x"51";  -- 'Q'
    constant ASX_MSG_BROKEN_TRADE       : std_logic_vector(7 downto 0) := x"42";  -- 'B'

    ----------------------------------------------------------------------------
    -- FIFO message format (for CDC between clock domains)
    -- Wider than NASDAQ due to 32-bit Order Book ID and 64-bit quantity
    ----------------------------------------------------------------------------
    constant ASX_MSG_TYPE_BITS  : integer := 5;   -- 32 message types
    constant ASX_MSG_DATA_BITS  : integer := 384; -- Max data needed
    constant ASX_MSG_FIFO_WIDTH : integer := ASX_MSG_TYPE_BITS + ASX_MSG_DATA_BITS;

    ----------------------------------------------------------------------------
    -- Order Book Directory record (from 'R' message)
    -- Stores decimal places for dynamic price scaling
    ----------------------------------------------------------------------------
    type orderbook_info_t is record
        orderbook_id    : std_logic_vector(31 downto 0);
        symbol          : std_logic_vector(63 downto 0);   -- 8 ASCII chars
        isin            : std_logic_vector(95 downto 0);   -- 12 ASCII chars
        currency        : std_logic_vector(23 downto 0);   -- 3 ASCII chars
        price_decimals  : unsigned(7 downto 0);            -- Number of decimal places
        nominal_value   : unsigned(31 downto 0);
        odd_lot_size    : unsigned(31 downto 0);
        round_lot_size  : unsigned(31 downto 0);
        block_lot_size  : unsigned(31 downto 0);
    end record;

    ----------------------------------------------------------------------------
    -- Helper functions
    ----------------------------------------------------------------------------
    function encode_asx_msg_type(msg_type : asx_msg_type_t) return std_logic_vector;
    function decode_asx_msg_type(encoded : std_logic_vector(ASX_MSG_TYPE_BITS-1 downto 0)) return asx_msg_type_t;
    function get_asx_msg_length(msg_type : std_logic_vector(7 downto 0)) return integer;

    ----------------------------------------------------------------------------
    -- Message encoding functions (for FIFO transport)
    ----------------------------------------------------------------------------
    function encode_asx_add_order(
        timestamp       : std_logic_vector(31 downto 0);
        order_id        : std_logic_vector(63 downto 0);
        orderbook_id    : std_logic_vector(31 downto 0);
        side            : std_logic;  -- '1'=Buy, '0'=Sell
        quantity        : std_logic_vector(63 downto 0);
        price           : std_logic_vector(31 downto 0);
        attributes      : std_logic_vector(15 downto 0)
    ) return std_logic_vector;

    function encode_asx_order_executed(
        timestamp       : std_logic_vector(31 downto 0);
        order_id        : std_logic_vector(63 downto 0);
        orderbook_id    : std_logic_vector(31 downto 0);
        side            : std_logic;
        exec_quantity   : std_logic_vector(63 downto 0);
        match_id        : std_logic_vector(63 downto 0);
        combo_group_id  : std_logic_vector(31 downto 0)
    ) return std_logic_vector;

    function encode_asx_order_delete(
        timestamp       : std_logic_vector(31 downto 0);
        order_id        : std_logic_vector(63 downto 0);
        orderbook_id    : std_logic_vector(31 downto 0);
        side            : std_logic
    ) return std_logic_vector;

end package asx_itch_msg_pkg;

package body asx_itch_msg_pkg is

    ----------------------------------------------------------------------------
    -- Encode message type to binary
    ----------------------------------------------------------------------------
    function encode_asx_msg_type(msg_type : asx_msg_type_t) return std_logic_vector is
        variable result : std_logic_vector(ASX_MSG_TYPE_BITS-1 downto 0);
    begin
        case msg_type is
            when MSG_NONE               => result := "00000";
            when MSG_TIMESTAMP          => result := "00001";
            when MSG_SYSTEM_EVENT       => result := "00010";
            when MSG_ORDER_BOOK_DIR     => result := "00011";
            when MSG_COMBINATION_LEG    => result := "00100";
            when MSG_TICK_SIZE          => result := "00101";
            when MSG_ORDER_BOOK_STATE   => result := "00110";
            when MSG_ADD_ORDER          => result := "00111";
            when MSG_ADD_ORDER_ATTRIB   => result := "01000";
            when MSG_ORDER_EXECUTED     => result := "01001";
            when MSG_ORDER_EXECUTED_PRICE => result := "01010";
            when MSG_ORDER_CANCEL       => result := "01011";
            when MSG_ORDER_DELETE       => result := "01100";
            when MSG_ORDER_REPLACE      => result := "01101";
            when MSG_TRADE              => result := "01110";
            when MSG_CROSS_TRADE        => result := "01111";
            when MSG_BROKEN_TRADE       => result := "10000";
            when MSG_STATS              => result := "11111";
            when others                 => result := "00000";
        end case;
        return result;
    end function;

    ----------------------------------------------------------------------------
    -- Decode binary to message type
    ----------------------------------------------------------------------------
    function decode_asx_msg_type(encoded : std_logic_vector(ASX_MSG_TYPE_BITS-1 downto 0)) return asx_msg_type_t is
    begin
        case encoded is
            when "00000" => return MSG_NONE;
            when "00001" => return MSG_TIMESTAMP;
            when "00010" => return MSG_SYSTEM_EVENT;
            when "00011" => return MSG_ORDER_BOOK_DIR;
            when "00100" => return MSG_COMBINATION_LEG;
            when "00101" => return MSG_TICK_SIZE;
            when "00110" => return MSG_ORDER_BOOK_STATE;
            when "00111" => return MSG_ADD_ORDER;
            when "01000" => return MSG_ADD_ORDER_ATTRIB;
            when "01001" => return MSG_ORDER_EXECUTED;
            when "01010" => return MSG_ORDER_EXECUTED_PRICE;
            when "01011" => return MSG_ORDER_CANCEL;
            when "01100" => return MSG_ORDER_DELETE;
            when "01101" => return MSG_ORDER_REPLACE;
            when "01110" => return MSG_TRADE;
            when "01111" => return MSG_CROSS_TRADE;
            when "10000" => return MSG_BROKEN_TRADE;
            when "11111" => return MSG_STATS;
            when others  => return MSG_NONE;
        end case;
    end function;

    ----------------------------------------------------------------------------
    -- Get message length from type byte
    ----------------------------------------------------------------------------
    function get_asx_msg_length(msg_type : std_logic_vector(7 downto 0)) return integer is
    begin
        case msg_type is
            when ASX_MSG_TIMESTAMP         => return SIZE_ASX_TIMESTAMP;
            when ASX_MSG_SYSTEM_EVENT      => return SIZE_ASX_SYSTEM_EVENT;
            when ASX_MSG_ORDER_BOOK_DIR    => return SIZE_ASX_ORDER_BOOK_DIR;
            when ASX_MSG_COMBINATION_LEG   => return SIZE_ASX_COMBINATION_LEG;
            when ASX_MSG_TICK_SIZE         => return SIZE_ASX_TICK_SIZE;
            when ASX_MSG_ORDER_BOOK_STATE  => return SIZE_ASX_ORDER_BOOK_STATE;
            when ASX_MSG_ADD_ORDER         => return SIZE_ASX_ADD_ORDER;
            when ASX_MSG_ADD_ORDER_ATTRIB  => return SIZE_ASX_ADD_ORDER_ATTRIB;
            when ASX_MSG_ORDER_EXECUTED    => return SIZE_ASX_ORDER_EXECUTED;
            when ASX_MSG_ORDER_EXEC_PRICE  => return SIZE_ASX_ORDER_EXEC_PRICE;
            when ASX_MSG_ORDER_CANCEL      => return SIZE_ASX_ORDER_CANCEL;
            when ASX_MSG_ORDER_DELETE      => return SIZE_ASX_ORDER_DELETE;
            when ASX_MSG_ORDER_REPLACE     => return SIZE_ASX_ORDER_REPLACE;
            when ASX_MSG_TRADE             => return SIZE_ASX_TRADE;
            when ASX_MSG_CROSS_TRADE       => return SIZE_ASX_CROSS_TRADE;
            when ASX_MSG_BROKEN_TRADE      => return SIZE_ASX_BROKEN_TRADE;
            when others                    => return 0;
        end case;
    end function;

    ----------------------------------------------------------------------------
    -- Encode ASX Add Order message for FIFO
    -- Layout: timestamp(32) & order_id(64) & orderbook_id(32) & side(1) &
    --         quantity(64) & price(32) & attributes(16) = 241 bits
    ----------------------------------------------------------------------------
    function encode_asx_add_order(
        timestamp       : std_logic_vector(31 downto 0);
        order_id        : std_logic_vector(63 downto 0);
        orderbook_id    : std_logic_vector(31 downto 0);
        side            : std_logic;
        quantity        : std_logic_vector(63 downto 0);
        price           : std_logic_vector(31 downto 0);
        attributes      : std_logic_vector(15 downto 0)
    ) return std_logic_vector is
        variable result : std_logic_vector(ASX_MSG_DATA_BITS-1 downto 0) := (others => '0');
    begin
        result(31 downto 0)     := timestamp;
        result(95 downto 32)    := order_id;
        result(127 downto 96)   := orderbook_id;
        result(128)             := side;
        result(192 downto 129)  := quantity;
        result(224 downto 193)  := price;
        result(240 downto 225)  := attributes;
        return result;
    end function;

    ----------------------------------------------------------------------------
    -- Encode ASX Order Executed message for FIFO
    ----------------------------------------------------------------------------
    function encode_asx_order_executed(
        timestamp       : std_logic_vector(31 downto 0);
        order_id        : std_logic_vector(63 downto 0);
        orderbook_id    : std_logic_vector(31 downto 0);
        side            : std_logic;
        exec_quantity   : std_logic_vector(63 downto 0);
        match_id        : std_logic_vector(63 downto 0);
        combo_group_id  : std_logic_vector(31 downto 0)
    ) return std_logic_vector is
        variable result : std_logic_vector(ASX_MSG_DATA_BITS-1 downto 0) := (others => '0');
    begin
        result(31 downto 0)     := timestamp;
        result(95 downto 32)    := order_id;
        result(127 downto 96)   := orderbook_id;
        result(128)             := side;
        result(192 downto 129)  := exec_quantity;
        result(256 downto 193)  := match_id;
        result(288 downto 257)  := combo_group_id;
        return result;
    end function;

    ----------------------------------------------------------------------------
    -- Encode ASX Order Delete message for FIFO
    ----------------------------------------------------------------------------
    function encode_asx_order_delete(
        timestamp       : std_logic_vector(31 downto 0);
        order_id        : std_logic_vector(63 downto 0);
        orderbook_id    : std_logic_vector(31 downto 0);
        side            : std_logic
    ) return std_logic_vector is
        variable result : std_logic_vector(ASX_MSG_DATA_BITS-1 downto 0) := (others => '0');
    begin
        result(31 downto 0)     := timestamp;
        result(95 downto 32)    := order_id;
        result(127 downto 96)   := orderbook_id;
        result(128)             := side;
        return result;
    end function;

end package body asx_itch_msg_pkg;
