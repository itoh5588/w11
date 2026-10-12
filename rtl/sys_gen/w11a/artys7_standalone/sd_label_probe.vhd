-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- microSD card label probe for the standalone Arty S7 system.  After reset
-- (and on each START pulse) it owns the SD pins, initializes the card,
-- reads block 0 and decodes a card label (little-endian words):
--   word 0..3  ASCII "W11SDLBL"
--   word 4     label version, 1
--   word 5     disk type: 1 RP07 (RH70), 2 RK05 (RK11), 3 RL01/RL02 (RL11)
--   word 6..7  first LBA of the disk data (low word first)
--   word 8     RL: bit u set = unit u is an RL02 (else RL01)
--   word 9     RL: bit u set = unit u is present
-- Bytes from 446 on stay free for an MBR partition table.
-- A card without a valid label, or a failed init or read, selects RP07
-- with the data at LBA 0: the layout of the original RP07 cards.
-- SEL: "00" RP07, "01" RK05, "10" RL.  READY is 1 while SEL, BASE and the
-- masks are valid; DONE pulses once when a probe ends.  ACTIVE is 1 while
-- the probe drives the SD pins.  LABELED tells a label was found.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;

entity sd_label_probe is
  generic (
    DELAY : positive := 10);            -- ms before the card init
  port (
    CLK : in slbit;
    RESET : in slbit;
    CE_MSEC : in slbit;
    START : in slbit;                   -- probe again
    ACTIVE : out slbit;
    READY : out slbit;
    DONE : out slbit;
    LABELED : out slbit;
    SEL : out slv2;
    BASE : out slv32;
    RL02_MASK : out slv4;
    PRESENT_MASK : out slv4;
    O_SD_CS_N : out slbit;
    O_SD_SCLK : out slbit;
    O_SD_MOSI : out slbit;
    I_SD_MISO : in slbit
  );
end sd_label_probe;

architecture syn of sd_label_probe is

  constant op_init : slv3 := "001";
  constant op_read : slv3 := "100";

  type word_array is array (0 to 9) of slv16;
  constant magic : word_array := (    -- "W11SDLBL", version 1
    x"3157", x"5331", x"4c44", x"4c42", x"0001",
    others => (others => '0'));

  type state_type is (s_wait, s_init_go, s_init_arm, s_init_wait,
                      s_read_go, s_read_arm, s_read_wait, s_eval, s_done);

  type regs_type is record
    state : state_type;
    cnt : natural range 0 to DELAY;
    words : word_array;
    ok : slbit;                         -- init and read without error
    ready : slbit;
    done : slbit;
    labeled : slbit;
    sel : slv2;
    base : slv32;
    rl02 : slv4;
    present : slv4;
  end record regs_type;

  constant regs_init : regs_type := (
    s_wait, 0, (others => (others => '0')), '0', '0', '0', '0',
    "00", (others => '0'), "1111", "1111");

  signal R_REGS : regs_type := regs_init;
  signal N_REGS : regs_type := regs_init;

  signal CTL_RESET : slbit := '0';
  signal SD_OP : slv3 := (others => '0');
  signal SD_GO : slbit := '0';
  signal SD_BUSY : slbit := '0';
  signal SD_INITOK : slbit := '0';
  signal SD_ERR : slv8 := (others => '0');
  signal SD_WE : slbit := '0';
  signal SD_WADDR : slv8 := (others => '0');
  signal SD_WDATA : slv16 := (others => '0');
  signal PHY_DIV : slv8 := (others => '0');
  signal PHY_START : slbit := '0';
  signal PHY_TXD : slv8 := (others => '0');
  signal PHY_RXD : slv8 := (others => '0');
  signal PHY_DONE : slbit := '0';

