--------------------------------------------------------------------------------
-- Package: itch_msg_common_pkg
-- Description: Shared message types and constants for both NASDAQ and ASX ITCH
--              Used for unified message format to FPGA2 order book engine
--
-- This package defines the common interface between:
--   - NASDAQ ITCH parser (UDP/MoldUDP64)
--   - ASX ITCH parser (TCP/SoupBinTCP)
--   - Aurora TX to FPGA2
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

package itch_msg_common_pkg is

    -- Market source indicator
    constant MARKET_NASDAQ : std_logic := '0';
    constant MARKET_ASX    : std_logic := '1';

    -- Message type enumeration (unified across markets)
    type msg_type_t is (
        MSG_NONE,
        MSG_SYSTEM_EVENT,      -- S
        MSG_STOCK_DIRECTORY,   -- R
        MSG_ADD_ORDER,         -- A
        MSG_ORDER_EXECUTED,    -- E
        MSG_ORDER_CANCEL,      -- X
        MSG_TRADE_NON_CROSS,   -- P
        MSG_TRADE_CROSS,       -- Q
        MSG_ORDER_REPLACE,     -- U
        MSG_ORDER_DELETE,      -- D
        MSG_STATS
    );

    -- Unified message format for Aurora TX
    -- Uses wider fields to accommodate both NASDAQ and ASX formats
    constant MSG_TYPE_BITS    : integer := 4;   -- Enough for 16 message types
    constant MSG_MARKET_BITS  : integer := 1;   -- NASDAQ=0, ASX=1
    constant MSG_DATA_BITS    : integer := 384; -- Wide enough for ASX 64-bit quantities
    constant MSG_FIFO_WIDTH   : integer := MSG_TYPE_BITS + MSG_MARKET_BITS + MSG_DATA_BITS;

    -- Field widths (unified - uses maximum of NASDAQ/ASX)
    constant ORDER_ID_WIDTH   : integer := 64;  -- Same for both
    constant QUANTITY_WIDTH   : integer := 64;  -- ASX uses 64-bit, NASDAQ 32-bit (zero-extend)
    constant PRICE_WIDTH      : integer := 32;  -- Same for both
    constant SYMBOL_WIDTH     : integer := 64;  -- 8 bytes for both
    constant TIMESTAMP_WIDTH  : integer := 48;  -- NASDAQ 48-bit, ASX 32-bit (zero-extend)
    constant BOOK_ID_WIDTH    : integer := 32;  -- ASX Order Book ID (NASDAQ Stock Locate is 16-bit)

    -- Helper functions to encode/decode message type
    function encode_msg_type(msg_type : msg_type_t) return std_logic_vector;
    function decode_msg_type(encoded : std_logic_vector(MSG_TYPE_BITS-1 downto 0)) return msg_type_t;

    -- Unified message encoding functions
    -- These work for both NASDAQ and ASX with appropriate field widths

    function encode_add_order(
        market       : std_logic;                        -- NASDAQ=0, ASX=1
        order_ref    : std_logic_vector(63 downto 0);    -- Order reference
        book_id      : std_logic_vector(31 downto 0);    -- Order Book ID (ASX) or Stock Locate (NASDAQ, zero-extended)
        buy_sell     : std_logic;                        -- '1'=Buy, '0'=Sell
        quantity     : std_logic_vector(63 downto 0);    -- Quantity (64-bit for ASX, 32-bit zero-extended for NASDAQ)
        symbol       : std_logic_vector(63 downto 0);    -- 8-char symbol
        price        : std_logic_vector(31 downto 0);    -- Price
        timestamp    : std_logic_vector(47 downto 0)     -- Timestamp
    ) return std_logic_vector;

    function encode_order_executed(
        market       : std_logic;
        order_ref    : std_logic_vector(63 downto 0);
        exec_qty     : std_logic_vector(63 downto 0);    -- Executed quantity
        match_number : std_logic_vector(63 downto 0)
    ) return std_logic_vector;

    function encode_order_cancel(
        market       : std_logic;
        order_ref    : std_logic_vector(63 downto 0);
        cancel_qty   : std_logic_vector(63 downto 0)     -- Cancelled quantity
    ) return std_logic_vector;

    function encode_order_delete(
        market       : std_logic;
        order_ref    : std_logic_vector(63 downto 0)
    ) return std_logic_vector;

    function encode_order_replace(
        market       : std_logic;
        orig_order   : std_logic_vector(63 downto 0);
        new_order    : std_logic_vector(63 downto 0);
        new_qty      : std_logic_vector(63 downto 0);
        new_price    : std_logic_vector(31 downto 0)
    ) return std_logic_vector;

end package itch_msg_common_pkg;

