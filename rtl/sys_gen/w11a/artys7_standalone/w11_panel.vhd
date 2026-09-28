-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- PDP-11/70 front panel for the standalone Arty S7 w11, for a panel drawn on
-- the host (tcode/panel.html, Web Serial).  Same serial protocol as the panel
-- of the PDP2011 Arty S7 port, so the same page works for both:
--
-- To the host, every 2^20 CLK cycles (14 ms at 75 MHz): 0x80, then 51 bytes,
-- one per lamp, each the brightness 0..15 (the part of the frame time the
-- lamp was on):
--   0..21   address       22..37  data
--   38 parity low, 39 parity high, 40 adrs err, 41 run, 42 pause, 43 master,
--   44 user, 45 super, 46 kernel, 47 data (i/d), 48 16 bit, 49 18 bit, 50 22 bit
--
-- From the host (a byte >= 0x80 starts a command, the data bytes are < 0x80),
-- each command ends with a check byte = xor of the low 7 bits of all bytes;
-- a command with a wrong check byte or a byte with a bad stop bit is ignored:
--   0x81 d0 d1 d2 d3 c  switch register: bits 6..0, 13..7, 20..14, 21
--   0x82 d c            d(2..0) ADDRESS knob, d(4..3) DATA knob, d(5) halt
--   0x83 d c            momentary: d(0) load adrs, d(1) exam, d(2) dep,
--                       d(3) cont, d(4) start
--
-- ADDRESS knob: 0 prog phy, 1 cons phy, 2 kernel d, 3 super d, 4 user d,
--               5 user i, 6 super i, 7 kernel i
-- DATA knob:    0 data paths, 1 bus reg, 2 display reg, 3 uadrs (state flags)
--
-- The switches act on the w11 through the cp registers on the rbus, like
-- ti_w11 does (this module is an rbus master, ACTIVE while it uses the rbus):
--   HALT (enable -> halt)   cntl stop
--   LOAD ADRS               console address := switch register (no rbus)
--   EXAM, DEP               only when halted; al/ah (22 bit) and mem, or
--                           r0..pc for 17777700..17777707; a 2nd EXAM (DEP)
--                           in a row goes to the next word (register)
--   CONT                    only when halted; HALT: cntl step, else cntl start
--   START                   only when halted; HALT: cntl creset, else creset,
--                           pc := console address, start
-- An rbus error (or an unsupported register address) lights ADRS ERR until
-- the next LOAD ADRS, EXAM or DEP.
-- After a reset: enable, switches 0, both knobs 0; without a host the machine
-- runs as before.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;
use work.rblib.all;
use work.pdp11.all;

entity w11_panel is
  generic (
    CDIV : positive := 651;             -- CLK cycles per bit (75 MHz/115200)
    RB_BASE : slv16 := x"0000");        -- cpu0 cp register base
  port (
    CLK : in slbit;
    RESET : in slbit;
    RXD : in slbit;                     -- from host (asynchronous)
    TXD : out slbit;                    -- to host
    HOLD : in slbit;                    -- another rbus master is active
    ACTIVE : out slbit;
    RB_MREQ : out rb_mreq_type;
    RB_SRES : in rb_sres_type;
    CP_STAT : in cp_stat_type;
    DM_STAT_EXP : in dm_stat_exp_type;
    DISPREG : in slv16;                 -- display register (177570)
    DMA_ACT : in slbit                  -- a DMA device is bus master
  );
end w11_panel;