begin

  -- a new probe starts with a fresh controller (and a new card init)
  CTL_RESET <= RESET or START;

  CTL : entity work.sdspi_ctl
    port map (
      CLK => CLK, RESET => CTL_RESET, CE_MSEC => CE_MSEC,
      OP => SD_OP, GO => SD_GO, LBA => (others => '0'), NBLK => x"0001",
      HOLD => '0', ABORT => '0', FASTDIV => x"02",
      BUSY => SD_BUSY, INITOK => SD_INITOK, V2 => open, HC => open,
      ERR => SD_ERR, R1 => open, TOKEN => open, RESP => open,
      BUF_WE => SD_WE, BUF_ADDR => SD_WADDR, BUF_DI => SD_WDATA,
      WBUF_ADDR => open, WBUF_DATA => x"0000",
      O_CS_N => O_SD_CS_N, PHY_DIV => PHY_DIV, PHY_START => PHY_START,
      PHY_TXD => PHY_TXD, PHY_RXD => PHY_RXD, PHY_DONE => PHY_DONE);

  PHY : entity work.sdspi_phy
    port map (
      CLK => CLK, RESET => CTL_RESET, DIV => PHY_DIV,
      START => PHY_START, TXD => PHY_TXD, RXD => PHY_RXD,
      DONE => PHY_DONE, BUSY => open,
      O_SCLK => O_SD_SCLK, O_MOSI => O_SD_MOSI, I_MISO => I_SD_MISO);

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

  proc_next: process (R_REGS, CE_MSEC, START, SD_BUSY, SD_INITOK, SD_ERR,
                      SD_WE, SD_WADDR, SD_WDATA)
    variable r : regs_type := regs_init;
    variable n : regs_type := regs_init;
    variable isdop : slv3 := (others => '0');
    variable isdgo : slbit := '0';
    variable widx : natural range 0 to 255 := 0;
  begin
    r := R_REGS;
    n := R_REGS;
    isdop := op_init;
    isdgo := '0';
    n.done := '0';

    case r.state is
      when s_wait =>
        if CE_MSEC = '1' then
          if r.cnt = DELAY - 1 then
            n.state := s_init_go;
          else
            n.cnt := r.cnt + 1;
          end if;
        end if;
      when s_init_go =>
        isdgo := '1';
        n.state := s_init_arm;
      when s_init_arm =>
        n.state := s_init_wait;
      when s_init_wait =>
        if SD_BUSY = '0' then
          if SD_INITOK = '1' and SD_ERR = x"00" then
            n.state := s_read_go;
          else
            n.state := s_eval;
          end if;
        end if;
      when s_read_go =>
        isdop := op_read;
        isdgo := '1';
        n.state := s_read_arm;
      when s_read_arm =>
        isdop := op_read;
        n.state := s_read_wait;
      when s_read_wait =>
        isdop := op_read;
        if SD_WE = '1' then
          widx := to_integer(unsigned(SD_WADDR));
          if widx <= word_array'high then
            n.words(widx) := SD_WDATA;
          end if;
        end if;
        if SD_BUSY = '0' then
          if SD_ERR = x"00" then
            n.ok := '1';
          end if;
          n.state := s_eval;
        end if;
      when s_eval =>
        n.sel := "00";                  -- default: unlabeled RP07 card
        n.base := (others => '0');
        n.rl02 := "1111";
        n.present := "1111";
        n.labeled := '0';
        if r.ok = '1' and r.words(0 to 4) = magic(0 to 4) and
           (r.words(5) = x"0001" or r.words(5) = x"0002" or
            r.words(5) = x"0003") then
          n.labeled := '1';
          n.sel := slv(unsigned(r.words(5)(1 downto 0)) - 1);
          n.base := r.words(7) & r.words(6);
          n.rl02 := r.words(8)(3 downto 0);
          n.present := r.words(9)(3 downto 0);
        end if;
        n.ready := '1';
        n.done := '1';
        n.state := s_done;
      when s_done =>
        null;
    end case;

    if START = '1' then
      n := regs_init;
      n.sel := r.sel;                   -- keep the outputs stable
      n.base := r.base;
      n.rl02 := r.rl02;
      n.present := r.present;
      n.labeled := r.labeled;
    end if;

    N_REGS <= n;
    SD_OP <= isdop;
    SD_GO <= isdgo;
    if r.state = s_done then
      ACTIVE <= '0';
    else
      ACTIVE <= '1';
    end if;
    READY <= r.ready;
    DONE <= r.done;
    LABELED <= r.labeled;
    SEL <= r.sel;
    BASE <= r.base;
    RL02_MASK <= r.rl02;
    PRESENT_MASK <= r.present;
  end process proc_next;

end syn;
