-- SPDX-License-Identifier: GPL-3.0-or-later
-- sd_label_probe: RK05, RL and RP07 labels, a wrong label version, no card
-- and an unlabeled card, each probe started by START (card changed).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.slvtypes.all;

entity tb_sd_label_probe is
end tb_sd_label_probe;

architecture sim of tb_sd_label_probe is
  signal CLK : slbit := '0';
  signal RESET : slbit := '1';
  signal CE_MSEC : slbit := '0';
  signal START : slbit := '0';
  signal ACTIVE, READY, DONE, LABELED : slbit := '0';
  signal SEL : slv2 := "00";
  signal BASE : slv32 := (others => '0');
  signal RL02_MASK, PRESENT_MASK : slv4 := (others => '0');
  signal CS_N, SCLK, MOSI, MISO : slbit := '1';
  signal MODE : natural := 1;
  signal LBL_TYPE : natural := 2;
  signal FINISHED : boolean := false;
begin
  CLK <= not CLK after 6666 ps when not FINISHED;

  proc_ce: process (CLK)
    variable count : natural := 0;
  begin
    if rising_edge(CLK) then
      CE_MSEC <= '0';
      count := count + 1;
      if count = 1000 then count := 0; CE_MSEC <= '1'; end if;
    end if;
  end process;

  DUT: entity work.sd_label_probe
    generic map (DELAY => 2)
    port map (
      CLK => CLK, RESET => RESET, CE_MSEC => CE_MSEC, START => START,
      ACTIVE => ACTIVE, READY => READY, DONE => DONE, LABELED => LABELED,
      SEL => SEL, BASE => BASE, RL02_MASK => RL02_MASK,
      PRESENT_MASK => PRESENT_MASK, O_SD_CS_N => CS_N, O_SD_SCLK => SCLK,
      O_SD_MOSI => MOSI, I_SD_MISO => MISO);

  CARD: entity work.sdcard_spi_model
    port map (MODE => MODE, LBL_TYPE => LBL_TYPE, CS_N => CS_N, SCLK => SCLK,
              MOSI => MOSI, MISO => MISO);

  proc_stim: process
    procedure probe(constant mode_v, label_v : in natural) is
    begin
      wait until falling_edge(CLK);
      MODE <= mode_v;
      LBL_TYPE <= label_v;
      START <= '1';
      wait until falling_edge(CLK);
      START <= '0';
      wait until falling_edge(CLK);
      assert READY = '0' and ACTIVE = '1' report "probe not restarted"
        severity failure;
      wait until rising_edge(CLK) and DONE = '1' for 100 ms;
      assert DONE = '1' report "probe timeout" severity failure;
      wait until falling_edge(CLK);
      assert READY = '1' and ACTIVE = '0' report "probe not ready"
        severity failure;
    end procedure probe;

    procedure expect(constant sel_v : in slv2; constant base_v : in slv32;
                     constant labeled_v : in slbit; constant what : in string) is
    begin
      assert SEL = sel_v report what & ": SEL" severity failure;
      assert BASE = base_v report what & ": BASE" severity failure;
      assert LABELED = labeled_v report what & ": LABELED" severity failure;
    end procedure expect;
  begin
    wait for 50 ns;
    wait until falling_edge(CLK);
    RESET <= '0';
    assert ACTIVE = '1' and READY = '0' report "after reset" severity failure;
    wait until rising_edge(CLK) and DONE = '1' for 100 ms;
    wait until falling_edge(CLK);
    assert READY = '1' report "first probe" severity failure;
    expect("01", x"00012345", '1', "RK05 label");

    probe(1, 3);
    expect("10", x"00012345", '1', "RL label");
    assert RL02_MASK = "0001" and PRESENT_MASK = "0011"
      report "RL masks" severity failure;

    probe(1, 1);
    expect("00", x"00012345", '1', "RP07 label");

    probe(1, 9);
    expect("00", x"00000000", '0', "wrong version");
    assert RL02_MASK = "1111" and PRESENT_MASK = "1111"
      report "default masks" severity failure;

    probe(1, 2);
    expect("01", x"00012345", '1', "RK05 label again");
    probe(0, 2);
    expect("00", x"00000000", '0', "no card");

    probe(2, 0);                        -- SDSC card, no label
    expect("00", x"00000000", '0', "unlabeled");

    report "tb_sd_label_probe: PASS";
    FINISHED <= true;
    wait;
  end process;
end sim;
