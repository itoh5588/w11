-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Native RH70 + RP07 disk controller (ibus, 176700, vector 254, BR5) that
-- reads a raw RP07 image from an SD card (block = LBA) and moves the data
-- into main memory by DMA; no backend and no rlink are involved.
--
-- The PDP-11 visible behavior follows ibdr_rhrp for one drive: unit 0 is an
-- RP07 (RM type controller, DT 020042, SN 1137), units 1-3 are absent (NED).
-- Registers, RMR protection, BRESET/CS2.CLR/DCLR/PRESET clearing, the RH70
-- interrupt rules and the LA sector counter are as in ibdr_rhrp.
--
-- Writing is enabled by WRITE_ENABLE only (default false: the drive reports
-- WRL and WRITE/WHD end with WLE).  With WRITE_ENABLE, WRITE fills a block
-- buffer from memory by DMA and writes it with CMD24, block by block; a
-- partial last block is filled with zeros.  WHD, WCD, WCHD and RHD end with
-- ILF.  READ converts
-- CHS to LBA = (C*32+T)*50+S, truncates at the end of the disk (AOE) and at
-- the end of memory (NEM), reads the blocks with CMD18 and writes the words
-- by DMA.  On completion WC, BA/BAE, DA and DC are updated like the backend
-- does.  An SD failure ends the transfer with ER1.UNS and ATA.
--
-- As on a real RH70, a transfer function that ends with a drive exception
-- (rejected at GO with WLE, IAE or UNS, or ended with AOE, UNS or ILF) sets
-- CS1.TRE.  The 2.11BSD xp driver looks at ER1 only when TRE is set;
-- without it a write-locked WRITE would count as done (ibdr_rhrp has the
-- same gap).  TRE is cleared by writing CS1 with TRE=1, by CS2.CLR, BRESET
-- and by the start of the next transfer.
--
-- MOL follows the card detect switch (0 = card present).  Removing the card
-- clears MOL and VV and forces a new SD initialization on the next READ.
-- BRESET or CS2.CLR during a transfer stops the SD read (CMD12) and the DMA.
-- Remote (rlink) accesses may read the registers without side effects;
-- remote writes are ignored, so a backend probing the RHRP cannot interfere.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;
use work.iblib.all;

entity ibdr_rp07n is
  generic (
    MEMLIMIT : natural := 16#3c0000#;   -- bytes of main memory (3840 kB)
    WRITE_ENABLE : boolean := false);   -- false: drive is write locked
  port (
    CLK : in slbit;
    RESET : in slbit;                   -- power-on reset
    CE_USEC : in slbit;
    CE_MSEC : in slbit;
    BRESET : in slbit;                  -- ibus reset
    ITIMER : in slbit;                  -- instruction timer
    IB_MREQ : in ib_mreq_type;
    IB_SRES : out ib_sres_type;
    EI_REQ : out slbit;
    EI_ACK : in slbit;
    O_SD_CS_N : out slbit;
    O_SD_SCLK : out slbit;
    O_SD_MOSI : out slbit;
    I_SD_MISO : in slbit;
    I_SD_CD : in slbit;                 -- card detect, 0 = card present
    DMA_REQ : out slbit;
    DMA_WE : out slbit;
    DMA_BUSY : in slbit;
    DMA_ACK_R : in slbit;
    DMA_ACK_W : in slbit;
    DMA_ADDR : out slv20;
    DMA_BE : out slv4;
    DMA_DI : out slv32;
    DMA_DO : in slv32;
    SDERR : out slv8;                   -- last SD error code (diagnostic)
    XCOUNT : out slv16                  -- completed transfers (diagnostic)
  );
end ibdr_rp07n;

