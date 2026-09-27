-- SPDX-License-Identifier: GPL-3.0-or-later
-- sdspi_rbus multi-block reads (CMD18/CMD12) to memory by DMA, against
-- sdcard_spi_model and a slow, variable-latency DMA memory model.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;
use work.rblib.all;

entity tb_sd_dma is
end tb_sd_dma;

architecture sim of tb_sd_dma is
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
  type mem_type is array (0 to 16#fff#) of slv32;  -- 16 kB
  signal MEM : mem_type := (others => x"aaaaaaaa");
  signal DMA_REQ : slbit := '0';
  signal DMA_WE : slbit := '0';
  signal DMA_BUSY : slbit := '0';
  signal DMA_ACK_W : slbit := '0';
  signal DMA_ADDR : slv20 := (others => '0');
  signal DMA_BE : slv4 := (others => '0');
  signal DMA_DI : slv32 := (others => '0');
  signal NWRITE : natural := 0;
  signal SLOWMEM : boolean := false;    -- 300..427 cycles per write
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
      DMA_REQ => DMA_REQ, DMA_WE => DMA_WE, DMA_BUSY => DMA_BUSY,
      DMA_ACK_W => DMA_ACK_W, DMA_ADDR => DMA_ADDR, DMA_BE => DMA_BE,
      DMA_DI => DMA_DI);

  -- DMA slave: takes a request while not busy, acknowledges after 1..80
  -- cycles (LFSR); slow enough to fill the writer FIFO and assert HOLD
  proc_mem: process (CLK)
    variable lfsr : slv8 := x"5a";
    variable wait_cnt : natural := 0;
    variable busy : boolean := false;
    variable a : natural;
    variable be : slv4;
    variable d : slv32;
  begin
    if rising_edge(CLK) then
      DMA_ACK_W <= '0';
      if not busy then
        if DMA_REQ = '1' and DMA_BUSY = '0' then
          assert DMA_WE = '1' report "unexpected DMA read" severity failure;
          a := to_integer(unsigned(DMA_ADDR));
          assert a <= MEM'high report "DMA address out of range"
            severity failure;
          be := DMA_BE;
          d := DMA_DI;
          busy := true;
          DMA_BUSY <= '1';
          lfsr := lfsr(6 downto 0) & (lfsr(7) xor lfsr(5) xor lfsr(4) xor
                                      lfsr(3));
          wait_cnt := to_integer(unsigned(lfsr(6 downto 0))) mod 80;
          if SLOWMEM then
            wait_cnt := 300 + to_integer(unsigned(lfsr(6 downto 0)));
          end if;
        end if;
      elsif wait_cnt = 0 then
        for lane in 0 to 3 loop
          if be(lane) = '1' then
            MEM(a)(8*lane+7 downto 8*lane) <= d(8*lane+7 downto 8*lane);
          end if;
        end loop;
        NWRITE <= NWRITE + 1;
        DMA_ACK_W <= '1';
        DMA_BUSY <= '0';
        busy := false;
      else
        wait_cnt := wait_cnt - 1;
      end if;
    end if;
  end process proc_mem;

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

    -- memory 16-bit word at byte address ba
    impure function memword(ba : natural) return slv16 is
    begin
      if (ba / 2) mod 2 = 0 then
        return MEM(ba / 4)(15 downto 0);
      end if;
      return MEM(ba / 4)(31 downto 16);
    end function memword;

    procedure mread_dma(constant l : in natural; constant nb : in natural;
                        constant ba : in natural; variable st : out slv16) is
      variable lv : slv32;
      variable bv : slv32;
      variable c : slv16;
      variable ch : slv16;
    begin
      lv := slv(to_unsigned(l, 32));
      bv := slv(to_unsigned(ba, 32));
      rb_write(x"fd11", lv(15 downto 0));
      rb_write(x"fd12", lv(31 downto 16));
      rb_write(x"fd18", slv(to_unsigned(nb, 16)));
      rb_write(x"fd19", bv(15 downto 0));
      rb_write(x"fd1a", bv(31 downto 16));
      run_op(5, st);
      rb_read(x"fd1b", c);
      rb_read(x"fd1c", ch);
      report "mread lba " & integer'image(l) & " nblk " & integer'image(nb) &
        " to " & integer'image(ba) & ": " &
        integer'image(to_integer(unsigned(slv32'(ch & c)))) & " cycles"
        severity note;
    end procedure mread_dma;

    procedure check_mem(constant l : in natural; constant nb : in natural;
                        constant ba : in natural) is
      variable bl : natural;
      variable bi : natural;
    begin
      for i in 0 to nb * 256 - 1 loop
        bl := l + i / 256;
        bi := 2 * (i mod 256);
        assert memword(ba + 2*i) = blkbyte(bl, bi+1) & blkbyte(bl, bi)
          report "memory word " & integer'image(i) & " at " &
            integer'image(ba + 2*i) & " wrong" severity failure;
      end loop;
      assert memword(ba - 2) = x"aaaa"
        report "word before the transfer was changed" severity failure;
      assert memword(ba + nb * 512) = x"aaaa"
        report "word after the transfer was changed" severity failure;
    end procedure check_mem;

    variable s : slv16;
    variable w : slv16;
  begin
    wait for 50 ns;
    wait until falling_edge(CLK);
    RESET <= '0';

    MODE <= 1;
    run_op(1, s);
    assert s(15 downto 8) = x"00" report "init failed" severity failure;

    -- multi-block read to the buffer only: buffer holds the last block
    rb_write(x"fd11", x"0064");         -- lba 100
    rb_write(x"fd12", x"0000");
    rb_write(x"fd18", x"0003");
    run_op(6, s);
    assert s(15 downto 8) = x"00" report "mread to buffer failed"
      severity failure;
    check_block(102);

    -- DMA, odd word start, near the end of an RP07 image (> 16 bit lba)
    mread_dma(1007990, 4, 16#1002#, s);
    assert s(15 downto 8) = x"00" report "mread dma failed" severity failure;
    check_mem(1007990, 4, 16#1002#);
    rb_read(x"fd1d", w);
    assert w = x"0400" report "DMA word count wrong" severity failure;

    -- DMA, aligned start
    mread_dma(7, 1, 16#2000#, s);
    assert s(15 downto 8) = x"00" report "aligned mread dma failed"
      severity failure;
    check_mem(7, 1, 16#2000#);

    -- very slow memory: the writer FIFO fills and HOLD must pause the SPI
    -- data phase, otherwise words are lost and check_mem fails
    SLOWMEM <= true;
    mread_dma(300, 2, 16#0802#, s);
    SLOWMEM <= false;
    assert s(15 downto 8) = x"00" report "slow memory mread failed"
      severity failure;
    check_mem(300, 2, 16#0802#);

    -- CRC error in a multi-block read; the card must be stopped by CMD12
    -- so the next command gets a proper answer (here: CRC error again)
    MODE <= 3;
    run_op(1, s);
    mread_dma(20, 3, 16#3000#, s);
    assert s(15 downto 8) = x"08" report "mread CRC error not detected"
      severity failure;
    run_op(4, s);
    assert s(15 downto 8) = x"08" report "command after CMD12 stop failed"
      severity failure;

    -- error token on CMD18
    MODE <= 4;
    run_op(1, s);
    mread_dma(20, 3, 16#3000#, s);
    assert s(15 downto 8) = x"07" report "mread error token not detected"
      severity failure;

    -- back to a good card: a plain read still works
    MODE <= 1;
    run_op(1, s);
    read_block(5);

    report "tb_sd_dma completed, DMA writes " & integer'image(NWRITE)
      severity note;
    STOP_CLOCK <= true;
    wait;
  end process proc_stim;

  proc_timeout: process
  begin
    wait for 100 ms;
    assert STOP_CLOCK report "tb_sd_dma timed out" severity failure;
    wait;
  end process proc_timeout;
end sim;
