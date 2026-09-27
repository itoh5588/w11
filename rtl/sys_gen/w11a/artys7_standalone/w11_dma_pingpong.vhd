-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- DMA master for the native DMA ping-pong coherence test.  Works together
-- with tcode/dma_pingpong.mac running on the PDP-11 CPU:
--   1. write buf[j] = seq+j (16-bit words j, 512 words at byte 0x8000);
--      odd iterations use two writes with byte enables 0101 and 1010
--   2. write seq (byte 0x8400, byte enables 0011; ack in the high half of
--      the same 32-bit word must survive)
--   3. poll ack by DMA read until ack = seq
--   4. read obuf (byte 0x8800) and check the complement the CPU wrote there
--
-- rbus registers (RB_ADDR + n):
--   0 cntl  rw  bit0: run  bit1: clear counters (write only)
--   1 stat  r   bit0: busy  bit1: waiting for ack  bits 7:4: state
--   2 iter  r   completed iterations
--   3 err   r   mismatches seen by DMA reads
--   4 seq   r   current seq
--   5 eadr  r   32-bit word index of last mismatch
--   6 edlo  r   last mismatching data, low half
--   7 edhi  r   last mismatching data, high half
--   8 wlat  r   max DMA write latency, cycles from request to acknowledge
--               (includes the cache invalidation), saturates at 0xffff
--   9 rlat  r   max DMA read latency, cycles from request to acknowledge
--   cntl bit1 also clears wlat and rlat
--
-- DMA protocol: DMA_REQ is held until DMA_BUSY is low at a clock edge, which
-- is the edge the request is taken.  Only an acknowledge after that edge
-- belongs to the request.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;
use work.rblib.all;

entity w11_dma_pingpong is
  generic (
    RB_ADDR : slv16 := x"fd00");
  port (
    CLK : in slbit;
    RESET : in slbit;
    RB_MREQ : in rb_mreq_type;
    RB_SRES : out rb_sres_type;
    DMA_REQ : out slbit;
    DMA_WE : out slbit;
    DMA_BUSY : in slbit;
    DMA_ACK_R : in slbit;
    DMA_ACK_W : in slbit;
    DMA_ADDR : out slv20;
    DMA_BE : out slv4;
    DMA_DI : out slv32;
    DMA_DO : in slv32
  );
end w11_dma_pingpong;

