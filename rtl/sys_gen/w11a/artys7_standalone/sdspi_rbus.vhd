-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- rbus test access to the read-only SD card block layer (sdspi_ctl).
--
-- rbus registers (RB_ADDR + n):
--   0 cmd/stat  w: bits 2:0 operation (1 init, 2 CID, 3 CSD, 4 read block,
--                  5 read nblk blocks to memory by DMA, 6 read nblk blocks
--                  to the buffer only)
--               r: bit0 busy (includes DMA drain), bit1 init ok, bit2 v2,
--                  bit3 block addressing,
--                  bit4 card detect pin, bits 15:8 error code
--   1 lbal  rw  block number, low half
--   2 lbah  rw  block number, high half
--   3 baddr rw  buffer word address (0..255)
--   4 bdata r   buffer word at baddr, then baddr+1
--   5 r1    r   bits 7:0 last R1, bits 15:8 last data token
--   6 fdiv  rw  SPI phase length - 1 after init (>= 2; 2 = 12.5 MHz)
--   7 resp  r   upper half of the last R3/R7 response (OCR bits 31:16)
--   8 nblk  rw  block count for operations 5 and 6 (0 means 1)
--   9 mal   rw  DMA byte address bits 15:0 (bit 0 ignored)
--  10 mah   rw  DMA byte address bits 21:16
--  11 cycl  r   CLK cycles of the last operation, low half
--  12 cych  r   CLK cycles of the last operation, high half
--  13 nwrd  r   words written by DMA in the last operation 5
-- The buffer always holds the last block read.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;
use work.rblib.all;

entity sdspi_rbus is
  generic (
    RB_ADDR : slv16 := x"fd10");
  port (
    CLK : in slbit;
    RESET : in slbit;
    CE_MSEC : in slbit;
    RB_MREQ : in rb_mreq_type;
    RB_SRES : out rb_sres_type;
    O_SD_CS_N : out slbit;
    O_SD_SCLK : out slbit;
    O_SD_MOSI : out slbit;
    I_SD_MISO : in slbit;
    I_SD_CD : in slbit;
    DMA_REQ : out slbit;
    DMA_WE : out slbit;
    DMA_BUSY : in slbit;
    DMA_ACK_W : in slbit;
    DMA_ADDR : out slv20;
    DMA_BE : out slv4;
    DMA_DI : out slv32
  );
end sdspi_rbus;

architecture syn of sdspi_rbus is

  type buf_type is array (0 to 255) of slv16;
  signal BUF : buf_type := (others => (others => '0'));

  signal R_SEL : slbit := '0';
  signal R_LBA : slv32 := (others => '0');
  signal R_BADDR : unsigned(7 downto 0) := (others => '0');
  signal R_FDIV : slv8 := x"02";
  signal R_CD : slv2 := (others => '1');
  signal R_NBLK : slv16 := (others => '0');
  signal R_MADDR : slv22 := (others => '0');
  signal R_ACTIVE : slbit := '0';        -- operation incl. DMA drain
  signal R_ARM : slbit := '0';           -- first cycle after GO
  signal R_DMAEN : slbit := '0';
  signal R_FLUSHED : slbit := '0';
  signal R_CYC : unsigned(31 downto 0) := (others => '0');

  signal CTL_OP : slv3 := (others => '0');
  signal WR_START : slbit := '0';
  signal WR_FLUSH : slbit := '0';
  signal WR_WE : slbit := '0';
  signal WR_HOLD : slbit := '0';
  signal WR_IDLE : slbit := '1';
  signal WR_NWORD : slv16 := (others => '0');
  signal CTL_HOLD : slbit := '0';

  signal GO : slbit := '0';
  signal BUSY : slbit := '0';
  signal INITOK : slbit := '0';
  signal V2 : slbit := '0';
  signal HC : slbit := '0';
  signal ERR : slv8 := (others => '0');
  signal R1 : slv8 := (others => '0');
  signal TOKEN : slv8 := (others => '0');
  signal RESP : slv32 := (others => '0');
  signal BUF_WE : slbit := '0';
  signal BUF_ADDR : slv8 := (others => '0');
  signal BUF_DI : slv16 := (others => '0');
  signal PHY_DIV : slv8 := (others => '0');
  signal PHY_START : slbit := '0';
  signal PHY_TXD : slv8 := (others => '0');
  signal PHY_RXD : slv8 := (others => '0');
  signal PHY_DONE : slbit := '0';

