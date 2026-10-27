-- SPDX-License-Identifier: GPL-3.0-or-later
-- RL01/RL02 unit type, get status, read/write and drive isolation,
-- and DMA through the UNIBUS map (ubmap_shadow) across a map page.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.slvtypes.all;
use work.iblib.all;

entity tb_ibdr_rl02n is
end tb_ibdr_rl02n;

architecture sim of tb_ibdr_rl02n is
  type mem_type is array (0 to 16383) of slv32;
  function init_memory return mem_type is
    variable m : mem_type := (others => (others => '0'));
  begin
    for i in 8#004000#/4 to (8#004000# + 255)/4 loop
      m(i) := x"55aa55aa";
    end loop;
    return m;
  end function;
  signal MEM : mem_type := init_memory;
  signal CLK : slbit := '0';
  signal RESET : slbit := '1';
  signal BRESET : slbit := '0';
  signal CE_MSEC : slbit := '0';
  signal DONE : boolean := false;
  signal IB_MREQ : ib_mreq_type := ib_mreq_init;
  signal IB_SRES : ib_sres_type := ib_sres_init;
  signal EI_REQ, EI_ACK : slbit := '0';
  signal CS_N, SCLK, MOSI, MISO : slbit := '1';
  signal DMA_REQ, DMA_WE, DMA_BUSY : slbit := '0';
  signal DMA_ACK_R, DMA_ACK_W : slbit := '0';
  signal DMA_ADDR : slv20 := (others => '0');
  signal DMA_BE : slv4 := (others => '0');
  signal DMA_DI, DMA_DO : slv32 := (others => '0');
  signal SDERR : slv8 := (others => '0');
  signal XCOUNT : slv16 := (others => '0');
  signal UB_ENA : slbit := '0';
  signal UB_TAB : slv(32*21-1 downto 0) := (others => '0');
  constant rlcs : natural := 8#174400#;
  constant rlba : natural := 8#174402#;
  constant rlda : natural := 8#174404#;
  constant rlmp : natural := 8#174406#;
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

  DUT: entity work.ibdr_rl02n
    port map (
      RL02_MASK => "0010", PRESENT_MASK => "0011",
      CLK => CLK, RESET => RESET, CE_MSEC => CE_MSEC, BRESET => BRESET,
      IB_MREQ => IB_MREQ, IB_SRES => IB_SRES,
      EI_REQ => EI_REQ, EI_ACK => EI_ACK,
      O_SD_CS_N => CS_N, O_SD_SCLK => SCLK, O_SD_MOSI => MOSI,
      I_SD_MISO => MISO, I_SD_CD => '0',
      DMA_REQ => DMA_REQ, DMA_WE => DMA_WE, DMA_BUSY => DMA_BUSY,
      DMA_ACK_R => DMA_ACK_R, DMA_ACK_W => DMA_ACK_W,
      DMA_ADDR => DMA_ADDR, DMA_BE => DMA_BE, DMA_DI => DMA_DI,
      DMA_DO => DMA_DO, UB_ENA => UB_ENA, UB_TAB => UB_TAB,
      SDERR => SDERR, XCOUNT => XCOUNT);

  UBMAP: entity work.ubmap_shadow
    port map (CLK => CLK, BRESET => BRESET, IB_MREQ => IB_MREQ,
              ENA => UB_ENA, TAB => UB_TAB);

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
      DMA_ACK_R <= '0'; DMA_ACK_W <= '0';
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
        DMA_BUSY <= '0'; pending := false;
      elsif DMA_REQ = '1' and DMA_BUSY = '0' then
        address := to_integer(unsigned(DMA_ADDR));
        assert address <= MEM'high report "DMA beyond test memory"
          severity failure;
        writing := DMA_WE; byte_en := DMA_BE; value := DMA_DI;
        pending := true; DMA_BUSY <= '1';
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

    -- a write that no device in this bench answers (UNIBUS map, MMR3)
    procedure ib_poke(constant addr : natural; constant data : natural) is
    begin
      wait until falling_edge(CLK);
      IB_MREQ.aval <= '1';
      IB_MREQ.addr <= slv(to_unsigned(addr mod 8192, 13)(12 downto 1));
      IB_MREQ.din <= slv(to_unsigned(data, 16));
      IB_MREQ.be0 <= '1'; IB_MREQ.be1 <= '1';
      wait until falling_edge(CLK);
      IB_MREQ.we <= '1';
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
        ib_read(rlcs, d);
        exit when d(7) = '1';
        for k in 1 to 20 loop wait until rising_edge(CLK); end loop;
      end loop;
      assert d(7) = '1' report "RL11 not ready" severity failure;
    end procedure;

    impure function memword(ba : natural) return slv16 is
    begin
      if (ba / 2) mod 2 = 0 then return MEM(ba / 4)(15 downto 0); end if;
      return MEM(ba / 4)(31 downto 16);
    end function;

    function block_byte(lba : natural; offset : natural) return slv8 is
    begin
      return slv(to_unsigned((lba * 37 + offset) mod 256, 8));
    end function;

    variable d : slv16;
    variable pa : natural;
  begin
    wait for 100 ns;
    wait until falling_edge(CLK); RESET <= '0';
    for i in 1 to 5 loop wait until rising_edge(CLK); end loop;

    -- Type bit: RL0 is RL01, RL1 is RL02.
    ib_write(rlda, 8#000013#);
    ib_write(rlcs, 8#000004#);
    ib_read(rlmp, d);
    assert d(7) = '0' and d(4) = '1' and d(2 downto 0) = "101"
      report "RL01 status" severity failure;
    ib_write(rlcs, 8#000404#);
    ib_read(rlmp, d);
    assert d(7) = '1' and d(4) = '1' and d(2 downto 0) = "101"
      report "RL02 status" severity failure;

    -- RL0 sector 0 -> SD LBA 0, 128 words.
    ib_write(rlda, 0);
    ib_write(rlba, 8#002000#);
    ib_write(rlmp, 8#177600#); -- -128
    ib_write(rlcs, 8#000014#);
    wait_rdy;
    ib_read(rlcs, d);
    assert d(15) = '0' report "RL0 READ error" severity failure;
    for i in 0 to 127 loop
      assert memword(8#002000# + i*2) =
             block_byte(0, i*2+1) & block_byte(0, i*2)
        report "RL0 read mismatch" severity failure;
    end loop;
    ib_write(rlcs, 8#000010#); -- READ HEADER after sector 0
    ib_read(rlmp, d);
    assert d(5 downto 0) = "000001" report "RL0 header position"
      severity failure;
    ib_write(rlcs, 8#000010#);
    ib_read(rlmp, d);
    assert d(5 downto 0) = "000010" report "RL0 header rotation"
      severity failure;

    -- WRITE RL1, then read back; RL0 must retain its own contents.
    assert memword(8#004000#) = x"55aa"
      report "test memory not initialized" severity failure;
    ib_write(rlda, 0);
    ib_write(rlba, 8#004000#);
    ib_write(rlmp, 8#177600#);
    ib_write(rlcs, 8#000412#);
    wait_rdy;
    ib_read(rlcs, d);
    assert d(15) = '0' report "RL1 WRITE error" severity failure;
    ib_write(rlda, 0);
    ib_write(rlba, 8#006000#);
    ib_write(rlmp, 8#177600#);
    ib_write(rlcs, 8#000414#);
    wait_rdy;
    ib_read(rlcs, d);
    assert d(15) = '0' report "RL1 READ error status " &
      integer'image(to_integer(unsigned(d))) severity failure;
    for i in 0 to 127 loop
      assert memword(8#006000# + i*2) = x"55aa"
        report "RL1 WRITE/READ mismatch word " & integer'image(i) &
               " actual " & integer'image(to_integer(unsigned(memword(8#006000# + i*2)))) &
               " sd error " & integer'image(to_integer(unsigned(SDERR)))
        severity failure;
    end loop;
    ib_write(rlda, 0);
    ib_write(rlba, 8#010000#);
    ib_write(rlmp, 8#177600#);
    ib_write(rlcs, 8#000014#);
    wait_rdy;
    for i in 0 to 127 loop
      assert memword(8#010000# + i*2) =
             block_byte(0, i*2+1) & block_byte(0, i*2)
        report "RL0 overwritten by RL1" severity failure;
    end loop;

    -- RL01 cannot address cylinder 256; RL2 is absent.
    ib_write(rlda, 8#100000#);
    ib_write(rlmp, 8#177600#);
    ib_write(rlcs, 8#000014#);
    wait_rdy;
    ib_read(rlcs, d);
    assert d(15) = '1' and d(13 downto 10) = "0101"
      report "RL01 cylinder bound" severity failure;
    ib_write(rlda, 0);
    ib_write(rlcs, 8#001004#); -- RL2 get status
    ib_read(rlcs, d);
    assert d(15) = '1' and d(14) = '1'
      report "absent RL2 status" severity failure;
    -- UNIBUS map: page 0 -> 040002 (not 4-byte aligned), page 1 -> 100002,
    -- then 100000. The UNIBUS buffer 017700 holds 32 words in page 0 and 96
    -- in page 1. The last word of page 0 is a low half; the first of page 1
    -- is a high half (a lone low and a lone high write), then a low half (a
    -- lone low write).
    ib_poke(8#170200#, 8#040002#);
    ib_poke(8#170202#, 0);
    ib_poke(8#170206#, 0);
    ib_poke(8#172516#, 8#000040#);       -- MMR3: enable the UNIBUS map
    assert UB_ENA = '1' report "UNIBUS map not enabled" severity failure;
    for pass in 0 to 1 loop
      ib_poke(8#170204#, 8#100002# - 2*pass);
      ib_write(rlda, 0);
      ib_write(rlba, 8#017700#);
      ib_write(rlmp, 8#177600#);
      ib_write(rlcs, 8#000014#);         -- RL0 READ through the map
      wait_rdy;
      ib_read(rlcs, d);
      assert d(15) = '0' report "mapped READ error" severity failure;
      for i in 0 to 127 loop
        if i < 32 then pa := 8#040002# + 8#017700# + i*2;
        else pa := 8#100002# - 2*pass + (i-32)*2; end if;
        assert memword(pa) = block_byte(0, i*2+1) & block_byte(0, i*2)
          report "mapped READ pass " & integer'image(pass) &
                 " word " & integer'image(i) severity failure;
      end loop;
    end loop;
    ib_write(rlda, 1);                   -- RL1 sector 1 from the same buffer
    ib_write(rlba, 8#017700#);
    ib_write(rlmp, 8#177600#);
    ib_write(rlcs, 8#000412#);
    wait_rdy;
    ib_read(rlcs, d);
    assert d(15) = '0' report "mapped WRITE error" severity failure;
    ib_poke(8#172516#, 0);               -- map off, read back unmapped
    assert UB_ENA = '0' report "UNIBUS map not disabled" severity failure;
    ib_write(rlda, 1);
    ib_write(rlba, 8#012000#);
    ib_write(rlmp, 8#177600#);
    ib_write(rlcs, 8#000414#);
    wait_rdy;
    for i in 0 to 127 loop
      assert memword(8#012000# + i*2) =
             block_byte(0, i*2+1) & block_byte(0, i*2)
        report "mapped WRITE word " & integer'image(i) severity failure;
    end loop;
    report "tb_ibdr_rl02n: PASS";
    DONE <= true;
    wait;
  end process;
end sim;
