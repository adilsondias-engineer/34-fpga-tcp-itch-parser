--------------------------------------------------------------------------------
-- Module: itch_message_mux
-- Description: Multiplexes NASDAQ and ASX ITCH messages for Aurora TX
--
-- Combines parsed messages from both NASDAQ (UDP) and ASX (TCP) ITCH parsers
-- into a unified message stream for transmission to FPGA2 (order book engine).
--
-- Message Priority:
--   - Round-robin between NASDAQ and ASX when both have messages
--   - Immediate service when only one source has messages
--
-- Output Format (to Aurora TX):
--   - 8-bit market indicator (0=NASDAQ, 1=ASX)
--   - Message type and fields in standardized format
--
-- Clock Domain: 156.25 MHz (XGMII/Aurora clock)
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

entity itch_message_mux is
    port (
        clk                 : in  std_logic;
        rst                 : in  std_logic;

        -- NASDAQ ITCH input (from itch_parser)
        nasdaq_msg_valid    : in  std_logic;
        nasdaq_msg_type     : in  std_logic_vector(7 downto 0);
        nasdaq_timestamp    : in  std_logic_vector(47 downto 0);
        nasdaq_order_ref    : in  std_logic_vector(63 downto 0);
        nasdaq_stock_locate : in  std_logic_vector(15 downto 0);
        nasdaq_buy_sell     : in  std_logic;
        nasdaq_shares       : in  std_logic_vector(31 downto 0);
        nasdaq_price        : in  std_logic_vector(31 downto 0);
        nasdaq_stock_symbol : in  std_logic_vector(63 downto 0);
        nasdaq_exec_shares  : in  std_logic_vector(31 downto 0);
        nasdaq_cancel_shares: in  std_logic_vector(31 downto 0);

        -- ASX ITCH input (from asx_itch_parser)
        asx_msg_valid       : in  std_logic;
        asx_msg_type        : in  std_logic_vector(7 downto 0);
        asx_timestamp       : in  std_logic_vector(31 downto 0);
        asx_order_id        : in  std_logic_vector(63 downto 0);
        asx_orderbook_id    : in  std_logic_vector(31 downto 0);
        asx_side            : in  std_logic;
        asx_quantity        : in  std_logic_vector(63 downto 0);
        asx_price           : in  std_logic_vector(31 downto 0);
        asx_exec_quantity   : in  std_logic_vector(63 downto 0);
        asx_cancel_quantity : in  std_logic_vector(63 downto 0);

        -- Unified output (to Aurora TX)
        out_msg_valid       : out std_logic;
        out_msg_type        : out std_logic_vector(7 downto 0);
        out_msg_market      : out std_logic_vector(7 downto 0);  -- 0=NASDAQ, 1=ASX
        out_msg_data        : out std_logic_vector(63 downto 0);
        out_msg_data_valid  : out std_logic;
        out_msg_last        : out std_logic;
        out_msg_ready       : in  std_logic;

        -- Statistics
        nasdaq_msg_count    : out std_logic_vector(31 downto 0);
        asx_msg_count       : out std_logic_vector(31 downto 0)
    );
end itch_message_mux;

architecture rtl of itch_message_mux is

    -- Market identifiers
    constant MARKET_NASDAQ  : std_logic_vector(7 downto 0) := x"00";
    constant MARKET_ASX     : std_logic_vector(7 downto 0) := x"01";

    -- State machine
    type state_type is (
        IDLE,
        SEND_NASDAQ_W1,
        SEND_NASDAQ_W2,
        SEND_NASDAQ_W3,
        SEND_ASX_W1,
        SEND_ASX_W2,
        SEND_ASX_W3
    );
    signal state : state_type := IDLE;

    -- Round-robin selector
    signal last_served      : std_logic := '0';  -- '0'=NASDAQ, '1'=ASX

    -- Latched message fields
    signal lat_nasdaq_type  : std_logic_vector(7 downto 0);
    signal lat_nasdaq_ts    : std_logic_vector(47 downto 0);
    signal lat_nasdaq_ref   : std_logic_vector(63 downto 0);
    signal lat_nasdaq_loc   : std_logic_vector(15 downto 0);
    signal lat_nasdaq_side  : std_logic;
    signal lat_nasdaq_qty   : std_logic_vector(31 downto 0);
    signal lat_nasdaq_price : std_logic_vector(31 downto 0);

    signal lat_asx_type     : std_logic_vector(7 downto 0);
    signal lat_asx_ts       : std_logic_vector(31 downto 0);
    signal lat_asx_id       : std_logic_vector(63 downto 0);
    signal lat_asx_book     : std_logic_vector(31 downto 0);
    signal lat_asx_side     : std_logic;
    signal lat_asx_qty      : std_logic_vector(63 downto 0);
    signal lat_asx_price    : std_logic_vector(31 downto 0);

    -- Statistics counters
    signal nasdaq_cnt       : unsigned(31 downto 0) := (others => '0');
    signal asx_cnt          : unsigned(31 downto 0) := (others => '0');

    -- Output registers
    signal out_valid_reg    : std_logic := '0';
    signal out_type_reg     : std_logic_vector(7 downto 0) := (others => '0');
    signal out_market_reg   : std_logic_vector(7 downto 0) := (others => '0');
    signal out_data_reg     : std_logic_vector(63 downto 0) := (others => '0');
    signal out_data_valid_reg : std_logic := '0';
    signal out_last_reg     : std_logic := '0';

