-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Test bench for w11_panel: the host side sends panel commands on RXD (8 CLK
-- cycles per bit), a fake cp rbus slave (2 busy cycles per access, cntl
-- start/stop set/clear cpugo) logs the accesses.  Checks HALT, LOAD ADRS,
-- EXAM/DEP with auto increment (memory and registers), CONT (step, start),
-- START, no access while running, a command with a bad check byte, and one
-- lamp frame (0x80 + 51 bytes: run, adrs err, console address).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;
use work.rblib.all;
use work.pdp11.all;

entity tb_w11_panel is
end tb_w11_panel;

architecture sim of tb_w11_panel is
  constant cdiv : positive := 8;
  signal CLK : slbit := '0';
  signal RESET : slbit := '1';
  signal RXD : slbit := '1';
  signal TXD : slbit := '1';
  signal ACTIVE : slbit := '0';
  signal RB_MREQ : rb_mreq_type := rb_mreq_init;
  signal RB_SRES : rb_sres_type := rb_sres_init;
  signal CP_STAT : cp_stat_type := cp_stat_init;
  signal DM_STAT_EXP : dm_stat_exp_type := dm_stat_exp_init;
  signal DONE : boolean := false;
  signal BCNT : natural := 0;
  signal NACC : natural := 0;
  type log_type is array (0 to 63) of slv(22 downto 0);  -- we, addr(5:0), data
  signal LOG : log_type := (others => (others => '0'));
  signal RXB : slv8 := (others => '0');                  -- byte from TXD
  signal RXB_T : boolean := false;                       -- toggles per byte
  type frame_type is array (0 to 50) of natural;
  signal FRAME : frame_type := (others => 0);
  signal NFRAME : natural := 0;
