-- SPDX-License-Identifier: GPL-3.0-or-later

library ieee;
use ieee.std_logic_1164.all;

use work.slvtypes.all;

entity tb_w11_mem_arbiter is
end tb_w11_mem_arbiter;

architecture sim of tb_w11_mem_arbiter is
  signal CLK   : slbit := '0';
  signal RESET : slbit := '1';

  signal CPU_REQ   : slbit := '0';
  signal CPU_WE    : slbit := '0';
  signal CPU_BUSY  : slbit;
  signal CPU_ACK_R : slbit;
  signal CPU_ACK_W : slbit;
  signal CPU_ADDR  : slv20 := (others => '0');
  signal CPU_BE    : slv4 := (others => '0');
  signal CPU_DI    : slv32 := (others => '0');
  signal CPU_DO    : slv32;

  signal DMA_REQ   : slbit := '0';
  signal DMA_WE    : slbit := '0';
  signal DMA_BUSY  : slbit;
  signal DMA_ACK_R : slbit;
  signal DMA_ACK_W : slbit;
  signal DMA_ADDR  : slv20 := (others => '0');
  signal DMA_BE    : slv4 := (others => '0');
  signal DMA_DI    : slv32 := (others => '0');
  signal DMA_DO    : slv32;

  signal INV_REQ  : slbit;
  signal INV_ADDR : slv20;
  signal INV_ACK  : slbit := '0';

  signal MEM_REQ   : slbit;
  signal MEM_WE    : slbit;
  signal MEM_BUSY  : slbit := '0';
  signal MEM_ACK_R : slbit := '0';
  signal MEM_ACK_W : slbit := '0';
  signal MEM_ADDR  : slv20;
  signal MEM_BE    : slv4;
  signal MEM_DI    : slv32;
  signal MEM_DO    : slv32 := (others => '0');

  signal STOP_CLOCK : boolean := false;
