--------------------------------------------------------------------------------
-- Module: nasdaq_itch_parser
-- Description: ITCH 5.0 protocol parser for NASDAQ market data
--              Parses binary ITCH messages from MoldUDP64 payload stream
--              Adapted from Project 23 for FPGA1 integration
--
-- Message Format:
--   [Type:1][Fields:variable]
--
-- Implemented Message Types:
--   'A' (0x41): Add Order - no MPID (36 bytes)
--   'E' (0x45): Order Executed (31 bytes)
--   'X' (0x58): Order Cancel (23 bytes)
--   'S' (0x53): System Event (12 bytes)
--   'R' (0x52): Stock Directory (39 bytes)
--   'D' (0x44): Order Delete (19 bytes)
--   'U' (0x55): Order Replace (35 bytes)
--   'P' (0x50): Trade (non-cross) (44 bytes)
--   'Q' (0x51): Cross Trade (40 bytes)
--
-- All multi-byte fields are big-endian (network byte order).
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
use work.symbol_filter_pkg.all;

entity nasdaq_itch_parser is
    port (
        clk                 : in  std_logic;
        rst                 : in  std_logic;

        -- ITCH message interface (from MoldUDP64 handler)
        itch_msg_valid      : in  std_logic;
        itch_msg_data       : in  std_logic_vector(7 downto 0);
        itch_msg_start      : in  std_logic;
        itch_msg_end        : in  std_logic;

        -- Parsed message outputs
        msg_valid           : out std_logic;
        msg_type            : out std_logic_vector(7 downto 0);
        msg_error           : out std_logic;

        -- Add Order ('A') fields
        add_order_valid     : out std_logic;
        stock_locate        : out std_logic_vector(15 downto 0);
        tracking_number     : out std_logic_vector(15 downto 0);
        timestamp           : out std_logic_vector(47 downto 0);
        order_ref           : out std_logic_vector(63 downto 0);
        buy_sell            : out std_logic;
        shares              : out std_logic_vector(31 downto 0);
        stock_symbol        : out std_logic_vector(63 downto 0);
        price               : out std_logic_vector(31 downto 0);

        -- Order Executed ('E') fields
        order_executed_valid : out std_logic;
        exec_shares          : out std_logic_vector(31 downto 0);
        match_number         : out std_logic_vector(63 downto 0);

        -- Order Cancel ('X') fields
        order_cancel_valid  : out std_logic;
        cancel_shares       : out std_logic_vector(31 downto 0);

        -- Order Delete ('D') fields
        order_delete_valid  : out std_logic;

        -- Order Replace ('U') fields
        order_replace_valid : out std_logic;
        original_order_ref  : out std_logic_vector(63 downto 0);
        new_order_ref       : out std_logic_vector(63 downto 0);
        new_shares          : out std_logic_vector(31 downto 0);
        new_price           : out std_logic_vector(31 downto 0);

        -- Statistics
        total_messages      : out std_logic_vector(31 downto 0);
        filtered_messages   : out std_logic_vector(31 downto 0)
    );
end nasdaq_itch_parser;