package body itch_msg_common_pkg is

    function encode_msg_type(msg_type : msg_type_t) return std_logic_vector is
        variable result : std_logic_vector(MSG_TYPE_BITS-1 downto 0);
    begin
        case msg_type is
            when MSG_NONE            => result := "0000";
            when MSG_SYSTEM_EVENT    => result := "0001";
            when MSG_STOCK_DIRECTORY => result := "0010";
            when MSG_ADD_ORDER       => result := "0011";
            when MSG_ORDER_EXECUTED  => result := "0100";
            when MSG_ORDER_CANCEL    => result := "0101";
            when MSG_TRADE_NON_CROSS => result := "0110";
            when MSG_TRADE_CROSS     => result := "0111";
            when MSG_ORDER_REPLACE   => result := "1000";
            when MSG_ORDER_DELETE    => result := "1001";
            when MSG_STATS           => result := "1111";
            when others              => result := "0000";
        end case;
        return result;
    end function;

    function decode_msg_type(encoded : std_logic_vector(MSG_TYPE_BITS-1 downto 0)) return msg_type_t is
    begin
        case encoded is
            when "0000" => return MSG_NONE;
            when "0001" => return MSG_SYSTEM_EVENT;
            when "0010" => return MSG_STOCK_DIRECTORY;
            when "0011" => return MSG_ADD_ORDER;
            when "0100" => return MSG_ORDER_EXECUTED;
            when "0101" => return MSG_ORDER_CANCEL;
            when "0110" => return MSG_TRADE_NON_CROSS;
            when "0111" => return MSG_TRADE_CROSS;
            when "1000" => return MSG_ORDER_REPLACE;
            when "1001" => return MSG_ORDER_DELETE;
            when "1111" => return MSG_STATS;
            when others => return MSG_NONE;
        end case;
    end function;

    -- Encode Add Order message
    -- Layout: market(1) & order_ref(64) & book_id(32) & buy_sell(1) & quantity(64) & symbol(64) & price(32) & timestamp(48)
    function encode_add_order(
        market       : std_logic;
        order_ref    : std_logic_vector(63 downto 0);
        book_id      : std_logic_vector(31 downto 0);
        buy_sell     : std_logic;
        quantity     : std_logic_vector(63 downto 0);
        symbol       : std_logic_vector(63 downto 0);
        price        : std_logic_vector(31 downto 0);
        timestamp    : std_logic_vector(47 downto 0)
    ) return std_logic_vector is
        variable result : std_logic_vector(MSG_DATA_BITS-1 downto 0) := (others => '0');
    begin
        result(0) := market;
        result(64 downto 1) := order_ref;
        result(96 downto 65) := book_id;
        result(97) := buy_sell;
        result(161 downto 98) := quantity;
        result(225 downto 162) := symbol;
        result(257 downto 226) := price;
        result(305 downto 258) := timestamp;
        return result;
    end function;

    -- Encode Order Executed message
    function encode_order_executed(
        market       : std_logic;
        order_ref    : std_logic_vector(63 downto 0);
        exec_qty     : std_logic_vector(63 downto 0);
        match_number : std_logic_vector(63 downto 0)
    ) return std_logic_vector is
        variable result : std_logic_vector(MSG_DATA_BITS-1 downto 0) := (others => '0');
    begin
        result(0) := market;
        result(64 downto 1) := order_ref;
        result(128 downto 65) := exec_qty;
        result(192 downto 129) := match_number;
        return result;
    end function;

    -- Encode Order Cancel message
    function encode_order_cancel(
        market       : std_logic;
        order_ref    : std_logic_vector(63 downto 0);
        cancel_qty   : std_logic_vector(63 downto 0)
    ) return std_logic_vector is
        variable result : std_logic_vector(MSG_DATA_BITS-1 downto 0) := (others => '0');
    begin
        result(0) := market;
        result(64 downto 1) := order_ref;
        result(128 downto 65) := cancel_qty;
        return result;
    end function;

    -- Encode Order Delete message
    function encode_order_delete(
        market       : std_logic;
        order_ref    : std_logic_vector(63 downto 0)
    ) return std_logic_vector is
        variable result : std_logic_vector(MSG_DATA_BITS-1 downto 0) := (others => '0');
    begin
        result(0) := market;
        result(64 downto 1) := order_ref;
        return result;
    end function;

    -- Encode Order Replace message
    function encode_order_replace(
        market       : std_logic;
        orig_order   : std_logic_vector(63 downto 0);
        new_order    : std_logic_vector(63 downto 0);
        new_qty      : std_logic_vector(63 downto 0);
        new_price    : std_logic_vector(31 downto 0)
    ) return std_logic_vector is
        variable result : std_logic_vector(MSG_DATA_BITS-1 downto 0) := (others => '0');
    begin
        result(0) := market;
        result(64 downto 1) := orig_order;
        result(128 downto 65) := new_order;
        result(192 downto 129) := new_qty;
        result(224 downto 193) := new_price;
        return result;
    end function;

end package body itch_msg_common_pkg;
