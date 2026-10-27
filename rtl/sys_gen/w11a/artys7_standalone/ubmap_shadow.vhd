-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copy of the 11/70 UNIBUS map for the native UNIBUS disk controllers.
--
-- The CPU's own map (pdp11_ubmap in the vmbox) translates only the rbus DMA
-- of the original w11. The native RK11 and RL11 controllers write memory
-- through w11_cpu_dma_path and bypass it. This module watches the ibus
-- writes to the map registers (170200-170377) and to MMR3 (172516), and
-- keeps the same contents with the same byte-enable rules. It never answers
-- the ibus; pdp11_ubmap and pdp11_mmu still own those addresses.
--
-- TAB holds the 32 map registers, bit 21:1 each, register n at
-- TAB(21*n+20 downto 21*n). ENA is MMR3 bit 5, cleared by BRESET like MMR3.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;
use work.iblib.all;

entity ubmap_shadow is
  port (
    CLK : in slbit;
    BRESET : in slbit;
    IB_MREQ : in ib_mreq_type;
    ENA : out slbit;                    -- MMR3 ena_ubmap
    TAB : out slv(32*21-1 downto 0)     -- map registers, bit 21:1
  );
end ubmap_shadow;

architecture syn of ubmap_shadow is

  constant ibaddr_ubmap : slv16 := slv(to_unsigned(8#170200#,16));
  constant ibaddr_mmr3 : slv16 := slv(to_unsigned(8#172516#,16));

  signal SEL_MAP : slbit := '0';
  signal SEL_MMR3 : slbit := '0';
  signal R_ENA : slbit := '0';
  signal R_TAB : slv(32*21-1 downto 0) := (others => '0');

begin

  SEL1 : ib_sel
    generic map (IB_ADDR => ibaddr_ubmap, SAWIDTH => 6)
    port map (CLK => CLK, IB_MREQ => IB_MREQ, SEL => SEL_MAP);

  SEL2 : ib_sel
    generic map (IB_ADDR => ibaddr_mmr3)
    port map (CLK => CLK, IB_MREQ => IB_MREQ, SEL => SEL_MMR3);

  proc_regs: process (CLK)
  begin
    if rising_edge(CLK) then
      -- one write enable per register; a variable slice index would make
      -- synthesis build a shifter across the whole table
      for i in 0 to 31 loop
        if SEL_MAP = '1' and IB_MREQ.we = '1' and
           unsigned(IB_MREQ.addr(6 downto 2)) = i then
          if IB_MREQ.addr(1) = '1' then -- high word: bit 21:16
            if IB_MREQ.be0 = '1' then
              R_TAB(21*i+20 downto 21*i+15) <= IB_MREQ.din(5 downto 0);
            end if;
          else                          -- low word: bit 15:1
            if IB_MREQ.be1 = '1' then
              R_TAB(21*i+14 downto 21*i+7) <= IB_MREQ.din(15 downto 8);
            end if;
            if IB_MREQ.be0 = '1' then
              R_TAB(21*i+6 downto 21*i) <= IB_MREQ.din(7 downto 1);
            end if;
          end if;
        end if;
      end loop;

      if BRESET = '1' then
        R_ENA <= '0';
      elsif SEL_MMR3 = '1' and IB_MREQ.we = '1' and IB_MREQ.be0 = '1' then
        R_ENA <= IB_MREQ.din(5);
      end if;
    end if;
  end process proc_regs;

  ENA <= R_ENA;
  TAB <= R_TAB;

end syn;
