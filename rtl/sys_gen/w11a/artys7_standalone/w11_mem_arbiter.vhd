-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- CPU-priority arbiter for the w11 SRAM-style main-memory interface.
-- One request is kept outstanding until the memory controller returns the
-- matching read or write acknowledgement.  While a request is outstanding
-- the owner sees BUSY, because the cache and the DMA master issue one-cycle
-- request pulses whenever BUSY is low and a pulse not forwarded is lost.

library ieee;
use ieee.std_logic_1164.all;

use work.slvtypes.all;

entity w11_mem_arbiter is
  port (
    CLK   : in slbit;
    RESET : in slbit;

    CPU_REQ   : in  slbit;
    CPU_WE    : in  slbit;
    CPU_BUSY  : out slbit;
    CPU_ACK_R : out slbit;
    CPU_ACK_W : out slbit;
    CPU_ADDR  : in  slv20;
    CPU_BE    : in  slv4;
    CPU_DI    : in  slv32;
    CPU_DO    : out slv32;

    DMA_REQ   : in  slbit;
    DMA_WE    : in  slbit;
    DMA_BUSY  : out slbit;
    DMA_ACK_R : out slbit;
    DMA_ACK_W : out slbit;
    DMA_ADDR  : in  slv20;
    DMA_BE    : in  slv4;
    DMA_DI    : in  slv32;
    DMA_DO    : out slv32;

    INV_REQ  : out slbit;
    INV_ADDR : out slv20;
    INV_ACK  : in  slbit;

    MEM_REQ   : out slbit;
    MEM_WE    : out slbit;
    MEM_BUSY  : in  slbit;
    MEM_ACK_R : in  slbit;
    MEM_ACK_W : in  slbit;
    MEM_ADDR  : out slv20;
    MEM_BE    : out slv4;
    MEM_DI    : out slv32;
    MEM_DO    : in  slv32
  );
end w11_mem_arbiter;

architecture syn of w11_mem_arbiter is
  type owner_type is (owner_none, owner_cpu, owner_dma,
                      owner_dma_inv, owner_cpu_inv);
  signal OWNER : owner_type := owner_none;
  signal DMA_WRITE : slbit := '0';
  signal DMA_ADDR_R : slv20 := (others => '0');
begin

  proc_owner: process (CLK)
  begin
    if rising_edge(CLK) then
      if RESET = '1' then
        OWNER <= owner_none;
        DMA_WRITE <= '0';
        DMA_ADDR_R <= (others => '0');
      else
        case OWNER is
          when owner_none =>
            if MEM_BUSY = '0' then
              if CPU_REQ = '1' then
                OWNER <= owner_cpu;
              elsif DMA_REQ = '1' then
                OWNER <= owner_dma;
                DMA_WRITE <= DMA_WE;
                DMA_ADDR_R <= DMA_ADDR;
              end if;
            end if;
          when owner_cpu =>
            if MEM_ACK_R = '1' or MEM_ACK_W = '1' then
              OWNER <= owner_none;
            end if;
          when owner_dma =>
            if MEM_ACK_R = '1' then
              OWNER <= owner_none;
            elsif MEM_ACK_W = '1' then
              if DMA_WRITE = '1' then
                OWNER <= owner_dma_inv;
              else
                OWNER <= owner_none;
              end if;
            end if;
          when owner_dma_inv =>
            if INV_ACK = '1' then
              OWNER <= owner_none;
            elsif CPU_REQ = '1' and MEM_BUSY = '0' then
              -- A cache miss already in progress must be allowed to finish
              -- before the cache can acknowledge invalidation.
              OWNER <= owner_cpu_inv;
            end if;
          when owner_cpu_inv =>
            if MEM_ACK_R = '1' or MEM_ACK_W = '1' then
              OWNER <= owner_dma_inv;
            end if;
        end case;
      end if;
    end if;
  end process proc_owner;

  proc_mux: process (OWNER, CPU_REQ, CPU_WE, CPU_ADDR, CPU_BE, CPU_DI,
                     DMA_REQ, DMA_WE, DMA_ADDR, DMA_BE, DMA_DI,
                     DMA_WRITE, DMA_ADDR_R, INV_ACK,
                     MEM_BUSY, MEM_ACK_R, MEM_ACK_W, MEM_DO)
  begin
    MEM_REQ  <= '0';
    MEM_WE   <= '0';
    MEM_ADDR <= (others => '0');
    MEM_BE   <= (others => '0');
    MEM_DI   <= (others => '0');

    CPU_BUSY  <= '1';
    CPU_ACK_R <= '0';
    CPU_ACK_W <= '0';
    CPU_DO    <= MEM_DO;
    DMA_BUSY  <= '1';
    DMA_ACK_R <= '0';
    DMA_ACK_W <= '0';
    DMA_DO    <= MEM_DO;
    INV_REQ   <= '0';
    INV_ADDR  <= DMA_ADDR_R;

    case OWNER is
      when owner_none =>
        CPU_BUSY <= MEM_BUSY;
        if CPU_REQ = '1' then
          MEM_REQ  <= not MEM_BUSY;
          MEM_WE   <= CPU_WE;
          MEM_ADDR <= CPU_ADDR;
          MEM_BE   <= CPU_BE;
          MEM_DI   <= CPU_DI;
        else
          DMA_BUSY <= MEM_BUSY;
          if DMA_REQ = '1' then
            MEM_REQ  <= not MEM_BUSY;
            MEM_WE   <= DMA_WE;
            MEM_ADDR <= DMA_ADDR;
            MEM_BE   <= DMA_BE;
            MEM_DI   <= DMA_DI;
          end if;
        end if;

      when owner_cpu =>
        CPU_ACK_R <= MEM_ACK_R;
        CPU_ACK_W <= MEM_ACK_W;

      when owner_dma =>
        DMA_ACK_R <= MEM_ACK_R;

      when owner_dma_inv =>
        INV_REQ   <= '1';
        DMA_ACK_W <= INV_ACK;
        CPU_BUSY  <= MEM_BUSY;
        if CPU_REQ = '1' and INV_ACK = '0' then
          MEM_REQ  <= not MEM_BUSY;
          MEM_WE   <= CPU_WE;
          MEM_ADDR <= CPU_ADDR;
          MEM_BE   <= CPU_BE;
          MEM_DI   <= CPU_DI;
        end if;

      when owner_cpu_inv =>
        INV_REQ   <= '1';
        CPU_ACK_R <= MEM_ACK_R;
        CPU_ACK_W <= MEM_ACK_W;
    end case;
  end process proc_mux;

end syn;