architecture syn of ibdr_rp07n is

  constant ibaddr_rhrp : slv16 := slv(to_unsigned(8#176700#, 16));

  constant ibaddr_cs1 : slv5 := "00000";
  constant ibaddr_wc  : slv5 := "00001";
  constant ibaddr_ba  : slv5 := "00010";
  constant ibaddr_da  : slv5 := "00011";
  constant ibaddr_cs2 : slv5 := "00100";
  constant ibaddr_ds  : slv5 := "00101";
  constant ibaddr_er1 : slv5 := "00110";
  constant ibaddr_as  : slv5 := "00111";
  constant ibaddr_la  : slv5 := "01000";
  constant ibaddr_db  : slv5 := "01001";
  constant ibaddr_mr1 : slv5 := "01010";
  constant ibaddr_dt  : slv5 := "01011";
  constant ibaddr_sn  : slv5 := "01100";
  constant ibaddr_of  : slv5 := "01101";
  constant ibaddr_dc  : slv5 := "01110";
  constant ibaddr_m13 : slv5 := "01111";  -- RM: holding register
  constant ibaddr_m14 : slv5 := "10000";  -- RM: MR2
  constant ibaddr_m15 : slv5 := "10001";  -- RM: ER2 (0)
  constant ibaddr_ec1 : slv5 := "10010";
  constant ibaddr_ec2 : slv5 := "10011";
  constant ibaddr_bae : slv5 := "10100";
  constant ibaddr_cs3 : slv5 := "10101";

  constant func_noop  : slv5 := "00000";
  constant func_unl   : slv5 := "00001";
  constant func_seek  : slv5 := "00010";
  constant func_recal : slv5 := "00011";
  constant func_dclr  : slv5 := "00100";
  constant func_pore  : slv5 := "00101";
  constant func_offs  : slv5 := "00110";
  constant func_retc  : slv5 := "00111";
  constant func_pres  : slv5 := "01000";
  constant func_pack  : slv5 := "01001";
  constant func_sear  : slv5 := "01100";
  constant func_wcd   : slv5 := "10100";
  constant func_wchd  : slv5 := "10101";
  constant func_write : slv5 := "11000";
  constant func_whd   : slv5 := "11001";
  constant func_read  : slv5 := "11100";
  constant func_rhd   : slv5 := "11101";

  constant rp07_camax : natural := 630 - 1;
  constant rp07_tamax : natural := 32 - 1;
  constant rp07_samax : natural := 50 - 1;
  constant rp07_nblk  : natural := 630 * 32 * 50;   -- 1008000
  constant idly_seek  : natural := 10;              -- ITIMER ticks

  constant op_init : slv3 := "001";
  constant op_mread : slv3 := "101";
  constant op_write : slv3 := "110";

  type estate_type is (e_idle, e_init_go, e_init_arm, e_init_wait,
                       e_calc, e_calc_aoe, e_calc_nem, e_read_go,
                       e_read_arm, e_read_wait, e_drain, e_step, e_done,
                       e_errx, e_wblk, e_wfill, e_warm, e_wwait);

  type regs_type is record
    ibsel : slbit;
    -- controller
    bae : slv6;
    cs1rdy : slbit;
    cs1ie : slbit;
    cs1func : slv5;
    cs2wce : slbit;
    cs2ned : slbit;
    cs2nem : slbit;
    cs2pge : slbit;
    cs2mxf : slbit;
    cs2pat : slbit;
    cs2bai : slbit;
    cs2unit2 : slbit;
    cs2unit : slv2;
    cs3wco : slbit;
    wc : slv16;
    ba : slv16;
    db : slv16;
    ireq : slbit;
    exc : slbit;                        -- drive exception in a transfer
    -- drive 0
    da : slv16;
    mr1 : slv16;
    ofs : slv16;
    dc : slv16;
    hr : slv16;
    mr2 : slv16;
    ata : slbit;
    pip : slbit;
    vv : slbit;
    om : slbit;
    er1uns : slbit;
    er1wle : slbit;
    er1iae : slbit;
    er1aoe : slbit;
    er1rmr : slbit;
    er1ilf : slbit;
    idlycnt : unsigned(7 downto 0);
    uscnt : unsigned(6 downto 0);
    sc : unsigned(5 downto 0);
    mol : slbit;
    cd : slv2;                          -- card detect synchronizer
    -- transfer engine
    xreq : slbit;                       -- transfer requested by GO
    xfunc : slv5;
    est : estate_type;
    abort : slbit;
    sdready : slbit;
    lba : unsigned(19 downto 0);
    nwrd : unsigned(16 downto 0);
    ndone : unsigned(16 downto 0);
    addr : unsigned(21 downto 0);
    aoe : slbit;
    nem : slbit;
    sderr : slv8;
    cc : unsigned(9 downto 0);
    ct : unsigned(4 downto 0);
    cs : unsigned(5 downto 0);
    bcnt : unsigned(8 downto 0);
    xcount : unsigned(15 downto 0);
    wblk : unsigned(8 downto 0);        -- WRITE: blocks written
    wcnt : unsigned(8 downto 0);        -- WRITE: words in current block
  end record regs_type;

  constant regs_init : regs_type := (
    '0',
    (others => '0'), '1', '0', (others => '0'),
    '0', '0', '0', '0', '0', '0', '0', '0', (others => '0'), '0',
    (others => '0'), (others => '0'), (others => '0'), '0', '0',
    (others => '0'), (others => '0'), (others => '0'), (others => '0'),
    (others => '0'), (others => '0'),
    '0', '0', '0', '0',
    '0', '0', '0', '0', '0', '0',
    (others => '0'), (others => '0'), (others => '0'), '0', "11",
    '0', (others => '0'), e_idle, '0', '0',
    (others => '0'), (others => '0'), (others => '0'), (others => '0'),
    '0', '0', (others => '0'),
    (others => '0'), (others => '0'), (others => '0'), (others => '0'),
    (others => '0'), (others => '0'), (others => '0'));

  signal R_REGS : regs_type := regs_init;
  signal N_REGS : regs_type := regs_init;

  -- SD block layer
  signal SD_OP : slv3 := (others => '0');
  signal SD_GO : slbit := '0';
  signal SD_LBA : slv32 := (others => '0');
  signal SD_NBLK : slv16 := (others => '0');
  signal SD_HOLD : slbit := '0';
  signal SD_ABORT : slbit := '0';
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
  -- DMA writer
  signal WR_START : slbit := '0';
  signal WR_BASE : slv22 := (others => '0');
  signal WR_FLUSH : slbit := '0';
  signal WR_WE : slbit := '0';
  signal WR_HOLD : slbit := '0';
  signal WR_IDLE : slbit := '1';
  signal WR_DMA_REQ : slbit := '0';
  signal WR_DMA_WE : slbit := '0';
  signal WR_DMA_ADDR : slv20 := (others => '0');
  signal WR_DMA_BE : slv4 := (others => '0');
  signal WR_DMA_DI : slv32 := (others => '0');
  -- DMA reader (WRITE)
  signal RD_START : slbit := '0';
  signal RD_BASE : slv22 := (others => '0');
  signal RD_NWORD : slv9 := (others => '0');
  signal RD_DONE : slbit := '0';
  signal RD_DMA_REQ : slbit := '0';
  signal RD_DMA_ADDR : slv20 := (others => '0');
  signal SD_WBUF_ADDR : slv8 := (others => '0');
  signal SD_WBUF_DATA : slv16 := (others => '0');
  signal WMODE : slbit := '0';           -- DMA port used by the reader

begin

  CTL : entity work.sdspi_ctl
    port map (
      CLK => CLK, RESET => RESET, CE_MSEC => CE_MSEC,
      OP => SD_OP, GO => SD_GO, LBA => SD_LBA, NBLK => SD_NBLK,
      HOLD => SD_HOLD, ABORT => SD_ABORT, FASTDIV => x"02",
      BUSY => SD_BUSY, INITOK => SD_INITOK, V2 => open, HC => open,
      ERR => SD_ERR, R1 => open, TOKEN => open, RESP => open,
      BUF_WE => SD_WE, BUF_ADDR => SD_WADDR, BUF_DI => SD_WDATA,
      WBUF_ADDR => SD_WBUF_ADDR, WBUF_DATA => SD_WBUF_DATA,
      O_CS_N => O_SD_CS_N, PHY_DIV => PHY_DIV, PHY_START => PHY_START,
      PHY_TXD => PHY_TXD, PHY_RXD => PHY_RXD, PHY_DONE => PHY_DONE);

  PHY : entity work.sdspi_phy
    port map (
      CLK => CLK, RESET => RESET, DIV => PHY_DIV, START => PHY_START,
      TXD => PHY_TXD, RXD => PHY_RXD, DONE => PHY_DONE, BUSY => open,
      O_SCLK => O_SD_SCLK, O_MOSI => O_SD_MOSI, I_MISO => I_SD_MISO);

  WR : entity work.sd_dma_wr
    port map (
      CLK => CLK, RESET => RESET, START => WR_START,
      BASE => WR_BASE, FLUSH => WR_FLUSH, WE => WR_WE,
      DI => SD_WDATA, HOLD => WR_HOLD, IDLE => WR_IDLE, NWORD => open,
      DMA_REQ => WR_DMA_REQ, DMA_WE => WR_DMA_WE, DMA_BUSY => DMA_BUSY,
      DMA_ACK_W => DMA_ACK_W, DMA_ADDR => WR_DMA_ADDR, DMA_BE => WR_DMA_BE,
      DMA_DI => WR_DMA_DI);

  RD : entity work.sd_dma_rd
    port map (
      CLK => CLK, RESET => RESET, START => RD_START, BASE => RD_BASE,
      NWORD => RD_NWORD, DONE => RD_DONE, RADDR => SD_WBUF_ADDR,
      RDATA => SD_WBUF_DATA, DMA_REQ => RD_DMA_REQ, DMA_BUSY => DMA_BUSY,
      DMA_ACK_R => DMA_ACK_R, DMA_ADDR => RD_DMA_ADDR, DMA_DO => DMA_DO);

  -- one DMA port: the writer serves READ, the reader serves WRITE
  DMA_REQ <= RD_DMA_REQ when WMODE = '1' else WR_DMA_REQ;
  DMA_WE <= '0' when WMODE = '1' else WR_DMA_WE;
  DMA_ADDR <= RD_DMA_ADDR when WMODE = '1' else WR_DMA_ADDR;
  DMA_BE <= "1111" when WMODE = '1' else WR_DMA_BE;
  DMA_DI <= WR_DMA_DI;

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

  proc_next: process (R_REGS, CE_USEC, BRESET, ITIMER, IB_MREQ, EI_ACK,
                      I_SD_CD, SD_BUSY, SD_INITOK, SD_ERR, SD_WE, WR_HOLD,
                      WR_IDLE, RD_DONE)
    variable r : regs_type := regs_init;
    variable n : regs_type := regs_init;
    variable ibreq : slbit := '0';
    variable ibw0 : slbit := '0';
    variable ibw1 : slbit := '0';
    variable idout : slv16 := (others => '0');
    variable ireg : slv5 := (others => '0');
    variable ined : slbit := '0';       -- selected drive does not exist
    variable ibusy : slbit := '0';      -- drive 0 busy (rmr protection)
    variable imbreg : slbit := '0';     -- massbus (drive) register
    variable inormr : slbit := '0';     -- write allowed while busy
    variable iclrcntl : boolean := false;
    variable ibreset : boolean := false;
    variable ifunc : slv5 := (others => '0');
    variable iiae : slbit := '0';
    variable iwle : slbit := '0';
    variable itre : slbit := '0';
    variable isc : slbit := '0';
    variable ierp : slbit := '0';
    variable isdgo : slbit := '0';
    variable isdop : slv3 := (others => '0');
    variable iwrstart : slbit := '0';
    variable iwrflush : slbit := '0';
    variable iwrwe : slbit := '0';
    variable irdstart : slbit := '0';
    variable t1 : unsigned(14 downto 0);
    variable t2 : unsigned(19 downto 0);
    variable avail : unsigned(19 downto 0);
    variable nblkreq : unsigned(8 downto 0);
    variable maxw : unsigned(21 downto 0);
    variable eaddr : unsigned(21 downto 0);
  begin
    r := R_REGS;
    n := R_REGS;

    ibreq := IB_MREQ.re or IB_MREQ.we;
    ibw0 := IB_MREQ.we and IB_MREQ.be0;
    ibw1 := IB_MREQ.we and IB_MREQ.be1;
    idout := (others => '0');
    iclrcntl := false;
    ibreset := false;
    isdgo := '0';
    isdop := op_mread;
    iwrstart := '0';
    iwrflush := '0';
    iwrwe := '0';
    irdstart := '0';

    ined := r.cs2unit2 or r.cs2unit(1) or r.cs2unit(0);
    ibusy := r.pip or not r.cs1rdy;
    itre := r.cs2wce or r.cs2ned or r.cs2nem or r.cs2pge or r.cs2mxf or
            r.exc;
    isc := itre or r.ata;
    ierp := r.er1uns or r.er1wle or r.er1iae or r.er1aoe or r.er1rmr or
            r.er1ilf;

    -- card detect: MOL, loss of the card clears VV and the SD state
    n.cd := r.cd(0) & I_SD_CD;
    n.mol := not r.cd(1);
    if r.cd(1) = '1' then
      n.vv := '0';
      n.sdready := '0';
    end if;

    -- seek like functions complete after a short delay
    if r.idlycnt = 0 then
      if r.pip = '1' then
        n.ata := '1';
        n.pip := '0';
      end if;
    elsif ITIMER = '1' then
      n.idlycnt := r.idlycnt - 1;
    end if;

    -- LA: current sector, advances every 128 usec
    if CE_USEC = '1' then
      n.uscnt := r.uscnt + 1;
      if r.uscnt = 0 then
        if r.sc >= rp07_samax then
          n.sc := (others => '0');
        else
          n.sc := r.sc + 1;
        end if;
      end if;
    end if;

    -- ibus -----------------------------------------------------------------
    n.ibsel := '0';
    if IB_MREQ.aval = '1' and
       IB_MREQ.addr(12 downto 6) = ibaddr_rhrp(12 downto 6) and
       unsigned(IB_MREQ.addr(5 downto 1)) <= unsigned(ibaddr_cs3) then
      n.ibsel := '1';
    end if;
    ireg := IB_MREQ.addr(5 downto 1);

    imbreg := '0';
    inormr := '0';
    case ireg is
      when ibaddr_da | ibaddr_ds | ibaddr_er1 | ibaddr_la | ibaddr_mr1 |
           ibaddr_dt | ibaddr_sn | ibaddr_of | ibaddr_dc | ibaddr_m13 |
           ibaddr_m14 | ibaddr_m15 | ibaddr_ec1 | ibaddr_ec2 =>
        imbreg := '1';
      when ibaddr_as =>
        imbreg := '1';
        inormr := '1';
      when others => null;
    end case;
    if ireg = ibaddr_mr1 then
      inormr := '1';
    end if;

    if r.ibsel = '1' and IB_MREQ.re = '1' then      -- read
      if imbreg = '1' and ined = '1' then
        if IB_MREQ.racc = '0' then
          n.cs2ned := '1';
        end if;
      else
        case ireg is
          when ibaddr_cs1 =>
            idout(15) := isc;
            idout(14) := itre;
            idout(11) := '1';                       -- DVA
            idout(9 downto 8) := r.bae(1 downto 0);
            idout(7) := r.cs1rdy;
            idout(6) := r.cs1ie;
            idout(5 downto 1) := r.cs1func;
            if ined = '1' and IB_MREQ.racc = '0' then
              n.cs2ned := '1';
            end if;
          when ibaddr_wc => idout := r.wc;
          when ibaddr_ba => idout := r.ba;
          when ibaddr_da => idout := r.da;
          when ibaddr_cs2 =>
            idout(14) := r.cs2wce;
            idout(12) := r.cs2ned;
            idout(11) := r.cs2nem;
            idout(10) := r.cs2pge;
            idout(9) := r.cs2mxf;
            idout(7) := '1';                        -- OR
            idout(6) := '1';                        -- IR
            idout(4) := r.cs2pat;
            idout(3) := r.cs2bai;
            idout(2) := r.cs2unit2;
            idout(1 downto 0) := r.cs2unit;
          when ibaddr_ds =>
            idout(15) := r.ata;
            idout(14) := ierp;
            idout(13) := r.pip;
            idout(12) := r.mol;
            if not WRITE_ENABLE then
              idout(11) := '1';                     -- WRL: write locked
            end if;
            idout(8) := '1';                        -- DPR
            if r.mol = '1' and r.cs1rdy = '1' and r.pip = '0' then
              idout(7) := '1';                      -- DRY
            end if;
            idout(6) := r.vv;
            idout(0) := r.om;
          when ibaddr_er1 =>
            idout(14) := r.er1uns;
            idout(11) := r.er1wle;
            idout(10) := r.er1iae;
            idout(9) := r.er1aoe;
            idout(2) := r.er1rmr;
            idout(0) := r.er1ilf;
          when ibaddr_as => idout(0) := r.ata;
          when ibaddr_la => idout(11 downto 6) := slv(r.sc);
          when ibaddr_db => idout := r.db;
          when ibaddr_mr1 => idout := r.mr1;
          when ibaddr_dt => idout := slv(to_unsigned(8#020042#, 16));
          when ibaddr_sn => idout := x"1137";
          when ibaddr_of => idout := r.ofs;
          when ibaddr_dc => idout := r.dc;
          when ibaddr_m13 => idout := r.hr;
          when ibaddr_m14 => idout := r.mr2;
          when ibaddr_bae => idout(5 downto 0) := r.bae;
          when ibaddr_cs3 =>
            idout(12) := r.cs2wce and r.cs3wco;
            idout(11) := r.cs2wce and not r.cs3wco;
            idout(6) := r.cs1ie;
          when others => null;                      -- m15, ec1, ec2: 0
        end case;
      end if;
    end if;

    if r.ibsel = '1' and IB_MREQ.we = '1' and IB_MREQ.racc = '0' then
      if imbreg = '1' and ined = '1' then           -- absent drive
        n.cs2ned := '1';
        if ireg = ibaddr_as then
          n.ata := r.ata and not IB_MREQ.din(0);
        end if;
      elsif imbreg = '1' and inormr = '0' and ibusy = '1' then
        n.er1rmr := '1';                            -- busy drive: refused
      else
        if imbreg = '1' then
          n.hr := not IB_MREQ.din;                  -- RM holding register
        end if;
        case ireg is
          when ibaddr_cs1 =>
            if ibw1 = '1' then
              if IB_MREQ.din(14) = '1' then         -- TRE=1: clear errors
                n.exc := '0';
                n.cs2wce := '0';
                n.cs2ned := '0';
                n.cs2nem := '0';
                n.cs2pge := '0';
                n.cs2mxf := '0';
              end if;
              if r.cs1rdy = '1' then
                n.bae(1 downto 0) := IB_MREQ.din(9 downto 8);
              end if;
            end if;
            if ibw0 = '1' then
              n.cs1ie := IB_MREQ.din(6);
              if IB_MREQ.din(6) = '1' and IB_MREQ.din(7) = '1' then
                n.ireq := '1';                      -- software interrupt
              end if;
              n.cs1func := IB_MREQ.din(5 downto 1);
              if ined = '1' then
                n.cs2ned := '1';
              elsif IB_MREQ.din(0) = '1' then       -- GO
                ifunc := IB_MREQ.din(5 downto 1);
                if r.cs1rdy = '0' and unsigned(ifunc) >= unsigned(func_wcd)
                then
                  n.cs2pge := '1';
                elsif ifunc = func_dclr then
                  n.er1uns := '0';
                  n.er1wle := '0';
                  n.er1iae := '0';
                  n.er1aoe := '0';
                  n.er1rmr := '0';
                  n.er1ilf := '0';
                  n.mr1 := (others => '0');
                elsif ierp = '1' then
                  n.er1ilf := '1';
                else
                  n.ata := '0';
                  case ifunc is
                    when func_noop | func_pore =>
                      null;
                    when func_unl =>                -- not for RM type
                      n.er1ilf := '1';
                      n.ata := '1';
                    when func_offs | func_retc =>
                      n.ata := '1';
                      if r.mol = '0' then
                        n.er1uns := '1';
                      elsif ifunc = func_offs then
                        n.om := '1';
                      else
                        n.om := '0';
                      end if;
                    when func_pres =>
                      n.vv := '1';
                      n.da := (others => '0');
                      n.ofs := (others => '0');
                      n.dc := (others => '0');
                    when func_pack =>
                      n.vv := '1';
                    when func_seek | func_recal | func_sear |
                         func_wcd | func_wchd | func_write | func_whd |
                         func_read | func_rhd =>
                      iwle := '0';
                      if (ifunc = func_write or ifunc = func_whd) and
                         not WRITE_ENABLE then
                        iwle := '1';                -- drive is write locked
                        n.er1wle := '1';
                      end if;
                      iiae := '0';
                      if unsigned(r.dc(9 downto 0)) > rp07_camax or
                         unsigned(r.da(12 downto 8)) > rp07_tamax or
                         unsigned(r.da(5 downto 0)) > rp07_samax then
                        iiae := '1';
                        n.er1iae := '1';
                      end if;
                      if r.mol = '0' or iiae = '1' or iwle = '1' then
                        if r.mol = '0' then
                          n.er1uns := '1';
                        end if;
                        n.ata := '1';
                        if unsigned(ifunc) >= unsigned(func_wcd) then
                          n.exc := '1';             -- transfer rejected: TRE
                        end if;
                      elsif unsigned(ifunc) < unsigned(func_wcd) then
                        n.pip := '1';               -- seek like
                        n.idlycnt := to_unsigned(idly_seek, 8);
                      elsif r.cs2bai = '1' then
                        n.cs2pge := '1';            -- BAI not supported
                      else
                        n.xfunc := ifunc;           -- transfer
                        n.xreq := '1';
                        n.cs1rdy := '0';
                        n.exc := '0';
                        n.cs2wce := '0';
                        n.cs2ned := '0';
                        n.cs2nem := '0';
                        n.cs2pge := '0';
                        n.cs2mxf := '0';
                      end if;
                    when others =>
                      n.er1ilf := '1';
                      n.ata := '1';
                  end case;
                end if;
              end if;
            end if;

          when ibaddr_wc =>
            if ibw1 = '1' then n.wc(15 downto 8) := IB_MREQ.din(15 downto 8);
            end if;
            if ibw0 = '1' then n.wc(7 downto 0) := IB_MREQ.din(7 downto 0);
            end if;
          when ibaddr_ba =>
            if ibw1 = '1' then n.ba(15 downto 8) := IB_MREQ.din(15 downto 8);
            end if;
            if ibw0 = '1' then
              n.ba(7 downto 0) := IB_MREQ.din(7 downto 1) & '0';
            end if;
          when ibaddr_db =>
            if ibw1 = '1' then n.db(15 downto 8) := IB_MREQ.din(15 downto 8);
            end if;
            if ibw0 = '1' then n.db(7 downto 0) := IB_MREQ.din(7 downto 0);
            end if;
          when ibaddr_da =>
            n.da := IB_MREQ.din and "0001111100111111";
          when ibaddr_cs2 =>
            if ibw0 = '1' then
              n.cs2pat := IB_MREQ.din(4);
              n.cs2bai := IB_MREQ.din(3);
              n.cs2unit2 := IB_MREQ.din(2);
              n.cs2unit := IB_MREQ.din(1 downto 0);
              if IB_MREQ.din(5) = '1' then
                iclrcntl := true;                   -- CS2.CLR
              end if;
            end if;
          when ibaddr_as =>
            n.ata := r.ata and not IB_MREQ.din(0);
          when ibaddr_mr1 => n.mr1 := IB_MREQ.din;
          when ibaddr_of => n.ofs := IB_MREQ.din and "0001110011111111";
          when ibaddr_dc => n.dc := IB_MREQ.din and "0000001111111111";
          when ibaddr_m14 => n.mr2 := IB_MREQ.din;
          when ibaddr_bae =>
            if ibw0 = '1' then
              n.bae := IB_MREQ.din(5 downto 0);
            end if;
          when ibaddr_cs3 =>
            if ibw0 = '1' then
              n.cs1ie := IB_MREQ.din(6);
            end if;
          when others => null;                      -- read-only registers
        end case;
      end if;
    end if;

    if BRESET = '1' then
      ibreset := true;
      iclrcntl := true;
    end if;
    if iclrcntl then                                -- BRESET or CS2.CLR
      n.exc := '0';
      n.cs1rdy := '1';
      n.cs1ie := '0';
      n.cs2wce := '0';
      n.cs2ned := '0';
      n.cs2nem := '0';
      n.cs2pge := '0';
      n.cs2mxf := '0';
      n.cs2pat := '0';
      n.cs2bai := '0';
      n.cs2unit2 := '0';
      n.cs2unit := (others => '0');
      n.bae := (others => '0');
      n.ireq := '0';
      n.wc := (others => '0');
      n.ba := (others => '0');
      n.db := (others => '0');
      n.mr1 := (others => '0');
      n.xreq := '0';
      if r.est /= e_idle then
        n.abort := '1';                             -- stop a running read
      end if;
    end if;
    if ibreset then                                 -- BRESET: drive too
      n.er1uns := '0';
      n.er1wle := '0';
      n.er1iae := '0';
      n.er1aoe := '0';
      n.er1rmr := '0';
      n.er1ilf := '0';
      n.cs1func := (others => '0');
      n.da := (others => '0');
      n.ofs := (others => '0');
      n.dc := (others => '0');
      n.hr := (others => '0');
      n.mr2 := (others => '0');
    end if;

    -- transfer engine --------------------------------------------------------
    case r.est is
      when e_idle =>
        n.abort := '0';
        if r.xreq = '1' and not iclrcntl then
          n.xreq := '0';
          n.aoe := '0';
          n.nem := '0';
          n.sderr := (others => '0');
          n.ndone := (others => '0');
          n.cc := unsigned(r.dc(9 downto 0));   -- registers stay as they
          n.ct := unsigned(r.da(12 downto 8));  -- are if the SD fails
          n.cs := unsigned(r.da(5 downto 0));
          n.addr := unsigned(r.bae) & unsigned(r.ba);
          if r.xfunc /= func_read and
             not (r.xfunc = func_write and WRITE_ENABLE) then
            n.est := e_errx;                        -- WHD, WCD, WCHD, RHD
          elsif r.sdready = '0' then
            n.est := e_init_go;
          else
            n.est := e_calc;
          end if;
        end if;

      when e_init_go =>
        isdgo := '1';
        isdop := op_init;
        n.est := e_init_arm;

      when e_init_arm =>
        n.est := e_init_wait;

      when e_init_wait =>
        if SD_BUSY = '0' then
          if r.abort = '1' then
            n.est := e_idle;
          elsif SD_INITOK = '1' and SD_ERR = x"00" then
            n.sdready := '1';
            n.est := e_calc;
          else
            n.sderr := SD_ERR;
            n.est := e_done;
          end if;
        end if;

      when e_calc =>                    -- CHS -> LBA, words, address
        t1 := unsigned(r.dc(9 downto 0)) & unsigned(r.da(12 downto 8));
        t2 := shift_left(resize(t1, 20), 5) + shift_left(resize(t1, 20), 4) +
              shift_left(resize(t1, 20), 1);
        n.lba := t2 + unsigned(r.da(5 downto 0));
        if r.wc = x"0000" then
          n.nwrd := to_unsigned(65536, 17);
        else
          n.nwrd := resize(unsigned(not r.wc), 17) + 1;
        end if;
        n.addr := unsigned(r.bae) & unsigned(r.ba);
        n.cc := unsigned(r.dc(9 downto 0));
        n.ct := unsigned(r.da(12 downto 8));
        n.cs := unsigned(r.da(5 downto 0));
        if r.abort = '1' then
          n.est := e_idle;
        else
          n.est := e_calc_aoe;
        end if;

      when e_calc_aoe =>                -- end of disk
        avail := to_unsigned(rp07_nblk, 20) - r.lba;
        nblkreq := resize(shift_right(r.nwrd + 255, 8), 9);
        if resize(nblkreq, 20) > avail then
          n.nwrd := resize(shift_left(avail, 8), 17);
          n.aoe := '1';
        end if;
        n.est := e_calc_nem;

      when e_calc_nem =>                -- end of memory
        if r.addr >= MEMLIMIT then
          maxw := (others => '0');
        else
          maxw := shift_right(to_unsigned(MEMLIMIT, 22) - r.addr, 1);
        end if;
        if resize(r.nwrd, 22) > maxw then
          n.nwrd := resize(maxw, 17);
          n.nem := '1';
        end if;
        if r.abort = '1' then
          n.est := e_idle;
        elsif r.xfunc = func_write then
          n.wblk := (others => '0');
          n.est := e_wblk;
        else
          n.est := e_read_go;
        end if;

      when e_read_go =>
        if r.nwrd = 0 then
          n.est := e_step;
        else
          isdgo := '1';
          isdop := op_mread;
          iwrstart := '1';
          n.est := e_read_arm;
        end if;

      when e_read_arm =>
        n.est := e_read_wait;

      when e_read_wait =>
        if SD_BUSY = '0' then
          if SD_ERR /= x"00" and r.abort = '0' then
            n.sderr := SD_ERR;
          end if;
          iwrflush := '1';
          n.est := e_drain;
        end if;

      when e_drain =>
        if WR_IDLE = '1' then
          if r.abort = '1' then
            n.est := e_idle;
          else
            n.bcnt := resize(shift_right(r.ndone + 255, 8), 9);
            n.est := e_step;
          end if;
        end if;

      when e_step =>                    -- advance CHS by the blocks done
        if r.abort = '1' then
          n.est := e_idle;
        elsif r.bcnt = 0 then
          n.est := e_done;
        else
          n.bcnt := r.bcnt - 1;
          if r.cs = rp07_samax then
            n.cs := (others => '0');
            if r.ct = rp07_tamax then
              n.ct := (others => '0');
              n.cc := r.cc + 1;
            else
              n.ct := r.ct + 1;
            end if;
          else
            n.cs := r.cs + 1;
          end if;
        end if;

      when e_done =>
        if r.abort = '1' then
          n.est := e_idle;
        else
          eaddr := r.addr + shift_left(resize(r.ndone, 22), 1);
          n.wc := slv(unsigned(r.wc) + r.ndone(15 downto 0));
          n.ba := slv(eaddr(15 downto 0));
          n.bae := slv(eaddr(21 downto 16));
          n.da := "000" & slv(r.ct) & "00" & slv(r.cs);
          n.dc := "000000" & slv(r.cc);
          if r.aoe = '1' then
            n.er1aoe := '1';
            n.exc := '1';
          end if;
          if r.nem = '1' then
            n.cs2nem := '1';
          end if;
          n.cs1rdy := '1';
          if r.sderr /= x"00" then              -- SD failure: UNS + ATA
            n.er1uns := '1';
            n.ata := '1';
            n.exc := '1';
          else
            n.ireq := r.cs1ie;                  -- done interrupt
          end if;
          n.xcount := r.xcount + 1;
          n.est := e_idle;
        end if;

      -- WRITE: per block, fill the buffer by DMA, then CMD24 --------------
      when e_wblk =>
        if r.ndone >= r.nwrd or r.abort = '1' then
          if r.abort = '1' then
            n.est := e_idle;
          else
            n.bcnt := r.wblk;
            n.est := e_step;
          end if;
        else
          if r.nwrd - r.ndone >= 256 then
            n.wcnt := to_unsigned(256, 9);
          else
            n.wcnt := resize(r.nwrd - r.ndone, 9);
          end if;
          n.est := e_wfill;
          irdstart := '1';
        end if;

      when e_wfill =>                   -- abort here: no CMD24 for the block
        if RD_DONE = '1' then
          if r.abort = '1' then
            n.est := e_idle;
          else
            isdgo := '1';
            isdop := op_write;
            n.est := e_warm;
          end if;
        end if;

      when e_warm =>
        n.est := e_wwait;

      when e_wwait =>
        if SD_BUSY = '0' then
          if SD_ERR /= x"00" then
            n.sderr := SD_ERR;
            n.bcnt := r.wblk;
            n.est := e_step;
          else
            n.ndone := r.ndone + r.wcnt;
            n.wblk := r.wblk + 1;
            n.est := e_wblk;
          end if;
        end if;

      when e_errx =>                    -- not supported transfer function
        if r.abort = '0' then
          n.er1ilf := '1';
          n.ata := '1';
          n.exc := '1';
          n.cs1rdy := '1';
        end if;
        n.est := e_idle;
    end case;

    -- stream words to the DMA writer, drop words beyond the word count
    if SD_WE = '1' and r.est = e_read_wait and r.abort = '0' and
       r.ndone < r.nwrd then
      iwrwe := '1';
      n.ndone := r.ndone + 1;
    end if;

    -- RH70 interrupts: done edge via ireq, attention level via SC
    if EI_ACK = '1' then
      n.ireq := '0';
      n.cs1ie := '0';
    end if;

    N_REGS <= n;

    IB_SRES.ack <= r.ibsel and ibreq;
    IB_SRES.busy <= '0';
    IB_SRES.dout <= idout;
    EI_REQ <= r.ireq or (isc and r.cs1ie and r.cs1rdy);

    SD_OP <= isdop;
    SD_GO <= isdgo;
    if r.xfunc = func_write then
      SD_LBA <= slv(resize(r.lba + r.wblk, 32));
    else
      SD_LBA <= slv(resize(r.lba, 32));
    end if;
    SD_NBLK <= slv(resize(shift_right(r.nwrd + 255, 8), 16));
    SD_HOLD <= WR_HOLD;
    SD_ABORT <= r.abort;
    WR_START <= iwrstart;
    WR_BASE <= slv(r.addr);
    RD_START <= irdstart;
    RD_BASE <= slv(r.addr + shift_left(resize(r.ndone, 22), 1));
    if r.nwrd - r.ndone >= 256 then
      RD_NWORD <= "100000000";
    else
      RD_NWORD <= slv(resize(r.nwrd - r.ndone, 9));
    end if;
    if r.est = e_wblk or r.est = e_wfill or r.est = e_warm or
       r.est = e_wwait then
      WMODE <= '1';
    else
      WMODE <= '0';
    end if;
    WR_FLUSH <= iwrflush;
    WR_WE <= iwrwe;
    SDERR <= r.sderr;
    XCOUNT <= slv(r.xcount);
  end process proc_next;

end syn;
