-- SPDX-License-Identifier: GPL-3.0-or-later
-- Native RK05: three-unit LBA mapping, read/write DMA, register advance,
-- interrupt and invalid unit. Uses the SPI card model, not a PC backend.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.slvtypes.all;
use work.iblib.all;

entity tb_ibdr_rk05n is
end tb_ibdr_rk05n;

architecture sim of tb_ibdr_rk05n is
  type mem_type is array (0 to 16383) of slv32;
  signal MEM : mem_type := (others => (others => '0'));
  signal CLK : slbit := '0';
  signal RESET : slbit := '1';
  signal BRESET : slbit := '0';
  signal CE_MSEC : slbit := '0';
  signal DONE : boolean := false;
  signal IB_MREQ : ib_mreq_type := ib_mreq_init;
  signal IB_SRES : ib_sres_type := ib_sres_init;
  signal EI_REQ : slbit := '0';
  signal EI_ACK : slbit := '0';
  signal CS_N, SCLK, MOSI, MISO : slbit := '1';
  signal DMA_REQ, DMA_WE, DMA_BUSY : slbit := '0';
  signal DMA_ACK_R, DMA_ACK_W : slbit := '0';
  signal DMA_ADDR : slv20 := (others => '0');
  signal DMA_BE : slv4 := (others => '0');
  signal DMA_DI, DMA_DO : slv32 := (others => '0');
  signal SDERR : slv8 := (others => '0');
  signal XCOUNT : slv16 := (others => '0');

  constant rkds : natural := 8#177400#;
  constant rker : natural := 8#177402#;
  constant rkcs : natural := 8#177404#;
  constant rkwc : natural := 8#177406#;
  constant rkba : natural := 8#177410#;
  constant rkda : natural := 8#177412#;
