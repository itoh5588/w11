-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Autostart bootstrap for the standalone Arty S7 system: an
-- rbus master that does what 'cpu0 cp -stapc' does from ti_w11, without a
-- PC.  DELAY ms after reset (and on each START pulse after that run) it
-- waits for READY, then
--   stops and resets the CPU (cntl: stop, creset),
--   writes the RP07, RK05, or RL01/RL02 bootstrap selected by BOOT
--   (al, memi), sets PC to its entry point and starts the CPU (pc, cntl:
--   start).  For RK05 it also sets the switch register to 1 (V6).
-- BOOT ("00" RP07, "01" RK05, "10" RL) is sampled when the sequence starts.
-- Each bootstrap reads the boot sectors of drive 0 and jumps to address 0.
-- ACTIVE is 1 while the sequence runs; the top routes RB_MREQ to the
-- rlink core otherwise.  rbus errors are ignored (stop on a halted CPU).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;
use work.rblib.all;

entity w11_autostart is
  generic (
    RB_BASE : slv16 := x"0000";         -- cpu0 cp register base
    DELAY : positive := 2000);          -- ms after reset
  port (
    CLK : in slbit;
    RESET : in slbit;
    CE_MSEC : in slbit;
    START : in slbit;                   -- run the sequence again
    BOOT : in slv2 := "00";             -- "00" RP07, "01" RK05, "10" RL
    READY : in slbit := '1';            -- BOOT is valid
    ACTIVE : out slbit;
    RB_MREQ : out rb_mreq_type;
    RB_SRES : in rb_sres_type
  );
end w11_autostart;

