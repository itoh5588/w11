-- SPDX-License-Identifier: GPL-3.0-or-later
-- ibdr_rp07n through the ibus, with sdcard_spi_model and a DMA memory:
-- reset values, NED, CS2.CLR, PACK, SEEK/ATA interrupt, RMR/DCLR, READ with
-- interrupt and register update, partial word count, AOE, IAE, WLE, ILF,
-- NEM, card removal/reinsertion and BRESET during a transfer.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;
use work.iblib.all;

entity tb_ibdr_rp07n is
end tb_ibdr_rp07n;

architecture sim of tb_ibdr_rp07n is
  constant memlimit : natural := 16#8000#;        -- 32 kB for the NEM test
  type mem_type is array (0 to memlimit/4 - 1) of slv32;
  signal MEM : mem_type := (others => x"aaaaaaaa");
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
  signal NWRITE : natural := 0;
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
    generic map (MEMLIMIT => memlimit)
    port map (
      CLK => CLK, RESET => RESET, CE_USEC => CE_USEC, CE_MSEC => CE_MSEC,
      BRESET => BRESET, ITIMER => ITIMER, IB_MREQ => IB_MREQ,
      IB_SRES => IB_SRES, EI_REQ => EI_REQ, EI_ACK => EI_ACK,
      O_SD_CS_N => CS_N, O_SD_SCLK => SCLK, O_SD_MOSI => MOSI,
      I_SD_MISO => MISO, I_SD_CD => CD,
      DMA_REQ => DMA_REQ, DMA_WE => DMA_WE, DMA_BUSY => DMA_BUSY,
      DMA_ACK_R => '0', DMA_ACK_W => DMA_ACK_W, DMA_ADDR => DMA_ADDR,
      DMA_BE => DMA_BE, DMA_DI => DMA_DI, DMA_DO => x"00000000",
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
  begin
    if rising_edge(CLK) then
      DMA_ACK_W <= '0';
      if not busy then
        if DMA_REQ = '1' and DMA_BUSY = '0' then
          assert DMA_WE = '1' report "DMA read with writes disabled"
            severity failure;
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

    -- READ: C,T,S, word count, byte address; IE set
    procedure do_read(constant c, t, s, nw, ba : in natural) is
    begin
      ib_write(rpcs2, 0);
      ib_write(rpdc, c);
      ib_write(rpda, t * 256 + s);
      ib_write(rpba, ba mod 65536);
      ib_write(rpbae, ba / 65536);
      ib_write(rpwc, (65536 - nw) mod 65536);
      ib_write(rpcs1, 8#100# + 8#071#);    -- IE + READ + GO
    end procedure do_read;

    variable d : slv16;
    variable nw0 : natural;
  begin
    wait for 50 ns;
    wait until falling_edge(CLK);
    RESET <= '0';
    for i in 1 to 10 loop wait until rising_edge(CLK); end loop;

    -- reset values
    expect(rpcs1, 8#004200#, "CS1 reset");     -- DVA, RDY
    expect(rpcs2, 8#000300#, "CS2 reset");     -- OR, IR
    expect(rpds, 8#014600#, "DS reset");       -- MOL WRL DPR DRY
    expect(rpdt, 8#020042#, "DT");
    expect(rpsn, 16#1137#, "SN");

    -- absent unit: NED, TRE, SC; CS2.CLR clears
    ib_write(rpcs2, 1);
    ib_read(rpds, d);
    expect(rpcs2, 8#010301#, "CS2 NED unit 1");
    expect(rpcs1, 8#144200#, "CS1 SC TRE");
    ib_write(rpcs2, 8#040#);
    expect(rpcs2, 8#000300#, "CS2 after CLR");

    -- PACK sets VV
    ib_write(rpcs1, 8#023#);
    expect(rpds, 8#014700#, "DS VV after PACK");

    -- SEEK: PIP, then ATA; attention interrupt with IE
    ib_write(rpdc, 100);
    ib_write(rpda, 5 * 256 + 7);
    ib_write(rpcs1, 8#105#);                  -- IE + SEEK + GO
    ib_read(rpds, d);
    assert d(13) = '1' report "PIP not set" severity failure;
    ib_write(rpda, 0);                        -- busy drive: RMR
    expect(rper1, 8#000004#, "ER1 RMR");
    for i in 0 to 2000 loop
      wait until rising_edge(CLK);
      exit when EI_REQ = '1';
    end loop;
    assert EI_REQ = '1' report "no attention interrupt" severity failure;
    expect(rpas, 1, "AS after SEEK");
    int_ack;
    ib_read(rpcs1, d);
    assert d(6) = '0' report "IE not cleared by interrupt" severity failure;
    ib_write(rpcs1, 8#011#);                  -- DCLR
    expect(rper1, 0, "ER1 after DCLR");
    ib_write(rpas, 1);
    expect(rpas, 0, "AS cleared");
    expect(rpda, 5 * 256 + 7, "DA unchanged by refused write");

    -- READ 2 blocks from C3 T2 S48 (crosses the sector wrap)
    do_read(3, 2, 48, 512, 16#1000#);
    ib_read(rpcs1, d);
    assert d(7) = '0' report "RDY not cleared by READ" severity failure;
    for i in 0 to 400000 loop
      wait until rising_edge(CLK);
      exit when EI_REQ = '1';
    end loop;
    assert EI_REQ = '1' report "no done interrupt" severity failure;
    int_ack;
    expect(rpcs1, 8#004270#, "CS1 after READ");  -- DVA RDY func=034
    expect(rpwc, 0, "WC after READ");
    expect(rpba, 16#1400#, "BA after READ");
    expect(rpda, 3 * 256 + 0, "DA after READ");
    expect(rpdc, 3, "DC after READ");
    expect(rper1, 0, "ER1 after READ");
    check_mem((3*32+2)*50+48, 512, 16#1000#);

    -- partial count, odd word start: 300 words at 0x2002
    do_read(0, 0, 0, 300, 16#2002#);
    wait_rdy;
    expect(rpwc, 0, "WC partial");
    expect(rpba, 16#2002# + 600, "BA partial");
    expect(rpda, 2, "DA partial (2 blocks)");
    check_mem(0, 300, 16#2002#);

    -- AOE: last block of the disk, 512 words requested
    do_read(629, 31, 49, 512, 16#3000#);
    wait_rdy;
    expect(rpwc, 8#177400#, "WC after AOE");
    expect(rper1, 8#001000#, "ER1 AOE");
    ib_read(rpcs1, d);
    assert d(14) = '1' report "TRE not set after AOE" severity failure;
    expect(rpdc, 630, "DC after AOE");
    check_mem(1007999, 256, 16#3000#);
    ib_write(rpcs1, 8#011#);                  -- DCLR

    -- IAE, WLE, ILF: ATA, RDY stays/returns 1
    ib_write(rpdc, 630);
    ib_write(rpcs1, 8#071#);
    expect(rper1, 8#002000#, "ER1 IAE");
    expect(rpas, 1, "ATA after IAE");
    ib_write(rpcs1, 8#011#);
    ib_write(rpas, 1);
    -- WRITE on the write locked drive, handled like the 2.11BSD xp driver:
    -- interrupt with CS1.TRE, then TRE|IE|DCLR|GO, clear AS, next SEARCH
    ib_write(rpdc, 0);
    ib_write(rpcs1, 8#161#);                  -- IE + WRITE + GO
    expect(rper1, 8#004000#, "ER1 WLE");
    for i in 0 to 100 loop
      wait until rising_edge(CLK);
      exit when EI_REQ = '1';
    end loop;
    assert EI_REQ = '1' report "no interrupt after WLE" severity failure;
    expect(rpcs1, 8#144360#, "CS1 SC TRE after WLE");
    int_ack;
    ib_write(rpcs1, 8#040111#);               -- TRE + IE + DCLR + GO
    expect(rper1, 0, "ER1 after driver DCLR");
    ib_read(rpcs1, d);
    assert d(14) = '0' report "TRE not cleared" severity failure;
    ib_write(rpas, 1);                        -- xpustart clears AS
    ib_write(rpcs1, 8#131#);                  -- IE + SEARCH + GO
    expect(rper1, 0, "ER1 after SEARCH (no ILF)");
    for i in 0 to 2000 loop
      wait until rising_edge(CLK);
      exit when EI_REQ = '1';
    end loop;
    assert EI_REQ = '1' report "no interrupt after SEARCH" severity failure;
    expect(rpas, 1, "AS after SEARCH");
    int_ack;
    ib_write(rpas, 1);
    ib_write(rpcs1, 8#051#);                  -- WCD
    wait_rdy;
    expect(rper1, 8#000001#, "ER1 ILF for WCD");
    ib_write(rpcs1, 8#011#);
    ib_write(rpas, 1);

    -- NEM: 512 words at memlimit-256 bytes -> 128 words, then NEM
    do_read(0, 0, 10, 512, memlimit - 256);
    wait_rdy;
    expect(rpcs2, 8#004300#, "CS2 NEM");
    expect(rpwc, (65536 - 512 + 128) mod 65536, "WC after NEM");
    check_mem(10, 128, memlimit - 256);
    ib_write(rpcs1, 8#040000#, "10");         -- TRE=1 clears CS2 errors
    expect(rpcs2, 8#000300#, "CS2 after TRE clear");

    -- card removed: MOL and VV off, READ gives UNS
    CD <= '1';
    MODE <= 0;
    for i in 1 to 10 loop wait until rising_edge(CLK); end loop;
    expect(rpds, 8#004400#, "DS without card");  -- WRL DPR
    ib_write(rpcs1, 8#071#);
    expect(rper1, 8#040000#, "ER1 UNS without card");
    ib_write(rpcs1, 8#011#);
    ib_write(rpas, 1);
    -- card back: a READ initializes the card again
    CD <= '0';
    MODE <= 1;
    for i in 1 to 10 loop wait until rising_edge(CLK); end loop;
    do_read(0, 1, 0, 256, 16#5000#);
    wait_rdy;
    expect(rper1, 0, "ER1 after reinsertion");
    check_mem(50, 256, 16#5000#);

    -- BRESET during a long read: RDY at once, DMA stops, next read ok
    do_read(1, 0, 0, 16384, 16#0400#);
    for i in 1 to 20000 loop wait until rising_edge(CLK); end loop;
    wait until falling_edge(CLK);
    BRESET <= '1';
    wait until falling_edge(CLK);
    BRESET <= '0';
    expect(rpcs1, 8#004200#, "CS1 after BRESET");
    for i in 1 to 30000 loop wait until rising_edge(CLK); end loop;
    nw0 := NWRITE;
    for i in 1 to 30000 loop wait until rising_edge(CLK); end loop;
    assert NWRITE = nw0 report "DMA continued after BRESET" severity failure;
    do_read(2, 0, 0, 256, 16#6000#);
    wait_rdy;
    expect(rper1, 0, "ER1 read after BRESET");
    check_mem(3200, 256, 16#6000#);        -- (2*32+0)*50

    report "tb_ibdr_rp07n completed, transfers " &
      integer'image(to_integer(unsigned(XCOUNT))) & ", DMA writes " &
      integer'image(NWRITE) severity note;
    STOP_CLOCK <= true;
    wait;
  end process proc_stim;

  proc_timeout: process
  begin
    wait for 200 ms;
    assert STOP_CLOCK report "tb_ibdr_rp07n timed out" severity failure;
    wait;
  end process proc_timeout;
end sim;