begin
  CLK <= not CLK after 5 ns when not STOP_CLOCK else '0';

  DUT: entity work.w11_mem_arbiter
    port map (
      CLK => CLK, RESET => RESET,
      CPU_REQ => CPU_REQ, CPU_WE => CPU_WE, CPU_BUSY => CPU_BUSY,
      CPU_ACK_R => CPU_ACK_R, CPU_ACK_W => CPU_ACK_W,
      CPU_ADDR => CPU_ADDR, CPU_BE => CPU_BE, CPU_DI => CPU_DI, CPU_DO => CPU_DO,
      DMA_REQ => DMA_REQ, DMA_WE => DMA_WE, DMA_BUSY => DMA_BUSY,
      DMA_ACK_R => DMA_ACK_R, DMA_ACK_W => DMA_ACK_W,
      DMA_ADDR => DMA_ADDR, DMA_BE => DMA_BE, DMA_DI => DMA_DI, DMA_DO => DMA_DO,
      INV_REQ => INV_REQ, INV_ADDR => INV_ADDR, INV_ACK => INV_ACK,
      MEM_REQ => MEM_REQ, MEM_WE => MEM_WE, MEM_BUSY => MEM_BUSY,
      MEM_ACK_R => MEM_ACK_R, MEM_ACK_W => MEM_ACK_W,
      MEM_ADDR => MEM_ADDR, MEM_BE => MEM_BE, MEM_DI => MEM_DI, MEM_DO => MEM_DO);

  proc_stim: process
  begin
    wait for 20 ns;
    wait until rising_edge(CLK);
    RESET <= '0';

    -- DMA-only write.
    DMA_WE   <= '1';
    DMA_ADDR <= x"12345";
    DMA_BE   <= "1111";
    DMA_DI   <= x"89abcdef";
    DMA_REQ  <= '1';
    wait for 1 ns;
    assert MEM_REQ = '1' and MEM_WE = '1' and MEM_ADDR = x"12345" and
           MEM_BE = "1111" and MEM_DI = x"89abcdef"
      report "DMA write was not forwarded" severity failure;
    wait until rising_edge(CLK);
    DMA_REQ <= '0';
    MEM_BUSY <= '1';
    wait until rising_edge(CLK);
    MEM_BUSY  <= '0';
    MEM_ACK_W <= '1';
    wait for 1 ns;
    assert DMA_ACK_W = '0'
      report "DMA write completed before cache invalidation" severity failure;
    wait until rising_edge(CLK);
    MEM_ACK_W <= '0';
    wait for 1 ns;
    assert INV_REQ = '1' and INV_ADDR = x"12345"
      report "DMA write did not request cache invalidation" severity failure;
    -- A cache miss already waiting behind the DMA write must finish before
    -- the cache can acknowledge the pending invalidation.
    CPU_WE   <= '0';
    CPU_ADDR <= x"00030";
    CPU_REQ  <= '1';
    wait for 1 ns;
    assert MEM_REQ = '1' and MEM_ADDR = x"00030" and CPU_BUSY = '0' and
           DMA_ACK_W = '0'
      report "pending CPU read was blocked by invalidation" severity failure;
    wait until rising_edge(CLK);
    CPU_REQ <= '0';
    MEM_BUSY <= '1';
    wait until rising_edge(CLK);
    MEM_BUSY <= '0';
    MEM_DO <= x"55667788";
    MEM_ACK_R <= '1';
    wait for 1 ns;
    assert CPU_ACK_R = '1' and CPU_DO = x"55667788" and DMA_ACK_W = '0'
      report "pending CPU read acknowledgement was misrouted" severity failure;
    wait until rising_edge(CLK);
    MEM_ACK_R <= '0';
    wait for 1 ns;
    assert INV_REQ = '1' and DMA_ACK_W = '0'
      report "DMA invalidation was lost after pending CPU read" severity failure;
    INV_ACK <= '1';
    wait for 1 ns;
    assert DMA_ACK_W = '1' and CPU_ACK_W = '0'
      report "DMA write acknowledgement routed incorrectly" severity failure;
    wait until rising_edge(CLK);
    INV_ACK <= '0';

    -- Simultaneous reads: CPU must win, held DMA request follows afterward.
    CPU_WE   <= '0';
    CPU_ADDR <= x"00010";
    CPU_REQ  <= '1';
    DMA_WE   <= '0';
    DMA_ADDR <= x"00020";
    DMA_REQ  <= '1';
    wait for 1 ns;
    assert MEM_REQ = '1' and MEM_ADDR = x"00010" and DMA_BUSY = '1'
      report "CPU did not win simultaneous requests" severity failure;
    wait until rising_edge(CLK);
    CPU_REQ <= '0';
    MEM_BUSY <= '1';
    wait until rising_edge(CLK);
    MEM_BUSY <= '0';
    MEM_DO <= x"11112222";
    MEM_ACK_R <= '1';
    wait for 1 ns;
    assert CPU_ACK_R = '1' and DMA_ACK_R = '0' and CPU_DO = x"11112222"
      report "CPU read acknowledgement routed incorrectly" severity failure;
    -- The controller is free again, but the arbiter still owns the request:
    -- a cache request pulse issued now would be lost.
    assert CPU_BUSY = '1'
      report "CPU saw BUSY low while its request was outstanding"
      severity failure;
    wait until rising_edge(CLK);
    MEM_ACK_R <= '0';
    wait for 1 ns;
    assert MEM_REQ = '1' and MEM_ADDR = x"00020"
      report "pending DMA read did not follow CPU transaction" severity failure;
    wait until rising_edge(CLK);
    DMA_REQ <= '0';
    MEM_BUSY <= '1';
    wait until rising_edge(CLK);
    MEM_BUSY <= '0';
    MEM_DO <= x"33334444";
    MEM_ACK_R <= '1';
    wait for 1 ns;
    assert DMA_ACK_R = '1' and CPU_ACK_R = '0' and DMA_DO = x"33334444"
      report "DMA read acknowledgement routed incorrectly" severity failure;
    assert DMA_BUSY = '1'
      report "DMA saw BUSY low while its request was outstanding"
      severity failure;
    wait until rising_edge(CLK);
    MEM_ACK_R <= '0';

    -- Non-contiguous byte enables and data must pass through unchanged.
    DMA_WE   <= '1';
    DMA_ADDR <= x"23456";
    DMA_BE   <= "0101";
    DMA_DI   <= x"00e1007e";
    DMA_REQ  <= '1';
    wait for 1 ns;
    assert MEM_REQ = '1' and MEM_WE = '1' and MEM_ADDR = x"23456" and
           MEM_BE = "0101" and MEM_DI = x"00e1007e"
      report "DMA byte enable or data was not forwarded" severity failure;
    wait until rising_edge(CLK);
    DMA_REQ <= '0';
    MEM_BUSY <= '1';
    wait until rising_edge(CLK);
    MEM_BUSY <= '0';
    MEM_ACK_W <= '1';
    wait until rising_edge(CLK);
    MEM_ACK_W <= '0';
    wait for 1 ns;
    assert INV_REQ = '1' and INV_ADDR = x"23456"
      report "partial DMA write did not invalidate the cache" severity failure;
    INV_ACK <= '1';
    wait for 1 ns;
    assert DMA_ACK_W = '1'
      report "partial DMA write was not acknowledged" severity failure;
    wait until rising_edge(CLK);
    INV_ACK <= '0';

    report "tb_w11_mem_arbiter completed" severity note;
    STOP_CLOCK <= true;
    wait;
  end process proc_stim;
end sim;
