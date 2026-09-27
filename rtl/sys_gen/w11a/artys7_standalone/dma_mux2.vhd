-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Two DMA masters on one DMA port (w11_mem_arbiter DMA side protocol).
-- A master holds REQ until BUSY is low at a clock edge; that edge takes the
-- request and the master then owns the port until its ACK_R/ACK_W.  When
-- both request, the master that did not have the last grant wins.

library ieee;
use ieee.std_logic_1164.all;

use work.slvtypes.all;

entity dma_mux2 is
  port (
    CLK : in slbit;
    RESET : in slbit;
    A_REQ : in slbit;
    A_WE : in slbit;
    A_BUSY : out slbit;
    A_ACK_R : out slbit;
    A_ACK_W : out slbit;
    A_ADDR : in slv20;
    A_BE : in slv4;
    A_DI : in slv32;
    B_REQ : in slbit;
    B_WE : in slbit;
    B_BUSY : out slbit;
    B_ACK_R : out slbit;
    B_ACK_W : out slbit;
    B_ADDR : in slv20;
    B_BE : in slv4;
    B_DI : in slv32;
    DMA_REQ : out slbit;
    DMA_WE : out slbit;
    DMA_BUSY : in slbit;
    DMA_ACK_R : in slbit;
    DMA_ACK_W : in slbit;
    DMA_ADDR : out slv20;
    DMA_BE : out slv4;
    DMA_DI : out slv32
  );
end dma_mux2;

architecture syn of dma_mux2 is
  signal R_WAIT : slbit := '0';          -- request taken, waiting for ack
  signal R_OWNB : slbit := '0';          -- owner / last grant is B
  signal SELB : slbit := '0';
begin

  -- selection while no request is outstanding
  SELB <= R_OWNB when R_WAIT = '1' else
          '1' when B_REQ = '1' and (A_REQ = '0' or R_OWNB = '0') else
          '0';

  proc_regs: process (CLK)
  begin
    if rising_edge(CLK) then
      if RESET = '1' then
        R_WAIT <= '0';
        R_OWNB <= '0';
      elsif R_WAIT = '0' then
        if DMA_BUSY = '0' and (A_REQ = '1' or B_REQ = '1') then
          R_WAIT <= '1';
          R_OWNB <= SELB;
        end if;
      elsif DMA_ACK_R = '1' or DMA_ACK_W = '1' then
        R_WAIT <= '0';
      end if;
    end if;
  end process proc_regs;

  DMA_REQ <= '0' when R_WAIT = '1' else A_REQ or B_REQ;
  DMA_WE <= B_WE when SELB = '1' else A_WE;
  DMA_ADDR <= B_ADDR when SELB = '1' else A_ADDR;
  DMA_BE <= B_BE when SELB = '1' else A_BE;
  DMA_DI <= B_DI when SELB = '1' else A_DI;

  A_BUSY <= '1' when R_WAIT = '1' or SELB = '1' else DMA_BUSY;
  B_BUSY <= '1' when R_WAIT = '1' or SELB = '0' else DMA_BUSY;
  A_ACK_R <= DMA_ACK_R when R_WAIT = '1' and R_OWNB = '0' else '0';
  A_ACK_W <= DMA_ACK_W when R_WAIT = '1' and R_OWNB = '0' else '0';
  B_ACK_R <= DMA_ACK_R when R_WAIT = '1' and R_OWNB = '1' else '0';
  B_ACK_W <= DMA_ACK_W when R_WAIT = '1' and R_OWNB = '1' else '0';

end syn;
