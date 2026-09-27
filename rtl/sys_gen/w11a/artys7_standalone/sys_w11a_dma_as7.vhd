-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Arty S7 w11a with the native DMA memory path.  Derived from sys_w11a_as7
-- (which stays unchanged): pdp11_sys70 is replaced by w11_cpu_dma_path, the
-- MIG interface write acknowledge and MEM_RESET are connected, and the DMA
-- port is driven by the w11_dma_pingpong exerciser (rbus 0xfd00) for the
-- hardware coherence test with tcode/dma_pingpong.mac.  sdspi_rbus (rbus
-- 0xfd10) gives read-only test access to the Pmod MicroSD card in JD and
-- reads blocks into memory by DMA; dma_mux2 shares the DMA port.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;
use work.xlib.all;
use work.cdclib.all;
use work.serportlib.all;
use work.rblib.all;
use work.rbdlib.all;
use work.rlinklib.all;
use work.bpgenlib.all;
use work.sysmonrbuslib.all;
use work.miglib.all;
use work.miglib_artys7.all;
use work.iblib.all;
use work.ibdlib.all;
use work.pdp11.all;
use work.sys_conf.all;

-- ----------------------------------------------------------------------------

entity sys_w11a_dma_as7 is                  -- top level
                                        -- implements artys7_dram_aif
  port (
    I_CLK100 : in slbit;                -- 100 MHz clock
    I_RXD : in slbit;                   -- receive data (board view)
    O_TXD : out slbit;                  -- transmit data (board view)
    I_SWI : in slv4;                    -- artys7 switches
    I_BTN : in slv4;                    -- artys7 buttons
    O_LED : out slv4;                   -- artys7 leds
    O_RGBLED0 : out slv3;               -- artys7 rgb-led 0
    O_RGBLED1 : out slv3;               -- artys7 rgb-led 1
    O_SD_CS_N : out slbit;              -- pmod microsd (JD): chip select
    O_SD_SCLK : out slbit;              -- pmod microsd (JD): spi clock
    O_SD_MOSI : out slbit;              -- pmod microsd (JD): cmd
    I_SD_MISO : in slbit;               -- pmod microsd (JD): dat0
    I_SD_CD : in slbit;                 -- pmod microsd (JD): card detect
    DDR3_DQ      : inout slv16;         -- dram: data in/out
    DDR3_DQS_P   : inout slv2;          -- dram: data strobe (diff-p)
    DDR3_DQS_N   : inout slv2;          -- dram: data strobe (diff-n)
    DDR3_ADDR    : out   slv14;         -- dram: address
    DDR3_BA      : out   slv3;          -- dram: bank address
    DDR3_RAS_N   : out   slbit;         -- dram: row addr strobe    (act.low)
    DDR3_CAS_N   : out   slbit;         -- dram: column addr strobe (act.low)
    DDR3_WE_N    : out   slbit;         -- dram: write enable       (act.low)
    DDR3_RESET_N : out   slbit;         -- dram: reset              (act.low)
    DDR3_CK_P    : out   slv1;          -- dram: clock (diff-p)
    DDR3_CK_N    : out   slv1;          -- dram: clock (diff-n)
    DDR3_CKE     : out   slv1;          -- dram: clock enable
    DDR3_CS_N    : out   slv1;          -- dram: chip select        (act.low)
    DDR3_DM      : out   slv2;          -- dram: data input mask
    DDR3_ODT     : out   slv1           -- dram: on-die termination
  );
end sys_w11a_dma_as7;

