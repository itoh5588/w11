-- SPDX-License-Identifier: GPL-3.0-or-later

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;
use work.pdp11.all;

entity tb_pdp11_cache_invalidate is
end tb_pdp11_cache_invalidate;

architecture sim of tb_pdp11_cache_invalidate is
  signal CLK   : slbit := '0';
  signal RESET : slbit := '1';
  signal STOP_CLOCK : boolean := false;

  signal EM_MREQ : em_mreq_type := em_mreq_init;
  signal EM_SRES : em_sres_type := em_sres_init;

  signal MEM_REQ   : slbit;
  signal MEM_WE    : slbit;
  signal MEM_BUSY  : slbit := '0';
  signal MEM_ACK_R : slbit := '0';
  signal MEM_ADDR  : slv20;
  signal MEM_BE    : slv4;
  signal MEM_DI    : slv32;
  signal MEM_DO    : slv32 := (others => '0');
  signal MEM_VALUE : slv32 := x"aaaabbbb";
  signal MEM_PENDING : slbit := '0';
  signal MEM_READS : natural := 0;

  signal INV_REQ  : slbit := '0';
  signal INV_ADDR : slv20 := (others => '0');
  signal INV_ACK  : slbit;
  signal DM_STAT_CA : dm_stat_ca_type;
begin
  CLK <= not CLK after 5 ns when not STOP_CLOCK else '0';

  DUT: entity work.pdp11_cache
    generic map (TWIDTH => 9)
    port map (
      CLK => CLK, GRESET => RESET,
      EM_MREQ => EM_MREQ, EM_SRES => EM_SRES, FMISS => '0',
      MEM_REQ => MEM_REQ, MEM_WE => MEM_WE,
      MEM_BUSY => MEM_BUSY, MEM_ACK_R => MEM_ACK_R,
      MEM_ADDR => MEM_ADDR, MEM_BE => MEM_BE, MEM_DI => MEM_DI, MEM_DO => MEM_DO,
      INV_REQ => INV_REQ, INV_ADDR => INV_ADDR, INV_ACK => INV_ACK,
      DM_STAT_CA => DM_STAT_CA);

  proc_memory: process (CLK)
  begin
    if rising_edge(CLK) then
      MEM_ACK_R <= '0';
      if MEM_PENDING = '1' then
        MEM_DO <= MEM_VALUE;
        MEM_ACK_R <= '1';
        MEM_PENDING <= '0';
      elsif MEM_REQ = '1' and MEM_WE = '0' then
        MEM_PENDING <= '1';
        MEM_READS <= MEM_READS + 1;
      end if;
    end if;
  end process proc_memory;

  proc_stim: process
  begin
    wait for 20 ns;
    wait until rising_edge(CLK);
    RESET <= '0';

    -- First read misses and fills the cache line.
    EM_MREQ.addr <= slv(to_unsigned(16#100#, EM_MREQ.addr'length));
    EM_MREQ.be <= "11";
    EM_MREQ.req <= '1';
    wait until EM_SRES.ack_r = '1';
    wait for 1 ns;
    assert EM_SRES.dout = x"bbbb" and MEM_READS = 1
      report "initial cache fill failed" severity failure;
    EM_MREQ.req <= '0';
    wait until rising_edge(CLK);

    -- The second read must hit without another memory transaction.
    EM_MREQ.req <= '1';
    wait until EM_SRES.ack_r = '1';
    wait for 1 ns;
    assert EM_SRES.dout = x"bbbb" and MEM_READS = 1
      report "second read was not a cache hit" severity failure;
    EM_MREQ.req <= '0';
    wait until rising_edge(CLK);

    -- Invalidate the same 32-bit word address used by the memory interface.
    INV_ADDR <= MEM_ADDR;
    INV_REQ <= '1';
    wait until rising_edge(CLK) and INV_ACK = '1'; -- ack is taken at the edge
    INV_REQ <= '0';
    wait until rising_edge(CLK);
    wait until rising_edge(CLK);

    -- Changed backing memory must be observed after invalidation.
    MEM_VALUE <= x"ccccdddd";
    EM_MREQ.req <= '1';
    wait until EM_SRES.ack_r = '1';
    wait for 1 ns;
    assert MEM_READS = 2
      report "invalidated line did not issue a new memory read" severity failure;
    assert EM_SRES.dout = x"dddd"
      report "memory refill returned the wrong word" severity failure;
    EM_MREQ.req <= '0';

    report "tb_pdp11_cache_invalidate completed" severity note;
    STOP_CLOCK <= true;
    wait;
  end process proc_stim;
end sim;
