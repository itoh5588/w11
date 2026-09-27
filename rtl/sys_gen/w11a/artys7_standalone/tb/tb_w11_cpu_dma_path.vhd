-- SPDX-License-Identifier: GPL-3.0-or-later
-- A running PDP-11 reads a DMA-updated word and increments a counter while
-- DMA writes and reads are started at every phase of the CPU loop.  An rbus
-- init (GRESET) during a DMA write must not leave a stale cache line.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;
use work.rblib.all;
use work.iblib.all;
use work.pdp11.all;

entity tb_w11_cpu_dma_path is
end tb_w11_cpu_dma_path;

architecture sim of tb_w11_cpu_dma_path is
  type mem_type is array (0 to 1023) of slv32;
  -- 0: MOV @#001000,R0; 4: INC @#001004; 10: BR back to 0.
  signal RAM : mem_type := (
    0 => x"020017c0", 1 => x"02040a9f", 2 => x"000001fb",
    128 => x"11223344", others => (others => '0'));
  type mem_state_type is (m_idle, m_wait1, m_wait2, m_ack);
  signal MEM_STATE : mem_state_type := m_idle;
  signal MEM_LFSR : slv8 := x"a5";      -- varies the memory latency
  signal MEM_WAIT : natural := 0;
  signal CLK : slbit := '0';
  signal RESET : slbit := '1';
  signal STOP_CLOCK : boolean := false;
  signal RB_MREQ : rb_mreq_type := rb_mreq_init;
  signal RB_SRES : rb_sres_type := rb_sres_init;
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
  signal DATA_READS : natural := 0;
  signal DMA_REQ : slbit := '0';
  signal DMA_WE : slbit := '1';
  signal DMA_BUSY : slbit := '0';
  signal DMA_ACK_R : slbit := '0';
  signal DMA_ACK_W : slbit := '0';
  signal DMA_ADDR : slv20 := x"00080";
  signal DMA_BE : slv4 := "1111";
  signal DMA_DI : slv32 := x"a5c35a3c";
  signal DMA_DO : slv32 := (others => '0');
  signal DMA_ACK_SEEN : slbit := '0';
  signal DMA_ACK_CLR : slbit := '0';
