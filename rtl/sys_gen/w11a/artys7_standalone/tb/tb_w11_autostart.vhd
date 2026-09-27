-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Test bench for w11_autostart: a fake rbus slave (2 busy cycles per write)
-- logs the writes; checks the order stop, creset, al, 23 x memi, pc, start,
-- no rbus activity outside ACTIVE, and that START runs the sequence again.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;
use work.rblib.all;

entity tb_w11_autostart is
end tb_w11_autostart;

architecture sim of tb_w11_autostart is
  signal CLK : slbit := '0';
  signal RESET : slbit := '1';
  signal CE_MSEC : slbit := '0';
  signal START : slbit := '0';
  signal ACTIVE : slbit := '0';
  signal RB_MREQ : rb_mreq_type := rb_mreq_init;
  signal RB_SRES : rb_sres_type := rb_sres_init;
  signal BCNT : natural := 0;
  signal NW : natural := 0;
  signal DONE : boolean := false;
  type log_type is array (0 to 127) of slv32;
  signal LOG : log_type := (others => (others => '0'));
  type exp_type is array (0 to 27) of natural;
  constant exp_addr : exp_type := (1, 1, 4, others => 7);
begin

  UUT : entity work.w11_autostart
    generic map (RB_BASE => x"0000", DELAY => 3)
    port map (CLK => CLK, RESET => RESET, CE_MSEC => CE_MSEC, START => START,
              ACTIVE => ACTIVE, RB_MREQ => RB_MREQ, RB_SRES => RB_SRES);

  CLK <= not CLK after 5 ns when not DONE;

  proc_ce: process
  begin
    while not DONE loop
      for i in 1 to 9 loop wait until rising_edge(CLK); end loop;
      CE_MSEC <= '1';
      wait until rising_edge(CLK);
      CE_MSEC <= '0';
    end loop;
    wait;
  end process;

  RB_SRES.ack <= RB_MREQ.we;
  RB_SRES.busy <= '1' when RB_MREQ.we = '1' and BCNT < 2 else '0';

  proc_slave: process (CLK)
  begin
    if rising_edge(CLK) then
      assert (RB_MREQ.aval = '0' and RB_MREQ.we = '0') or ACTIVE = '1'
        report "rbus access without ACTIVE" severity failure;
      if RB_MREQ.we = '1' then
        assert RB_MREQ.aval = '1' report "we without aval" severity failure;
        if BCNT >= 2 then
          LOG(NW) <= RB_MREQ.addr & RB_MREQ.din;
          NW <= NW + 1;
          BCNT <= 0;
        else
          BCNT <= BCNT + 1;
        end if;
      else
        BCNT <= 0;
      end if;
    end if;
  end process;

  proc_stim: process
    procedure check(constant base : natural) is
      variable a : natural;
    begin
      assert NW = base + 28 report "write count " & integer'image(NW)
        severity failure;
      for i in 0 to 27 loop
        a := to_integer(unsigned(LOG(base + i)(31 downto 16)));
        if i < 26 then
          assert a = exp_addr(i) report "addr at " & integer'image(i)
            severity failure;
        end if;
      end loop;
      assert LOG(base + 0)(15 downto 0) = x"0002" report "stop" severity failure;
      assert LOG(base + 1)(15 downto 0) = x"0004" report "creset" severity failure;
      assert LOG(base + 2)(15 downto 0) = x"c000"
        report "al" severity failure;
      assert LOG(base + 3)(15 downto 0) = x"15c1" report "word 0" severity failure;
      assert LOG(base + 25)(15 downto 0) = x"0000" report "word 22" severity failure;
      assert unsigned(LOG(base + 26)(31 downto 16)) = 15 and
        LOG(base + 26)(15 downto 0) = x"c000" report "pc" severity failure;
      assert unsigned(LOG(base + 27)(31 downto 16)) = 1 and
        LOG(base + 27)(15 downto 0) = x"0001" report "start" severity failure;
    end procedure;
  begin
    wait for 30 ns;
    wait until falling_edge(CLK);
    RESET <= '0';
    for i in 1 to 30 loop wait until rising_edge(CLK); end loop;
    assert NW = 0 report "started before DELAY" severity failure;
    wait for 3 us;
    check(0);
    assert ACTIVE = '0' report "ACTIVE stuck" severity failure;
    wait for 2 us;
    assert NW = 28 report "ran again without START" severity failure;
    wait until falling_edge(CLK);
    START <= '1';
    wait until falling_edge(CLK);
    START <= '0';
    wait for 3 us;
    check(28);
    report "tb_w11_autostart: PASS";
    DONE <= true;
    wait;
  end process;
end sim;