architecture syn of sys_w11a_dma_as7 is

  signal CLK100_BUF :   slbit := '0';

  signal CLK :   slbit := '0';

  signal RESET   : slbit := '0';
  signal CE_USEC : slbit := '0';
  signal CE_MSEC : slbit := '0';

  signal CLKS :  slbit := '0';
  signal CES_MSEC : slbit := '0';

  signal CLKMIG : slbit := '0';
  signal CLKREF : slbit := '0';

  signal LOCKED     : slbit := '0';   -- raw LOCKED
  signal LOCKED_CLK : slbit := '0';   -- sync'ed to CLK

  signal GBL_RESET : slbit := '0';

  signal RXD :   slbit := '1';
  signal TXD :   slbit := '0';

  signal RB_MREQ        : rb_mreq_type := rb_mreq_init;
  signal RB_SRES        : rb_sres_type := rb_sres_init;
  signal RB_SRES_CPU    : rb_sres_type := rb_sres_init;
  signal RB_SRES_SYSMON : rb_sres_type := rb_sres_init;
  signal RB_SRES_USRACC : rb_sres_type := rb_sres_init;
  signal RB_SRES_PP     : rb_sres_type := rb_sres_init;
  signal RB_SRES_SD     : rb_sres_type := rb_sres_init;

  signal RB_LAM  : slv16 := (others=>'0');
  signal RB_STAT : slv4  := (others=>'0');

  signal SER_MONI : serport_moni_type := serport_moni_init;

  signal GRESET  : slbit := '0';        -- general reset (from rbus)
  signal CRESET  : slbit := '0';        -- cpu reset     (from cp)
  signal BRESET  : slbit := '0';        -- bus reset     (from cp or cpu)
  signal PERFEXT : slv8  := (others=>'0');

  signal EI_PRI  : slv3   := (others=>'0');
  signal EI_VECT : slv9_2 := (others=>'0');
  signal EI_ACKM : slbit  := '0';
  signal CP_STAT : cp_stat_type := cp_stat_init;
  signal DM_STAT_EXP : dm_stat_exp_type := dm_stat_exp_init;

  signal MEM_REQ   : slbit := '0';
  signal MEM_WE    : slbit := '0';
  signal MEM_BUSY  : slbit := '0';
  signal MEM_ACK_R : slbit := '0';
  signal MEM_ACK_W : slbit := '0';
  signal MEM_RESET : slbit := '0';

  signal DMA_REQ   : slbit := '0';
  signal DMA_WE    : slbit := '0';
  signal DMA_BUSY  : slbit := '0';
  signal DMA_ACK_R : slbit := '0';
  signal DMA_ACK_W : slbit := '0';
  signal DMA_ADDR  : slv20 := (others=>'0');
  signal DMA_BE    : slv4  := (others=>'0');
  signal DMA_DI    : slv32 := (others=>'0');
  signal DMA_DO    : slv32 := (others=>'0');

  signal PP_REQ    : slbit := '0';       -- ping-pong exerciser DMA
  signal PP_WE     : slbit := '0';
  signal PP_BUSY   : slbit := '0';
  signal PP_ACK_R  : slbit := '0';
  signal PP_ACK_W  : slbit := '0';
  signal PP_ADDR   : slv20 := (others=>'0');
  signal PP_BE     : slv4  := (others=>'0');
  signal PP_DI     : slv32 := (others=>'0');
  signal SD_REQ    : slbit := '0';       -- SD block reader DMA
  signal SD_WE     : slbit := '0';
  signal SD_BUSY   : slbit := '0';
  signal SD_ACK_W  : slbit := '0';
  signal SD_ADDR   : slv20 := (others=>'0');
  signal SD_BE     : slv4  := (others=>'0');
  signal SD_DI     : slv32 := (others=>'0');
  signal MEM_ACT_R : slbit := '0';
  signal MEM_ACT_W : slbit := '0';
  signal MEM_ADDR  : slv20 := (others=>'0');
  signal MEM_BE    : slv4  := (others=>'0');
  signal MEM_DI    : slv32 := (others=>'0');
  signal MEM_DO    : slv32 := (others=>'0');

  signal MIG_MONI  : sramif2migui_moni_type := sramif2migui_moni_init;

  signal XADC_TEMP : slv12 := (others=>'0'); -- xadc die temp; on CLK

  signal IB_MREQ : ib_mreq_type := ib_mreq_init;
  signal IB_SRES_IBDR  : ib_sres_type := ib_sres_init;

  signal DISPREG  : slv16 := (others=>'0');
  signal ABCLKDIV : slv16 := (others=>'0');
  signal IOLEDS   : slv4  := (others=>'0');

  signal SWI     : slv4 := (others=>'0');
  signal BTN     : slv4 := (others=>'0');
  signal LED     : slv4 := (others=>'0');
  signal RGB_R   : slv2 := (others=>'0');
  signal RGB_G   : slv2 := (others=>'0');
  signal RGB_B   : slv2 := (others=>'0');

  constant rbaddr_rbmon : slv16 := x"ffe8"; -- ffe8/0008: 1111 1111 1110 1xxx
  constant rbaddr_sysmon: slv16 := x"fb00"; -- fb00/0080: 1111 1011 0xxx xxxx
  constant rbaddr_dmapp : slv16 := x"fd00"; -- fd00/0010: 1111 1101 0000 xxxx
  constant rbaddr_sdspi : slv16 := x"fd10"; -- fd10/0010: 1111 1101 0001 xxxx

  constant sysid_proj  : slv16 := x"0201";   -- w11a
  constant sysid_board : slv8  := x"0a";     -- artys7
  constant sysid_vers  : slv8  := x"00";

