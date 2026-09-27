-- SPDX-License-Identifier: GPL-3.0-or-later
-- Ping-pong coherence test: w11_dma_pingpong against tcode/dma_pingpong.mac
-- running on the real PDP-11 CPU, with a variable-latency memory model.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;
use work.rblib.all;
use work.iblib.all;
use work.pdp11.all;

entity tb_w11_dma_pingpong is
end tb_w11_dma_pingpong;

architecture sim of tb_w11_dma_pingpong is
  type mem_type is array (0 to 16#23ff#) of slv32;
  -- tcode/dma_pingpong.mac assembled, start address 001000
  signal RAM : mem_type := (
    128 => x"84000a1f",
    129 => x"84020a1f",
    130 => x"84040a1f",
    131 => x"0a050a04",
    132 => x"840017c0",
    133 => x"03fc2004",
    134 => x"15c11002",
    135 => x"15c08000",
    136 => x"15c38800",
    137 => x"22420200",
    138 => x"0a850303",
    139 => x"8404115f",
    140 => x"0a501448",
    141 => x"7ec90a82",
    142 => x"e5c41084",
    143 => x"111f0200",
    144 => x"01e68402",
    others => (others => '0'));
  type mem_state_type is (m_idle, m_wait1, m_wait2, m_ack);
  signal MEM_STATE : mem_state_type := m_idle;
  signal MEM_LFSR : slv8 := x"a5";      -- varies the memory latency
  signal MEM_WAIT : natural := 0;
  signal CLK : slbit := '0';
  signal RESET : slbit := '1';
  signal STOP_CLOCK : boolean := false;
  signal RB_MREQ : rb_mreq_type := rb_mreq_init;
  signal RB_SRES : rb_sres_type := rb_sres_init;
  signal RB_SRES_CPU : rb_sres_type := rb_sres_init;
  signal RB_SRES_PP : rb_sres_type := rb_sres_init;
  signal CP_STAT : cp_stat_type := cp_stat_init;
  signal IB_MREQ : ib_mreq_type := ib_mreq_init;
  signal MEM_RESET : slbit := '1';
  signal MEM_REQ : slbit := '0';
  signal MEM_WE : slbit := '0';
  signal MEM_BUSY : slbit := '0';
  signal MEM_ACK_R : slbit := '0';
  signal MEM_ACK_W : slbit := '0';
  signal MEM_ADDR : slv20 := (others => '0');
  signal MEM_BE : slv4 := (others => '0');
  signal MEM_DI : slv32 := (others => '0');
  signal MEM_DO : slv32 := (others => '0');
  signal CAP_WE : slbit := '0';
  signal CAP_ADDR : slv20 := (others => '0');
  signal CAP_BE : slv4 := (others => '0');
  signal CAP_DI : slv32 := (others => '0');
  signal DMA_REQ : slbit := '0';
  signal DMA_WE : slbit := '0';
  signal DMA_BUSY : slbit := '0';
  signal DMA_ACK_R : slbit := '0';
  signal DMA_ACK_W : slbit := '0';
  signal DMA_ADDR : slv20 := (others => '0');
  signal DMA_BE : slv4 := (others => '0');
  signal DMA_DI : slv32 := (others => '0');
  signal DMA_DO : slv32 := (others => '0');
begin
  CLK <= not CLK after 5 ns when not STOP_CLOCK else '0';

  DUT: entity work.w11_cpu_dma_path
    port map (
      CLK => CLK, RESET => RESET,
      RB_MREQ => RB_MREQ, RB_SRES => RB_SRES_CPU, RB_STAT => open,
      RB_LAM_CPU => open, GRESET => open, CRESET => open,
      BRESET => open, CP_STAT => CP_STAT,
      EI_PRI => "000", EI_VECT => (others => '0'), EI_ACKM => open,
      PERFEXT => (others => '0'),
      IB_MREQ => IB_MREQ, IB_SRES => ib_sres_init,
      DM_STAT_EXP => open,
      DMA_REQ => DMA_REQ, DMA_WE => DMA_WE, DMA_BUSY => DMA_BUSY,
      DMA_ACK_R => DMA_ACK_R, DMA_ACK_W => DMA_ACK_W,
      DMA_ADDR => DMA_ADDR, DMA_BE => DMA_BE,
      DMA_DI => DMA_DI, DMA_DO => DMA_DO,
      MEM_RESET => MEM_RESET,
      MEM_REQ => MEM_REQ, MEM_WE => MEM_WE, MEM_BUSY => MEM_BUSY,
      MEM_ACK_R => MEM_ACK_R, MEM_ACK_W => MEM_ACK_W,
      MEM_ADDR => MEM_ADDR, MEM_BE => MEM_BE,
      MEM_DI => MEM_DI, MEM_DO => MEM_DO);

  PINGPONG: entity work.w11_dma_pingpong
    port map (
      CLK => CLK, RESET => RESET,
      RB_MREQ => RB_MREQ, RB_SRES => RB_SRES_PP,
      DMA_REQ => DMA_REQ, DMA_WE => DMA_WE, DMA_BUSY => DMA_BUSY,
      DMA_ACK_R => DMA_ACK_R, DMA_ACK_W => DMA_ACK_W,
      DMA_ADDR => DMA_ADDR, DMA_BE => DMA_BE,
      DMA_DI => DMA_DI, DMA_DO => DMA_DO);

  RB_SRES.ack <= RB_SRES_CPU.ack or RB_SRES_PP.ack;
  RB_SRES.busy <= RB_SRES_CPU.busy or RB_SRES_PP.busy;
  RB_SRES.err <= RB_SRES_CPU.err or RB_SRES_PP.err;
  RB_SRES.dout <= RB_SRES_CPU.dout or RB_SRES_PP.dout;

  proc_memory: process (CLK)
    variable index : natural;
  begin
    if rising_edge(CLK) then
      MEM_ACK_R <= '0';
      MEM_ACK_W <= '0';
      if MEM_RESET = '1' then
        MEM_STATE <= m_idle;
        MEM_BUSY <= '0';
      else
        case MEM_STATE is
          when m_idle =>
            if MEM_REQ = '1' then
              CAP_WE <= MEM_WE;
              CAP_ADDR <= MEM_ADDR;
              CAP_BE <= MEM_BE;
              CAP_DI <= MEM_DI;
              MEM_BUSY <= '1';
              MEM_WAIT <= to_integer(unsigned(MEM_LFSR(2 downto 0)));
              MEM_LFSR <= MEM_LFSR(6 downto 0) &
                (MEM_LFSR(7) xor MEM_LFSR(5) xor MEM_LFSR(4) xor MEM_LFSR(3));
              MEM_STATE <= m_wait1;
            end if;
          when m_wait1 =>
            if MEM_WAIT = 0 then
              MEM_STATE <= m_wait2;
            else
              MEM_WAIT <= MEM_WAIT - 1;
            end if;
          when m_wait2 =>
            index := to_integer(unsigned(CAP_ADDR));
            assert index < RAM'length report "memory address out of range"
              severity failure;
            if CAP_WE = '1' then
              for lane in 0 to 3 loop
                if CAP_BE(lane) = '1' then
                  RAM(index)(8*lane+7 downto 8*lane) <=
                    CAP_DI(8*lane+7 downto 8*lane);
                end if;
              end loop;
              MEM_ACK_W <= '1';
            else
              MEM_DO <= RAM(index);
              MEM_ACK_R <= '1';
            end if;
            MEM_BUSY <= '0';
            MEM_STATE <= m_ack;
          when m_ack =>
            MEM_STATE <= m_idle;
        end case;
      end if;
    end if;
  end process proc_memory;

  proc_stim: process
    procedure rb_write(constant addr : in slv16;
                       constant data : in slv16) is
    begin
      wait until falling_edge(CLK);
      RB_MREQ.aval <= '1';
      RB_MREQ.addr <= addr;
      RB_MREQ.din <= data;
      wait until falling_edge(CLK);
      RB_MREQ.we <= '1';
      loop
        wait until falling_edge(CLK);
        exit when RB_SRES.ack = '1' and RB_SRES.busy = '0';
      end loop;
      assert RB_SRES.err = '0' report "RBus write error" severity failure;
      RB_MREQ <= rb_mreq_init;
      wait until falling_edge(CLK);
    end procedure rb_write;

    procedure rb_read(constant addr : in slv16;
                      variable data : out slv16) is
    begin
      wait until falling_edge(CLK);
      RB_MREQ.aval <= '1';
      RB_MREQ.addr <= addr;
      wait until falling_edge(CLK);
      RB_MREQ.re <= '1';
      loop
        wait until falling_edge(CLK);
        exit when RB_SRES.ack = '1' and RB_SRES.busy = '0';
      end loop;
      assert RB_SRES.err = '0' report "RBus read error" severity failure;
      data := RB_SRES.dout;
      RB_MREQ <= rb_mreq_init;
      wait until falling_edge(CLK);
    end procedure rb_read;

    variable iter : slv16;
    variable err : slv16;
    variable r5 : slv16;
    variable wlat : slv16;
    variable rlat : slv16;
  begin
    wait for 30 ns;
    wait until falling_edge(CLK);
    RESET <= '0';

    rb_write(x"000f", x"0200");         -- PC = 001000
    rb_write(x"0001", x"0001");         -- start CPU
    for cycle in 0 to 200 loop          -- let the CPU clear seq/ack/errc
      wait until rising_edge(CLK);
    end loop;
    rb_write(x"fd00", x"0003");         -- clear counters, run

    for poll in 0 to 4000 loop
      for cycle in 0 to 200 loop
        wait until rising_edge(CLK);
      end loop;
      rb_read(x"fd02", iter);
      exit when unsigned(iter) >= 4;
    end loop;
    assert unsigned(iter) >= 4
      report "ping-pong did not complete 4 iterations" severity failure;

    rb_write(x"fd00", x"0000");         -- stop after this iteration
    rb_read(x"fd08", wlat);
    rb_read(x"fd09", rlat);
    report "max DMA latency write " & integer'image(to_integer(unsigned(wlat)))
      & " read " & integer'image(to_integer(unsigned(rlat))) & " cycles"
      severity note;
    assert unsigned(wlat) > 0 and unsigned(rlat) > 0
      report "DMA latency not measured" severity failure;
    rb_read(x"fd03", err);
    assert err = x"0000"
      report "DMA side saw mismatches" severity failure;
    rb_write(x"0001", x"0002");         -- stop CPU
    rb_read(x"000d", r5);               -- R5 = CPU error count
    assert r5 = x"0000"
      report "CPU side saw mismatches" severity failure;
    assert RAM(16#2100#)(31 downto 16) = RAM(16#2100#)(15 downto 0)
      report "ack does not match seq" severity failure;

    report "tb_w11_dma_pingpong completed, iterations " &
      integer'image(to_integer(unsigned(iter))) severity note;
    STOP_CLOCK <= true;
    wait;
  end process proc_stim;

  proc_timeout: process
  begin
    wait for 10 ms;
    assert STOP_CLOCK report "ping-pong simulation timed out" severity failure;
    wait;
  end process proc_timeout;
end sim;
