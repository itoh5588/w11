-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ARTY S7 hardware self-test for the native memory arbiter and cache
-- invalidation path.  This is a volatile JTAG test image; it does not access
-- the SD card or configuration flash.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;
use work.xlib.all;
use work.cdclib.all;
use work.rblib.all;
use work.bpgenlib.all;
use work.miglib.all;
use work.miglib_artys7.all;
use work.sysmonrbuslib.all;
use work.pdp11.all;

entity sys_w11a_dma_test_as7 is
  port (
    I_CLK100 : in slbit;
    I_RXD : in slbit;
    O_TXD : out slbit;
    I_SWI : in slv4;
    I_BTN : in slv4;
    O_LED : out slv4;
    O_RGBLED0 : out slv3;
    O_RGBLED1 : out slv3;
    DDR3_DQ      : inout slv16;
    DDR3_DQS_P   : inout slv2;
    DDR3_DQS_N   : inout slv2;
    DDR3_ADDR    : out   slv14;
    DDR3_BA      : out   slv3;
    DDR3_RAS_N   : out   slbit;
    DDR3_CAS_N   : out   slbit;
    DDR3_WE_N    : out   slbit;
    DDR3_RESET_N : out   slbit;
    DDR3_CK_P    : out   slv1;
    DDR3_CK_N    : out   slv1;
    DDR3_CKE     : out   slv1;
    DDR3_CS_N    : out   slv1;
    DDR3_DM      : out   slv2;
    DDR3_ODT     : out   slv1
  );
end sys_w11a_dma_test_as7;

architecture syn of sys_w11a_dma_test_as7 is
  constant TEST_ADDR : slv20 := x"c0000";
  constant DATA_OLD  : slv32 := x"11223344";
  constant DATA_NEW  : slv32 := x"a5c35a3c";
  constant DATA_PART : slv32 := x"a5e15a7e";

  type state_type is (
    s_wait_mig,
    s_old_write_req, s_old_write_wait,
    s_old_read_lo, s_old_read_hi,
    s_new_write_req, s_new_write_wait,
    s_new_read_lo, s_new_read_hi,
    s_dma_read_req, s_dma_read_wait,
    s_part_write_req, s_part_write_wait,
    s_part_read_lo, s_part_read_hi,
    s_part_dma_read_req, s_part_dma_read_wait,
    s_pass, s_fail
  );

  signal CLK100_BUF : slbit := '0';
  signal CLK : slbit := '0';
  signal CLKS : slbit := '0';
  signal CLKMIG : slbit := '0';
  signal CLKREF : slbit := '0';
  signal LOCKED : slbit := '0';
  signal LOCKED_CLK : slbit := '0';
  signal RESET : slbit := '1';

  signal STATE : state_type := s_wait_mig;
  signal TIMEOUT : unsigned(27 downto 0) := (others => '0');

  signal EM_MREQ : em_mreq_type := em_mreq_init;
  signal EM_SRES : em_sres_type := em_sres_init;
  signal DM_STAT_CA : dm_stat_ca_type := dm_stat_ca_init;

  signal CPU_REQ   : slbit := '0';
  signal CPU_WE    : slbit := '0';
  signal CPU_BUSY  : slbit := '0';
  signal CPU_ACK_R : slbit := '0';
  signal CPU_ACK_W : slbit := '0';
  signal CPU_ADDR  : slv20 := (others => '0');
  signal CPU_BE    : slv4 := (others => '0');
  signal CPU_DI    : slv32 := (others => '0');
  signal CPU_DO    : slv32 := (others => '0');

  signal DMA_REQ   : slbit := '0';
  signal DMA_WE    : slbit := '0';
  signal DMA_BUSY  : slbit := '0';
  signal DMA_ACK_R : slbit := '0';
  signal DMA_ACK_W : slbit := '0';
  signal DMA_ADDR  : slv20 := TEST_ADDR;
  signal DMA_BE    : slv4 := "1111";
  signal DMA_DI    : slv32 := (others => '0');
  signal DMA_DO    : slv32 := (others => '0');

  signal INV_REQ  : slbit := '0';
  signal INV_ADDR : slv20 := (others => '0');
  signal INV_ACK  : slbit := '0';

  signal MEM_REQ   : slbit := '0';
  signal MEM_WE    : slbit := '0';
  signal MEM_BUSY  : slbit := '1';
  signal MEM_ACK_R : slbit := '0';
  signal MEM_ACK_W : slbit := '0';
  signal MEM_ADDR  : slv20 := (others => '0');
  signal MEM_BE    : slv4 := (others => '0');
  signal MEM_DI    : slv32 := (others => '0');
  signal MEM_DO    : slv32 := (others => '0');
  signal MEM_ACT_R : slbit := '0';
  signal MEM_ACT_W : slbit := '0';
  signal MIG_MONI : sramif2migui_moni_type := sramif2migui_moni_init;
  signal XADC_TEMP : slv12 := (others => '0');
  signal RB_SRES_SYSMON : rb_sres_type := rb_sres_init;
  signal TXD : slbit := '1';
  signal TX_BUSY : slbit := '0';
  signal TX_DATA : slv8 := (others => '0');
  signal TX_BIT : integer range 0 to 9 := 0;
  signal TX_BAUD : integer range 0 to 650 := 0;
  signal TX_PAUSE : unsigned(23 downto 0) := (others => '0');
