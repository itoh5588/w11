-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Autostart of the RP07 bootstrap for the standalone Arty S7 system: an
-- rbus master that does what 'cpu0 cp -stapc' does from ti_w11, without a
-- PC.  DELAY ms after reset (and again on each START pulse) it
--   stops and resets the CPU (cntl: stop, creset),
--   writes the bootstrap (tcode/rp07_boot.mac) to 140000 (al, memi),
--   sets PC to 140000 and starts the CPU (pc, cntl: start).
-- The bootstrap reads block 0 of RP07 unit 0 to address 0 and jumps to it.
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
    ACTIVE : out slbit;
    RB_MREQ : out rb_mreq_type;
    RB_SRES : in rb_sres_type
  );
end w11_autostart;

architecture syn of w11_autostart is

  constant boot_addr : slv16 := slv(to_unsigned(8#140000#, 16));

  type word_array is array (natural range <>) of natural;

  -- tcode/rp07_boot.mac assembled at 140000
  constant boot_code : word_array := (
    8#012701#, 8#176700#, 8#012761#, 8#000040#, 8#000010#, 8#012711#,
    8#000021#, 8#005061#, 8#000004#, 8#005061#, 8#000050#, 8#012761#,
    8#177400#, 8#000002#, 8#012711#, 8#000071#, 8#105711#, 8#100376#,
    8#005711#, 8#100402#, 8#005000#, 8#005007#, 8#000000#);

  -- rbus accesses: offset in the cp window and data; step nwords+3 is start
  constant n_pre : natural := 3;        -- stop, creset, al
  constant n_steps : natural := n_pre + boot_code'length + 2;

  type state_type is (s_wait, s_aval, s_we, s_next, s_done);

  type regs_type is record
    state : state_type;
    cnt : natural range 0 to DELAY;
    step : natural range 0 to n_steps;
  end record regs_type;

  constant regs_init : regs_type := (s_wait, 0, 0);

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

  proc_next: process (R_REGS, CE_MSEC, START, RB_SRES)
    variable r : regs_type := regs_init;
    variable n : regs_type := regs_init;
    variable iaddr : slv5 := (others => '0');
    variable idata : slv16 := (others => '0');
    variable imreq : rb_mreq_type := rb_mreq_init;
  begin
    r := R_REGS;
    n := R_REGS;
    imreq := rb_mreq_init;

    if r.step < 1 then                  -- stop
      iaddr := "00001"; idata := x"0002";
    elsif r.step < 2 then               -- creset
      iaddr := "00001"; idata := x"0004";
    elsif r.step < n_pre then           -- al (clears ah: 16 bit address)
      iaddr := "00100"; idata := boot_addr;
    elsif r.step < n_pre + boot_code'length then -- memi
      iaddr := "00111"; idata := slv(to_unsigned(boot_code(r.step - n_pre), 16));
    elsif r.step < n_steps - 1 then     -- pc
      iaddr := "01111"; idata := boot_addr;
    else                                -- start
      iaddr := "00001"; idata := x"0001";
    end if;

    case r.state is
      when s_wait =>
        if CE_MSEC = '1' then
          if r.cnt = DELAY - 1 then
            n.state := s_aval;
            n.step := 0;
          else
            n.cnt := r.cnt + 1;
          end if;
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

    if START = '1' and (r.state = s_done or r.state = s_wait) then
      n.state := s_aval;
      n.step := 0;
    end if;

    imreq.addr := RB_BASE(15 downto 5) & iaddr;
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
