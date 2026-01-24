--------------------------------------------------------------------------------
-- Package: symbol_filter_pkg
-- Description: Symbol filtering package for ITCH parser (NASDAQ and ASX)
--              Configurable symbol list for filtering market data messages
--              Copied from Project 23, extended for dual-market support
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

package symbol_filter_pkg is

    -- Symbol configuration
    constant SYMBOL_WIDTH : integer := 64; -- 8 bytes = 64 bits
    constant MAX_SYMBOLS  : integer := 16;  -- Support up to 16 symbols (8 NASDAQ + 8 ASX)

    -- Symbol filter list (8 bytes each, space-padded)
    -- NASDAQ symbols: AAPL, TSLA, SPY, QQQ, GOOGL, MSFT, AMZN, NVDA
    -- ASX symbols: BHP, CBA, CSL, WBC, NAB, ANZ, WES, WOW
    type symbol_array_t is array (0 to MAX_SYMBOLS-1) of std_logic_vector(SYMBOL_WIDTH-1 downto 0);

    constant FILTER_SYMBOL_LIST : symbol_array_t := (
        -- NASDAQ symbols
        0 => x"4141504C20202020",  -- "AAPL    "
        1 => x"54534C4120202020",  -- "TSLA    "
        2 => x"5350592020202020",  -- "SPY     "
        3 => x"5151512020202020",  -- "QQQ     "
        4 => x"474F4F474C202020",  -- "GOOGL   "
        5 => x"4D53465420202020",  -- "MSFT    "
        6 => x"414D5A4E20202020",  -- "AMZN    "
        7 => x"4E56444120202020",  -- "NVDA    "
        -- ASX symbols
        8  => x"4248502020202020",  -- "BHP     "
        9  => x"4342412020202020",  -- "CBA     "
        10 => x"43534C2020202020",  -- "CSL     "
        11 => x"5742432020202020",  -- "WBC     "
        12 => x"4E41422020202020",  -- "NAB     "
        13 => x"414E5A2020202020",  -- "ANZ     "
        14 => x"5745532020202020",  -- "WES     "
        15 => x"574F572020202020"   -- "WOW     "
    );

    -- Filter enable/disable
    constant ENABLE_SYMBOL_FILTER : boolean := false;  -- DISABLED FOR TESTING - accept all symbols

    -- Function to check if symbol matches filter list
    function is_symbol_filtered(symbol : std_logic_vector(SYMBOL_WIDTH-1 downto 0)) return boolean;

end package symbol_filter_pkg;

package body symbol_filter_pkg is

    -- Check if symbol is in the filter list
    function is_symbol_filtered(symbol : std_logic_vector(SYMBOL_WIDTH-1 downto 0)) return boolean is
    begin
        -- If filtering is disabled, pass all symbols
        if not ENABLE_SYMBOL_FILTER then
            return true;
        end if;

        -- Check against each symbol in the filter list
        for i in 0 to MAX_SYMBOLS-1 loop
            if symbol = FILTER_SYMBOL_LIST(i) then
                return true;  -- Symbol matches filter list
            end if;
        end loop;

        return false;  -- Symbol not in filter list
    end function;

end package body symbol_filter_pkg;