begin
  CLK <= not CLK after 5 ns when not STOP_CLOCK else '0';

  DUT: entity work.w11_cpu_dma_path
    port map (
      CLK => CLK, RESET => RESET,
      RB_MREQ => RB_MREQ, RB_SRES => RB_SRES, RB_STAT => open,
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
              if index = 128 then
                DATA_READS <= DATA_READS + 1;
              end if;
            end if;
            MEM_BUSY <= '0';
            MEM_STATE <= m_ack;
          when m_ack =>
            MEM_STATE <= m_idle;
        end case;
      end if;
    end if;
  end process proc_memory;

  proc_dma_ack: process (CLK)
  begin
    if rising_edge(CLK) then
      if DMA_ACK_CLR = '1' then
        DMA_ACK_SEEN <= '0';
      elsif DMA_ACK_W = '1' then
        DMA_ACK_SEEN <= '1';
      end if;
    end if;
  end process proc_dma_ack;

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

    procedure rb_greset is
    begin
      wait until falling_edge(CLK);
      RB_MREQ.init <= '1';
      RB_MREQ.addr <= x"0000";
      RB_MREQ.din <= x"0001";          -- c_init_rbf_greset
      wait until falling_edge(CLK);
      RB_MREQ <= rb_mreq_init;
      wait until falling_edge(CLK);
    end procedure rb_greset;

    procedure dma_access(constant we : in slbit;
                         constant addr : in slv20;
                         constant be : in slv4;
                         constant data : in slv32;
                         variable dout : out slv32) is
    begin
      wait until falling_edge(CLK);
      DMA_WE <= we;
      DMA_ADDR <= addr;
      DMA_BE <= be;
      DMA_DI <= data;
      DMA_REQ <= '1';
      for cycle in 0 to 5000 loop
        wait until rising_edge(CLK);
        exit when DMA_BUSY = '0';
      end loop;
      assert DMA_BUSY = '0'
        report "CPU traffic starved the DMA request" severity failure;
      DMA_REQ <= '0';
      for cycle in 0 to 5000 loop
        wait until rising_edge(CLK);
        exit when DMA_ACK_R = '1' or DMA_ACK_W = '1';
      end loop;
      assert (we = '1' and DMA_ACK_W = '1') or (we = '0' and DMA_ACK_R = '1')
        report "DMA access did not complete" severity failure;
      dout := DMA_DO;
    end procedure dma_access;

    procedure wait_cpu_progress is
      variable count : slv16;
    begin
      count := RAM(129)(15 downto 0);
      for cycle in 0 to 5000 loop
        wait until rising_edge(CLK);
        exit when RAM(129)(15 downto 0) /= count;
      end loop;
      assert RAM(129)(15 downto 0) /= count
        report "CPU stopped making progress" severity failure;
    end procedure wait_cpu_progress;

    variable r0 : slv16;
    variable dout : slv32;
    variable reads : natural;
    variable value : slv32;
  begin
    wait for 30 ns;
    wait until falling_edge(CLK);
    RESET <= '0';

    rb_write(x"000f", x"0000"); -- PC = 0
    rb_write(x"0001", x"0001"); -- start CPU
    for cycle in 0 to 5000 loop
      wait until rising_edge(CLK);
      exit when CP_STAT.cpugo = '1' and DATA_READS >= 1;
    end loop;
    assert CP_STAT.cpugo = '1' and DATA_READS >= 1
      report "CPU did not execute the memory-read loop" severity failure;

    -- Start DMA writes and reads at every phase of the CPU loop.  A lost
    -- CPU request would stop the loop; a missed invalidation would keep the
    -- CPU from refetching the DMA-updated word.
    for phase in 0 to 63 loop
      for cycle in 1 to phase loop
        wait until rising_edge(CLK);
      end loop;
      value := x"a5c3" & std_logic_vector(to_unsigned(phase, 16));
      reads := DATA_READS;
      dma_access('1', x"00080", "1111", value, dout);
      assert RAM(128) = value
        report "DMA write did not update backing memory" severity failure;
      for cycle in 0 to 5000 loop
        wait until rising_edge(CLK);
        exit when DATA_READS > reads;
      end loop;
      assert DATA_READS > reads
        report "CPU did not refetch the DMA-updated word at phase " &
          integer'image(phase) & ", counter " &
          integer'image(to_integer(unsigned(RAM(129)(15 downto 0))))
        severity failure;
      wait_cpu_progress;

      for cycle in 1 to phase loop
        wait until rising_edge(CLK);
      end loop;
      dma_access('0', x"00081", "1111", x"00000000", dout);
      assert dout(15 downto 0) /= x"0000"
        report "DMA read did not see the CPU-written counter"
        severity failure;
      wait_cpu_progress;
    end loop;

    -- Byte-lane write: only the low byte of the word read by the CPU changes.
    dma_access('1', x"00080", "0001", x"ffffff5a", dout);
    assert RAM(128) = x"a5c3005a"
      report "DMA byte-enable write changed the wrong bytes" severity failure;
    reads := DATA_READS;
    for cycle in 0 to 5000 loop
      wait until rising_edge(CLK);
      exit when DATA_READS > reads;
    end loop;
    wait_cpu_progress;

    rb_write(x"0001", x"0002"); -- stop CPU
    rb_read(x"0008", r0);        -- read R0
    assert r0 = x"005a"
      report "CPU register did not observe the DMA update" severity failure;
    dma_access('0', x"00081", "1111", x"00000000", dout);
    assert dout = RAM(129)
      report "DMA read after CPU stop returned wrong data" severity failure;

    -- GRESET at every point of a DMA write, with the word cached by the CPU.
    -- The memory side keeps running, so the write and its invalidation must
    -- complete and the restarted CPU must load the new value.
    for delay in 0 to 15 loop
      rb_write(x"000f", x"0000"); -- PC = 0
      rb_write(x"0001", x"0001"); -- start CPU
      wait_cpu_progress;
      wait_cpu_progress;          -- MOV done: word 128 is now cached

      value := x"b00d" & std_logic_vector(to_unsigned(delay, 16));
      wait until falling_edge(CLK);
      DMA_ACK_CLR <= '1';
      DMA_WE <= '1';
      DMA_ADDR <= x"00080";
      DMA_BE <= "1111";
      DMA_DI <= value;
      DMA_REQ <= '1';
      for cycle in 0 to 5000 loop
        wait until rising_edge(CLK);
        exit when DMA_BUSY = '0';
      end loop;
      assert DMA_BUSY = '0'
        report "CPU traffic starved the DMA request" severity failure;
      DMA_REQ <= '0';
      DMA_ACK_CLR <= '0';
      for cycle in 1 to delay loop
        wait until rising_edge(CLK);
      end loop;
      rb_greset;
      for cycle in 0 to 5000 loop
        wait until rising_edge(CLK);
        exit when DMA_ACK_SEEN = '1';
      end loop;
      assert DMA_ACK_SEEN = '1'
        report "DMA write lost by GRESET at delay " & integer'image(delay)
        severity failure;
      assert RAM(128) = value
        report "DMA write did not reach memory" severity failure;
      assert CP_STAT.cpugo = '0'
        report "CPU still running after GRESET" severity failure;

      rb_write(x"000f", x"0000"); -- PC = 0
      rb_write(x"0001", x"0001"); -- restart CPU
      wait_cpu_progress;
      rb_write(x"0001", x"0002"); -- stop CPU
      rb_read(x"0008", r0);
      assert r0 = value(15 downto 0)
        report "stale cache line after GRESET at delay " &
          integer'image(delay) severity failure;
    end loop;

    report "tb_w11_cpu_dma_path completed" severity note;
    STOP_CLOCK <= true;
    wait;
  end process proc_stim;

  proc_timeout: process
  begin
    wait for 1 ms;
    assert STOP_CLOCK report "CPU/DMA simulation timed out" severity failure;
    wait;
  end process proc_timeout;
end sim;
