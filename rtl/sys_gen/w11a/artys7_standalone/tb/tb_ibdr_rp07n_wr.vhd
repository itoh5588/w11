-- SPDX-License-Identifier: GPL-3.0-or-later
-- ibdr_rp07n with WRITE_ENABLE through the ibus, with sdcard_spi_model and
-- a DMA memory preset with a known pattern: WRITE with interrupt and
-- register update, read back, partial count with zero fill, odd word start,
-- AOE, NEM, SD write rejects (CRC, write error) and BRESET during a write.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;
use work.iblib.all;

entity tb_ibdr_rp07n_wr is
end tb_ibdr_rp07n_wr;

architecture sim of tb_ibdr_rp07n_wr is
  constant memlimit : natural := 16#8000#;        -- 32 kB for the NEM test
  type mem_type is array (0 to memlimit/4 - 1) of slv32;
  -- 16-bit word at byte address ba: (ba/2)*7 + 0x1234
  function patword(ba : natural) return slv16 is
  begin
    return slv(to_unsigned(((ba / 2) * 7 + 16#1234#) mod 65536, 16));
  end function patword;
  function mem_preset return mem_type is
    variable m : mem_type;
  begin
    for i in m'range loop
      m(i) := patword(4*i + 2) & patword(4*i);
    end loop;
    return m;
  end function mem_preset;
  signal MEM : mem_type := mem_preset;
  signal CLK : slbit := '0';
  signal RESET : slbit := '1';
  signal CE_USEC : slbit := '0';
  signal CE_MSEC : slbit := '0';
  signal ITIMER : slbit := '0';
  signal BRESET : slbit := '0';
  signal STOP_CLOCK : boolean := false;
  signal IB_MREQ : ib_mreq_type := ib_mreq_init;
  signal IB_SRES : ib_sres_type := ib_sres_init;
  signal EI_REQ : slbit := '0';
  signal EI_ACK : slbit := '0';
  signal CS_N : slbit := '1';
  signal SCLK : slbit := '0';
  signal MOSI : slbit := '1';
  signal MISO : slbit := '1';
  signal CD : slbit := '0';
  signal MODE : natural := 1;
  signal DMA_REQ : slbit := '0';
  signal DMA_WE : slbit := '0';
  signal DMA_BUSY : slbit := '0';
  signal DMA_ACK_W : slbit := '0';
  signal DMA_ADDR : slv20 := (others => '0');
  signal DMA_BE : slv4 := (others => '0');
  signal DMA_DI : slv32 := (others => '0');
  signal DMA_DO : slv32 := (others => '0');
  signal DMA_ACK_R : slbit := '0';
  signal NWRITE : natural := 0;
  signal NREAD : natural := 0;
  signal SDERR : slv8 := (others => '0');
  signal XCOUNT : slv16 := (others => '0');

  constant rpcs1 : natural := 8#176700#;
  constant rpwc  : natural := 8#176702#;
  constant rpba  : natural := 8#176704#;
  constant rpda  : natural := 8#176706#;
  constant rpcs2 : natural := 8#176710#;
  constant rpds  : natural := 8#176712#;
  constant rper1 : natural := 8#176714#;
  constant rpas  : natural := 8#176716#;
  constant rpdt  : natural := 8#176726#;
  constant rpsn  : natural := 8#176730#;
  constant rpdc  : natural := 8#176734#;
  constant rpbae : natural := 8#176750#;
begin
  CLK <= not CLK after 6666 ps when not STOP_CLOCK else '0';

  proc_ce: process (CLK)
    variable cu : natural := 0;
    variable cm : natural := 0;
    variable ct : natural := 0;
  begin
    if rising_edge(CLK) then
      CE_USEC <= '0';
      CE_MSEC <= '0';
      ITIMER <= '0';
      cu := cu + 1;
      if cu = 75 then cu := 0; CE_USEC <= '1'; end if;
      cm := cm + 1;
      if cm = 1000 then cm := 0; CE_MSEC <= '1'; end if;  -- fast "ms"
      ct := ct + 1;
      if ct = 50 then ct := 0; ITIMER <= '1'; end if;
    end if;
  end process proc_ce;

  DUT: entity work.ibdr_rp07n
    generic map (MEMLIMIT => memlimit, WRITE_ENABLE => true)
    port map (
      CLK => CLK, RESET => RESET, CE_USEC => CE_USEC, CE_MSEC => CE_MSEC,
      BRESET => BRESET, ITIMER => ITIMER, IB_MREQ => IB_MREQ,
      IB_SRES => IB_SRES, EI_REQ => EI_REQ, EI_ACK => EI_ACK,
      O_SD_CS_N => CS_N, O_SD_SCLK => SCLK, O_SD_MOSI => MOSI,
      I_SD_MISO => MISO, I_SD_CD => CD,
      DMA_REQ => DMA_REQ, DMA_WE => DMA_WE, DMA_BUSY => DMA_BUSY,
      DMA_ACK_R => DMA_ACK_R, DMA_ACK_W => DMA_ACK_W, DMA_ADDR => DMA_ADDR,
      DMA_BE => DMA_BE, DMA_DI => DMA_DI, DMA_DO => DMA_DO,
      SDERR => SDERR, XCOUNT => XCOUNT);

  CARD: entity work.sdcard_spi_model
    port map (MODE => MODE, CS_N => CS_N, SCLK => SCLK, MOSI => MOSI,
              MISO => MISO);

  proc_mem: process (CLK)
    variable lfsr : slv8 := x"5a";
    variable wait_cnt : natural := 0;
    variable busy : boolean := false;
    variable a : natural;
    variable be : slv4;
    variable d : slv32;
    variable we : slbit;
  begin
    if rising_edge(CLK) then
      DMA_ACK_W <= '0';
      DMA_ACK_R <= '0';
      if not busy then
        if DMA_REQ = '1' and DMA_BUSY = '0' then
          we := DMA_WE;
          a := to_integer(unsigned(DMA_ADDR));
          assert a <= MEM'high report "DMA beyond memory limit"
            severity failure;
          be := DMA_BE;
          d := DMA_DI;
          busy := true;
          DMA_BUSY <= '1';
          lfsr := lfsr(6 downto 0) & (lfsr(7) xor lfsr(5) xor lfsr(4) xor
                                      lfsr(3));
          wait_cnt := to_integer(unsigned(lfsr(5 downto 0)));
        end if;
      elsif wait_cnt = 0 then
        if we = '1' then
          for lane in 0 to 3 loop
            if be(lane) = '1' then
              MEM(a)(8*lane+7 downto 8*lane) <= d(8*lane+7 downto 8*lane);
            end if;
          end loop;
          NWRITE <= NWRITE + 1;
          DMA_ACK_W <= '1';
        else
          DMA_DO <= MEM(a);
          NREAD <= NREAD + 1;
          DMA_ACK_R <= '1';
        end if;
        DMA_BUSY <= '0';
        busy := false;
      else
        wait_cnt := wait_cnt - 1;
      end if;
    end if;
  end process proc_mem;

  proc_stim: process
    procedure ib_write(constant addr : in natural; constant data : in natural;
                       constant be : in slv2 := "11") is
    begin
      wait until falling_edge(CLK);
      IB_MREQ.aval <= '1';
      IB_MREQ.addr <= slv(to_unsigned(addr mod 8192, 13)(12 downto 1));
      IB_MREQ.din <= slv(to_unsigned(data, 16));
      IB_MREQ.be0 <= be(0);
      IB_MREQ.be1 <= be(1);
      wait until falling_edge(CLK);
      IB_MREQ.we <= '1';
      wait until rising_edge(CLK);
      assert IB_SRES.ack = '1' and IB_SRES.busy = '0'
        report "ibus write not acked" severity failure;
      wait until falling_edge(CLK);
      IB_MREQ <= ib_mreq_init;
    end procedure ib_write;

    procedure ib_read(constant addr : in natural; variable data : out slv16)
    is
    begin
      wait until falling_edge(CLK);
      IB_MREQ.aval <= '1';
      IB_MREQ.addr <= slv(to_unsigned(addr mod 8192, 13)(12 downto 1));
      IB_MREQ.be0 <= '1';
      IB_MREQ.be1 <= '1';
      wait until falling_edge(CLK);
      IB_MREQ.re <= '1';
      wait until rising_edge(CLK);
      assert IB_SRES.ack = '1' and IB_SRES.busy = '0'
        report "ibus read not acked" severity failure;
      data := IB_SRES.dout;
      wait until falling_edge(CLK);
      IB_MREQ <= ib_mreq_init;
    end procedure ib_read;

    procedure expect(constant addr : in natural; constant val : in natural;
                     constant what : in string) is
      variable d : slv16;
    begin
      ib_read(addr, d);
      assert d = slv(to_unsigned(val, 16))
        report what & ": got " & integer'image(to_integer(unsigned(d))) &
          " expected " & integer'image(val) severity failure;
    end procedure expect;

    procedure wait_rdy is
      variable d : slv16;
    begin
      for i in 0 to 100000 loop
        ib_read(rpcs1, d);
        exit when d(7) = '1';
        for k in 1 to 50 loop wait until rising_edge(CLK); end loop;
      end loop;
      assert d(7) = '1' report "RDY not set" severity failure;
    end procedure wait_rdy;

    procedure int_ack is                -- CPU takes the interrupt
    begin
      wait until falling_edge(CLK);
      EI_ACK <= '1';
      wait until falling_edge(CLK);
      EI_ACK <= '0';
    end procedure int_ack;

    function blkbyte(l : natural; i : natural) return slv8 is
      variable v : slv8;
    begin
      v := slv(to_unsigned((l * 37 + i) mod 256, 8));
      if i >= 256 then
        v := v xor x"55";
      end if;
      return v;
    end function blkbyte;

    impure function memword(ba : natural) return slv16 is
    begin
      if (ba / 2) mod 2 = 0 then
        return MEM(ba / 4)(15 downto 0);
      end if;
      return MEM(ba / 4)(31 downto 16);
    end function memword;

    procedure check_mem(constant lba : in natural; constant nw : in natural;
                        constant ba : in natural) is
      variable bl, bi : natural;
    begin
      for i in 0 to nw - 1 loop
        bl := lba + i / 256;
        bi := 2 * (i mod 256);
        assert memword(ba + 2*i) = blkbyte(bl, bi+1) & blkbyte(bl, bi)
          report "memory word " & integer'image(i) & " of transfer at " &
            integer'image(ba) & " lba " & integer'image(lba) & " is " &
            integer'image(to_integer(unsigned(slv16'(memword(ba + 2*i))))) &
            " expected " & integer'image(to_integer(unsigned(slv16'(
            blkbyte(bl, bi+1) & blkbyte(bl, bi))))) severity failure;
      end loop;
      assert memword(ba - 2) = x"aaaa"
        report "word before the transfer changed" severity failure;
      if ba + 2*nw < memlimit then
        assert memword(ba + 2*nw) = x"aaaa"
          report "word after the transfer at " & integer'image(ba) &
            " changed to " & integer'image(to_integer(unsigned(
            memword(ba + 2*nw)))) severity failure;
      end if;
    end procedure check_mem;

    -- READ/WRITE: C,T,S, word count, byte address; IE set
    procedure do_xfer(constant func, c, t, s, nw, ba : in natural) is
    begin
      ib_write(rpcs2, 0);
      ib_write(rpdc, c);
      ib_write(rpda, t * 256 + s);
      ib_write(rpba, ba mod 65536);
      ib_write(rpbae, ba / 65536);
      ib_write(rpwc, (65536 - nw) mod 65536);
      ib_write(rpcs1, 8#100# + func + ((ba / 65536) mod 4) * 256);
    end procedure do_xfer;

    procedure wait_done is
    begin
      for i in 0 to 2000000 loop
        wait until rising_edge(CLK);
        exit when EI_REQ = '1';
      end loop;
      assert EI_REQ = '1' report "no interrupt" severity failure;
      int_ack;
    end procedure wait_done;

    -- memory at rba holds nw words written from wba, then zeros up to nz
    procedure check_back(constant rba, wba, nw, nz : in natural) is
    begin
      for i in 0 to nz - 1 loop
        if i < nw then
          assert memword(rba + 2*i) = patword(wba + 2*i)
            report "read back word " & integer'image(i) & " wrong"
            severity failure;
        else
          assert memword(rba + 2*i) = x"0000"
            report "zero fill word " & integer'image(i) & " wrong"
            severity failure;
        end if;
      end loop;
    end procedure check_back;

    procedure reinsert(constant m : in natural) is
    begin
      CD <= '1';
      MODE <= 0;
      for i in 1 to 10 loop wait until rising_edge(CLK); end loop;
      CD <= '0';
      MODE <= m;
      for i in 1 to 10 loop wait until rising_edge(CLK); end loop;
    end procedure reinsert;

    constant f_read : natural := 8#071#;
    constant f_write : natural := 8#061#;
    variable d : slv16;
    variable nr0 : natural;
  begin
    wait for 50 ns;
    wait until falling_edge(CLK);
    RESET <= '0';
    for i in 1 to 10 loop wait until rising_edge(CLK); end loop;

    expect(rpds, 8#010600#, "DS: MOL DPR DRY, no WRL");

    -- WRITE 2 blocks from 0x1000 to C0 T1 S48 (lba 98), crossing sectors
    do_xfer(f_write, 0, 1, 48, 512, 16#1000#);
    wait_done;
    expect(rpcs1, 8#004260#, "CS1 after WRITE");
    expect(rper1, 0, "ER1 after WRITE");
    expect(rpwc, 0, "WC after WRITE");
    expect(rpba, 16#1400#, "BA after WRITE");
    expect(rpda, 2 * 256 + 0, "DA after WRITE");
    expect(rpdc, 0, "DC after WRITE");
    do_xfer(f_read, 0, 1, 48, 512, 16#4000#);
    wait_done;
    check_back(16#4000#, 16#1000#, 512, 512);

    -- partial count, odd word start: 300 words from 0x2002 to lba 200
    do_xfer(f_write, 0, 4, 0, 300, 16#2002#);
    wait_done;
    expect(rpwc, 0, "WC partial WRITE");
    expect(rpba, 16#2002# + 600, "BA partial WRITE");
    expect(rpda, 4 * 256 + 2, "DA partial WRITE");
    do_xfer(f_read, 0, 4, 0, 512, 16#5000#);
    wait_done;
    check_back(16#5000#, 16#2002#, 300, 512);

    -- AOE: 512 words to the last block, 256 written
    do_xfer(f_write, 629, 31, 49, 512, 16#1000#);
    wait_done;
    expect(rpwc, 8#177400#, "WC after write AOE");
    expect(rper1, 8#001000#, "ER1 write AOE");
    ib_read(rpcs1, d);
    assert d(14) = '1' report "TRE not set after write AOE" severity failure;
    ib_write(rpcs1, 8#040011#);               -- TRE + DCLR
    do_xfer(f_read, 629, 31, 49, 256, 16#6000#);
    wait_done;
    check_back(16#6000#, 16#1000#, 256, 256);

    -- NEM: 512 words at memlimit-256 bytes, 128 words then NEM
    do_xfer(f_write, 1, 0, 0, 512, memlimit - 256);
    wait_done;
    expect(rpcs2, 8#004300#, "CS2 NEM on WRITE");
    expect(rpwc, (65536 - 512 + 128) mod 65536, "WC after write NEM");
    ib_write(rpcs1, 8#040000#, "10");
    do_xfer(f_read, 1, 0, 0, 256, 16#6000#);
    wait_done;
    check_back(16#6000#, memlimit - 256, 128, 256);

    -- SD rejects the data (CRC) and write error: UNS, TRE, ATA
    reinsert(5);
    do_xfer(f_write, 2, 0, 0, 256, 16#1000#);
    wait_done;
    expect(rper1, 8#040000#, "ER1 UNS on SD CRC reject");
    expect(rpas, 1, "ATA on SD CRC reject");
    ib_read(rpcs1, d);
    assert d(14) = '1' report "TRE not set on SD reject" severity failure;
    ib_write(rpcs1, 8#040011#);
    ib_write(rpas, 1);
    reinsert(6);
    do_xfer(f_write, 2, 0, 0, 256, 16#1000#);
    wait_done;
    expect(rper1, 8#040000#, "ER1 UNS on SD write error");
    ib_write(rpcs1, 8#040011#);
    ib_write(rpas, 1);

    -- BRESET during an 8 block write: RDY at once, the engine ends after the
    -- current block, then a READ works
    reinsert(1);
    do_xfer(f_write, 3, 0, 0, 2048, 16#0400#);
    for i in 1 to 150000 loop wait until rising_edge(CLK); end loop;
    wait until falling_edge(CLK);
    BRESET <= '1';
    wait until falling_edge(CLK);
    BRESET <= '0';
    expect(rpcs1, 8#004200#, "CS1 after BRESET");
    do_xfer(f_read, 0, 1, 48, 512, 16#7000#);
    wait_done;
    expect(rper1, 0, "ER1 read after BRESET");
    check_back(16#7000#, 16#1000#, 512, 512);

    -- BRESET while the buffer for the 2nd block is filled (DMA reads of
    -- block 1): block 0 is written, blocks 1..3 must stay untouched
    do_xfer(f_write, 1, 20, 0, 1024, 16#1000#);   -- lba 2600..2603
    nr0 := NREAD;
    for i in 0 to 2000000 loop
      wait until rising_edge(CLK);
      exit when NREAD >= nr0 + 128 + 10;        -- 128 pair reads per block
    end loop;
    wait until falling_edge(CLK);
    BRESET <= '1';
    wait until falling_edge(CLK);
    BRESET <= '0';
    for i in 1 to 200000 loop wait until rising_edge(CLK); end loop;
    do_xfer(f_read, 1, 20, 0, 1024, 16#5000#);
    wait_done;
    check_back(16#5000#, 16#1000#, 256, 256);   -- block 0 written
    for i in 256 to 1023 loop                   -- blocks 1..3 unchanged
      assert memword(16#5000# + 2*i) =
             blkbyte(2600 + i/256, 2*(i mod 256)+1) &
             blkbyte(2600 + i/256, 2*(i mod 256))
        report "block written after BRESET, word " & integer'image(i)
        severity failure;
    end loop;

    report "tb_ibdr_rp07n_wr completed, transfers " &
      integer'image(to_integer(unsigned(XCOUNT))) & ", DMA reads " &
      integer'image(NREAD) & ", DMA writes " & integer'image(NWRITE)
      severity note;
    STOP_CLOCK <= true;
    wait;
  end process proc_stim;

  proc_timeout: process
  begin
    wait for 400 ms;
    assert STOP_CLOCK report "tb_ibdr_rp07n_wr timed out" severity failure;
    wait;
  end process proc_timeout;
end sim;