begin

    -- Mux state machine
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= IDLE;
                last_served <= '0';
                nasdaq_cnt <= (others => '0');
                asx_cnt <= (others => '0');
                out_valid_reg <= '0';
                out_data_valid_reg <= '0';
                out_last_reg <= '0';
            else
                -- Default: clear output signals
                out_valid_reg <= '0';
                out_data_valid_reg <= '0';
                out_last_reg <= '0';

                case state is
                    when IDLE =>
                        if out_msg_ready = '1' then
                            -- Round-robin selection
                            if nasdaq_msg_valid = '1' and asx_msg_valid = '1' then
                                -- Both have messages, use round-robin
                                if last_served = '1' then
                                    -- Serve NASDAQ
                                    lat_nasdaq_type <= nasdaq_msg_type;
                                    lat_nasdaq_ts <= nasdaq_timestamp;
                                    lat_nasdaq_ref <= nasdaq_order_ref;
                                    lat_nasdaq_loc <= nasdaq_stock_locate;
                                    lat_nasdaq_side <= nasdaq_buy_sell;
                                    lat_nasdaq_qty <= nasdaq_shares;
                                    lat_nasdaq_price <= nasdaq_price;
                                    state <= SEND_NASDAQ_W1;
                                    last_served <= '0';
                                else
                                    -- Serve ASX
                                    lat_asx_type <= asx_msg_type;
                                    lat_asx_ts <= asx_timestamp;
                                    lat_asx_id <= asx_order_id;
                                    lat_asx_book <= asx_orderbook_id;
                                    lat_asx_side <= asx_side;
                                    lat_asx_qty <= asx_quantity;
                                    lat_asx_price <= asx_price;
                                    state <= SEND_ASX_W1;
                                    last_served <= '1';
                                end if;
                            elsif nasdaq_msg_valid = '1' then
                                -- Only NASDAQ
                                lat_nasdaq_type <= nasdaq_msg_type;
                                lat_nasdaq_ts <= nasdaq_timestamp;
                                lat_nasdaq_ref <= nasdaq_order_ref;
                                lat_nasdaq_loc <= nasdaq_stock_locate;
                                lat_nasdaq_side <= nasdaq_buy_sell;
                                lat_nasdaq_qty <= nasdaq_shares;
                                lat_nasdaq_price <= nasdaq_price;
                                state <= SEND_NASDAQ_W1;
                                last_served <= '0';
                            elsif asx_msg_valid = '1' then
                                -- Only ASX
                                lat_asx_type <= asx_msg_type;
                                lat_asx_ts <= asx_timestamp;
                                lat_asx_id <= asx_order_id;
                                lat_asx_book <= asx_orderbook_id;
                                lat_asx_side <= asx_side;
                                lat_asx_qty <= asx_quantity;
                                lat_asx_price <= asx_price;
                                state <= SEND_ASX_W1;
                                last_served <= '1';
                            end if;
                        end if;

                    -- NASDAQ message output (3 words)
                    when SEND_NASDAQ_W1 =>
                        out_valid_reg <= '1';
                        out_type_reg <= lat_nasdaq_type;
                        out_market_reg <= MARKET_NASDAQ;
                        -- Word 1: timestamp(48) + stock_locate(16)
                        out_data_reg <= lat_nasdaq_ts & lat_nasdaq_loc;
                        out_data_valid_reg <= '1';
                        nasdaq_cnt <= nasdaq_cnt + 1;
                        state <= SEND_NASDAQ_W2;

                    when SEND_NASDAQ_W2 =>
                        -- Word 2: order_ref(64)
                        out_data_reg <= lat_nasdaq_ref;
                        out_data_valid_reg <= '1';
                        state <= SEND_NASDAQ_W3;

                    when SEND_NASDAQ_W3 =>
                        -- Word 3: side(8) + qty(32) + price(24 MSB)
                        out_data_reg <= "0000000" & lat_nasdaq_side & lat_nasdaq_qty & lat_nasdaq_price(31 downto 8);
                        out_data_valid_reg <= '1';
                        out_last_reg <= '1';
                        state <= IDLE;

                    -- ASX message output (3 words)
                    when SEND_ASX_W1 =>
                        out_valid_reg <= '1';
                        out_type_reg <= lat_asx_type;
                        out_market_reg <= MARKET_ASX;
                        -- Word 1: timestamp(32) + orderbook_id(32)
                        out_data_reg <= lat_asx_ts & lat_asx_book;
                        out_data_valid_reg <= '1';
                        asx_cnt <= asx_cnt + 1;
                        state <= SEND_ASX_W2;

                    when SEND_ASX_W2 =>
                        -- Word 2: order_id(64)
                        out_data_reg <= lat_asx_id;
                        out_data_valid_reg <= '1';
                        state <= SEND_ASX_W3;

                    when SEND_ASX_W3 =>
                        -- Word 3: side(8) + qty_low(32) + price(24 MSB)
                        out_data_reg <= "0000000" & lat_asx_side & lat_asx_qty(31 downto 0) & lat_asx_price(31 downto 8);
                        out_data_valid_reg <= '1';
                        out_last_reg <= '1';
                        state <= IDLE;
                end case;
            end if;
        end if;
    end process;

    -- Output assignments
    out_msg_valid <= out_valid_reg;
    out_msg_type <= out_type_reg;
    out_msg_market <= out_market_reg;
    out_msg_data <= out_data_reg;
    out_msg_data_valid <= out_data_valid_reg;
    out_msg_last <= out_last_reg;

    nasdaq_msg_count <= std_logic_vector(nasdaq_cnt);
    asx_msg_count <= std_logic_vector(asx_cnt);

end rtl;
