-- SPDX-License-Identifier: GPL-3.0-or-later
-- Native RL11 with RL01/RL02 drives on a dedicated raw microSD card.
-- One 256-byte RL sector occupies one 512-byte SD block. This requires the
-- matching pack_rl_sd.py media layout; a normal RL image is not directly
-- usable on the card. Each drive has an RL02-sized (40960 block) slot.
-- RL02_MASK selects drive type per unit; PRESENT_MASK selects available units.
-- Both are inputs, set from the card label; BASE is the first SD LBA of RL0.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.slvtypes.all;
use work.iblib.all;

entity ibdr_rl02n is
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
    RL02_MASK : in slv4 := "1111";      -- bit u: unit u is an RL02
    PRESENT_MASK : in slv4 := "1111";   -- bit u: unit u is present
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
end ibdr_rl02n;

architecture syn of ibdr_rl02n is
  constant ibaddr_rl11 : slv16 := slv(to_unsigned(8#174400#, 16));
  constant slot_sectors : natural := 512 * 2 * 40;
  constant op_init : slv3 := "001";
  constant op_read : slv3 := "100";
  constant op_write : slv3 := "110";

  type position_array is array (0 to 3) of slv16;
  type state_type is (e_idle, e_validate, e_init_go, e_init_arm,
                      e_init_wait, e_prepare, e_read_go, e_read_arm,
                      e_read_wait, e_drain, e_write_go, e_write_wait,
                      e_write_sd_go, e_write_sd_arm, e_write_sd_wait,
                      e_advance, e_finish);
  type regs_type is record
    ibsel : slbit;
    state : state_type;
    crdy : slbit;
    ie : slbit;
    func : slv3;
    ds : slv2;
    bae : slv2;
    ba : slv16;
    da : slv16;
    mp : slv16;
    mpseq : slv2;
    ecode : slv4;
    de : slbit;
    pos : position_array;
    ireq : slbit;
    sdready : slbit;
    cd : slv2;
    left : unsigned(16 downto 0);
    xfer : unsigned(8 downto 0);
    received : unsigned(8 downto 0);
    addr : unsigned(17 downto 0);
    lba : unsigned(17 downto 0);
    sderr : slv8;
    xcount : unsigned(15 downto 0);
  end record;
  constant regs_init : regs_type := (
    ibsel => '0', state => e_idle, crdy => '1', ie => '0',
    func => (others => '0'), ds => (others => '0'),
    bae => (others => '0'), ba => (others => '0'),
    da => (others => '0'), mp => (others => '0'),
    mpseq => (others => '0'), ecode => (others => '0'), de => '0',
    pos => (others => (others => '0')),
    ireq => '0', sdready => '0', cd => "11",
    left => (others => '0'), xfer => (others => '0'),
    received => (others => '0'), addr => (others => '0'),
    lba => (others => '0'), sderr => (others => '0'),
    xcount => (others => '0'));
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
begin

  SD_LBA_ABS <= slv(unsigned(SD_LBA) + unsigned(BASE));
  ENGINE_RESET <= RESET or BRESET;

  CTL: entity work.sdspi_ctl
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

  PHY: entity work.sdspi_phy
    port map (
      CLK => CLK, RESET => ENGINE_RESET, DIV => PHY_DIV,
      START => PHY_START, TXD => PHY_TXD, RXD => PHY_RXD,
      DONE => PHY_DONE, BUSY => open,
      O_SCLK => O_SD_SCLK, O_MOSI => O_SD_MOSI, I_MISO => I_SD_MISO);

  WR: entity work.sd_dma_wr
    port map (
      CLK => CLK, RESET => ENGINE_RESET, START => WR_START,
      BASE => WR_BASE, UB_ENA => UB_ENA, UB_TAB => UB_TAB,
      FLUSH => WR_FLUSH, WE => WR_WE,
      DI => SD_WDATA, HOLD => WR_HOLD, IDLE => WR_IDLE, NWORD => open,
      DMA_REQ => WR_DMA_REQ, DMA_WE => WR_DMA_WE, DMA_BUSY => DMA_BUSY,
      DMA_ACK_W => DMA_ACK_W, DMA_ADDR => WR_DMA_ADDR,
      DMA_BE => WR_DMA_BE, DMA_DI => WR_DMA_DI);

  RD: entity work.sd_dma_rd
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
      if ENGINE_RESET = '1' then R <= regs_init;
      else R <= N_REGS; end if;
    end if;
  end process;

  proc_next: process (R, IB_MREQ, EI_ACK, I_SD_CD, SD_BUSY,
                     SD_INITOK, SD_ERR, SD_WE, WR_IDLE, RD_DONE,
                     RL02_MASK, PRESENT_MASK)
    variable n : regs_type;
    variable ibreq : slbit;
    variable idout : slv16;
    variable ireg : slv2;
    variable data : slv16;
    variable isdgo : slbit;
    variable isdop : slv3;
    variable iwrstart, iwrflush, iwrwe, irdstart : slbit;
    variable unit_no : natural range 0 to 3;
    variable cyl : natural range 0 to 511;
    variable head : natural range 0 to 1;
    variable sec : natural range 0 to 63;
    variable cmax : natural range 0 to 512;
    variable status : slv16;
    variable seek_cyl : integer range -511 to 1023;
    variable block_words : unsigned(8 downto 0);
    variable next_addr : unsigned(18 downto 0);
  begin
    n := R;
    idout := (others => '0');
    isdgo := '0'; isdop := op_read;
    iwrstart := '0'; iwrflush := '0'; iwrwe := '0'; irdstart := '0';
    ibreq := IB_MREQ.re or IB_MREQ.we;
    ireg := IB_MREQ.addr(2 downto 1);
    unit_no := to_integer(unsigned(R.ds));
    n.ibsel := '0';
    if IB_MREQ.aval = '1' and
       IB_MREQ.addr(12 downto 3) = ibaddr_rl11(12 downto 3) then
      n.ibsel := '1';
    end if;
    n.cd := R.cd(0) & I_SD_CD;
    if R.cd(1) = '1' then n.sdready := '0'; end if;

    status := (others => '0');

    if R.ibsel = '1' and IB_MREQ.re = '1' then
      case ireg is
        when "00" =>
          if R.ecode /= "0000" or R.de = '1' then idout(15) := '1'; end if;
          idout(14) := R.de;
          idout(13 downto 10) := R.ecode;
          idout(9 downto 8) := R.ds;
          idout(7) := R.crdy;
          idout(6) := R.ie;
          idout(5 downto 4) := R.bae;
          idout(3 downto 1) := R.func;
          if PRESENT_MASK(unit_no) = '1' and R.cd(1) = '0' then
            idout(0) := '1';
          end if;
        when "01" => idout := R.ba;
        when "10" => idout := R.da;
        when "11" =>
          if R.mpseq = "01" then
            idout := R.mp;
            n.mpseq := "10";
          elsif R.mpseq = "10" then
            idout := (others => '0'); -- READ HEADER CRC placeholder
            n.mpseq := "11";
          else
            idout := R.mp;
          end if;
        when others => null;
      end case;
    end if;

    if R.ibsel = '1' and IB_MREQ.we = '1' and IB_MREQ.racc = '0' then
      case ireg is
        when "00" =>
          if IB_MREQ.be1 = '1' and R.crdy = '1' then
            n.ds := IB_MREQ.din(9 downto 8);
          end if;
          if IB_MREQ.be0 = '1' then
            n.ie := IB_MREQ.din(6);
            n.bae := IB_MREQ.din(5 downto 4);
            if IB_MREQ.din(6) = '0' then n.ireq := '0'; end if;
            if R.crdy = '1' then
              n.func := IB_MREQ.din(3 downto 1);
              if IB_MREQ.din(7) = '0' then
                n.ireq := '0';
                n.ecode := (others => '0');
                n.de := '0';
                case IB_MREQ.din(3 downto 1) is
                  when "000" => n.ireq := n.ie; -- NOOP
                  when "010" =>             -- GET STATUS
                    if PRESENT_MASK(to_integer(unsigned(n.ds))) = '0' or
                       R.cd(1) = '1' or
                       (R.da and x"00f7") /= x"0003" then
                      n.de := '1'; n.ecode := "0001";
                    else
                      unit_no := to_integer(unsigned(n.ds));
                      status := (others => '0');
                      status(3 downto 0) := "1101";
                      status(4) := '1'; -- heads out, as in attached w11 RL drive
                      status(6) := R.pos(unit_no)(6);
                      status(7) := RL02_MASK(unit_no);
                      if not WRITE_ENABLE then status(13) := '1'; end if;
                      n.mp := status; n.mpseq := "01";
                    end if;
                    n.ireq := n.ie;
                  when "011" =>             -- SEEK, relative cylinders
                    if PRESENT_MASK(to_integer(unsigned(n.ds))) = '0' or
                       R.cd(1) = '1' or
                       (R.da and x"000b") /= x"0001" then
                      n.ecode := "0001";
                    else
                      cmax := 256;
                      if RL02_MASK(to_integer(unsigned(n.ds))) = '1' then
                        cmax := 512;
                      end if;
                      seek_cyl := to_integer(unsigned(R.pos(to_integer(unsigned(n.ds)))(15 downto 7)));
                      if R.da(2) = '1' then
                        seek_cyl := seek_cyl + to_integer(unsigned(R.da(15 downto 7)));
                      else
                        seek_cyl := seek_cyl - to_integer(unsigned(R.da(15 downto 7)));
                      end if;
                      if seek_cyl < 0 then seek_cyl := 0; end if;
                      if seek_cyl >= cmax then seek_cyl := cmax - 1; end if;
                      n.pos(to_integer(unsigned(n.ds))) :=
                        slv(to_unsigned(seek_cyl, 9)) & R.da(4) & "000000";
                    end if;
                    n.ireq := n.ie;
                  when "100" =>             -- READ HEADER
                    unit_no := to_integer(unsigned(n.ds));
                    if PRESENT_MASK(unit_no) = '0' or R.cd(1) = '1' then
                      n.de := '1'; n.ecode := "0001";
                    else
                      n.mp := R.pos(unit_no);
                      n.mpseq := "01";
                      if unsigned(R.pos(unit_no)(5 downto 0)) = 39 then
                        n.pos(unit_no)(5 downto 0) := (others => '0');
                      else
                        n.pos(unit_no)(5 downto 0) :=
                          slv(unsigned(R.pos(unit_no)(5 downto 0)) + 1);
                      end if;
                    end if;
                    n.ireq := n.ie;
                  when "101" | "110" | "111" =>
                    n.crdy := '0'; n.state := e_validate;
                  when others =>
                    n.ecode := "0001"; n.ireq := n.ie;
                end case;
              elsif R.ie = '0' and n.ie = '1' then
                n.ireq := '1';
              end if;
            end if;
          end if;
        when "01" =>
          data := R.ba;
          if IB_MREQ.be0 = '1' then data(7 downto 0) := IB_MREQ.din(7 downto 0); end if;
          if IB_MREQ.be1 = '1' then data(15 downto 8) := IB_MREQ.din(15 downto 8); end if;
          n.ba := data(15 downto 1) & '0';
        when "10" =>
          data := R.da;
          if IB_MREQ.be0 = '1' then data(7 downto 0) := IB_MREQ.din(7 downto 0); end if;
          if IB_MREQ.be1 = '1' then data(15 downto 8) := IB_MREQ.din(15 downto 8); end if;
          n.da := data;
        when "11" =>
          data := R.mp;
          if IB_MREQ.be0 = '1' then data(7 downto 0) := IB_MREQ.din(7 downto 0); end if;
          if IB_MREQ.be1 = '1' then data(15 downto 8) := IB_MREQ.din(15 downto 8); end if;
          n.mp := data;
          n.mpseq := "00";
        when others => null;
      end case;
    end if;

    case R.state is
      when e_idle => null;
      when e_validate =>
        unit_no := to_integer(unsigned(R.ds));
        cyl := to_integer(unsigned(R.da(15 downto 7)));
        head := to_integer(unsigned(R.da(6 downto 6)));
        sec := to_integer(unsigned(R.da(5 downto 0)));
        cmax := 256;
        if RL02_MASK(unit_no) = '1' then cmax := 512; end if;
        if PRESENT_MASK(unit_no) = '0' or R.cd(1) = '1' then
          n.de := '1'; n.ecode := "0001"; n.state := e_finish;
        elsif cyl >= cmax or sec >= 40 then
          n.ecode := "0101"; n.state := e_finish; -- header not found
        elsif R.func = "101" and not WRITE_ENABLE then
          n.de := '1'; n.ecode := "0001"; n.state := e_finish;
        elsif R.func = "101" or R.func = "110" or R.func = "111" then
          if R.func /= "111" and
             R.pos(unit_no)(15 downto 6) /= R.da(15 downto 6) then
            n.ecode := "0101"; n.state := e_finish;
          else
            n.lba := to_unsigned(unit_no * slot_sectors +
                                 (cyl * 2 + head) * 40 + sec, 18);
            n.addr := unsigned(R.bae) & unsigned(R.ba);
            n.left := resize(unsigned(not R.mp), 17) + 1;
            if R.mp = x"0000" then n.left := to_unsigned(65536, 17); end if;
            if R.sdready = '1' then n.state := e_prepare;
            else n.state := e_init_go; end if;
          end if;
        else
          n.ecode := "0001"; n.state := e_finish;
        end if;
      when e_init_go =>
        isdgo := '1'; isdop := op_init; n.state := e_init_arm;
      when e_init_arm => n.state := e_init_wait;
      when e_init_wait =>
        if SD_BUSY = '0' then
          if SD_INITOK = '1' and SD_ERR = x"00" then
            n.sdready := '1'; n.state := e_prepare;
          else
            n.sderr := SD_ERR; n.de := '1'; n.ecode := "0001";
            n.state := e_finish;
          end if;
        end if;
      when e_prepare =>
        sec := to_integer(unsigned(R.da(5 downto 0)));
        if R.left = 0 then
          n.state := e_finish;
        elsif sec >= 40 then
          n.ecode := "0101"; n.state := e_finish;
        else
          if R.left >= 128 then block_words := to_unsigned(128, 9);
          else block_words := resize(R.left, 9); end if;
          next_addr := resize(R.addr, 19) + shift_left(resize(block_words, 19), 1);
          if next_addr > to_unsigned(262144, 19) then
            n.ecode := "1000"; n.state := e_finish; -- NXM
          else
            n.xfer := block_words;
            n.received := (others => '0');
            if R.func = "101" then n.state := e_write_go;
            else n.state := e_read_go; end if;
          end if;
        end if;
      when e_read_go =>
        iwrstart := '1'; isdgo := '1'; isdop := op_read;
        n.state := e_read_arm;
      when e_read_arm => n.state := e_read_wait;
      when e_read_wait =>
        if SD_WE = '1' and unsigned(SD_WADDR) < R.xfer then
          iwrwe := '1'; n.received := R.received + 1;
        end if;
        if SD_BUSY = '0' then
          iwrflush := '1';
          if SD_ERR /= x"00" or n.received /= R.xfer then
            n.sderr := SD_ERR; n.de := '1'; n.ecode := "0001";
          end if;
          n.state := e_drain;
        end if;
      when e_drain =>
        if WR_IDLE = '1' then
          if R.ecode /= "0000" then n.state := e_finish;
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
            n.sderr := SD_ERR; n.de := '1'; n.ecode := "0001";
            n.state := e_finish;
          else n.state := e_advance; end if;
        end if;
      when e_advance =>
        n.left := R.left - R.xfer;
        n.mp := slv(unsigned(R.mp) + resize(R.xfer, 16));
        next_addr := resize(R.addr, 19) + shift_left(resize(R.xfer, 19), 1);
        n.addr := next_addr(17 downto 0);
        n.ba := slv(next_addr(15 downto 0));
        n.bae := slv(next_addr(17 downto 16));
        n.lba := R.lba + 1;
        unit_no := to_integer(unsigned(R.ds));
        if unsigned(R.da(5 downto 0)) = 39 then
          n.da(5 downto 0) := (others => '0');
          n.pos(unit_no)(5 downto 0) := (others => '0');
          if R.left > resize(R.xfer, 17) then
            n.ecode := "0101"; n.state := e_finish;
          else n.state := e_prepare; end if;
        else
          n.da(5 downto 0) := slv(unsigned(R.da(5 downto 0)) + 1);
          n.pos(unit_no)(5 downto 0) := n.da(5 downto 0);
          n.state := e_prepare;
        end if;
      when e_finish =>
        n.crdy := '1'; n.ireq := R.ie;
        n.xcount := R.xcount + 1;
        n.state := e_idle;
    end case;

    if EI_ACK = '1' then n.ireq := '0'; end if;
    N_REGS <= n;
    IB_SRES.ack <= R.ibsel and ibreq;
    IB_SRES.busy <= '0';
    IB_SRES.dout <= idout;
    EI_REQ <= R.ireq;
    SD_OP <= isdop; SD_GO <= isdgo;
    SD_LBA <= slv(resize(R.lba, 32));
    WR_START <= iwrstart;
    WR_BASE <= "0000" & slv(R.addr);
    WR_FLUSH <= iwrflush;
    WR_WE <= iwrwe;
    RD_START <= irdstart;
    if R.state = e_write_go or R.state = e_write_wait or
       R.state = e_write_sd_go or R.state = e_write_sd_arm or
       R.state = e_write_sd_wait then WMODE <= '1';
    else WMODE <= '0'; end if;
    SDERR <= R.sderr;
    XCOUNT <= slv(R.xcount);
  end process;
end syn;
