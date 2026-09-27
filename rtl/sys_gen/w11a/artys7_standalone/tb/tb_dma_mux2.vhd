-- SPDX-License-Identifier: GPL-3.0-or-later
-- dma_mux2: two masters with random request timing write and read back
-- their own regions through a variable-latency slave.  Checks data, that
-- every acknowledge reaches only the master that waits for it, and that
-- both masters make progress.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;

entity tb_dma_mux2 is
end tb_dma_mux2;

architecture sim of tb_dma_mux2 is
  type mem_type is array (0 to 255) of slv32;
  signal MEM : mem_type := (others => (others => '0'));
  signal CLK : slbit := '0';
  signal RESET : slbit := '1';
  signal STOP_CLOCK : boolean := false;
  type port_type is record
    req : slbit;
    we : slbit;
    addr : slv20;
    be : slv4;
    di : slv32;
  end record port_type;
  type port_array is array (0 to 1) of port_type;
  type bool_array is array (0 to 1) of boolean;
  signal P : port_array := (others => ('0', '0', (others => '0'),
                                       (others => '0'), (others => '0')));
  signal DONE : bool_array := (others => false);
  signal A_BUSY, B_BUSY : slbit := '1';
  signal A_ACK_R, A_ACK_W, B_ACK_R, B_ACK_W : slbit := '0';
  signal DMA_REQ, DMA_WE, DMA_BUSY, DMA_ACK_R, DMA_ACK_W : slbit := '0';
  signal DMA_ADDR : slv20 := (others => '0');
  signal DMA_BE : slv4 := (others => '0');
  signal DMA_DI, DMA_DO : slv32 := (others => '0');
begin
  CLK <= not CLK after 5 ns when not STOP_CLOCK else '0';

  DUT: entity work.dma_mux2
    port map (
      CLK => CLK, RESET => RESET,
      A_REQ => P(0).req, A_WE => P(0).we, A_BUSY => A_BUSY,
      A_ACK_R => A_ACK_R, A_ACK_W => A_ACK_W, A_ADDR => P(0).addr,
      A_BE => P(0).be, A_DI => P(0).di,
      B_REQ => P(1).req, B_WE => P(1).we, B_BUSY => B_BUSY,
      B_ACK_R => B_ACK_R, B_ACK_W => B_ACK_W, B_ADDR => P(1).addr,
      B_BE => P(1).be, B_DI => P(1).di,
      DMA_REQ => DMA_REQ, DMA_WE => DMA_WE, DMA_BUSY => DMA_BUSY,
      DMA_ACK_R => DMA_ACK_R, DMA_ACK_W => DMA_ACK_W, DMA_ADDR => DMA_ADDR,
      DMA_BE => DMA_BE, DMA_DI => DMA_DI);

  proc_slave: process (CLK)
    variable lfsr : slv8 := x"3c";
    variable busy : boolean := false;
    variable cnt : natural := 0;
    variable we : slbit;
    variable a : natural;
    variable d : slv32;
  begin
    if rising_edge(CLK) then
      DMA_ACK_R <= '0';
      DMA_ACK_W <= '0';
      lfsr := lfsr(6 downto 0) & (lfsr(7) xor lfsr(5) xor lfsr(4) xor lfsr(3));
      if not busy then
        DMA_BUSY <= lfsr(0) and lfsr(1);  -- sometimes busy while idle
        if DMA_REQ = '1' and DMA_BUSY = '0' then
          busy := true;
          DMA_BUSY <= '1';
          we := DMA_WE;
          a := to_integer(unsigned(DMA_ADDR(7 downto 0)));
          d := DMA_DI;
          cnt := to_integer(unsigned(lfsr(3 downto 0)));
        end if;
      elsif cnt = 0 then
        if we = '1' then
          MEM(a) <= d;
          DMA_ACK_W <= '1';
        else
          DMA_DO <= MEM(a);
          DMA_ACK_R <= '1';
        end if;
        busy := false;
        DMA_BUSY <= '0';
      else
        cnt := cnt - 1;
      end if;
    end if;
  end process proc_slave;

  gen_master: for m in 0 to 1 generate
    proc_master: process
      variable lfsr : slv8;
      variable waiting : boolean := false;
      variable pv : port_type;
      procedure access_mem(constant we : in slbit; constant idx : in natural;
                           constant data : in slv32) is
      begin
        pv.req := '1';
        pv.we := we;
        pv.addr := slv(to_unsigned(128 * m + idx, 20));
        pv.be := "1111";
        pv.di := data;
        P(m) <= pv;
        loop
          wait until rising_edge(CLK);
          exit when (m = 0 and A_BUSY = '0') or (m = 1 and B_BUSY = '0');
        end loop;
        pv.req := '0';
        P(m) <= pv;
        loop
          wait until rising_edge(CLK);
          exit when (m = 0 and (A_ACK_R = '1' or A_ACK_W = '1')) or
                    (m = 1 and (B_ACK_R = '1' or B_ACK_W = '1'));
        end loop;
        if we = '0' then
          assert DMA_DO = data
            report "master " & integer'image(m) & " read back wrong data"
            severity failure;
        end if;
      end procedure access_mem;
    begin
      if m = 0 then lfsr := x"a1"; else lfsr := x"5e"; end if;
      wait until RESET = '0';
      for round in 0 to 20 loop
        for i in 0 to 99 loop
          for k in 1 to to_integer(unsigned(lfsr(1 downto 0))) loop
            wait until rising_edge(CLK);
          end loop;
          lfsr := lfsr(6 downto 0) &
                  (lfsr(7) xor lfsr(5) xor lfsr(4) xor lfsr(3));
          access_mem('1', i, slv(to_unsigned(m * 65536 + round * 256 + i,
                                             32)));
          access_mem('0', i, slv(to_unsigned(m * 65536 + round * 256 + i,
                                             32)));
        end loop;
      end loop;
      DONE(m) <= true;
      wait;
    end process proc_master;
  end generate gen_master;

  -- an acknowledge must only reach a master that has a request taken
  proc_check: process (CLK)
    variable a_wait, b_wait : boolean := false;
  begin
    if rising_edge(CLK) then
      assert not ((A_ACK_R = '1' or A_ACK_W = '1') and not a_wait)
        report "stray acknowledge to master A" severity failure;
      assert not ((B_ACK_R = '1' or B_ACK_W = '1') and not b_wait)
        report "stray acknowledge to master B" severity failure;
      if P(0).req = '1' and A_BUSY = '0' then a_wait := true; end if;
      if A_ACK_R = '1' or A_ACK_W = '1' then a_wait := false; end if;
      if P(1).req = '1' and B_BUSY = '0' then b_wait := true; end if;
      if B_ACK_R = '1' or B_ACK_W = '1' then b_wait := false; end if;
    end if;
  end process proc_check;

  proc_stim: process
  begin
    wait for 30 ns;
    wait until falling_edge(CLK);
    RESET <= '0';
    wait until DONE(0) and DONE(1) for 20 ms;
    assert DONE(0) and DONE(1) report "masters did not finish" severity failure;
    report "tb_dma_mux2 completed" severity note;
    STOP_CLOCK <= true;
    wait;
  end process proc_stim;
end sim;