begin
  CLK100_BUFG: bufg_unisim
    port map (I => I_CLK100, O => CLK100_BUF);

  GEN_CLKALL: s7_cmt_1ce1ce2c
    generic map (
      CLKIN_PERIOD => 10.0, CLKIN_JITTER => 0.01, STARTUP_WAIT => false,
      CLK0_VCODIV => 1, CLK0_VCOMUL => 9, CLK0_OUTDIV => 12,
      CLK0_GENTYPE => "MMCM", CLK0_CDUWIDTH => 7,
      CLK0_USECDIV => 75, CLK0_MSECDIV => 1000,
      CLK1_VCODIV => 1, CLK1_VCOMUL => 12, CLK1_OUTDIV => 10,
      CLK1_GENTYPE => "PLL", CLK1_CDUWIDTH => 7,
      CLK1_USECDIV => 120, CLK1_MSECDIV => 1000,
      CLK23_VCODIV => 1, CLK23_VCOMUL => 16,
      CLK2_OUTDIV => 10, CLK3_OUTDIV => 8, CLK23_GENTYPE => "PLL")
    port map (
      CLKIN => CLK100_BUF,
      CLK0 => CLK, CE0_USEC => open, CE0_MSEC => open,
      CLK1 => CLKS, CE1_USEC => open, CE1_MSEC => open,
      CLK2 => CLKMIG, CLK3 => CLKREF, LOCKED => LOCKED);

  CDC_LOCKED: cdc_signal_s1_as
    port map (CLKO => CLK, DI => LOCKED, DO => LOCKED_CLK);

  RESET <= (not LOCKED_CLK) or I_BTN(0);

  -- MIG temperature compensation requires a live XADC value.  Keeping this
  -- identical to the production Arty S7 design also preserves the CDC timing
  -- constraints inside sramif_mig_artys7.
  SYSMON: sysmonx_rbus_base
    generic map (CLK_MHZ => 75, RB_ADDR => x"fb00")
    port map (
      CLK => CLK, RESET => RESET,
      RB_MREQ => rb_mreq_init, RB_SRES => RB_SRES_SYSMON,
      ALM => open, OT => open, TEMP => XADC_TEMP);

  CACHE: pdp11_cache
    generic map (TWIDTH => 7)
    port map (
      CLK => CLK, GRESET => RESET,
      EM_MREQ => EM_MREQ, EM_SRES => EM_SRES, FMISS => '0',
      MEM_REQ => CPU_REQ, MEM_WE => CPU_WE,
      MEM_BUSY => CPU_BUSY, MEM_ACK_R => CPU_ACK_R,
      MEM_ADDR => CPU_ADDR, MEM_BE => CPU_BE, MEM_DI => CPU_DI, MEM_DO => CPU_DO,
      INV_REQ => INV_REQ, INV_ADDR => INV_ADDR, INV_ACK => INV_ACK,
      DM_STAT_CA => DM_STAT_CA);

  ARBITER: entity work.w11_mem_arbiter
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

  MEMCTL: sramif_mig_artys7
    port map (
      CLK => CLK, RESET => RESET,
      REQ => MEM_REQ, WE => MEM_WE, BUSY => MEM_BUSY,
      ACK_R => MEM_ACK_R, ACK_W => MEM_ACK_W,
      ACT_R => MEM_ACT_R, ACT_W => MEM_ACT_W,
      ADDR => MEM_ADDR, BE => MEM_BE, DI => MEM_DI, DO => MEM_DO,
      CLKMIG => CLKMIG, CLKREF => CLKREF, TEMP => XADC_TEMP,
      MONI => MIG_MONI,
      DDR3_DQ => DDR3_DQ, DDR3_DQS_P => DDR3_DQS_P, DDR3_DQS_N => DDR3_DQS_N,
      DDR3_ADDR => DDR3_ADDR, DDR3_BA => DDR3_BA,
      DDR3_RAS_N => DDR3_RAS_N, DDR3_CAS_N => DDR3_CAS_N,
      DDR3_WE_N => DDR3_WE_N, DDR3_RESET_N => DDR3_RESET_N,
      DDR3_CK_P => DDR3_CK_P, DDR3_CK_N => DDR3_CK_N,
      DDR3_CKE => DDR3_CKE, DDR3_CS_N => DDR3_CS_N,
      DDR3_DM => DDR3_DM, DDR3_ODT => DDR3_ODT);

  proc_state: process (CLK)
  begin
    if rising_edge(CLK) then
      if RESET = '1' then
        STATE <= s_wait_mig;
        TIMEOUT <= (others => '0');
      else
        if STATE /= s_pass and STATE /= s_fail then
          TIMEOUT <= TIMEOUT + 1;
          if TIMEOUT = (TIMEOUT'range => '1') then
            STATE <= s_fail;
          else
            case STATE is
              when s_wait_mig =>
                if MEM_BUSY = '0' then STATE <= s_old_write_req; end if;
              when s_old_write_req =>
                if DMA_BUSY = '0' then STATE <= s_old_write_wait; end if;
              when s_old_write_wait =>
                if DMA_ACK_W = '1' then STATE <= s_old_read_lo; end if;
              when s_old_read_lo =>
                if EM_SRES.ack_r = '1' then
                  if EM_SRES.dout = DATA_OLD(15 downto 0) then
                    STATE <= s_old_read_hi;
                  else
                    STATE <= s_fail;
                  end if;
                end if;
              when s_old_read_hi =>
                if EM_SRES.ack_r = '1' then
                  if EM_SRES.dout = DATA_OLD(31 downto 16) then
                    STATE <= s_new_write_req;
                  else
                    STATE <= s_fail;
                  end if;
                end if;
              when s_new_write_req =>
                if DMA_BUSY = '0' then STATE <= s_new_write_wait; end if;
              when s_new_write_wait =>
                if DMA_ACK_W = '1' then STATE <= s_new_read_lo; end if;
              when s_new_read_lo =>
                if EM_SRES.ack_r = '1' then
                  if EM_SRES.dout = DATA_NEW(15 downto 0) then
                    STATE <= s_new_read_hi;
                  else
                    STATE <= s_fail;
                  end if;
                end if;
              when s_new_read_hi =>
                if EM_SRES.ack_r = '1' then
                  if EM_SRES.dout = DATA_NEW(31 downto 16) then
                    STATE <= s_dma_read_req;
                  else
                    STATE <= s_fail;
                  end if;
                end if;
              when s_dma_read_req =>
                if DMA_BUSY = '0' then STATE <= s_dma_read_wait; end if;
              when s_dma_read_wait =>
                if DMA_ACK_R = '1' then
                  if DMA_DO = DATA_NEW then
                    STATE <= s_part_write_req;
                  else
                    STATE <= s_fail;
                  end if;
                end if;
              when s_part_write_req =>
                if DMA_BUSY = '0' then STATE <= s_part_write_wait; end if;
              when s_part_write_wait =>
                if DMA_ACK_W = '1' then STATE <= s_part_read_lo; end if;
              when s_part_read_lo =>
                if EM_SRES.ack_r = '1' then
                  if EM_SRES.dout = DATA_PART(15 downto 0) then
                    STATE <= s_part_read_hi;
                  else
                    STATE <= s_fail;
                  end if;
                end if;
              when s_part_read_hi =>
                if EM_SRES.ack_r = '1' then
                  if EM_SRES.dout = DATA_PART(31 downto 16) then
                    STATE <= s_part_dma_read_req;
                  else
                    STATE <= s_fail;
                  end if;
                end if;
              when s_part_dma_read_req =>
                if DMA_BUSY = '0' then STATE <= s_part_dma_read_wait; end if;
              when s_part_dma_read_wait =>
                if DMA_ACK_R = '1' then
                  if DMA_DO = DATA_PART then
                    STATE <= s_pass;
                  else
                    STATE <= s_fail;
                  end if;
                end if;
              when others => null;
            end case;
          end if;
        end if;
      end if;
    end if;
  end process proc_state;

  proc_drive: process (STATE)
  begin
    EM_MREQ <= em_mreq_init;
    DMA_REQ <= '0';
    DMA_WE <= '1';
    DMA_ADDR <= TEST_ADDR;
    DMA_BE <= "1111";
    DMA_DI <= DATA_OLD;

    case STATE is
      when s_old_write_req =>
        DMA_REQ <= '1';
      when s_old_read_lo =>
        EM_MREQ.req <= '1';
        EM_MREQ.be <= "11";
        EM_MREQ.addr <= TEST_ADDR & '0';
      when s_old_read_hi =>
        EM_MREQ.req <= '1';
        EM_MREQ.be <= "11";
        EM_MREQ.addr <= TEST_ADDR & '1';
      when s_new_write_req =>
        DMA_REQ <= '1';
        DMA_DI <= DATA_NEW;
      when s_new_read_lo =>
        EM_MREQ.req <= '1';
        EM_MREQ.be <= "11";
        EM_MREQ.addr <= TEST_ADDR & '0';
      when s_new_read_hi =>
        EM_MREQ.req <= '1';
        EM_MREQ.be <= "11";
        EM_MREQ.addr <= TEST_ADDR & '1';
      when s_dma_read_req =>
        DMA_REQ <= '1';
        DMA_WE <= '0';
      when s_part_write_req =>
        DMA_REQ <= '1';
        DMA_BE <= "0101";
        DMA_DI <= x"00e1007e";
      when s_part_read_lo =>
        EM_MREQ.req <= '1';
        EM_MREQ.be <= "11";
        EM_MREQ.addr <= TEST_ADDR & '0';
      when s_part_read_hi =>
        EM_MREQ.req <= '1';
        EM_MREQ.be <= "11";
        EM_MREQ.addr <= TEST_ADDR & '1';
      when s_part_dma_read_req =>
        DMA_REQ <= '1';
        DMA_WE <= '0';
      when others => null;
    end case;
  end process proc_drive;

  -- Repeated 115200 8N1 status: W while waiting/running, P on pass, F on
  -- failure.  The board USB UART exposes this on the FT2232 serial port.
  proc_uart: process (CLK)
  begin
    if rising_edge(CLK) then
      if RESET = '1' then
        TXD <= '1';
        TX_BUSY <= '0';
        TX_BIT <= 0;
        TX_BAUD <= 0;
        TX_PAUSE <= (others => '0');
      elsif TX_BUSY = '0' then
        TX_PAUSE <= TX_PAUSE + 1;
        if TX_PAUSE = 0 then
          if STATE = s_pass then
            TX_DATA <= x"50"; -- P
          elsif STATE = s_fail then
            TX_DATA <= x"46"; -- F
          else
            TX_DATA <= x"57"; -- W
          end if;
          TX_BUSY <= '1';
          TX_BIT <= 0;
          TX_BAUD <= 650;
          TXD <= '0';
        end if;
      elsif TX_BAUD /= 0 then
        TX_BAUD <= TX_BAUD - 1;
      else
        TX_BAUD <= 650;
        if TX_BIT = 9 then
          TX_BUSY <= '0';
          TXD <= '1';
        else
          TX_BIT <= TX_BIT + 1;
          if TX_BIT = 8 then
            TXD <= '1';
          else
            TXD <= TX_DATA(TX_BIT);
          end if;
        end if;
      end if;
    end if;
  end process proc_uart;

  O_TXD <= TXD;
  O_LED(0) <= LOCKED_CLK;
  O_LED(1) <= '1' when STATE /= s_wait_mig and STATE /= s_pass and STATE /= s_fail else '0';
  O_LED(2) <= '1' when STATE = s_pass else '0';
  O_LED(3) <= '1' when STATE = s_fail else '0';
  O_RGBLED0 <= "000";
  O_RGBLED1 <= "000";
end syn;
