-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- DMA writer: stores a stream of 16-bit words into PDP-11 main memory,
-- starting at the byte address BASE (22 bit, bit 0 ignored).
--
-- Two consecutive words of one 32-bit memory word are merged into a single
-- write with byte enables 1111; a word without its partner (odd start or
-- end) is written alone with 0011 or 1100.  Writes queue in a 16 entry
-- FIFO; HOLD asks the producer to pause while at most 3 entries are free,
-- which covers a word already in flight.  IDLE is set when the FIFO is empty
-- and no write is outstanding.
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

begin

  proc_regs: process (CLK)
    variable push : boolean;
    variable pop : boolean;
    variable e : entry_type;
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
        R_NWORD <= (others => '0');
      else
        if START = '1' then
          R_WADDR <= unsigned(BASE(21 downto 1));
          R_PEND <= '0';
          R_NWORD <= (others => '0');
        elsif WE = '1' then
          R_WADDR <= R_WADDR + 1;
          R_NWORD <= R_NWORD + 1;
          if R_WADDR(0) = '0' then      -- low half: wait for its partner
            R_PEND <= '1';
            R_PLO <= DI;
            R_PADDR <= slv(R_WADDR(20 downto 1));
          else
            e.addr := slv(R_WADDR(20 downto 1));
            if R_PEND = '1' then
              e.be := "1111";
              e.data := DI & R_PLO;
            else
              e.be := "1100";
              e.data := DI & x"0000";
            end if;
            R_PEND <= '0';
            push := true;
          end if;
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

  HOLD <= '1' when R_COUNT >= 13 else '0';
  IDLE <= '1' when R_COUNT = 0 and R_WAIT = '0' and R_PEND = '0' else '0';
  NWORD <= slv(R_NWORD);

end syn;