begin
  CLK <= not CLK after 6666 ps when not DONE;

  proc_ce: process (CLK)
    variable count : natural := 0;
  begin
    if rising_edge(CLK) then
      CE_MSEC <= '0';
      count := count + 1;
      if count = 1000 then count := 0; CE_MSEC <= '1'; end if;
    end if;
  end process;

  DUT: entity work.ibdr_rk05n
    port map (
      CLK => CLK, RESET => RESET, CE_MSEC => CE_MSEC, BRESET => BRESET,
      IB_MREQ => IB_MREQ, IB_SRES => IB_SRES,
      EI_REQ => EI_REQ, EI_ACK => EI_ACK,
      O_SD_CS_N => CS_N, O_SD_SCLK => SCLK, O_SD_MOSI => MOSI,
      I_SD_MISO => MISO, I_SD_CD => '0',
      DMA_REQ => DMA_REQ, DMA_WE => DMA_WE, DMA_BUSY => DMA_BUSY,
      DMA_ACK_R => DMA_ACK_R, DMA_ACK_W => DMA_ACK_W,
      DMA_ADDR => DMA_ADDR, DMA_BE => DMA_BE, DMA_DI => DMA_DI,
      DMA_DO => DMA_DO, SDERR => SDERR, XCOUNT => XCOUNT);

  CARD: entity work.sdcard_spi_model
    port map (MODE => 1, CS_N => CS_N, SCLK => SCLK,
              MOSI => MOSI, MISO => MISO);

  proc_dma: process (CLK)
    variable pending : boolean := false;
    variable writing : slbit := '0';
    variable address : natural := 0;
    variable byte_en : slv4;
    variable value : slv32;
  begin
    if rising_edge(CLK) then
      DMA_ACK_R <= '0';
      DMA_ACK_W <= '0';
      if pending then
        if writing = '1' then
          for lane in 0 to 3 loop
            if byte_en(lane) = '1' then
              MEM(address)(8*lane+7 downto 8*lane) <=
                value(8*lane+7 downto 8*lane);
            end if;
          end loop;
          DMA_ACK_W <= '1';
        else
          DMA_DO <= MEM(address);
          DMA_ACK_R <= '1';
        end if;
        DMA_BUSY <= '0';
        pending := false;
      elsif DMA_REQ = '1' and DMA_BUSY = '0' then
        address := to_integer(unsigned(DMA_ADDR));
        assert address <= MEM'high report "DMA out of test memory"
          severity failure;
        writing := DMA_WE;
        byte_en := DMA_BE;
        value := DMA_DI;
        pending := true;
        DMA_BUSY <= '1';
      end if;
    end if;
  end process;

  proc_stim: process
    procedure ib_write(constant addr : natural; constant data : natural) is
    begin
      wait until falling_edge(CLK);
      IB_MREQ.aval <= '1';
      IB_MREQ.addr <= slv(to_unsigned(addr mod 8192, 13)(12 downto 1));
      IB_MREQ.din <= slv(to_unsigned(data, 16));
      IB_MREQ.be0 <= '1'; IB_MREQ.be1 <= '1';
      wait until falling_edge(CLK);
      IB_MREQ.we <= '1';
      wait until rising_edge(CLK);
      assert IB_SRES.ack = '1' report "ibus write not acked"
        severity failure;
      wait until falling_edge(CLK);
      IB_MREQ <= ib_mreq_init;
    end procedure;

    procedure ib_read(constant addr : natural; variable data : out slv16) is
    begin
      wait until falling_edge(CLK);
      IB_MREQ.aval <= '1';
      IB_MREQ.addr <= slv(to_unsigned(addr mod 8192, 13)(12 downto 1));
      wait until falling_edge(CLK);
      IB_MREQ.re <= '1';
      wait until rising_edge(CLK);
      assert IB_SRES.ack = '1' report "ibus read not acked"
        severity failure;
      data := IB_SRES.dout;
      wait until falling_edge(CLK);
      IB_MREQ <= ib_mreq_init;
    end procedure;

    procedure wait_rdy is
      variable d : slv16;
    begin
      for i in 0 to 300000 loop
        ib_read(rkcs, d);
        exit when d(7) = '1';
        for k in 1 to 20 loop wait until rising_edge(CLK); end loop;
      end loop;
      assert d(7) = '1' report "RK11 not ready" severity failure;
    end procedure;

    procedure expect_reg(constant addr : natural; constant value : natural) is
      variable d : slv16;
    begin
      ib_read(addr, d);
      assert d = slv(to_unsigned(value, 16))
        report "register mismatch at " & integer'image(addr) &
               " got " & integer'image(to_integer(unsigned(d))) &
               " expected " & integer'image(value) severity failure;
    end procedure;

    function blkbyte(l : natural; i : natural) return slv8 is
      variable v : slv8;
    begin
      v := slv(to_unsigned((l * 37 + i) mod 256, 8));
      if i >= 256 then v := v xor x"55"; end if;
      return v;
    end function;

    impure function memword(ba : natural) return slv16 is
    begin
      if (ba / 2) mod 2 = 0 then
        return MEM(ba / 4)(15 downto 0);
      end if;
      return MEM(ba / 4)(31 downto 16);
    end function;

    procedure check_block(constant lba : natural; constant ba : natural) is
    begin
      for i in 0 to 255 loop
        assert memword(ba + i*2) = blkbyte(lba, i*2+1) & blkbyte(lba, i*2)
          report "read mismatch at word " & integer'image(i) &
                 " LBA " & integer'image(lba) severity failure;
      end loop;
    end procedure;

    variable d : slv16;
  begin
    wait for 100 ns;
    wait until falling_edge(CLK);
    RESET <= '0';
    for i in 1 to 5 loop wait until rising_edge(CLK); end loop;
    ib_read(rkds, d);
    assert d(7) = '1' report "RK0 not ready" severity failure;

    -- RK1, first sector -> card LBA 4872. Read 256 words into 02000.
    ib_write(rkda, 8#020000#);
    ib_write(rkba, 8#002000#);
    ib_write(rkwc, 8#177400#);       -- -256 words
    ib_write(rkcs, 8#000105#);       -- READ + IE + GO
    wait_rdy;
    assert EI_REQ = '1' report "missing READ interrupt" severity failure;
    expect_reg(rker, 0);
    expect_reg(rkwc, 0);
    expect_reg(rkba, 8#003000#);
    expect_reg(rkda, 8#020001#);
    check_block(4872, 8#002000#);
    wait until falling_edge(CLK); EI_ACK <= '1';
    wait until falling_edge(CLK); EI_ACK <= '0';

    -- One full-sector WRITE, then read it back elsewhere.
    ib_write(rkda, 8#040000#);      -- RK2 sector 0
    ib_write(rkba, 8#002000#);
    ib_write(rkwc, 8#177400#);
    ib_write(rkcs, 8#000003#);      -- WRITE + GO
    wait_rdy;
    expect_reg(rker, 0);
    ib_write(rkda, 8#040000#);
    ib_write(rkba, 8#004000#);
    ib_write(rkwc, 8#177400#);
    ib_write(rkcs, 8#000005#);      -- READ + GO
    wait_rdy;
    for i in 0 to 255 loop
      assert memword(8#004000# + 2*i) = memword(8#002000# + 2*i)
        report "WRITE/READ mismatch" severity failure;
    end loop;

    -- Crossing sector 11 changes surface 0 to surface 1.
    ib_write(rkda, 8#000013#);
    ib_write(rkba, 8#006000#);
    ib_write(rkwc, 8#177000#);      -- -512 words
    ib_write(rkcs, 8#000005#);
    wait_rdy;
    expect_reg(rkda, 8#000021#);
    check_block(11, 8#006000#);
    check_block(12, 8#007000#);

    ib_write(rkda, 8#060000#);      -- absent RK3
    ib_write(rkwc, 8#177400#);
    ib_write(rkcs, 8#000005#);
    wait_rdy;
    ib_read(rker, d);
    assert d(7) = '1' report "missing nonexistent-drive error"
      severity failure;
    assert XCOUNT = x"0005" report "completion count" severity failure;
    report "tb_ibdr_rk05n: PASS";
    DONE <= true;
    wait;
  end process;
end sim;