begin

  UUT : entity work.w11_panel
    generic map (CDIV => cdiv, RB_BASE => x"0000")
    port map (CLK => CLK, RESET => RESET, RXD => RXD, TXD => TXD,
              HOLD => '0', ACTIVE => ACTIVE, RB_MREQ => RB_MREQ,
              RB_SRES => RB_SRES, CP_STAT => CP_STAT,
              DM_STAT_EXP => DM_STAT_EXP, DISPREG => x"a5a5", DMA_ACT => '0');

  CLK <= not CLK after 5 ns when not DONE;

  -- fake cp slave
  RB_SRES.ack <= RB_MREQ.re or RB_MREQ.we;
  RB_SRES.busy <= '1' when (RB_MREQ.re or RB_MREQ.we) = '1' and BCNT < 2 else '0';
  RB_SRES.dout <= slv(to_unsigned(16#1000#, 16) + unsigned(RB_MREQ.addr));

  proc_slave: process (CLK)
  begin
    if rising_edge(CLK) then
      assert (RB_MREQ.aval = '0' and RB_MREQ.re = '0' and RB_MREQ.we = '0')
        or ACTIVE = '1' report "rbus access without ACTIVE" severity failure;
      if (RB_MREQ.re or RB_MREQ.we) = '1' then
        assert RB_MREQ.aval = '1' report "re/we without aval" severity failure;
        if BCNT >= 2 then
          LOG(NACC) <= RB_MREQ.we & RB_MREQ.addr(5 downto 0) & RB_MREQ.din;
          NACC <= NACC + 1;
          BCNT <= 0;
          if RB_MREQ.we = '1' and RB_MREQ.addr(4 downto 0) = c_rbaddr_cntl then
            if RB_MREQ.din(4 downto 0) = c_cpfunc_start then
              CP_STAT.cpugo <= '1';
            elsif RB_MREQ.din(4 downto 0) = c_cpfunc_stop then
              CP_STAT.cpugo <= '0';
            end if;
          end if;
        else
          BCNT <= BCNT + 1;
        end if;
      else
        BCNT <= 0;
      end if;
      if RESET = '1' then
        CP_STAT.cpugo <= '1';           -- running, as after the autostart
      end if;
    end if;
  end process;

  -- receive the lamp frames
  proc_txd: process
    variable b : slv8;
  begin
    wait until TXD = '0';
    for i in 1 to cdiv / 2 loop wait until rising_edge(CLK); end loop;
    for i in 0 to 7 loop
      for j in 1 to cdiv loop wait until rising_edge(CLK); end loop;
      b(i) := TXD;
    end loop;
    for j in 1 to cdiv loop wait until rising_edge(CLK); end loop;
    assert TXD = '1' report "tx stop bit" severity failure;
    RXB <= b;
    RXB_T <= not RXB_T;
  end process;

  proc_frame: process
    variable idx : integer := -1;
  begin
    wait on RXB_T;
    if RXB = x"80" then
      idx := 0;
    elsif idx >= 0 then
      assert unsigned(RXB) <= 15 report "lamp byte > 15" severity failure;
      FRAME(idx) <= to_integer(unsigned(RXB));
      idx := idx + 1;
      if idx = 51 then
        NFRAME <= NFRAME + 1;
        idx := -1;
      end if;
    end if;
  end process;

  proc_stim: process
    type bytes is array (natural range <>) of natural;
    variable nexp : natural := 0;

    procedure send(constant b : in bytes) is
      variable v : slv8;
    begin
      for k in b'range loop
        v := slv(to_unsigned(b(k), 8));
        RXD <= '0';
        for j in 1 to cdiv loop wait until rising_edge(CLK); end loop;
        for i in 0 to 7 loop
          RXD <= v(i);
          for j in 1 to cdiv loop wait until rising_edge(CLK); end loop;
        end loop;
        RXD <= '1';
        for j in 1 to cdiv loop wait until rising_edge(CLK); end loop;
      end loop;
      wait for 1 us;
    end procedure;

    -- a command with its check byte
    procedure cmd(constant b : in bytes) is
      variable c : natural := 0;
      variable all_b : bytes(0 to b'length);
    begin
      for k in b'range loop
        c := to_integer(unsigned(to_unsigned(c, 7) xor to_unsigned(b(k) mod 128, 7)));
        all_b(k - b'low) := b(k);
      end loop;
      all_b(b'length) := c;
      send(all_b);
    end procedure;

    procedure setsw(constant v : in natural) is
    begin
      cmd((16#81#, v mod 128, (v / 128) mod 128, (v / 16384) mod 128,
           (v / 2097152) mod 2));
    end procedure;

    procedure pulse(constant bitno : in natural) is
    begin
      cmd((16#83#, 2 ** bitno));
    end procedure;

    procedure levels(constant halt : in natural) is
    begin
      cmd((16#82#, halt * 32));
    end procedure;

    procedure expect(constant we : in slbit; constant addr : in slv5;
                     constant din : in natural) is
    begin
      assert nexp < NACC report "missing access " & integer'image(nexp)
        severity failure;
      assert LOG(nexp)(22) = we and LOG(nexp)(20 downto 16) = addr
        report "access " & integer'image(nexp) & " addr/we" severity failure;
      if we = '1' then
        assert unsigned(LOG(nexp)(15 downto 0)) = din
          report "access " & integer'image(nexp) & " data" severity failure;
      end if;
      nexp := nexp + 1;
    end procedure;

    procedure no_more is
    begin
      assert NACC = nexp report "extra access " & integer'image(nexp)
        severity failure;
    end procedure;

    constant load : natural := 0;
    constant exam : natural := 1;
    constant dep : natural := 2;
    constant cont : natural := 3;
    constant start : natural := 4;
    constant a17777710 : natural := 16#3fffc8#;
  begin
    wait for 30 ns;
    wait until falling_edge(CLK);
    RESET <= '0';
    wait for 1 us;

    levels(1);                          -- HALT: stop
    expect('1', c_rbaddr_cntl, 2);
    no_more;
    assert CP_STAT.cpugo = '0' report "not stopped" severity failure;
    levels(1);                          -- no edge: nothing
    no_more;

    setsw(8#1000#);                     -- LOAD ADRS, EXAM, EXAM
    pulse(load);
    no_more;
    pulse(exam);
    expect('1', c_rbaddr_al, 8#1000#);
    expect('1', c_rbaddr_ah, 16#40#);
    expect('0', c_rbaddr_mem, 0);
    pulse(exam);
    expect('1', c_rbaddr_al, 8#1002#);
    expect('1', c_rbaddr_ah, 16#40#);
    expect('0', c_rbaddr_mem, 0);

    setsw(16#1234#);                    -- DEP (same word), DEP (next)
    pulse(dep);
    expect('1', c_rbaddr_al, 8#1002#);
    expect('1', c_rbaddr_ah, 16#40#);
    expect('1', c_rbaddr_mem, 16#1234#);
    pulse(dep);
    expect('1', c_rbaddr_al, 8#1004#);
    expect('1', c_rbaddr_ah, 16#40#);
    expect('1', c_rbaddr_mem, 16#1234#);

    setsw(16#3fffc6#);                  -- 17777706 (SP), EXAM, EXAM (PC)
    pulse(load);
    pulse(exam);
    expect('0', c_rbaddr_sp, 0);
    pulse(exam);
    expect('0', c_rbaddr_pc, 0);
    no_more;

    setsw(8#123456#);                   -- 22 bit address: ah
    pulse(load);
    setsw(16#0077#);
    pulse(dep);
    expect('1', c_rbaddr_al, 8#123456# mod 65536);
    expect('1', c_rbaddr_ah, 16#40# + 8#123456# / 65536);
    expect('1', c_rbaddr_mem, 16#77#);

    pulse(cont);                        -- HALT: step
    expect('1', c_rbaddr_cntl, 3);
    no_more;

    send((16#83#, 2 ** exam, 0));       -- wrong check byte: ignored
    no_more;

    levels(0);                          -- ENABLE, CONT: start
    no_more;
    pulse(cont);
    expect('1', c_rbaddr_cntl, 1);
    assert CP_STAT.cpugo = '1' report "not started" severity failure;
    pulse(exam);                        -- running: ignored
    pulse(start);
    pulse(cont);
    no_more;

    levels(1);                          -- HALT, START with HALT: creset
    expect('1', c_rbaddr_cntl, 2);
    setsw(8#1000#);
    pulse(load);
    pulse(start);
    expect('1', c_rbaddr_cntl, 4);
    no_more;
    levels(0);                          -- START: creset, pc, start
    pulse(start);
    expect('1', c_rbaddr_cntl, 4);
    expect('1', c_rbaddr_pc, 8#1000#);
    expect('1', c_rbaddr_cntl, 1);
    no_more;

    levels(1);                          -- 17777710: not supported, ADRS ERR
    expect('1', c_rbaddr_cntl, 2);
    setsw(a17777710);
    pulse(load);
    pulse(exam);
    no_more;

    wait until NFRAME = 2;              -- a whole frame with this state
    wait until NFRAME = 3;
    assert FRAME(40) = 15 report "adrs err lamp" severity failure;
    assert FRAME(41) = 0 report "run lamp" severity failure;
    assert FRAME(48) = 15 report "16 bit lamp" severity failure;
    assert FRAME(46) = 15 report "kernel lamp" severity failure;
    for i in 0 to 21 loop
      if (a17777710 / 2 ** i) mod 2 = 1 then
        assert FRAME(i) = 15 report "address lamp " & integer'image(i)
          severity failure;
      else
        assert FRAME(i) = 0 report "address lamp " & integer'image(i)
          severity failure;
      end if;
    end loop;

    report "tb_w11_panel: PASS";
    DONE <= true;
    wait;
  end process;
end sim;