architecture syn of w11_panel is

  constant nlamps : natural := 51;

  -- host state
  signal SW : slv22 := (others => '0');
  signal ADSS : slv3 := "000";
  signal DDSS : slv2 := "00";
  signal HALT : slbit := '0';
  signal HALT_R : slbit := '0';
  signal PEND : slv5 := (others => '0'); -- load exam dep cont start
  signal PEND_STOP : slbit := '0';

  -- uart receive
  signal RX_S : slv3 := "111";
  signal RX_BUSY : slbit := '0';
  signal RX_DIV : natural range 0 to CDIV - 1 := 0;
  signal RX_BITS : natural range 0 to 9 := 0;
  signal RX_HOLD : slbit := '0';        -- after a framing error: wait for idle
  signal RX_IDLE : natural range 0 to 10 * CDIV := 0;
  signal RX_SHIFT : slv8 := (others => '0');
  signal RX_CMD : slv8 := (others => '0');
  signal RX_N : natural range 0 to 4 := 0;
  signal RX_D : slv(27 downto 0) := (others => '0');
  signal RX_CHK : slv7 := (others => '0');

  -- console
  type state_type is (s_idle, s_aval, s_acc, s_next);
  signal STATE : state_type := s_idle;
  type addr_array is array (0 to 2) of slv5;
  type data_array is array (0 to 2) of slv16;
  signal ACC_ADDR : addr_array := (others => (others => '0'));
  signal ACC_DIN : data_array := (others => (others => '0'));
  signal ACC_WE : slv3 := (others => '0');
  signal ACC_N : natural range 0 to 2 := 0;   -- index of the last access
  signal ACC_I : natural range 0 to 2 := 0;
  signal ACC_DEP : slbit := '0';         -- data of a good DEP is displayed
  signal CONS_ADDR : slv22 := (others => '0');
  signal CONS_DATA : slv16 := (others => '0');
  signal CONS_ERR : slbit := '0';
  signal LAST_EXAM : slbit := '0';
  signal LAST_DEP : slbit := '0';

  -- lamps
  signal PHYS : slv22 := (others => '0');     -- last cpu bus address
  signal VIRT : slv16 := (others => '0');     -- last virtual address (knob)
  signal BUSREG : slv16 := (others => '0');
  signal DSPACE : slbit := '0';
  signal LAMPS : slv(nlamps - 1 downto 0) := (others => '0');
  type count_array is array (0 to nlamps - 1) of unsigned(16 downto 0);
  signal COUNTS : count_array := (others => (others => '0'));
  type bright_array is array (0 to nlamps - 1) of slv4;
  signal BRIGHT : bright_array := (others => (others => '0'));
  signal FRAME_CNT : unsigned(19 downto 0) := (others => '0');

  -- uart transmit
  signal TX_BUSY : slbit := '0';
  signal TX_SHIFT : slv10 := (others => '1');
  signal TX_BITS : natural range 0 to 10 := 0;
  signal TX_DIV : natural range 0 to CDIV - 1 := 0;
  signal TX_IDX : natural range 0 to nlamps + 1 := nlamps + 1; -- +1: idle

  -- 17777700..17777717: the general registers
  function is_regsp(a : slv22) return boolean is
  begin
    return a(21 downto 4) = "111111111111111100";
  end function is_regsp;

begin

