-- SPDX-License-Identifier: GPL-3.0-or-later
-- sdspi_rbus against sdcard_spi_model: init, CID, block reads, SDSC byte
-- addressing, CRC error, error token, missing card, SPI clock limits.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;
use work.rblib.all;

entity tb_sdspi is
end tb_sdspi;

architecture sim of tb_sdspi is
  signal CLK : slbit := '0';
  signal RESET : slbit := '1';
  signal CE_MSEC : slbit := '0';
  signal STOP_CLOCK : boolean := false;
  signal RB_MREQ : rb_mreq_type := rb_mreq_init;
  signal RB_SRES : rb_sres_type := rb_sres_init;
  signal CS_N : slbit := '1';
  signal SCLK : slbit := '0';
  signal MOSI : slbit := '1';
  signal MISO : slbit := '1';
  signal MODE : natural := 1;
  signal MIN_SLOW_NS : natural := 1000000;  -- shortest SCLK phase in init
  signal MIN_FAST_NS : natural := 1000000;  -- shortest SCLK phase after init
  signal FASTPHASE : boolean := false;
begin
  CLK <= not CLK after 6666 ps when not STOP_CLOCK else '0'; -- 75 MHz

  proc_msec: process (CLK)                  -- fast "ms" tick for the TB
    variable cnt : natural := 0;
  begin
    if rising_edge(CLK) then
      CE_MSEC <= '0';
      cnt := cnt + 1;
      if cnt = 1000 then
        cnt := 0;
        CE_MSEC <= '1';
      end if;
    end if;
  end process proc_msec;

  DUT: entity work.sdspi_rbus
    port map (
      CLK => CLK, RESET => RESET, CE_MSEC => CE_MSEC,
      RB_MREQ => RB_MREQ, RB_SRES => RB_SRES,
      O_SD_CS_N => CS_N, O_SD_SCLK => SCLK, O_SD_MOSI => MOSI,
      I_SD_MISO => MISO, I_SD_CD => '0',
      DMA_REQ => open, DMA_WE => open, DMA_BUSY => '1', DMA_ACK_W => '0',
      DMA_ADDR => open, DMA_BE => open, DMA_DI => open);

  CARD: entity work.sdcard_spi_model
    port map (MODE => MODE, CS_N => CS_N, SCLK => SCLK, MOSI => MOSI,
              MISO => MISO);

  proc_sclk: process (SCLK)
    variable t_last : time := 0 ns;
    variable ph : natural;
  begin
    if t_last /= 0 ns then
      ph := (now - t_last) / 1 ns;
      if FASTPHASE then
        if ph < MIN_FAST_NS then MIN_FAST_NS <= ph; end if;
      else
        if ph < MIN_SLOW_NS then MIN_SLOW_NS <= ph; end if;
      end if;
    end if;
    t_last := now;
  end process proc_sclk;

  proc_stim: process
    procedure rb_write(constant addr : in slv16; constant data : in slv16) is
    begin
      wait until falling_edge(CLK);
      RB_MREQ.aval <= '1';
      RB_MREQ.addr <= addr;
      RB_MREQ.din <= data;
      wait until falling_edge(CLK);
      RB_MREQ.we <= '1';
      wait until falling_edge(CLK);
      assert RB_SRES.ack = '1' report "rbus write not acked" severity failure;
      RB_MREQ <= rb_mreq_init;
      wait until falling_edge(CLK);
    end procedure rb_write;

    procedure rb_read(constant addr : in slv16; variable data : out slv16) is
    begin
      wait until falling_edge(CLK);
      RB_MREQ.aval <= '1';
      RB_MREQ.addr <= addr;
      wait until falling_edge(CLK);
      RB_MREQ.re <= '1';
      wait until rising_edge(CLK);      -- master takes data at this edge
      assert RB_SRES.ack = '1' report "rbus read not acked" severity failure;
      data := RB_SRES.dout;
      wait until falling_edge(CLK);
      RB_MREQ <= rb_mreq_init;
      wait until falling_edge(CLK);
    end procedure rb_read;

    procedure run_op(constant op : in natural; variable stat : out slv16) is
      variable s : slv16;
    begin
      rb_write(x"fd10", slv(to_unsigned(op, 16)));
      loop
        for i in 1 to 200 loop
          wait until rising_edge(CLK);
        end loop;
        rb_read(x"fd10", s);
        exit when s(0) = '0';
      end loop;
      stat := s;
    end procedure run_op;

    function blkbyte(l : natural; i : natural) return slv8 is
      variable v : slv8;
    begin
      v := slv(to_unsigned((l * 37 + i) mod 256, 8));
      if i >= 256 then
        v := v xor x"55";
      end if;
      return v;
    end function blkbyte;

    procedure check_block(constant l : in natural) is
      variable w : slv16;
    begin
      rb_write(x"fd13", x"0000");
      for i in 0 to 255 loop
        rb_read(x"fd14", w);
        assert w = blkbyte(l, 2*i+1) & blkbyte(l, 2*i)
          report "block " & integer'image(l) & " word " & integer'image(i) &
            " wrong" severity failure;
      end loop;
    end procedure check_block;

    procedure read_block(constant l : in natural) is
      variable s : slv16;
      variable lv : slv32;
    begin
      lv := slv(to_unsigned(l, 32));
      rb_write(x"fd11", lv(15 downto 0));
      rb_write(x"fd12", lv(31 downto 16));
      run_op(4, s);
      assert s(15 downto 8) = x"00"
        report "block read error " & integer'image(to_integer(unsigned(
          s(15 downto 8)))) severity failure;
      check_block(l);
    end procedure read_block;

    variable s : slv16;
    variable w : slv16;
  begin
    wait for 50 ns;
    wait until falling_edge(CLK);
    RESET <= '0';

    -- read before init is refused
    run_op(4, s);
    assert s(15 downto 8) = x"09" report "read before init accepted"
      severity failure;

    -- SDHC v2
    MODE <= 1;
    run_op(1, s);
    assert s(15 downto 8) = x"00" and s(3 downto 1) = "111"
      report "SDHC init failed" severity failure;
    FASTPHASE <= true;
    run_op(2, s);
    assert s(15 downto 8) = x"00" report "CID read failed" severity failure;
    rb_write(x"fd13", x"0000");
    for i in 0 to 7 loop
      rb_read(x"fd14", w);
      assert w = slv(to_unsigned(16#10# + 2*i + 1, 8)) &
                 slv(to_unsigned(16#10# + 2*i, 8))
        report "CID word " & integer'image(i) & " = " &
          integer'image(to_integer(unsigned(w))) severity failure;
    end loop;
    read_block(0);
    read_block(1007999);                -- last RP07 block, > 16 bit
    assert MIN_SLOW_NS >= 1250
      report "init SCLK faster than 400 kHz" severity failure;
    report "init SCLK phase >= " & integer'image(MIN_SLOW_NS) & " ns"
      severity note;
    assert MIN_FAST_NS >= 39 and MIN_FAST_NS <= 41
      report "fast SCLK phase not 40 ns: " & integer'image(MIN_FAST_NS)
      severity failure;

    -- SDSC v1, byte addressing
    FASTPHASE <= false;
    MODE <= 2;
    run_op(1, s);
    assert s(15 downto 8) = x"00" and s(3 downto 1) = "001"
      report "SDSC init failed" severity failure;
    FASTPHASE <= true;                  -- later inits are not measured
    read_block(4660);

    -- data CRC error
    MODE <= 3;
    run_op(1, s);
    run_op(4, s);
    assert s(15 downto 8) = x"08" report "CRC error not detected"
      severity failure;

    -- error token
    MODE <= 4;
    run_op(1, s);
    run_op(4, s);
    assert s(15 downto 8) = x"07" report "error token not detected"
      severity failure;
    rb_read(x"fd15", w);
    assert w(15 downto 8) = x"08" report "error token value wrong"
      severity failure;

    -- no card
    MODE <= 0;
    run_op(1, s);
    assert s(15 downto 8) = x"01" and s(1) = '0'
      report "missing card not detected" severity failure;

    assert MIN_SLOW_NS >= 1250
      report "SDSC init SCLK faster than 400 kHz" severity failure;
    report "tb_sdspi completed, init SCLK phase >= " &
      integer'image(MIN_SLOW_NS) & " ns, fast phase " &
      integer'image(MIN_FAST_NS) & " ns" severity note;
    STOP_CLOCK <= true;
    wait;
  end process proc_stim;

  proc_timeout: process
  begin
    wait for 100 ms;
    assert STOP_CLOCK report "tb_sdspi timed out" severity failure;
    wait;
  end process proc_timeout;
end sim;
