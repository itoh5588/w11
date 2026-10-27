-- SPDX-License-Identifier: GPL-3.0-or-later
-- Native RK11/RK05 for the standalone V6 machine. Three RK05 units occupy
-- consecutive 4872-sector slots on a dedicated raw microSD card.
-- Transfers use the same SPI and DMA blocks as ibdr_rp07n. No rlink backend.
-- This controller implements the RK11 operations used by the V6 RK driver:
-- control reset, read, write, seek and drive reset. Other functions report
-- program error. A partial-sector WRITE zero pads the rest of that sector.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;
use work.iblib.all;

entity ibdr_rk05n is
  generic (
    WRITE_ENABLE : boolean := true);
  port (
    CLK : in slbit;
    RESET : in slbit;
    CE_MSEC : in slbit;
    BRESET : in slbit;
    IB_MREQ : in ib_mreq_type;
    IB_SRES : out ib_sres_type;
    EI_REQ : out slbit;
    EI_ACK : in slbit;
    O_SD_CS_N : out slbit;
    O_SD_SCLK : out slbit;
    O_SD_MOSI : out slbit;
    I_SD_MISO : in slbit;
    I_SD_CD : in slbit;
    BASE : in slv32 := (others => '0'); -- first SD LBA of the disk data
    DMA_REQ : out slbit;
    DMA_WE : out slbit;
    DMA_BUSY : in slbit;
    DMA_ACK_R : in slbit;
    DMA_ACK_W : in slbit;
    DMA_ADDR : out slv20;
    DMA_BE : out slv4;
    DMA_DI : out slv32;
    DMA_DO : in slv32;
    UB_ENA : in slbit := '0';           -- UNIBUS map enable (ubmap_shadow)
    UB_TAB : in slv(32*21-1 downto 0) := (others => '0'); -- UNIBUS map
    SDERR : out slv8;
    XCOUNT : out slv16
  );
end ibdr_rk05n;