begin

  assert (sys_conf_clksys mod 1000000) = 0
    report "assert sys_conf_clksys on MHz grid"
    severity failure;

  CLK100_BUFG: bufg_unisim
    port map (
      I => I_CLK100,
      O => CLK100_BUF
    );

  GEN_CLKALL : s7_cmt_1ce1ce2c          -- clock generator system ------------
    generic map (
      CLKIN_PERIOD   => 10.0,
      CLKIN_JITTER   => 0.01,
      STARTUP_WAIT   => false,
      CLK0_VCODIV    => sys_conf_clksys_vcodivide,
      CLK0_VCOMUL    => sys_conf_clksys_vcomultiply,
      CLK0_OUTDIV    => sys_conf_clksys_outdivide,
      CLK0_GENTYPE   => sys_conf_clksys_gentype,
      CLK0_CDUWIDTH  => 7,
      CLK0_USECDIV   => sys_conf_clksys_mhz,
      CLK0_MSECDIV   => 1000,
      CLK1_VCODIV    => sys_conf_clkser_vcodivide,
      CLK1_VCOMUL    => sys_conf_clkser_vcomultiply,
      CLK1_OUTDIV    => sys_conf_clkser_outdivide,
      CLK1_GENTYPE   => sys_conf_clkser_gentype,
      CLK1_CDUWIDTH  => 7,
      CLK1_USECDIV   => sys_conf_clkser_mhz,
      CLK1_MSECDIV   => 1000,
      CLK23_VCODIV   =>  1,
      CLK23_VCOMUL   => 16,             -- vco 1600 MHz
      CLK2_OUTDIV    => 10,             -- mig sys 160.0 MHz
      CLK3_OUTDIV    =>  8,             -- mig ref 200.0 MHz
      CLK23_GENTYPE  => "PLL")
    port map (
      CLKIN     => CLK100_BUF,
      CLK0      => CLK,
      CE0_USEC  => CE_USEC,
      CE0_MSEC  => CE_MSEC,
      CLK1      => CLKS,
      CE1_USEC  => open,
      CE1_MSEC  => CES_MSEC,
      CLK2      => CLKMIG,
      CLK3      => CLKREF,
      LOCKED    => LOCKED
    );

  CDC_CLK_LOCKED : cdc_signal_s1_as
    port map (
      CLKO  => CLK,
      DI    => LOCKED,
      DO    => LOCKED_CLK
    );

  GBL_RESET <= not LOCKED_CLK;

  IOB_RS232 : bp_rs232_2line_iob         -- serport iob ----------------------
    port map (
      CLK      => CLKS,
      RXD      => RXD,
      TXD      => TXD,
      I_RXD    => I_RXD,
      O_TXD    => O_TXD
    );

  RLINK : rlink_sp2c                    -- rlink for serport -----------------
    generic map (
      BTOWIDTH     => 9,                -- 512 cycles, for slow mem iface
      RTAWIDTH     => 12,
      SYSID        => sysid_proj & sysid_board & sysid_vers,
      IFAWIDTH     => 5,                --  32 word input fifo
      OFAWIDTH     => 5,                --  32 word output fifo
      ENAPIN_RLMON => sbcntl_sbf_rlmon,
      ENAPIN_RBMON => sbcntl_sbf_rbmon,
      CDWIDTH      => 12,
      CDINIT       => sys_conf_ser2rri_cdinit,
      RBMON_AWIDTH => sys_conf_rbmon_awidth,
      RBMON_RBADDR => rbaddr_rbmon)
    port map (
      CLK      => CLK,
      CE_USEC  => CE_USEC,
      CE_MSEC  => CE_MSEC,
      CE_INT   => CE_MSEC,
      RESET    => RESET,
      CLKS     => CLKS,
      CES_MSEC => CES_MSEC,
      ENAXON   => '1',                  -- XON statically enabled !
      ESCFILL  => '0',
      RXSD     => RXD,
      TXSD     => TXD,
      CTS_N    => '0',
      RTS_N    => open,
      RB_MREQ  => RB_MREQ,
      RB_SRES  => RB_SRES,
      RB_LAM   => RB_LAM,
      RB_STAT  => RB_STAT,
      RL_MONI  => open,
      SER_MONI => SER_MONI
    );

  PERFEXT(0) <= MIG_MONI.rdrhit;        -- ext_rdrhit
  PERFEXT(1) <= MIG_MONI.wrrhit;        -- ext_wrrhit
  PERFEXT(2) <= MIG_MONI.wrflush;       -- ext_wrflush
  PERFEXT(3) <= SER_MONI.rxact;         -- ext_rlrxact
  PERFEXT(4) <= not SER_MONI.rxok;      -- ext_rlrxback
  PERFEXT(5) <= SER_MONI.txact;         -- ext_rltxact
  PERFEXT(6) <= not SER_MONI.txok;      -- ext_rltxback
  PERFEXT(7) <= CE_USEC;                -- ext_usec

  SYS70 : entity work.w11_cpu_dma_path -- 1 cpu system with DMA port --------
    port map (
      CLK         => CLK,
      RESET       => GBL_RESET,         -- memory side: as MEMCTL before
      RB_MREQ     => RB_MREQ,
      RB_SRES     => RB_SRES_CPU,
      RB_STAT     => RB_STAT,
      RB_LAM_CPU  => RB_LAM(0),
      GRESET      => GRESET,
      CRESET      => CRESET,
      BRESET      => BRESET,
      CP_STAT     => CP_STAT,
      EI_PRI      => EI_PRI,
      EI_VECT     => EI_VECT,
      EI_ACKM     => EI_ACKM,
      PERFEXT     => PERFEXT,
      IB_MREQ     => IB_MREQ,
      IB_SRES     => IB_SRES_IBDR,
      DM_STAT_EXP => DM_STAT_EXP,
      DMA_REQ     => DMA_REQ,
      DMA_WE      => DMA_WE,
      DMA_BUSY    => DMA_BUSY,
      DMA_ACK_R   => DMA_ACK_R,
      DMA_ACK_W   => DMA_ACK_W,
      DMA_ADDR    => DMA_ADDR,
      DMA_BE      => DMA_BE,
      DMA_DI      => DMA_DI,
      DMA_DO      => DMA_DO,
      MEM_RESET   => MEM_RESET,
      MEM_REQ     => MEM_REQ,
      MEM_WE      => MEM_WE,
      MEM_BUSY    => MEM_BUSY,
      MEM_ACK_R   => MEM_ACK_R,
      MEM_ACK_W   => MEM_ACK_W,
      MEM_ADDR    => MEM_ADDR,
      MEM_BE      => MEM_BE,
      MEM_DI      => MEM_DI,
      MEM_DO      => MEM_DO
    );

  DMAPP : entity work.w11_dma_pingpong  -- DMA coherence exerciser ----------
    generic map (
      RB_ADDR     => rbaddr_dmapp)
    port map (
      CLK         => CLK,
      RESET       => GBL_RESET,
      RB_MREQ     => RB_MREQ,
      RB_SRES     => RB_SRES_PP,
      DMA_REQ     => PP_REQ,
      DMA_WE      => PP_WE,
      DMA_BUSY    => PP_BUSY,
      DMA_ACK_R   => PP_ACK_R,
      DMA_ACK_W   => PP_ACK_W,
      DMA_ADDR    => PP_ADDR,
      DMA_BE      => PP_BE,
      DMA_DI      => PP_DI,
      DMA_DO      => DMA_DO
    );

  DMAMUX : entity work.dma_mux2         -- ping-pong and SD share the port --
    port map (
      CLK         => CLK,
      RESET       => GBL_RESET,
      A_REQ       => PP_REQ,
      A_WE        => PP_WE,
      A_BUSY      => PP_BUSY,
      A_ACK_R     => PP_ACK_R,
      A_ACK_W     => PP_ACK_W,
      A_ADDR      => PP_ADDR,
      A_BE        => PP_BE,
      A_DI        => PP_DI,
      B_REQ       => SD_REQ,
      B_WE        => SD_WE,
      B_BUSY      => SD_BUSY,
      B_ACK_R     => open,
      B_ACK_W     => SD_ACK_W,
      B_ADDR      => SD_ADDR,
      B_BE        => SD_BE,
      B_DI        => SD_DI,
      DMA_REQ     => DMA_REQ,
      DMA_WE      => DMA_WE,
      DMA_BUSY    => DMA_BUSY,
      DMA_ACK_R   => DMA_ACK_R,
      DMA_ACK_W   => DMA_ACK_W,
      DMA_ADDR    => DMA_ADDR,
      DMA_BE      => DMA_BE,
      DMA_DI      => DMA_DI
    );

  SDSPI : entity work.sdspi_rbus         -- read-only SD card test access --
    generic map (
      RB_ADDR     => rbaddr_sdspi)
    port map (
      CLK         => CLK,
      RESET       => GBL_RESET,
      CE_MSEC     => CE_MSEC,
      RB_MREQ     => RB_MREQ,
      RB_SRES     => RB_SRES_SD,
      O_SD_CS_N   => O_SD_CS_N,
      O_SD_SCLK   => O_SD_SCLK,
      O_SD_MOSI   => O_SD_MOSI,
      I_SD_MISO   => I_SD_MISO,
      I_SD_CD     => I_SD_CD,
      DMA_REQ     => SD_REQ,
      DMA_WE      => SD_WE,
      DMA_BUSY    => SD_BUSY,
      DMA_ACK_W   => SD_ACK_W,
      DMA_ADDR    => SD_ADDR,
      DMA_BE      => SD_BE,
      DMA_DI      => SD_DI
    );

  IBDR_SYS : ibdr_maxisys               -- IO system -------------------------
    port map (
      CLK      => CLK,
      CE_USEC  => CE_USEC,
      CE_MSEC  => CE_MSEC,
      RESET    => GRESET,
      BRESET   => BRESET,
      ITIMER   => DM_STAT_EXP.se_itimer,
      IDEC     => DM_STAT_EXP.se_idec,
      CPUSUSP  => CP_STAT.cpususp,
      RB_LAM   => RB_LAM(15 downto 1),
      IB_MREQ  => IB_MREQ,
      IB_SRES  => IB_SRES_IBDR,
      EI_ACKM  => EI_ACKM,
      EI_PRI   => EI_PRI,
      EI_VECT  => EI_VECT,
      DISPREG  => DISPREG
    );

  MEMCTL: sramif_mig_artys7             -- SRAM to MIG iface -----------------
    port map (
      CLK          => CLK,
      RESET        => MEM_RESET,
      REQ          => MEM_REQ,
      WE           => MEM_WE,
      BUSY         => MEM_BUSY,
      ACK_R        => MEM_ACK_R,
      ACK_W        => MEM_ACK_W,
      ACT_R        => MEM_ACT_R,
      ACT_W        => MEM_ACT_W,
      ADDR         => MEM_ADDR,
      BE           => MEM_BE,
      DI           => MEM_DI,
      DO           => MEM_DO,
      CLKMIG       => CLKMIG,
      CLKREF       => CLKREF,
      TEMP         => XADC_TEMP,
      MONI         => MIG_MONI,
      DDR3_DQ      => DDR3_DQ,
      DDR3_DQS_P   => DDR3_DQS_P,
      DDR3_DQS_N   => DDR3_DQS_N,
      DDR3_ADDR    => DDR3_ADDR,
      DDR3_BA      => DDR3_BA,
      DDR3_RAS_N   => DDR3_RAS_N,
      DDR3_CAS_N   => DDR3_CAS_N,
      DDR3_WE_N    => DDR3_WE_N,
      DDR3_RESET_N => DDR3_RESET_N,
      DDR3_CK_P    => DDR3_CK_P,
      DDR3_CK_N    => DDR3_CK_N,
      DDR3_CKE     => DDR3_CKE,
      DDR3_CS_N    => DDR3_CS_N,
      DDR3_DM      => DDR3_DM,
      DDR3_ODT     => DDR3_ODT
    );

  LED_IO : ioleds_sp1c                  -- hio leds from serport -------------
    port map (
      SER_MONI => SER_MONI,
      IOLEDS   => IOLEDS
    );

  ABCLKDIV <= SER_MONI.abclkdiv(11 downto 0) & '0' & SER_MONI.abclkdiv_f;

  HIO70 : entity work.pdp11_hio70_artys7 -- hio from sys70 --------------------
    port map (
      CLK         => CLK,
      MODE        => SWI,
      MEM_ACT_R   => MEM_ACT_R,
      MEM_ACT_W   => MEM_ACT_W,
      CP_STAT     => CP_STAT,
      DM_STAT_EXP => DM_STAT_EXP,
      DISPREG     => DISPREG,
      IOLEDS      => IOLEDS,
      ABCLKDIV    => ABCLKDIV,
      LED         => LED,
      RGB_R       => RGB_R,
      RGB_G       => RGB_G,
      RGB_B       => RGB_B
    );

  HIO : bp_swibtnled
    generic map (
      SWIDTH   => I_SWI'length,
      BWIDTH   => I_BTN'length,
      LWIDTH   => O_LED'length,
      DEBOUNCE => sys_conf_hio_debounce)
    port map (
      CLK     => CLK,
      RESET   => RESET,
      CE_MSEC => CE_MSEC,
      SWI     => SWI,
      BTN     => BTN,
      LED     => LED,
      I_SWI   => I_SWI,
      I_BTN   => I_BTN,
      O_LED   => O_LED
    );

  HIORGB : rgbdrv_3x2mux
    port map (
      CLK       => CLK,
      RESET     => RESET,
      CE_USEC   => CE_USEC,
      DATR      => RGB_R,
      DATG      => RGB_G,
      DATB      => RGB_B,
      O_RGBLED0 => O_RGBLED0,
      O_RGBLED1 => O_RGBLED1
    );

  SMRB : sysmonx_rbus_base            -- always instantiated, needed for mig
    generic map (                     -- use default INIT_ (Vccint=1.00)
      CLK_MHZ  => sys_conf_clksys_mhz,
      RB_ADDR  => rbaddr_sysmon)
    port map (
      CLK      => CLK,
      RESET    => RESET,
      RB_MREQ  => RB_MREQ,
      RB_SRES  => RB_SRES_SYSMON,
      ALM      => open,
      OT       => open,
      TEMP     => XADC_TEMP
    );

  UARB : rbd_usracc
    port map (
      CLK     => CLK,
      RB_MREQ => RB_MREQ,
      RB_SRES => RB_SRES_USRACC
    );

  RB_SRES_OR : rb_sres_or_6             -- rbus or ---------------------------
    port map (
      RB_SRES_1  => RB_SRES_CPU,
      RB_SRES_2  => RB_SRES_SYSMON,
      RB_SRES_3  => RB_SRES_USRACC,
      RB_SRES_4  => RB_SRES_PP,
      RB_SRES_5  => RB_SRES_SD,
      RB_SRES_OR => RB_SRES
    );

end syn;