begin

  RBSEL : rb_sel
    generic map (RB_ADDR => RB_ADDR, SAWIDTH => 4)
    port map (CLK => CLK, RB_MREQ => RB_MREQ, SEL => R_SEL);

  CTL : entity work.sdspi_ctl
    port map (
      CLK => CLK, RESET => RESET, CE_MSEC => CE_MSEC,
      OP => CTL_OP, GO => GO, LBA => R_LBA, NBLK => R_NBLK, HOLD => CTL_HOLD,
      ABORT => '0',
      FASTDIV => R_FDIV, BUSY => BUSY, INITOK => INITOK, V2 => V2, HC => HC,
      ERR => ERR, R1 => R1, TOKEN => TOKEN, RESP => RESP,
      BUF_WE => BUF_WE, BUF_ADDR => BUF_ADDR, BUF_DI => BUF_DI,
      WBUF_ADDR => open, WBUF_DATA => x"0000",
      O_CS_N => O_SD_CS_N, PHY_DIV => PHY_DIV, PHY_START => PHY_START,
      PHY_TXD => PHY_TXD, PHY_RXD => PHY_RXD, PHY_DONE => PHY_DONE);

  PHY : entity work.sdspi_phy
    port map (
      CLK => CLK, RESET => RESET, DIV => PHY_DIV, START => PHY_START,
      TXD => PHY_TXD, RXD => PHY_RXD, DONE => PHY_DONE, BUSY => open,
      O_SCLK => O_SD_SCLK, O_MOSI => O_SD_MOSI, I_MISO => I_SD_MISO);

  WR : entity work.sd_dma_wr
    port map (
      CLK => CLK, RESET => RESET, START => WR_START, BASE => R_MADDR,
      FLUSH => WR_FLUSH, WE => WR_WE, DI => BUF_DI, HOLD => WR_HOLD,
      IDLE => WR_IDLE, NWORD => WR_NWORD,
      DMA_REQ => DMA_REQ, DMA_WE => DMA_WE, DMA_BUSY => DMA_BUSY,
      DMA_ACK_W => DMA_ACK_W, DMA_ADDR => DMA_ADDR, DMA_BE => DMA_BE,
      DMA_DI => DMA_DI);

  GO <= R_SEL and RB_MREQ.we and not R_ACTIVE
          when RB_MREQ.addr(3 downto 0) = "0000" else '0';
  CTL_OP <= "101" when RB_MREQ.din(2 downto 0) = "110" else
            RB_MREQ.din(2 downto 0);
  WR_START <= GO;
  WR_WE <= BUF_WE and R_DMAEN;
  CTL_HOLD <= WR_HOLD and R_DMAEN;
  WR_FLUSH <= '1' when R_ACTIVE = '1' and R_ARM = '0' and BUSY = '0' and
                       R_DMAEN = '1' and R_FLUSHED = '0' else '0';

  proc_buf: process (CLK)
  begin
    if rising_edge(CLK) then
      if BUF_WE = '1' then
        BUF(to_integer(unsigned(BUF_ADDR))) <= BUF_DI;
      end if;
    end if;
  end process proc_buf;

  proc_regs: process (CLK)
  begin
    if rising_edge(CLK) then
      R_CD <= R_CD(0) & I_SD_CD;
      if RESET = '1' then
        R_LBA <= (others => '0');
        R_BADDR <= (others => '0');
        R_FDIV <= x"02";
        R_ACTIVE <= '0';
        R_ARM <= '0';
        R_DMAEN <= '0';
      else
        -- operation sequencing: sdspi_ctl raises BUSY one cycle after GO;
        -- with DMA, the held word is flushed and the FIFO drained at the end
        R_ARM <= '0';
        if GO = '1' then
          R_ACTIVE <= '1';
          R_ARM <= '1';
          R_FLUSHED <= '0';
          R_CYC <= (others => '0');
          if RB_MREQ.din(2 downto 0) = "101" then
            R_DMAEN <= '1';
          else
            R_DMAEN <= '0';
          end if;
        elsif R_ACTIVE = '1' then
          R_CYC <= R_CYC + 1;
          if WR_FLUSH = '1' then
            R_FLUSHED <= '1';
          end if;
          if R_ARM = '0' and BUSY = '0' and
             (R_DMAEN = '0' or (R_FLUSHED = '1' and WR_IDLE = '1')) then
            R_ACTIVE <= '0';
          end if;
        end if;

        if R_SEL = '1' then
          if RB_MREQ.we = '1' then
            case RB_MREQ.addr(3 downto 0) is
              when "0001" => R_LBA(15 downto 0) <= RB_MREQ.din;
              when "0010" => R_LBA(31 downto 16) <= RB_MREQ.din;
              when "0011" => R_BADDR <= unsigned(RB_MREQ.din(7 downto 0));
              when "0110" => R_FDIV <= RB_MREQ.din(7 downto 0);
              when "1000" => R_NBLK <= RB_MREQ.din;
              when "1001" => R_MADDR(15 downto 0) <= RB_MREQ.din;
              when "1010" => R_MADDR(21 downto 16) <= RB_MREQ.din(5 downto 0);
              when others => null;
            end case;
          elsif RB_MREQ.re = '1' and RB_MREQ.addr(3 downto 0) = "0100" then
            R_BADDR <= R_BADDR + 1;
          end if;
        end if;
      end if;
    end if;
  end process proc_regs;

  proc_rbus: process (R_SEL, RB_MREQ, R_ACTIVE, INITOK, V2, HC, ERR, R1,
                      TOKEN, RESP, R_LBA, R_BADDR, R_FDIV, R_CD, BUF, R_NBLK,
                      R_MADDR, R_CYC, WR_NWORD)
    variable idout : slv16 := (others => '0');
  begin
    idout := (others => '0');
    if R_SEL = '1' and RB_MREQ.re = '1' then
      case RB_MREQ.addr(3 downto 0) is
        when "0000" =>
          idout(0) := R_ACTIVE;
          idout(1) := INITOK;
          idout(2) := V2;
          idout(3) := HC;
          idout(4) := R_CD(1);
          idout(15 downto 8) := ERR;
        when "0001" => idout := R_LBA(15 downto 0);
        when "0010" => idout := R_LBA(31 downto 16);
        when "0011" => idout(7 downto 0) := slv(R_BADDR);
        when "0100" => idout := BUF(to_integer(R_BADDR));
        when "0101" => idout := TOKEN & R1;
        when "0110" => idout(7 downto 0) := R_FDIV;
        when "0111" => idout := RESP(31 downto 16);
        when "1000" => idout := R_NBLK;
        when "1001" => idout := R_MADDR(15 downto 0);
        when "1010" => idout(5 downto 0) := R_MADDR(21 downto 16);
        when "1011" => idout := slv(R_CYC(15 downto 0));
        when "1100" => idout := slv(R_CYC(31 downto 16));
        when "1101" => idout := WR_NWORD;
        when others => null;
      end case;
    end if;
    RB_SRES.dout <= idout;
    RB_SRES.ack <= R_SEL and (RB_MREQ.re or RB_MREQ.we);
    RB_SRES.err <= '0';
    RB_SRES.busy <= '0';
  end process proc_rbus;

end syn;