architecture syn of ibdr_rk05n is
  constant ibaddr_rk11 : slv16 := slv(to_unsigned(8#177400#, 16));
  constant rk_sectors : natural := 203 * 2 * 12;
  constant op_init : slv3 := "001";
  constant op_read : slv3 := "100";
  constant op_write : slv3 := "110";

  type state_type is (e_idle, e_validate, e_init_go, e_init_arm,
                      e_init_wait, e_prepare, e_read_go, e_read_arm,
                      e_read_wait, e_drain, e_write_go, e_write_wait,
                      e_write_sd_go, e_write_sd_arm, e_write_sd_wait,
                      e_advance, e_finish);
  type regs_type is record
    ibsel : slbit;
    state : state_type;
    rdy : slbit;
    ie : slbit;
    func : slv3;
    mex : slv2;
    wc : slv16;
    ba : slv16;
    da : slv16;
    er : slv16;
    ireq : slbit;
    sdready : slbit;
    cd : slv2;
    left : unsigned(16 downto 0);
    xfer : unsigned(8 downto 0);
    received : unsigned(8 downto 0);
    addr : unsigned(17 downto 0);
    lba : unsigned(15 downto 0);
    sderr : slv8;
    xcount : unsigned(15 downto 0);
  end record;
  constant regs_init : regs_type := (
    '0', e_idle, '1', '0', (others => '0'), (others => '0'),
    (others => '0'), (others => '0'), (others => '0'), (others => '0'),
    '0', '0', "11", (others => '0'), (others => '0'),
    (others => '0'), (others => '0'), (others => '0'),
    (others => '0'), (others => '0'));
  signal R : regs_type := regs_init;
  signal N_REGS : regs_type := regs_init;
  signal ENGINE_RESET : slbit := '0';

  signal SD_OP : slv3 := (others => '0');
  signal SD_GO : slbit := '0';
  signal SD_LBA : slv32 := (others => '0');
  signal SD_LBA_ABS : slv32 := (others => '0');
  signal SD_BUSY : slbit := '0';
  signal SD_INITOK : slbit := '0';
  signal SD_ERR : slv8 := (others => '0');
  signal SD_WE : slbit := '0';
  signal SD_WADDR : slv8 := (others => '0');
  signal SD_WDATA : slv16 := (others => '0');
  signal SD_WBUF_ADDR : slv8 := (others => '0');
  signal SD_WBUF_DATA : slv16 := (others => '0');
  signal PHY_DIV : slv8 := (others => '0');
  signal PHY_START : slbit := '0';
  signal PHY_TXD : slv8 := (others => '0');
  signal PHY_RXD : slv8 := (others => '0');
  signal PHY_DONE : slbit := '0';

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
  signal RD_START : slbit := '0';
  signal RD_DONE : slbit := '0';
  signal RD_DMA_REQ : slbit := '0';
  signal RD_DMA_ADDR : slv20 := (others => '0');
  signal WMODE : slbit := '0';

  function advance_da(da : slv16) return slv16 is
    variable result : unsigned(15 downto 0) := unsigned(da);
  begin
    if unsigned(da(3 downto 0)) < 11 then
      result(3 downto 0) := unsigned(da(3 downto 0)) + 1;
    else
      result(3 downto 0) := (others => '0');
      if da(4) = '0' then
        result(4) := '1';
      else
        result(4) := '0';
        result(12 downto 5) := unsigned(da(12 downto 5)) + 1;
      end if;
    end if;
    return slv(result);
  end function;
begin

  SD_LBA_ABS <= slv(unsigned(SD_LBA) + unsigned(BASE));
  ENGINE_RESET <= RESET or BRESET;

  CTL : entity work.sdspi_ctl
    port map (
      CLK => CLK, RESET => ENGINE_RESET, CE_MSEC => CE_MSEC,
      OP => SD_OP, GO => SD_GO, LBA => SD_LBA_ABS, NBLK => x"0001",
      HOLD => WR_HOLD, ABORT => '0', FASTDIV => x"02",
      BUSY => SD_BUSY, INITOK => SD_INITOK, V2 => open, HC => open,
      ERR => SD_ERR, R1 => open, TOKEN => open, RESP => open,
      BUF_WE => SD_WE, BUF_ADDR => SD_WADDR, BUF_DI => SD_WDATA,
      WBUF_ADDR => SD_WBUF_ADDR, WBUF_DATA => SD_WBUF_DATA,
      O_CS_N => O_SD_CS_N, PHY_DIV => PHY_DIV, PHY_START => PHY_START,
      PHY_TXD => PHY_TXD, PHY_RXD => PHY_RXD, PHY_DONE => PHY_DONE);

  PHY : entity work.sdspi_phy
    port map (
      CLK => CLK, RESET => ENGINE_RESET, DIV => PHY_DIV,
      START => PHY_START, TXD => PHY_TXD, RXD => PHY_RXD,
      DONE => PHY_DONE, BUSY => open,
      O_SCLK => O_SD_SCLK, O_MOSI => O_SD_MOSI, I_MISO => I_SD_MISO);

  WR : entity work.sd_dma_wr
    port map (
      CLK => CLK, RESET => ENGINE_RESET, START => WR_START,
      BASE => WR_BASE, UB_ENA => UB_ENA, UB_TAB => UB_TAB,
      FLUSH => WR_FLUSH, WE => WR_WE,
      DI => SD_WDATA, HOLD => WR_HOLD, IDLE => WR_IDLE, NWORD => open,
      DMA_REQ => WR_DMA_REQ, DMA_WE => WR_DMA_WE, DMA_BUSY => DMA_BUSY,
      DMA_ACK_W => DMA_ACK_W, DMA_ADDR => WR_DMA_ADDR,
      DMA_BE => WR_DMA_BE, DMA_DI => WR_DMA_DI);

  RD : entity work.sd_dma_rd
    port map (
      CLK => CLK, RESET => ENGINE_RESET, START => RD_START,
      BASE => WR_BASE, UB_ENA => UB_ENA, UB_TAB => UB_TAB,
      NWORD => slv(R.xfer), DONE => RD_DONE,
      RADDR => SD_WBUF_ADDR, RDATA => SD_WBUF_DATA,
      DMA_REQ => RD_DMA_REQ, DMA_BUSY => DMA_BUSY,
      DMA_ACK_R => DMA_ACK_R, DMA_ADDR => RD_DMA_ADDR, DMA_DO => DMA_DO);

  DMA_REQ <= RD_DMA_REQ when WMODE = '1' else WR_DMA_REQ;
  DMA_WE <= '0' when WMODE = '1' else WR_DMA_WE;
  DMA_ADDR <= RD_DMA_ADDR when WMODE = '1' else WR_DMA_ADDR;
  DMA_BE <= "1111" when WMODE = '1' else WR_DMA_BE;
  DMA_DI <= WR_DMA_DI;

  proc_regs: process (CLK)
  begin
    if rising_edge(CLK) then
      if ENGINE_RESET = '1' then
        R <= regs_init;
      else
        R <= N_REGS;
      end if;
    end if;
  end process;

  proc_next: process (R, IB_MREQ, EI_ACK, I_SD_CD,
                     SD_BUSY, SD_INITOK, SD_ERR, SD_WE, WR_HOLD,
                     WR_IDLE, RD_DONE)
    variable n : regs_type;
    variable ibreq : slbit;
    variable idout : slv16;
    variable data : slv16;
    variable ireg : slv3;
    variable isdgo : slbit;
    variable isdop : slv3;
    variable iwrstart : slbit;
    variable iwrflush : slbit;
    variable iwrwe : slbit;
    variable irdstart : slbit;
    variable unit_no : natural range 0 to 7;
    variable cyl : natural range 0 to 255;
    variable sec : natural range 0 to 15;
    variable block_words : unsigned(8 downto 0);
    variable next_addr : unsigned(18 downto 0);
  begin
    n := R;
    idout := (others => '0');
    isdgo := '0';
    isdop := op_read;
    iwrstart := '0';
    iwrflush := '0';
    iwrwe := '0';
    irdstart := '0';
    ibreq := IB_MREQ.re or IB_MREQ.we;
    ireg := IB_MREQ.addr(3 downto 1);

    n.ibsel := '0';
    if IB_MREQ.aval = '1' and
       IB_MREQ.addr(12 downto 4) = ibaddr_rk11(12 downto 4) then
      n.ibsel := '1';
    end if;
    n.cd := R.cd(0) & I_SD_CD;
    if R.cd(1) = '1' then
      n.sdready := '0';
    end if;

    if R.ibsel = '1' and IB_MREQ.re = '1' then
      case ireg is
        when "000" =>                   -- RKDS
          if R.cd(1) = '0' and unsigned(R.da(15 downto 13)) < 3 then
            idout(7 downto 6) := "11";  -- drive ready, access ready
            if not WRITE_ENABLE then
              idout(5) := '1';
            end if;
          end if;
        when "001" => idout := R.er;   -- RKER
        when "010" =>                   -- RKCS
          if R.er /= x"0000" then
            idout(15 downto 14) := "11";
          end if;
          idout(7) := R.rdy;
          idout(6) := R.ie;
          idout(5 downto 4) := R.mex;
          idout(3 downto 1) := R.func;
          idout(0) := not R.rdy;
        when "011" => idout := R.wc;   -- RKWC
        when "100" => idout := R.ba;   -- RKBA
        when "101" => idout := R.da;   -- RKDA
        when "110" => idout(11) := '1'; -- RKMR: control reset done
        when others => null;
      end case;
    end if;

    if R.ibsel = '1' and IB_MREQ.we = '1' and IB_MREQ.racc = '0' then
      case ireg is
        when "010" =>                   -- RKCS
          if IB_MREQ.be0 = '1' then
            n.ie := IB_MREQ.din(6);
            n.mex := IB_MREQ.din(5 downto 4);
            n.func := IB_MREQ.din(3 downto 1);
            if IB_MREQ.din(6) = '0' then
              n.ireq := '0';
            elsif R.ie = '0' and R.rdy = '1' then
              n.ireq := '1';
            end if;
            if IB_MREQ.din(0) = '1' and R.rdy = '1' then
              n.ireq := '0';
              n.er := (others => '0');
              n.rdy := '0';
              case IB_MREQ.din(3 downto 1) is
                when "000" =>
                  n := regs_init;
                  n.ibsel := R.ibsel;
                when "001" | "010" => n.state := e_validate;
                when "100" | "110" =>
                  n.rdy := '1';         -- seek and drive reset
                  n.ireq := n.ie;
                when others =>
                  n.er(10) := '1';      -- program error
                  n.state := e_finish;
              end case;
            end if;
          end if;
        when "011" | "100" | "101" =>
          if R.rdy = '1' then
            data := R.wc;
            if ireg = "100" then data := R.ba; end if;
            if ireg = "101" then data := R.da; end if;
            if IB_MREQ.be0 = '1' then
              data(7 downto 0) := IB_MREQ.din(7 downto 0);
            end if;
            if IB_MREQ.be1 = '1' then
              data(15 downto 8) := IB_MREQ.din(15 downto 8);
            end if;
            case ireg is
              when "011" => n.wc := data;
              when "100" => n.ba := data;
              when others => n.da := data;
            end case;
          end if;
        when others => null;
      end case;
    end if;

    case R.state is
      when e_idle => null;
      when e_validate =>
        unit_no := to_integer(unsigned(R.da(15 downto 13)));
        cyl := to_integer(unsigned(R.da(12 downto 5)));
        sec := to_integer(unsigned(R.da(3 downto 0)));
        if R.cd(1) = '1' then
          n.er(15) := '1';              -- drive error / card absent
          n.state := e_finish;
        elsif unit_no >= 3 then
          n.er(7) := '1';               -- nonexistent drive
          n.state := e_finish;
        elsif cyl >= 203 then
          n.er(6) := '1';               -- nonexistent cylinder
          n.state := e_finish;
        elsif sec >= 12 then
          n.er(5) := '1';               -- nonexistent sector
          n.state := e_finish;
        elsif R.func = "001" and not WRITE_ENABLE then
          n.er(13) := '1';              -- write lock
          n.state := e_finish;
        elsif R.ba(0) = '1' then
          n.er(11) := '1';              -- odd DMA address
          n.state := e_finish;
        else
          n.lba := to_unsigned(unit_no * rk_sectors + cyl * 24 +
                               to_integer(unsigned(R.da(4 downto 4))) * 12 +
                               sec, 16);
          n.addr := unsigned(R.mex & R.ba);
          n.left := resize(unsigned(not R.wc), 17) + 1;
          if R.wc = x"0000" then
            n.left := to_unsigned(65536, 17);
          end if;
          if R.sdready = '1' then
            n.state := e_prepare;
          else
            n.state := e_init_go;
          end if;
        end if;

      when e_init_go =>
        isdgo := '1'; isdop := op_init; n.state := e_init_arm;
      when e_init_arm => n.state := e_init_wait;
      when e_init_wait =>
        if SD_BUSY = '0' then
          if SD_INITOK = '1' and SD_ERR = x"00" then
            n.sdready := '1'; n.state := e_prepare;
          else
            n.sderr := SD_ERR; n.er(15) := '1'; n.state := e_finish;
          end if;
        end if;

      when e_prepare =>
        if R.left = 0 then
          n.state := e_finish;
        elsif R.lba >= 3 * rk_sectors then
          n.er(6) := '1'; n.state := e_finish;
        else
          if R.left >= 256 then
            block_words := to_unsigned(256, 9);
          else
            block_words := resize(R.left, 9);
          end if;
          next_addr := resize(R.addr, 19) + shift_left(resize(block_words, 19), 1);
          if next_addr > to_unsigned(262144, 19) then
            n.er(11) := '1'; n.state := e_finish; -- NXM
          else
            n.xfer := block_words;
            n.received := (others => '0');
            if R.func = "010" then
              n.state := e_read_go;
            else
              n.state := e_write_go;
            end if;
          end if;
        end if;

      when e_read_go =>
        iwrstart := '1'; isdgo := '1'; isdop := op_read;
        n.state := e_read_arm;
      when e_read_arm => n.state := e_read_wait;
      when e_read_wait =>
        if SD_WE = '1' and R.received < R.xfer then
          iwrwe := '1'; n.received := R.received + 1;
        end if;
        if SD_BUSY = '0' then
          iwrflush := '1';
          if SD_ERR /= x"00" or n.received /= R.xfer then
            n.sderr := SD_ERR; n.er(15) := '1';
          end if;
          n.state := e_drain;
        end if;
      when e_drain =>
        if WR_IDLE = '1' then
          if R.er /= x"0000" then n.state := e_finish;
          else n.state := e_advance; end if;
        end if;

      when e_write_go =>
        irdstart := '1'; n.state := e_write_wait;
      when e_write_wait =>
        if RD_DONE = '1' then n.state := e_write_sd_go; end if;
      when e_write_sd_go =>
        isdgo := '1'; isdop := op_write; n.state := e_write_sd_arm;
      when e_write_sd_arm => n.state := e_write_sd_wait;
      when e_write_sd_wait =>
        if SD_BUSY = '0' then
          if SD_ERR /= x"00" then
            n.sderr := SD_ERR; n.er(15) := '1'; n.state := e_finish;
          else
            n.state := e_advance;
          end if;
        end if;

      when e_advance =>
        n.left := R.left - R.xfer;
        n.wc := slv(unsigned(R.wc) + resize(R.xfer, 16));
        next_addr := resize(R.addr, 19) + shift_left(resize(R.xfer, 19), 1);
        n.addr := next_addr(17 downto 0);
        n.ba := slv(next_addr(15 downto 0));
        n.mex := slv(next_addr(17 downto 16));
        n.da := advance_da(R.da);
        n.lba := R.lba + 1;
        n.state := e_prepare;

      when e_finish =>
        n.rdy := '1';
        n.ireq := R.ie;
        n.xcount := R.xcount + 1;
        n.state := e_idle;
    end case;

    if EI_ACK = '1' then n.ireq := '0'; end if;

    N_REGS <= n;
    IB_SRES.ack <= R.ibsel and ibreq;
    IB_SRES.busy <= '0';
    IB_SRES.dout <= idout;
    EI_REQ <= R.ireq;
    SD_OP <= isdop;
    SD_GO <= isdgo;
    SD_LBA <= slv(resize(R.lba, 32));
    WR_START <= iwrstart;
    WR_BASE <= "0000" & slv(R.addr);
    WR_FLUSH <= iwrflush;
    WR_WE <= iwrwe;
    RD_START <= irdstart;
    if R.state = e_write_go or R.state = e_write_wait or
       R.state = e_write_sd_go or R.state = e_write_sd_arm or
       R.state = e_write_sd_wait then
      WMODE <= '1';
    else
      WMODE <= '0';
    end if;
    SDERR <= R.sderr;
    XCOUNT <= slv(R.xcount);
  end process;
end syn;
