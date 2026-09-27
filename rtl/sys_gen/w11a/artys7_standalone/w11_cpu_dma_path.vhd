-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- PDP-11/70 system with a native, cache-coherent DMA memory port.
--
-- As in sys_w11a_as7, the memory side is reset only by RESET, not by GRESET:
-- an rbus init must not abort a memory transfer or drop a pending cache
-- invalidation, otherwise a DMA write could leave a stale cache line.

library ieee;
use ieee.std_logic_1164.all;

use work.slvtypes.all;
use work.rblib.all;
use work.iblib.all;
use work.pdp11.all;

entity w11_cpu_dma_path is
  port (
    CLK : in slbit;
    RESET : in slbit;
    RB_MREQ : in rb_mreq_type;
    RB_SRES : out rb_sres_type;
    RB_STAT : out slv4;
    RB_LAM_CPU : out slbit;
    GRESET : out slbit;
    CRESET : out slbit;
    BRESET : out slbit;
    CP_STAT : out cp_stat_type;
    EI_PRI : in slv3;
    EI_VECT : in slv9_2;
    EI_ACKM : out slbit;
    PERFEXT : in slv8;
    IB_MREQ : out ib_mreq_type;
    IB_SRES : in ib_sres_type;
    DM_STAT_EXP : out dm_stat_exp_type;

    DMA_REQ : in slbit;
    DMA_WE : in slbit;
    DMA_BUSY : out slbit;
    DMA_ACK_R : out slbit;
    DMA_ACK_W : out slbit;
    DMA_ADDR : in slv20;
    DMA_BE : in slv4;
    DMA_DI : in slv32;
    DMA_DO : out slv32;

    MEM_RESET : out slbit;             -- reset for the memory backend (RESET)
    MEM_REQ : out slbit;
    MEM_WE : out slbit;
    MEM_BUSY : in slbit;
    MEM_ACK_R : in slbit;
    MEM_ACK_W : in slbit;
    MEM_ADDR : out slv20;
    MEM_BE : out slv4;
    MEM_DI : out slv32;
    MEM_DO : in slv32
  );
end w11_cpu_dma_path;

architecture syn of w11_cpu_dma_path is
  signal GRESET_L : slbit := '0';
  signal CPU_REQ : slbit := '0';
  signal CPU_WE : slbit := '0';
  signal CPU_BUSY : slbit := '0';
  signal CPU_ACK_R : slbit := '0';
  signal CPU_ACK_W : slbit := '0';
  signal CPU_ADDR : slv20 := (others => '0');
  signal CPU_BE : slv4 := (others => '0');
  signal CPU_DI : slv32 := (others => '0');
  signal CPU_DO : slv32 := (others => '0');
  signal INV_REQ : slbit := '0';
  signal INV_ADDR : slv20 := (others => '0');
  signal INV_ACK : slbit := '0';
begin
  GRESET <= GRESET_L;
  MEM_RESET <= RESET;

  CPU: pdp11_sys70
    port map (
      CLK => CLK, RESET => RESET,
      RB_MREQ => RB_MREQ, RB_SRES => RB_SRES, RB_STAT => RB_STAT,
      RB_LAM_CPU => RB_LAM_CPU, GRESET => GRESET_L,
      CRESET => CRESET, BRESET => BRESET, CP_STAT => CP_STAT,
      EI_PRI => EI_PRI, EI_VECT => EI_VECT, EI_ACKM => EI_ACKM,
      PERFEXT => PERFEXT, IB_MREQ => IB_MREQ, IB_SRES => IB_SRES,
      MEM_REQ => CPU_REQ, MEM_WE => CPU_WE,
      MEM_BUSY => CPU_BUSY, MEM_ACK_R => CPU_ACK_R,
      MEM_ADDR => CPU_ADDR, MEM_BE => CPU_BE,
      MEM_DI => CPU_DI, MEM_DO => CPU_DO,
      DM_STAT_EXP => DM_STAT_EXP,
      INV_REQ => INV_REQ, INV_ADDR => INV_ADDR, INV_ACK => INV_ACK);

  ARBITER: entity work.w11_mem_arbiter
    port map (
      CLK => CLK, RESET => RESET,
      CPU_REQ => CPU_REQ, CPU_WE => CPU_WE, CPU_BUSY => CPU_BUSY,
      CPU_ACK_R => CPU_ACK_R, CPU_ACK_W => CPU_ACK_W,
      CPU_ADDR => CPU_ADDR, CPU_BE => CPU_BE, CPU_DI => CPU_DI,
      CPU_DO => CPU_DO,
      DMA_REQ => DMA_REQ, DMA_WE => DMA_WE, DMA_BUSY => DMA_BUSY,
      DMA_ACK_R => DMA_ACK_R, DMA_ACK_W => DMA_ACK_W,
      DMA_ADDR => DMA_ADDR, DMA_BE => DMA_BE, DMA_DI => DMA_DI,
      DMA_DO => DMA_DO,
      INV_REQ => INV_REQ, INV_ADDR => INV_ADDR, INV_ACK => INV_ACK,
      MEM_REQ => MEM_REQ, MEM_WE => MEM_WE, MEM_BUSY => MEM_BUSY,
      MEM_ACK_R => MEM_ACK_R, MEM_ACK_W => MEM_ACK_W,
      MEM_ADDR => MEM_ADDR, MEM_BE => MEM_BE, MEM_DI => MEM_DI,
      MEM_DO => MEM_DO);
end syn;