-- ---------------------------------------------------------------- lamps
  proc_lamps: process (CLK)
    variable m : slv2;
    variable d : slbit;
    variable run : slbit;
    variable a : slv22;
    variable dat : slv16;
  begin
    if rising_edge(CLK) then
      if DM_STAT_EXP.vm_emmreq.req = '1' then
        PHYS <= DM_STAT_EXP.vm_emmreq.addr & '0';
        if DM_STAT_EXP.vm_emmreq.we = '1' then
          BUSREG <= DM_STAT_EXP.vm_emmreq.din;
        end if;
      elsif DM_STAT_EXP.vm_ibmreq.aval = '1' and DM_STAT_EXP.vm_ibmreq.racc = '0'
            and (DM_STAT_EXP.vm_ibmreq.re or DM_STAT_EXP.vm_ibmreq.we) = '1' then
        PHYS <= "111111111" & DM_STAT_EXP.vm_ibmreq.addr & '0';
        if DM_STAT_EXP.vm_ibmreq.we = '1' then
          BUSREG <= DM_STAT_EXP.vm_ibmreq.din;
        end if;
      end if;
      if DM_STAT_EXP.vm_emsres.ack_r = '1' then
        BUSREG <= DM_STAT_EXP.vm_emsres.dout;
      end if;

      case ADSS is                      -- mode and i/d of the ADDRESS knob
        when "010" => m := "00"; d := '1';
        when "011" => m := "01"; d := '1';
        when "100" => m := "11"; d := '1';
        when "101" => m := "11"; d := '0';
        when "110" => m := "01"; d := '0';
        when others => m := "00"; d := '0';
      end case;
      if DM_STAT_EXP.vm_cntl.req = '1' and DM_STAT_EXP.vm_cntl.cacc = '0' then
        DSPACE <= DM_STAT_EXP.vm_cntl.dspace;
        if DM_STAT_EXP.vm_cntl.mode = m and DM_STAT_EXP.vm_cntl.dspace = d then
          VIRT <= DM_STAT_EXP.vm_addr;
        end if;
      end if;

      run := CP_STAT.cpugo;
      if ADSS = "001" or run = '0' then
        a := CONS_ADDR;
      elsif ADSS = "000" then
        a := PHYS;
      else
        a := "000000" & VIRT;
      end if;
      case DDSS is
        when "00" =>
          if run = '1' then
            dat := DM_STAT_EXP.dp_dres;
          else
            dat := CONS_DATA;
          end if;
        when "01" => dat := BUSREG;
        when "10" => dat := DISPREG;
        when others => dat := x"00" & DM_STAT_EXP.se_snum;
      end case;

      LAMPS(21 downto 0) <= a;
      LAMPS(37 downto 22) <= dat;
      LAMPS(38) <= '0';                 -- parity low
      LAMPS(39) <= '0';                 -- parity high
      LAMPS(40) <= CONS_ERR;
      LAMPS(41) <= run;
      LAMPS(42) <= CP_STAT.cpuwait or CP_STAT.cpususp;
      LAMPS(43) <= not DMA_ACT;
      if DM_STAT_EXP.dp_psw.cmode = "11" then LAMPS(44) <= '1'; else LAMPS(44) <= '0'; end if;
      if DM_STAT_EXP.dp_psw.cmode = "01" then LAMPS(45) <= '1'; else LAMPS(45) <= '0'; end if;
      if DM_STAT_EXP.dp_psw.cmode = "00" then LAMPS(46) <= '1'; else LAMPS(46) <= '0'; end if;
      LAMPS(47) <= DSPACE;
      LAMPS(48) <= not DM_STAT_EXP.vm_mmustat.ena_mmu;
      LAMPS(49) <= DM_STAT_EXP.vm_mmustat.ena_mmu and not DM_STAT_EXP.vm_mmustat.ena_22bit;
      LAMPS(50) <= DM_STAT_EXP.vm_mmustat.ena_mmu and DM_STAT_EXP.vm_mmustat.ena_22bit;

      -- every 16th cycle each lamp is sampled; after 2^20 cycles (65536
      -- samples) the counts become the brightness and the frame is sent
      FRAME_CNT <= FRAME_CNT + 1;
      if FRAME_CNT = (FRAME_CNT'range => '1') then
        for i in 0 to nlamps - 1 loop
          if COUNTS(i)(16) = '1' then
            BRIGHT(i) <= "1111";
          else
            BRIGHT(i) <= slv(COUNTS(i)(15 downto 12));
          end if;
          COUNTS(i) <= (others => '0');
        end loop;
      elsif FRAME_CNT(3 downto 0) = "0000" then
        for i in 0 to nlamps - 1 loop
          if LAMPS(i) = '1' then
            COUNTS(i) <= COUNTS(i) + 1;
          end if;
        end loop;
      end if;
    end if;
  end process proc_lamps;

-- ---------------------------------------------------------------- uart transmit
-- a frame is 52 bytes, 4.5 ms at 115200 bps, inside the 14 ms frame time
  proc_tx: process (CLK)
  begin
    if rising_edge(CLK) then
      if FRAME_CNT = (FRAME_CNT'range => '1') and TX_IDX = nlamps + 1 then
        TX_IDX <= 0;                    -- BRIGHT is loaded now
      end if;

      if TX_BUSY = '0' then
        if TX_IDX <= nlamps then
          if TX_IDX = 0 then
            TX_SHIFT <= '1' & x"80" & '0';
          else
            TX_SHIFT <= '1' & "0000" & BRIGHT(TX_IDX - 1) & '0';
          end if;
          TX_IDX <= TX_IDX + 1;
          TX_BITS <= 10;
          TX_DIV <= 0;
          TX_BUSY <= '1';
        end if;
      elsif TX_DIV = CDIV - 1 then
        TX_DIV <= 0;
        if TX_BITS = 1 then
          TX_BUSY <= '0';
        else
          TX_SHIFT <= '1' & TX_SHIFT(9 downto 1);
          TX_BITS <= TX_BITS - 1;
        end if;
      else
        TX_DIV <= TX_DIV + 1;
      end if;
    end if;
  end process proc_tx;

  TXD <= TX_SHIFT(0) when TX_BUSY = '1' else '1';

-- ---------------------------------------------------------------- uart receive
  proc_rx: process (CLK)
  begin
    if rising_edge(CLK) then
      RX_S <= RX_S(1 downto 0) & RXD;
      HALT_R <= HALT;

      if RX_S(2) = '0' then
        RX_IDLE <= 0;
      elsif RX_IDLE < 10 * CDIV then
        RX_IDLE <= RX_IDLE + 1;
      end if;

      if RX_HOLD = '1' then
        if RX_IDLE = 10 * CDIV then     -- a whole byte time high: in sync
          RX_HOLD <= '0';
        end if;
      elsif RX_BUSY = '0' then
        if RX_S(2) = '0' then           -- start bit
          RX_BUSY <= '1';
          RX_DIV <= CDIV / 2;
          RX_BITS <= 0;
        end if;
      elsif RX_DIV = CDIV - 1 then
        RX_DIV <= 0;
        if RX_BITS = 0 then
          if RX_S(2) = '1' then
            RX_BUSY <= '0';             -- false start
          end if;
          RX_BITS <= 1;
        elsif RX_BITS <= 8 then
          RX_SHIFT <= RX_S(2) & RX_SHIFT(7 downto 1);
          RX_BITS <= RX_BITS + 1;
        else
          RX_BUSY <= '0';               -- stop bit
          if RX_S(2) = '0' then
            RX_CMD <= x"00";            -- framing error: drop the command
            RX_HOLD <= '1';             -- and wait for the line to be idle
          elsif RX_SHIFT(7) = '1' then
            if RX_SHIFT = x"81" or RX_SHIFT = x"82" or RX_SHIFT = x"83" then
              RX_CMD <= RX_SHIFT;
            else
              RX_CMD <= x"00";          -- 0x80 and unknown commands
            end if;
            RX_N <= 0;
            RX_CHK <= RX_SHIFT(6 downto 0);
          elsif RX_CMD /= x"00" then
            -- the byte after the data bytes is the check byte
            if (RX_CMD = x"81" and RX_N = 4) or (RX_CMD /= x"81" and RX_N = 1) then
              if RX_SHIFT(6 downto 0) = RX_CHK then
                case RX_CMD is
                  when x"81" =>
                    SW <= RX_D(21 downto 0);
                  when x"82" =>
                    ADSS <= RX_D(2 downto 0);
                    DDSS <= RX_D(4 downto 3);
                    HALT <= RX_D(5);
                  when others =>
                    PEND <= PEND or RX_D(4 downto 0);
                end case;
              end if;
              RX_CMD <= x"00";
            else
              case RX_N is
                when 0 => RX_D(6 downto 0) <= RX_SHIFT(6 downto 0);
                when 1 => RX_D(13 downto 7) <= RX_SHIFT(6 downto 0);
                when 2 => RX_D(20 downto 14) <= RX_SHIFT(6 downto 0);
                when others => RX_D(27 downto 21) <= RX_SHIFT(6 downto 0);
              end case;
              RX_CHK <= RX_CHK xor RX_SHIFT(6 downto 0);
              if RX_N < 4 then
                RX_N <= RX_N + 1;
              end if;
            end if;
          end if;
        end if;
      else
        RX_DIV <= RX_DIV + 1;
      end if;

      if HALT = '1' and HALT_R = '0' then
        PEND_STOP <= '1';
      end if;

      -- the console sequencer takes one pending request at a time
      if STATE = s_idle and HOLD = '0' then
        if PEND_STOP = '1' then
          PEND_STOP <= '0';
        elsif PEND(0) = '1' then
          PEND(0) <= '0';
        elsif PEND(1) = '1' then
          PEND(1) <= '0';
        elsif PEND(2) = '1' then
          PEND(2) <= '0';
        elsif PEND(3) = '1' then
          PEND(3) <= '0';
        elsif PEND(4) = '1' then
          PEND(4) <= '0';
        end if;
      end if;

      if RESET = '1' then
        SW <= (others => '0');
        ADSS <= "000";
        DDSS <= "00";
        HALT <= '0';
        HALT_R <= '0';
        PEND <= (others => '0');
        PEND_STOP <= '0';
        RX_CMD <= x"00";
      end if;
    end if;
  end process proc_rx;

-- ---------------------------------------------------------------- console
  proc_cons: process (CLK)
    variable a : slv22;
    variable halted : boolean;
    variable go : boolean;
  begin
    if rising_edge(CLK) then
      halted := CP_STAT.cpugo = '0';
      go := false;

      case STATE is
        when s_idle =>
          if HOLD = '0' then
            if PEND_STOP = '1' then                      -- HALT
              ACC_ADDR(0) <= c_rbaddr_cntl;
              ACC_DIN(0) <= x"00" & "000" & c_cpfunc_stop;
              ACC_WE <= "001";
              ACC_N <= 0;
              ACC_DEP <= '0';
              go := true;
            elsif PEND(0) = '1' then                     -- LOAD ADRS
              CONS_ADDR <= SW;
              CONS_ERR <= '0';
              LAST_EXAM <= '0';
              LAST_DEP <= '0';
            elsif PEND(1) = '1' or PEND(2) = '1' then    -- EXAM, DEP
              if halted then
                a := CONS_ADDR;
                if (PEND(1) = '1' and LAST_EXAM = '1') or
                   (PEND(1) = '0' and LAST_DEP = '1') then
                  if is_regsp(a) then
                    a := slv(unsigned(a) + 1);
                  else
                    a := slv(unsigned(a) + 2);
                  end if;
                end if;
                CONS_ADDR <= a;
                CONS_ERR <= '0';
                LAST_EXAM <= PEND(1);
                LAST_DEP <= not PEND(1);
                ACC_DEP <= not PEND(1);
                if is_regsp(a) then
                  if a(3) = '1' then
                    CONS_ERR <= '1';      -- other register set, SSP, USP
                  else
                    ACC_ADDR(0) <= "01" & a(2 downto 0);
                    ACC_DIN(0) <= SW(15 downto 0);
                    ACC_WE <= "00" & not PEND(1);
                    ACC_N <= 0;
                    go := true;
                  end if;
                else
                  ACC_ADDR(0) <= c_rbaddr_al;
                  ACC_DIN(0) <= a(15 downto 0);
                  ACC_ADDR(1) <= c_rbaddr_ah;
                  ACC_DIN(1) <= x"00" & "01" & a(21 downto 16); -- 22 bit
                  ACC_ADDR(2) <= c_rbaddr_mem;
                  ACC_DIN(2) <= SW(15 downto 0);
                  ACC_WE <= not PEND(1) & "11";
                  ACC_N <= 2;
                  go := true;
                end if;
              end if;
            elsif PEND(3) = '1' then                     -- CONT
              if halted then
                ACC_ADDR(0) <= c_rbaddr_cntl;
                if HALT = '1' then
                  ACC_DIN(0) <= x"00" & "000" & c_cpfunc_step;
                else
                  ACC_DIN(0) <= x"00" & "000" & c_cpfunc_start;
                end if;
                ACC_WE <= "001";
                ACC_N <= 0;
                ACC_DEP <= '0';
                go := true;
              end if;
            elsif PEND(4) = '1' then                     -- START
              if halted then
                ACC_ADDR(0) <= c_rbaddr_cntl;
                ACC_DIN(0) <= x"00" & "000" & c_cpfunc_creset;
                ACC_ADDR(1) <= c_rbaddr_pc;
                ACC_DIN(1) <= CONS_ADDR(15 downto 0);
                ACC_ADDR(2) <= c_rbaddr_cntl;
                ACC_DIN(2) <= x"00" & "000" & c_cpfunc_start;
                ACC_WE <= "111";
                if HALT = '1' then
                  ACC_N <= 0;
                else
                  ACC_N <= 2;
                end if;
                ACC_DEP <= '0';
                LAST_EXAM <= '0';
                LAST_DEP <= '0';
                go := true;
              end if;
            end if;
          end if;
          if go then
            ACC_I <= 0;
            STATE <= s_aval;
          end if;

        when s_aval =>
          STATE <= s_acc;

        when s_acc =>
          if RB_SRES.ack = '0' then     -- nobody there
            CONS_ERR <= '1';
            STATE <= s_idle;
          elsif RB_SRES.busy = '0' then
            if RB_SRES.err = '1' then
              CONS_ERR <= '1';
              STATE <= s_idle;
            elsif ACC_I = ACC_N then
              if ACC_WE(ACC_I) = '0' then
                CONS_DATA <= RB_SRES.dout;
              elsif ACC_DEP = '1' then
                CONS_DATA <= ACC_DIN(ACC_I);
              end if;
              STATE <= s_idle;
            else
              STATE <= s_next;
            end if;
          end if;

        when s_next =>
          ACC_I <= ACC_I + 1;
          STATE <= s_aval;
      end case;

      if RESET = '1' then
        STATE <= s_idle;
        CONS_ADDR <= (others => '0');
        CONS_DATA <= (others => '0');
        CONS_ERR <= '0';
        LAST_EXAM <= '0';
        LAST_DEP <= '0';
      end if;
    end if;
  end process proc_cons;

  proc_mreq: process (STATE, ACC_I, ACC_ADDR, ACC_DIN, ACC_WE)
    variable imreq : rb_mreq_type;
  begin
    imreq := rb_mreq_init;
    if STATE = s_aval or STATE = s_acc then
      imreq.aval := '1';
    end if;
    if STATE = s_acc then
      imreq.we := ACC_WE(ACC_I);
      imreq.re := not ACC_WE(ACC_I);
    end if;
    imreq.addr := RB_BASE(15 downto 5) & ACC_ADDR(ACC_I);
    imreq.din := ACC_DIN(ACC_I);
    RB_MREQ <= imreq;
  end process proc_mreq;

  ACTIVE <= '0' when STATE = s_idle else '1';

end syn;
