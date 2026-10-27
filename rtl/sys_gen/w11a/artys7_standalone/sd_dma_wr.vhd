-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- DMA writer: stores a stream of 16-bit words into PDP-11 main memory,
-- starting at the byte address BASE (22 bit, bit 0 ignored).
--
-- Two consecutive words of one 32-bit memory word are merged into a single
-- write with byte enables 1111; a word without its partner (odd start or
-- end) is written alone with 0011 or 1100.  Writes queue in a 16 entry
-- FIFO; HOLD asks the producer to pause while at most 4 entries are free,
-- which covers a word already in flight.  IDLE is set when the FIFO is empty
-- and no write is outstanding.
--
-- With UB_ENA set at START, BASE(17:0) is a UNIBUS address and each word is
-- translated through the UNIBUS map in UB_TAB (see ubmap_shadow).  Within
-- one 8 KB map page the words stay contiguous.  When a page boundary breaks
-- a pair, the held low half is written alone; if the new word is a high
-- half, it is written alone one clock later (words never arrive on two
-- consecutive clocks).
--
-- DMA protocol: DMA_REQ is held until DMA_BUSY is low at a clock edge, that
-- edge takes the request; the matching DMA_ACK_W follows later.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;

entity sd_dma_wr is
  port (
    CLK : in slbit;
    RESET : in slbit;
    START : in slbit;                   -- load BASE, clear word count
    BASE : in slv22;
    UB_ENA : in slbit := '0';           -- translate through the UNIBUS map
    UB_TAB : in slv(32*21-1 downto 0) := (others => '0');
    FLUSH : in slbit;                   -- stream ended: write a held word
    WE : in slbit;                      -- next stream word
    DI : in slv16;
    HOLD : out slbit;
    IDLE : out slbit;
    NWORD : out slv16;                  -- words written since START
    DMA_REQ : out slbit;
    DMA_WE : out slbit;
    DMA_BUSY : in slbit;
    DMA_ACK_W : in slbit;
    DMA_ADDR : out slv20;
    DMA_BE : out slv4;
    DMA_DI : out slv32
  );
end sd_dma_wr;

architecture syn of sd_dma_wr is

  type entry_type is record
    addr : slv20;
    be : slv4;
    data : slv32;
  end record entry_type;
  type fifo_type is array (0 to 15) of entry_type;

  signal FIFO : fifo_type;
  signal R_HEAD : unsigned(3 downto 0) := (others => '0');
  signal R_TAIL : unsigned(3 downto 0) := (others => '0');
  signal R_COUNT : unsigned(4 downto 0) := (others => '0');
  signal R_WADDR : unsigned(20 downto 0) := (others => '0'); -- word address
  signal R_PEND : slbit := '0';          -- low half held back
  signal R_PLO : slv16 := (others => '0');
  signal R_PADDR : slv20 := (others => '0');
  signal R_WAIT : slbit := '0';          -- write taken, waiting for ack
  signal R_NWORD : unsigned(15 downto 0) := (others => '0');
  signal R_UBENA : slbit := '0';
  signal R_XTRA : slbit := '0';          -- a high half waits for the FIFO
  signal R_XADDR : slv20 := (others => '0');
  signal R_XHI : slv16 := (others => '0');

  -- word address in, physical word address out
  function ub_xlat(waddr : unsigned(20 downto 0); ena : slbit;
                   tab : slv(32*21-1 downto 0)) return unsigned is
    variable n : natural;
  begin
    if ena = '0' then return waddr; end if;
    n := to_integer(waddr(16 downto 12));
    return unsigned(tab(21*n+20 downto 21*n)) + resize(waddr(11 downto 0), 21);
  end function;

begin

  proc_regs: process (CLK)
    variable push : boolean;
    variable pop : boolean;
    variable e : entry_type;
    variable pw : unsigned(20 downto 0);
  begin
    if rising_edge(CLK) then
      push := false;
      pop := false;
      e := ((others => '0'), (others => '0'), (others => '0'));

      if RESET = '1' then
        R_HEAD <= (others => '0');
        R_TAIL <= (others => '0');
        R_COUNT <= (others => '0');
        R_PEND <= '0';
        R_WAIT <= '0';
        R_XTRA <= '0';
        R_NWORD <= (others => '0');
      else
        pw := ub_xlat(R_WADDR, R_UBENA, UB_TAB);
        if START = '1' then
          R_WADDR <= unsigned(BASE(21 downto 1));
          R_UBENA <= UB_ENA;
          R_PEND <= '0';
          R_NWORD <= (others => '0');
        elsif WE = '1' then
          R_WADDR <= R_WADDR + 1;
          R_NWORD <= R_NWORD + 1;
          if pw(0) = '0' then           -- low half: wait for its partner
            if R_PEND = '1' then        -- the held one has none
              e.addr := R_PADDR;
              e.be := "0011";
              e.data := x"0000" & R_PLO;
              push := true;
            end if;
            R_PEND <= '1';
            R_PLO <= DI;
            R_PADDR <= slv(pw(20 downto 1));
          else
            if R_PEND = '1' and R_PADDR = slv(pw(20 downto 1)) then
              e.addr := R_PADDR;
              e.be := "1111";
              e.data := DI & R_PLO;
            elsif R_PEND = '1' then     -- held low half is not the partner
              e.addr := R_PADDR;
              e.be := "0011";
              e.data := x"0000" & R_PLO;
              R_XTRA <= '1';
              R_XADDR <= slv(pw(20 downto 1));
              R_XHI <= DI;
            else
              e.addr := slv(pw(20 downto 1));
              e.be := "1100";
              e.data := DI & x"0000";
            end if;
            R_PEND <= '0';
            push := true;
          end if;
        elsif R_XTRA = '1' then
          e.addr := R_XADDR;
          e.be := "1100";
          e.data := R_XHI & x"0000";
          R_XTRA <= '0';
          push := true;
        elsif FLUSH = '1' and R_PEND = '1' then
          e.addr := R_PADDR;
          e.be := "0011";
          e.data := x"0000" & R_PLO;
          R_PEND <= '0';
          push := true;
        end if;

        -- DMA side
        if R_WAIT = '0' then
          if R_COUNT /= 0 and DMA_BUSY = '0' then
            pop := true;                -- request taken at this edge
            R_WAIT <= '1';
          end if;
        elsif DMA_ACK_W = '1' then
          R_WAIT <= '0';
        end if;

        if push then
          FIFO(to_integer(R_TAIL)) <= e;
          R_TAIL <= R_TAIL + 1;
        end if;
        if pop then
          R_HEAD <= R_HEAD + 1;
        end if;
        if push and not pop then
          R_COUNT <= R_COUNT + 1;
        elsif pop and not push then
          R_COUNT <= R_COUNT - 1;
        end if;
      end if;
    end if;
  end process proc_regs;

  DMA_REQ <= '1' when R_WAIT = '0' and R_COUNT /= 0 else '0';
  DMA_WE <= '1';
  DMA_ADDR <= FIFO(to_integer(R_HEAD)).addr;
  DMA_BE <= FIFO(to_integer(R_HEAD)).be;
  DMA_DI <= FIFO(to_integer(R_HEAD)).data;

  HOLD <= '1' when R_COUNT >= 12 else '0';
  IDLE <= '1' when R_COUNT = 0 and R_WAIT = '0' and R_PEND = '0' and
                   R_XTRA = '0' else '0';
  NWORD <= slv(R_NWORD);

end syn;
