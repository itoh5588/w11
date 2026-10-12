-- SPDX-License-Identifier: GPL-3.0-or-later
-- Verify the RL01/RL02 bootstrap sequence.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.slvtypes.all;
use work.rblib.all;

entity tb_w11_autostart_rl is
end tb_w11_autostart_rl;

architecture sim of tb_w11_autostart_rl is
  signal CLK : slbit := '0';
  signal RESET : slbit := '1';
  signal CE_MSEC : slbit := '0';
  signal ACTIVE : slbit := '0';
  signal RB_MREQ : rb_mreq_type := rb_mreq_init;
  signal RB_SRES : rb_sres_type := rb_sres_init;
  signal DONE : boolean := false;
  type log_type is array (0 to 61) of slv32;
  signal LOG : log_type := (others => (others => '0'));
  signal NW : natural := 0;
begin
  CLK <= not CLK after 5 ns when not DONE;
  RB_SRES.ack <= RB_MREQ.we;
  RB_SRES.busy <= '0';

  DUT: entity work.w11_autostart
    generic map (DELAY => 1)
    port map (
      CLK => CLK, RESET => RESET, CE_MSEC => CE_MSEC,
      START => '0', BOOT => "10", ACTIVE => ACTIVE,
      RB_MREQ => RB_MREQ, RB_SRES => RB_SRES);

  proc_log: process (CLK)
  begin
    if rising_edge(CLK) and RB_MREQ.we = '1' then
      assert NW < LOG'length report "too many writes" severity failure;
      LOG(NW) <= RB_MREQ.addr & RB_MREQ.din;
      NW <= NW + 1;
    end if;
  end process;

  proc_stim: process
  begin
    wait for 25 ns;
    wait until falling_edge(CLK);
    RESET <= '0';
    CE_MSEC <= '1';
    wait until falling_edge(CLK);
    CE_MSEC <= '0';
    wait for 3 us;
    assert NW = 62 report "wrong RL bootstrap word count"
      severity failure;
    assert LOG(0) = x"00010002" report "stop" severity failure;
    assert LOG(1) = x"00010004" report "creset" severity failure;
    assert LOG(2) = x"00040400" report "RL bootstrap address" severity failure;
    assert LOG(3) = x"0007444c" report "RL bootstrap ID" severity failure;
    assert LOG(59) = x"00070a07" report "RL bootstrap last word" severity failure;
    assert LOG(60) = x"000f0402" report "RL boot PC" severity failure;
    assert LOG(61) = x"00010001" report "start" severity failure;
    report "tb_w11_autostart_rl: PASS";
    DONE <= true;
    wait;
  end process;
end sim;