architecture rtl of nasdaq_itch_parser is

    -- State machine
    type state_type is (IDLE, READ_TYPE, COUNT_BYTES, COMPLETE, ERROR);
    signal state : state_type := IDLE;

    -- Message type constants
    constant MSG_ADD_ORDER        : std_logic_vector(7 downto 0) := x"41";  -- 'A'
    constant MSG_ORDER_EXECUTED   : std_logic_vector(7 downto 0) := x"45";  -- 'E'
    constant MSG_ORDER_DELETE     : std_logic_vector(7 downto 0) := x"44";  -- 'D'
    constant MSG_ORDER_CANCEL     : std_logic_vector(7 downto 0) := x"58";  -- 'X'
    constant MSG_ORDER_REPLACE    : std_logic_vector(7 downto 0) := x"55";  -- 'U'
    constant MSG_SYSTEM_EVENT     : std_logic_vector(7 downto 0) := x"53";  -- 'S'
    constant MSG_STOCK_DIR        : std_logic_vector(7 downto 0) := x"52";  -- 'R'
    constant MSG_TRADE            : std_logic_vector(7 downto 0) := x"50";  -- 'P'
    constant MSG_CROSS_TRADE      : std_logic_vector(7 downto 0) := x"51";  -- 'Q'

    -- Message size constants (bytes)
    constant SIZE_SYSTEM_EVENT    : integer := 12;
    constant SIZE_STOCK_DIR       : integer := 39;
    constant SIZE_ADD_ORDER       : integer := 36;
    constant SIZE_ORDER_EXECUTED  : integer := 31;
    constant SIZE_ORDER_CANCEL    : integer := 23;
    constant SIZE_ORDER_DELETE    : integer := 19;
    constant SIZE_ORDER_REPLACE   : integer := 35;
    constant SIZE_TRADE           : integer := 44;
    constant SIZE_CROSS_TRADE     : integer := 40;

    -- Message parsing
    signal current_msg_type     : std_logic_vector(7 downto 0) := (others => '0');
    signal expected_length      : integer range 0 to 255 := 0;
    signal byte_counter         : integer range 0 to 255 := 0;

    -- Field extraction registers
    signal stock_locate_reg     : std_logic_vector(15 downto 0) := (others => '0');
    signal tracking_number_reg  : std_logic_vector(15 downto 0) := (others => '0');
    signal timestamp_reg        : std_logic_vector(47 downto 0) := (others => '0');
    signal order_ref_reg        : std_logic_vector(63 downto 0) := (others => '0');
    signal buy_sell_reg         : std_logic := '0';
    signal shares_reg           : std_logic_vector(31 downto 0) := (others => '0');
    signal stock_symbol_reg     : std_logic_vector(63 downto 0) := (others => '0');
    signal price_reg            : std_logic_vector(31 downto 0) := (others => '0');
    signal exec_shares_reg      : std_logic_vector(31 downto 0) := (others => '0');
    signal match_number_reg     : std_logic_vector(63 downto 0) := (others => '0');
    signal cancel_shares_reg    : std_logic_vector(31 downto 0) := (others => '0');

    -- Order Replace fields
    signal original_order_ref_reg : std_logic_vector(63 downto 0) := (others => '0');
    signal new_order_ref_reg    : std_logic_vector(63 downto 0) := (others => '0');
    signal new_shares_reg       : std_logic_vector(31 downto 0) := (others => '0');
    signal new_price_reg        : std_logic_vector(31 downto 0) := (others => '0');

    -- Statistics
    signal total_msg_counter    : unsigned(31 downto 0) := (others => '0');
    signal filtered_msg_counter : unsigned(31 downto 0) := (others => '0');

    -- Function: Get expected message length based on type
    function get_msg_length(msg_type: std_logic_vector(7 downto 0)) return integer is
    begin
        case msg_type is
            when MSG_SYSTEM_EVENT => return SIZE_SYSTEM_EVENT;
            when MSG_STOCK_DIR => return SIZE_STOCK_DIR;
            when MSG_ADD_ORDER => return SIZE_ADD_ORDER;
            when MSG_ORDER_EXECUTED => return SIZE_ORDER_EXECUTED;
            when MSG_ORDER_CANCEL => return SIZE_ORDER_CANCEL;
            when MSG_ORDER_DELETE => return SIZE_ORDER_DELETE;
            when MSG_ORDER_REPLACE => return SIZE_ORDER_REPLACE;
            when MSG_TRADE => return SIZE_TRADE;
            when MSG_CROSS_TRADE => return SIZE_CROSS_TRADE;
            when others => return 0;
        end case;
    end function;


  attribute MAX_FANOUT : integer;
  attribute MAX_FANOUT of shares_reg : signal is 16;
  attribute MAX_FANOUT of exec_shares_reg  : signal is 16;
  attribute MAX_FANOUT of cancel_shares_reg  : signal is 16;
  attribute MAX_FANOUT of msg_valid  : signal is 16;
  attribute MAX_FANOUT of msg_error  : signal is 16;
  attribute MAX_FANOUT of msg_type  : signal is 16;
  attribute MAX_FANOUT of current_msg_type  : signal is 16;
  attribute MAX_FANOUT of order_ref_reg  : signal is 16;
  attribute MAX_FANOUT of price_reg  : signal is 16;
      
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
                msg_valid <= '0';
                msg_error <= '0';
                add_order_valid <= '0';
                order_executed_valid <= '0';
                order_cancel_valid <= '0';
                order_delete_valid <= '0';
                order_replace_valid <= '0';
                total_msg_counter <= (others => '0');
                filtered_msg_counter <= (others => '0');
            else
                -- Default: clear pulse signals
                msg_valid <= '0';
                msg_error <= '0';
                add_order_valid <= '0';
                order_executed_valid <= '0';
                order_cancel_valid <= '0';
                order_delete_valid <= '0';
                order_replace_valid <= '0';

                case state is
                    when IDLE =>
                        if itch_msg_start = '1' and itch_msg_valid = '1' then
                            -- First byte is message type
                            current_msg_type <= itch_msg_data;
                            expected_length <= get_msg_length(itch_msg_data);
                            byte_counter <= 1;

                            if get_msg_length(itch_msg_data) = 0 then
                                state <= ERROR;
                            else
                                state <= COUNT_BYTES;
                            end if;
                        end if;

                    when READ_TYPE =>
                        state <= IDLE;

                    when COUNT_BYTES =>
                        if itch_msg_valid = '1' then
                            -- Extract fields based on message type and byte position
                            if current_msg_type = MSG_ADD_ORDER then
                                case byte_counter is
                                    when 1 => stock_locate_reg(15 downto 8) <= itch_msg_data;
                                    when 2 => stock_locate_reg(7 downto 0) <= itch_msg_data;
                                    when 3 => tracking_number_reg(15 downto 8) <= itch_msg_data;
                                    when 4 => tracking_number_reg(7 downto 0) <= itch_msg_data;
                                    when 5 => timestamp_reg(47 downto 40) <= itch_msg_data;
                                    when 6 => timestamp_reg(39 downto 32) <= itch_msg_data;
                                    when 7 => timestamp_reg(31 downto 24) <= itch_msg_data;
                                    when 8 => timestamp_reg(23 downto 16) <= itch_msg_data;
                                    when 9 => timestamp_reg(15 downto 8) <= itch_msg_data;
                                    when 10 => timestamp_reg(7 downto 0) <= itch_msg_data;
                                    when 11 => order_ref_reg(63 downto 56) <= itch_msg_data;
                                    when 12 => order_ref_reg(55 downto 48) <= itch_msg_data;
                                    when 13 => order_ref_reg(47 downto 40) <= itch_msg_data;
                                    when 14 => order_ref_reg(39 downto 32) <= itch_msg_data;
                                    when 15 => order_ref_reg(31 downto 24) <= itch_msg_data;
                                    when 16 => order_ref_reg(23 downto 16) <= itch_msg_data;
                                    when 17 => order_ref_reg(15 downto 8) <= itch_msg_data;
                                    when 18 => order_ref_reg(7 downto 0) <= itch_msg_data;
                                    when 19 =>
                                        if itch_msg_data = x"42" then  -- 'B'
                                            buy_sell_reg <= '1';
                                        else
                                            buy_sell_reg <= '0';
                                        end if;
                                    when 20 => shares_reg(31 downto 24) <= itch_msg_data;
                                    when 21 => shares_reg(23 downto 16) <= itch_msg_data;
                                    when 22 => shares_reg(15 downto 8) <= itch_msg_data;
                                    when 23 => shares_reg(7 downto 0) <= itch_msg_data;
                                    when 24 => stock_symbol_reg(63 downto 56) <= itch_msg_data;
                                    when 25 => stock_symbol_reg(55 downto 48) <= itch_msg_data;
                                    when 26 => stock_symbol_reg(47 downto 40) <= itch_msg_data;
                                    when 27 => stock_symbol_reg(39 downto 32) <= itch_msg_data;
                                    when 28 => stock_symbol_reg(31 downto 24) <= itch_msg_data;
                                    when 29 => stock_symbol_reg(23 downto 16) <= itch_msg_data;
                                    when 30 => stock_symbol_reg(15 downto 8) <= itch_msg_data;
                                    when 31 => stock_symbol_reg(7 downto 0) <= itch_msg_data;
                                    when 32 => price_reg(31 downto 24) <= itch_msg_data;
                                    when 33 => price_reg(23 downto 16) <= itch_msg_data;
                                    when 34 => price_reg(15 downto 8) <= itch_msg_data;
                                    when 35 => price_reg(7 downto 0) <= itch_msg_data;
                                    when others => null;
                                end case;

                            elsif current_msg_type = MSG_ORDER_EXECUTED then
                                case byte_counter is
                                    when 11 => order_ref_reg(63 downto 56) <= itch_msg_data;
                                    when 12 => order_ref_reg(55 downto 48) <= itch_msg_data;
                                    when 13 => order_ref_reg(47 downto 40) <= itch_msg_data;
                                    when 14 => order_ref_reg(39 downto 32) <= itch_msg_data;
                                    when 15 => order_ref_reg(31 downto 24) <= itch_msg_data;
                                    when 16 => order_ref_reg(23 downto 16) <= itch_msg_data;
                                    when 17 => order_ref_reg(15 downto 8) <= itch_msg_data;
                                    when 18 => order_ref_reg(7 downto 0) <= itch_msg_data;
                                    when 19 => exec_shares_reg(31 downto 24) <= itch_msg_data;
                                    when 20 => exec_shares_reg(23 downto 16) <= itch_msg_data;
                                    when 21 => exec_shares_reg(15 downto 8) <= itch_msg_data;
                                    when 22 => exec_shares_reg(7 downto 0) <= itch_msg_data;
                                    when 23 => match_number_reg(63 downto 56) <= itch_msg_data;
                                    when 24 => match_number_reg(55 downto 48) <= itch_msg_data;
                                    when 25 => match_number_reg(47 downto 40) <= itch_msg_data;
                                    when 26 => match_number_reg(39 downto 32) <= itch_msg_data;
                                    when 27 => match_number_reg(31 downto 24) <= itch_msg_data;
                                    when 28 => match_number_reg(23 downto 16) <= itch_msg_data;
                                    when 29 => match_number_reg(15 downto 8) <= itch_msg_data;
                                    when 30 => match_number_reg(7 downto 0) <= itch_msg_data;
                                    when others => null;
                                end case;

                            elsif current_msg_type = MSG_ORDER_CANCEL then
                                case byte_counter is
                                    when 11 => order_ref_reg(63 downto 56) <= itch_msg_data;
                                    when 12 => order_ref_reg(55 downto 48) <= itch_msg_data;
                                    when 13 => order_ref_reg(47 downto 40) <= itch_msg_data;
                                    when 14 => order_ref_reg(39 downto 32) <= itch_msg_data;
                                    when 15 => order_ref_reg(31 downto 24) <= itch_msg_data;
                                    when 16 => order_ref_reg(23 downto 16) <= itch_msg_data;
                                    when 17 => order_ref_reg(15 downto 8) <= itch_msg_data;
                                    when 18 => order_ref_reg(7 downto 0) <= itch_msg_data;
                                    when 19 => cancel_shares_reg(31 downto 24) <= itch_msg_data;
                                    when 20 => cancel_shares_reg(23 downto 16) <= itch_msg_data;
                                    when 21 => cancel_shares_reg(15 downto 8) <= itch_msg_data;
                                    when 22 => cancel_shares_reg(7 downto 0) <= itch_msg_data;
                                    when others => null;
                                end case;

                            elsif current_msg_type = MSG_ORDER_DELETE then
                                case byte_counter is
                                    when 11 => order_ref_reg(63 downto 56) <= itch_msg_data;
                                    when 12 => order_ref_reg(55 downto 48) <= itch_msg_data;
                                    when 13 => order_ref_reg(47 downto 40) <= itch_msg_data;
                                    when 14 => order_ref_reg(39 downto 32) <= itch_msg_data;
                                    when 15 => order_ref_reg(31 downto 24) <= itch_msg_data;
                                    when 16 => order_ref_reg(23 downto 16) <= itch_msg_data;
                                    when 17 => order_ref_reg(15 downto 8) <= itch_msg_data;
                                    when 18 => order_ref_reg(7 downto 0) <= itch_msg_data;
                                    when others => null;
                                end case;

                            elsif current_msg_type = MSG_ORDER_REPLACE then
                                -- ITCH 5.0 Replace: orig_ref(11-18), new_ref(19-26), shares(27-30), price(31-34)
                                case byte_counter is
                                    when 11 => original_order_ref_reg(63 downto 56) <= itch_msg_data;
                                    when 12 => original_order_ref_reg(55 downto 48) <= itch_msg_data;
                                    when 13 => original_order_ref_reg(47 downto 40) <= itch_msg_data;
                                    when 14 => original_order_ref_reg(39 downto 32) <= itch_msg_data;
                                    when 15 => original_order_ref_reg(31 downto 24) <= itch_msg_data;
                                    when 16 => original_order_ref_reg(23 downto 16) <= itch_msg_data;
                                    when 17 => original_order_ref_reg(15 downto 8) <= itch_msg_data;
                                    when 18 => original_order_ref_reg(7 downto 0) <= itch_msg_data;
                                    when 19 => new_order_ref_reg(63 downto 56) <= itch_msg_data;
                                    when 20 => new_order_ref_reg(55 downto 48) <= itch_msg_data;
                                    when 21 => new_order_ref_reg(47 downto 40) <= itch_msg_data;
                                    when 22 => new_order_ref_reg(39 downto 32) <= itch_msg_data;
                                    when 23 => new_order_ref_reg(31 downto 24) <= itch_msg_data;
                                    when 24 => new_order_ref_reg(23 downto 16) <= itch_msg_data;
                                    when 25 => new_order_ref_reg(15 downto 8) <= itch_msg_data;
                                    when 26 => new_order_ref_reg(7 downto 0) <= itch_msg_data;
                                    when 27 => new_shares_reg(31 downto 24) <= itch_msg_data;
                                    when 28 => new_shares_reg(23 downto 16) <= itch_msg_data;
                                    when 29 => new_shares_reg(15 downto 8) <= itch_msg_data;
                                    when 30 => new_shares_reg(7 downto 0) <= itch_msg_data;
                                    when 31 => new_price_reg(31 downto 24) <= itch_msg_data;
                                    when 32 => new_price_reg(23 downto 16) <= itch_msg_data;
                                    when 33 => new_price_reg(15 downto 8) <= itch_msg_data;
                                    when 34 => new_price_reg(7 downto 0) <= itch_msg_data;
                                    when others => null;
                                end case;
                            end if;

                            -- Check if message complete
                            if byte_counter >= (expected_length - 1) then
                                byte_counter <= byte_counter + 1;
                                state <= COMPLETE;
                            else
                                byte_counter <= byte_counter + 1;
                            end if;
                        end if;

                        -- Check for premature end
                        if itch_msg_end = '1' and byte_counter < (expected_length - 1) then
                            state <= ERROR;
                        end if;

                    when COMPLETE =>
                        total_msg_counter <= total_msg_counter + 1;

                        -- Symbol filtering
                        if current_msg_type = MSG_ADD_ORDER then
                            if is_symbol_filtered(stock_symbol_reg) then
                                msg_valid <= '1';
                                add_order_valid <= '1';
                                filtered_msg_counter <= filtered_msg_counter + 1;
                            end if;
                        elsif current_msg_type = MSG_ORDER_EXECUTED then
                            msg_valid <= '1';
                            order_executed_valid <= '1';
                            filtered_msg_counter <= filtered_msg_counter + 1;
                        elsif current_msg_type = MSG_ORDER_CANCEL then
                            msg_valid <= '1';
                            order_cancel_valid <= '1';
                            filtered_msg_counter <= filtered_msg_counter + 1;
                        elsif current_msg_type = MSG_ORDER_DELETE then
                            msg_valid <= '1';
                            order_delete_valid <= '1';
                            filtered_msg_counter <= filtered_msg_counter + 1;
                        elsif current_msg_type = MSG_ORDER_REPLACE then
                            msg_valid <= '1';
                            order_replace_valid <= '1';
                            filtered_msg_counter <= filtered_msg_counter + 1;
                        end if;

                        state <= IDLE;

                    when ERROR =>
                        msg_error <= '1';
                        state <= IDLE;

                    when others =>
                        state <= IDLE;
                end case;

                -- Force return to IDLE on message end
                if itch_msg_end = '1' then
                    if state /= COMPLETE and state /= IDLE and state /= ERROR then
                        if not (state = COUNT_BYTES and (byte_counter + 1) >= expected_length) then
                            msg_error <= '1';
                            state <= IDLE;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Output assignments
    msg_type <= current_msg_type;
    stock_locate <= stock_locate_reg;
    tracking_number <= tracking_number_reg;
    timestamp <= timestamp_reg;
    order_ref <= order_ref_reg;
    buy_sell <= buy_sell_reg;
    shares <= shares_reg;
    stock_symbol <= stock_symbol_reg;
    price <= price_reg;
    exec_shares <= exec_shares_reg;
    match_number <= match_number_reg;
    cancel_shares <= cancel_shares_reg;
    original_order_ref <= original_order_ref_reg;
    new_order_ref <= new_order_ref_reg;
    new_shares <= new_shares_reg;
    new_price <= new_price_reg;
    total_messages <= std_logic_vector(total_msg_counter);
    filtered_messages <= std_logic_vector(filtered_msg_counter);

end rtl;