architecture syn of w11_autostart is

  type word_array is array (natural range <>) of natural;

  -- tcode/rp07_boot.mac assembled at 140000
  constant rp_boot_code : word_array := (
    8#012701#, 8#176700#, 8#012761#, 8#000040#, 8#000010#, 8#012711#,
    8#000021#, 8#005061#, 8#000004#, 8#005061#, 8#000050#, 8#012761#,
    8#177400#, 8#000002#, 8#012711#, 8#000071#, 8#105711#, 8#100376#,
    8#005711#, 8#100402#, 8#005000#, 8#005007#, 8#000000#);

  -- Rw11CntlRK11::BootCode, originally the SimH RK11 boot loader.
  -- The first word is an ID; execution starts at 002002. Read two sectors.
  constant rk_boot_code : word_array := (
    8#042113#, 8#012706#, 8#002000#, 8#012700#, 8#000000#,
    8#010003#, 8#000303#, 8#006303#, 8#006303#, 8#006303#,
    8#006303#, 8#006303#, 8#012701#, 8#177412#, 8#010311#,
    8#005041#, 8#012741#, 8#177000#, 8#012741#, 8#000005#,
    8#005002#, 8#005003#, 8#012704#, 8#002020#, 8#005005#,
    8#105711#, 8#100376#, 8#105011#, 8#005007#);

  -- Rw11CntlRL11::BootCode, originally the SimH RL11 boot loader.
  -- Word zero is an ID; execution starts at 002002.
  constant rl_boot_code : word_array := (
    8#042114#, 8#012706#, 8#002000#, 8#012700#, 8#000000#,
    8#010003#, 8#000303#, 8#012701#, 8#174400#,
    8#012761#, 8#000013#, 8#000004#,
    8#052703#, 8#000004#, 8#010311#, 8#105711#, 8#100376#,
    8#105003#, 8#052703#, 8#000010#, 8#010311#, 8#105711#,
    8#100376#, 8#016102#, 8#000006#, 8#042702#, 8#000077#,
    8#005202#, 8#010261#, 8#000004#, 8#105003#,
    8#052703#, 8#000006#, 8#010311#, 8#105711#, 8#100376#,
    8#005061#, 8#000002#, 8#005061#, 8#000004#,
    8#012761#, 8#177000#, 8#000006#, 8#105003#,
    8#052703#, 8#000014#, 8#010311#, 8#105711#,
    8#100376#, 8#042711#, 8#000377#, 8#005002#,
    8#005003#, 8#012704#, 8#002020#, 8#005005#, 8#005007#);

  constant boot_rp : slv2 := "00";
  constant boot_rk : slv2 := "01";

  -- word of the bootstrap written in step 'step' (after 'pre' setup steps)
  function code_word(code : word_array; pre, step : natural) return slv16 is
  begin
    if step >= pre and step - pre <= code'high then
      return slv(to_unsigned(code(step - pre), 16));
    end if;
    return (others => '0');
  end function;

  -- rbus accesses: stop, creset, [RK05: switch = 1], al, memi..., pc, start
  constant n_steps_max : natural := 4 + rl_boot_code'length + 2;

  type state_type is (s_wait, s_ready, s_aval, s_we, s_next, s_done);

  type regs_type is record
    state : state_type;
    cnt : natural range 0 to DELAY;
    step : natural range 0 to n_steps_max;
    boot : slv2;
  end record regs_type;

  constant regs_init : regs_type := (s_wait, 0, 0, boot_rp);

  signal R_REGS : regs_type := regs_init;
  signal N_REGS : regs_type := regs_init;

begin

  proc_regs: process (CLK)
  begin
    if rising_edge(CLK) then
      if RESET = '1' then
        R_REGS <= regs_init;
      else
        R_REGS <= N_REGS;
      end if;
    end if;
  end process proc_regs;

  proc_next: process (R_REGS, CE_MSEC, START, BOOT, READY, RB_SRES)
    variable r : regs_type := regs_init;
    variable n : regs_type := regs_init;
    variable n_pre : natural range 3 to 4 := 3;
    variable n_code : natural range 0 to n_steps_max := 0;
    variable n_steps : natural range 0 to n_steps_max := 0;
    variable boot_addr : slv16 := (others => '0');
    variable start_addr : slv16 := (others => '0');
    variable code : slv16 := (others => '0');
    variable iaddr : slv5 := (others => '0');
    variable idata : slv16 := (others => '0');
    variable imreq : rb_mreq_type := rb_mreq_init;
  begin
    r := R_REGS;
    n := R_REGS;
    imreq := rb_mreq_init;

    n_pre := 3;
    boot_addr := slv(to_unsigned(8#002000#, 16));
    start_addr := slv(to_unsigned(8#002002#, 16));
    case r.boot is
      when boot_rp =>
        n_code := rp_boot_code'length;
        boot_addr := slv(to_unsigned(8#140000#, 16));
        start_addr := boot_addr;
        code := code_word(rp_boot_code, 3, r.step);
      when boot_rk =>
        n_pre := 4;
        n_code := rk_boot_code'length;
        code := code_word(rk_boot_code, 4, r.step);
      when others =>
        n_code := rl_boot_code'length;
        code := code_word(rl_boot_code, 3, r.step);
    end case;
    n_steps := n_pre + n_code + 2;

    if r.step < 1 then                  -- stop
      iaddr := "00001"; idata := x"0002";
    elsif r.step < 2 then               -- creset
      iaddr := "00001"; idata := x"0004";
    elsif r.boot = boot_rk and r.step < 3 then -- ibus remote switch register
      iaddr := "00000"; idata := x"0001";
    elsif r.step < n_pre then           -- al (clears ah: 16 bit address)
      iaddr := "00100"; idata := boot_addr;
    elsif r.step < n_pre + n_code then -- memi
      iaddr := "00111"; idata := code;
    elsif r.step < n_steps - 1 then     -- pc
      iaddr := "01111"; idata := start_addr;
    else                                -- start
      iaddr := "00001"; idata := x"0001";
    end if;

    case r.state is
      when s_wait =>
        if CE_MSEC = '1' then
          if r.cnt = DELAY - 1 then
            n.state := s_ready;
          else
            n.cnt := r.cnt + 1;
          end if;
        end if;
      when s_ready =>
        if READY = '1' then
          n.boot := BOOT;
          n.step := 0;
          n.state := s_aval;
        end if;
      when s_aval =>
        imreq.aval := '1';
        n.state := s_we;
      when s_we =>
        imreq.aval := '1';
        imreq.we := '1';
        if RB_SRES.ack = '1' and RB_SRES.busy = '0' then
          n.state := s_next;
        end if;
      when s_next =>
        if r.step = n_steps - 1 then
          n.state := s_done;
        else
          n.step := r.step + 1;
          n.state := s_aval;
        end if;
      when s_done =>
        null;
    end case;

    -- before the first run START is not needed: the sequence follows DELAY
    if START = '1' and r.state = s_done then
      n.state := s_ready;
    end if;

    if r.boot = boot_rk and r.step = 2 then
      -- cpu0 ibus window: 0x4000 + ((177570 & 017777) / 2)
      imreq.addr := x"4fbc";
    else
      imreq.addr := RB_BASE(15 downto 5) & iaddr;
    end if;
    imreq.din := idata;

    N_REGS <= n;
    RB_MREQ <= imreq;
    if r.state = s_aval or r.state = s_we or r.state = s_next then
      ACTIVE <= '1';
    else
      ACTIVE <= '0';
    end if;
  end process proc_next;

end syn;