architecture syn of w11_dma_pingpong is

  constant buf_waddr : unsigned(19 downto 0) := x"02000"; -- byte 0x8000
  constant seq_waddr : slv20 := x"02100";                 -- byte 0x8400
  constant obuf_waddr : unsigned(19 downto 0) := x"02200"; -- byte 0x8800
  constant nbuf : natural := 256;                         -- 32-bit words
  constant poll_delay : natural := 63;

  type state_type is (s_idle, s_wr_req, s_wr_wait, s_seq_req, s_seq_wait,
                      s_poll_req, s_poll_wait, s_poll_delay,
                      s_rd_req, s_rd_wait);

  type regs_type is record
    state : state_type;
    run : slbit;
    idx : unsigned(7 downto 0);
    half : slbit;                       -- second byte-lane write
    seq : unsigned(15 downto 0);
    delay : natural range 0 to poll_delay;
    iter : unsigned(15 downto 0);
    err : unsigned(15 downto 0);
    eadr : slv16;
    edat : slv32;
    lat : unsigned(15 downto 0);        -- current request latency
    wlat : unsigned(15 downto 0);
    rlat : unsigned(15 downto 0);
  end record regs_type;

  constant regs_init : regs_type := (
    s_idle, '0', (others => '0'), '0', (others => '0'), 0,
    (others => '0'), (others => '0'), (others => '0'), (others => '0'),
    (others => '0'), (others => '0'), (others => '0'));

  signal R_REGS : regs_type := regs_init;
  signal N_REGS : regs_type := regs_init;
  signal R_SEL : slbit := '0';

  function state_code(s : state_type) return slv4 is
  begin
    return slv(to_unsigned(state_type'pos(s), 4));
  end function state_code;

begin

  RBSEL : rb_sel
    generic map (RB_ADDR => RB_ADDR, SAWIDTH => 4)
    port map (CLK => CLK, RB_MREQ => RB_MREQ, SEL => R_SEL);

  proc_regs: process (CLK)
  begin
    if rising_edge(CLK) then
      if RESET = '1' then
        R_REGS <= regs_init;
      else
        R_REGS <= N_REGS;
      end if;
    end if;
  end process proc_regs;

  proc_next: process (R_REGS, R_SEL, RB_MREQ, DMA_BUSY, DMA_ACK_R, DMA_ACK_W,
                      DMA_DO)
    variable r : regs_type := regs_init;
    variable n : regs_type := regs_init;
    variable ireq : slbit := '0';
    variable iwe : slbit := '0';
    variable iaddr : slv20 := (others => '0');
    variable ibe : slv4 := (others => '0');
    variable idi : slv32 := (others => '0');
    variable vlo : unsigned(15 downto 0);
    variable vhi : unsigned(15 downto 0);
    variable irb_ack : slbit := '0';
    variable irb_dout : slv16 := (others => '0');
  begin
    r := R_REGS;
    n := R_REGS;

    -- expected buffer contents for the current word
    vlo := r.seq + shift_left(resize(r.idx, 16), 1);
    vhi := vlo + 1;

    -- request latency: counts from the first request cycle to the ack
    if r.lat /= x"ffff" then
      n.lat := r.lat + 1;
    end if;
    if DMA_ACK_W = '1' and r.lat > r.wlat then
      n.wlat := r.lat;
    end if;
    if DMA_ACK_R = '1' and r.lat > r.rlat then
      n.rlat := r.lat;
    end if;

    ireq := '0';
    iwe := '0';
    iaddr := slv(buf_waddr + resize(r.idx, 20));
    ibe := "1111";
    idi := slv(vhi) & slv(vlo);

    case r.state is
      when s_idle =>
        if r.run = '1' then
          n.seq := r.seq + 1;
          if r.seq = x"ffff" then
            n.seq := x"0001";           -- the CPU treats seq=0 as seen
          end if;
          n.idx := (others => '0');
          n.half := '0';
          n.state := s_wr_req;
          n.lat := (others => '0');
        end if;

      when s_wr_req =>
        ireq := '1';
        iwe := '1';
        if r.seq(0) = '1' then          -- odd seq: two byte-lane writes
          if r.half = '0' then
            ibe := "0101";
          else
            ibe := "1010";
          end if;
        end if;
        if DMA_BUSY = '0' then
          n.state := s_wr_wait;
        end if;

      when s_wr_wait =>
        if DMA_ACK_W = '1' then
          if r.seq(0) = '1' and r.half = '0' then
            n.half := '1';
            n.state := s_wr_req;
            n.lat := (others => '0');
          else
            n.half := '0';
            n.idx := r.idx + 1;
            if r.idx = nbuf - 1 then
              n.state := s_seq_req;
              n.lat := (others => '0');
            else
              n.state := s_wr_req;
              n.lat := (others => '0');
            end if;
          end if;
        end if;

      when s_seq_req =>
        ireq := '1';
        iwe := '1';
        iaddr := seq_waddr;
        ibe := "0011";
        idi := x"dead" & slv(r.seq);    -- high half must not be written
        if DMA_BUSY = '0' then
          n.state := s_seq_wait;
        end if;

      when s_seq_wait =>
        if DMA_ACK_W = '1' then
          n.state := s_poll_req;
          n.lat := (others => '0');
        end if;

      when s_poll_req =>
        ireq := '1';
        iaddr := seq_waddr;
        if DMA_BUSY = '0' then
          n.state := s_poll_wait;
        end if;

      when s_poll_wait =>
        if DMA_ACK_R = '1' then
          if DMA_DO(15 downto 0) /= slv(r.seq) then -- seq was damaged
            n.err := r.err + 1;
            n.eadr := slv(resize(unsigned(seq_waddr), 16));
            n.edat := DMA_DO;
          end if;
          if DMA_DO(31 downto 16) = slv(r.seq) then
            n.idx := (others => '0');
            n.state := s_rd_req;
            n.lat := (others => '0');
          else
            n.delay := poll_delay;
            n.state := s_poll_delay;
          end if;
        end if;

      when s_poll_delay =>              -- leave memory bandwidth to the CPU
        if r.delay = 0 then
          n.state := s_poll_req;
          n.lat := (others => '0');
        else
          n.delay := r.delay - 1;
        end if;

      when s_rd_req =>
        ireq := '1';
        iaddr := slv(obuf_waddr + resize(r.idx, 20));
        if DMA_BUSY = '0' then
          n.state := s_rd_wait;
        end if;

      when s_rd_wait =>
        if DMA_ACK_R = '1' then
          if DMA_DO /= (not slv(vhi)) & (not slv(vlo)) then
            n.err := r.err + 1;
            n.eadr := slv(resize(obuf_waddr + resize(r.idx, 20), 16));
            n.edat := DMA_DO;
          end if;
          n.idx := r.idx + 1;
          if r.idx = nbuf - 1 then
            n.iter := r.iter + 1;
            n.state := s_idle;
          else
            n.state := s_rd_req;
            n.lat := (others => '0');
          end if;
        end if;
    end case;

    -- rbus
    irb_ack := '0';
    irb_dout := (others => '0');
    if R_SEL = '1' then
      irb_ack := RB_MREQ.re or RB_MREQ.we;
      if RB_MREQ.we = '1' and RB_MREQ.addr(3 downto 0) = "0000" then
        n.run := RB_MREQ.din(0);
        if RB_MREQ.din(1) = '1' then
          n.wlat := (others => '0');
          n.rlat := (others => '0');
          n.iter := (others => '0');
          n.err := (others => '0');
          n.eadr := (others => '0');
          n.edat := (others => '0');
        end if;
      end if;
      if RB_MREQ.re = '1' then
        case RB_MREQ.addr(3 downto 0) is
          when "0000" => irb_dout(0) := r.run;
          when "0001" =>
            if r.state /= s_idle then
              irb_dout(0) := '1';
            end if;
            if r.state = s_poll_req or r.state = s_poll_wait or
               r.state = s_poll_delay then
              irb_dout(1) := '1';
            end if;
            irb_dout(7 downto 4) := state_code(r.state);
          when "0010" => irb_dout := slv(r.iter);
          when "0011" => irb_dout := slv(r.err);
          when "0100" => irb_dout := slv(r.seq);
          when "0101" => irb_dout := r.eadr;
          when "0110" => irb_dout := r.edat(15 downto 0);
          when "0111" => irb_dout := r.edat(31 downto 16);
          when "1000" => irb_dout := slv(r.wlat);
          when "1001" => irb_dout := slv(r.rlat);
          when others => null;
        end case;
      end if;
    end if;

    N_REGS <= n;

    DMA_REQ <= ireq;
    DMA_WE <= iwe;
    DMA_ADDR <= iaddr;
    DMA_BE <= ibe;
    DMA_DI <= idi;

    RB_SRES.ack <= irb_ack;
    RB_SRES.err <= '0';
    RB_SRES.busy <= '0';
    RB_SRES.dout <= irb_dout;
  end process proc_next;

end syn;
