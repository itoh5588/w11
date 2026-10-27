-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- DMA reader: fills a 256 word block buffer from PDP-11 main memory for an
-- SD block write.  START loads the byte address BASE (22 bit, bit 0
-- ignored) and the number of valid words NWORD (1..256); words beyond NWORD
-- are set to 0 (a partial last block is written with zeros, as on a real
-- disk).  An aligned pair of words is fetched with one 32-bit read and
-- stored in two cycles (one buffer write port).  DONE
-- is a one cycle pulse when the buffer is complete.  The buffer is read by
-- the SD controller through RADDR/RDATA (asynchronous read).
--
-- With UB_ENA set at START, BASE(17:0) is a UNIBUS address and each word is
-- translated through the UNIBUS map in UB_TAB (see ubmap_shadow).  The
-- physical address is registered in s_xlat before each request.  A pair is
-- not fetched across an 8 KB map page, whose next page may lie elsewhere.
--
-- DMA protocol: DMA_REQ is held until DMA_BUSY is low at a clock edge, that
-- edge takes the request; the data come with the later DMA_ACK_R.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;

entity sd_dma_rd is
  port (
    CLK : in slbit;
    RESET : in slbit;
    START : in slbit;
    BASE : in slv22;
    UB_ENA : in slbit := '0';           -- translate through the UNIBUS map
    UB_TAB : in slv(32*21-1 downto 0) := (others => '0');
    NWORD : in slv9;                    -- 1..256
    DONE : out slbit;
    RADDR : in slv8;
    RDATA : out slv16;
    DMA_REQ : out slbit;
    DMA_BUSY : in slbit;
    DMA_ACK_R : in slbit;
    DMA_ADDR : out slv20;
    DMA_DO : in slv32
  );
end sd_dma_rd;

architecture syn of sd_dma_rd is

  type buf_type is array (0 to 255) of slv16;
  signal BUF : buf_type := (others => (others => '0'));

  type state_type is (s_idle, s_xlat, s_req, s_wait, s_hi, s_zero);
  signal R_STATE : state_type := s_idle;
  signal R_WADDR : unsigned(20 downto 0) := (others => '0'); -- word address
  signal R_IDX : unsigned(8 downto 0) := (others => '0');    -- buffer word
  signal R_LEFT : unsigned(8 downto 0) := (others => '0');   -- words to read
  signal R_DONE : slbit := '0';
  signal R_HI : slv16 := (others => '0');                    -- 2nd word
  signal R_UBENA : slbit := '0';
  signal R_PW : unsigned(20 downto 0) := (others => '0');    -- physical
  signal R_PAIR : boolean := false;

begin

  proc_regs: process (CLK)
    variable pw : unsigned(20 downto 0);
    variable n : natural;
  begin
    if rising_edge(CLK) then
      R_DONE <= '0';
      if RESET = '1' then
        R_STATE <= s_idle;
      else
        case R_STATE is
          when s_idle =>
            if START = '1' then
              R_WADDR <= unsigned(BASE(21 downto 1));
              R_UBENA <= UB_ENA;
              R_IDX <= (others => '0');
              R_LEFT <= unsigned(NWORD);
              R_STATE <= s_xlat;
            end if;

          when s_xlat =>
            pw := R_WADDR;
            if R_UBENA = '1' then
              n := to_integer(R_WADDR(16 downto 12));
              pw := unsigned(UB_TAB(21*n+20 downto 21*n)) +
                    resize(R_WADDR(11 downto 0), 21);
            end if;
            R_PW <= pw;
            -- a pair is read when the word is the low half, two are left,
            -- and the second word is in the same map page
            R_PAIR <= pw(0) = '0' and R_LEFT >= 2 and
                      (R_UBENA = '0' or R_WADDR(11 downto 0) /= x"fff");
            R_STATE <= s_req;

          when s_req =>
            if R_LEFT = 0 then
              R_STATE <= s_zero;
            elsif DMA_BUSY = '0' then     -- request taken at this edge
              R_STATE <= s_wait;
            end if;

          when s_wait =>
            if DMA_ACK_R = '1' then
              if R_PW(0) = '0' then
                BUF(to_integer(R_IDX(7 downto 0))) <= DMA_DO(15 downto 0);
              else
                BUF(to_integer(R_IDX(7 downto 0))) <= DMA_DO(31 downto 16);
              end if;
              R_WADDR <= R_WADDR + 1;
              R_IDX <= R_IDX + 1;
              R_LEFT <= R_LEFT - 1;
              if R_PAIR then
                R_HI <= DMA_DO(31 downto 16);
                R_STATE <= s_hi;
              else
                R_STATE <= s_xlat;
              end if;
            end if;

          when s_hi =>                    -- second word of a pair
            BUF(to_integer(R_IDX(7 downto 0))) <= R_HI;
            R_WADDR <= R_WADDR + 1;
            R_IDX <= R_IDX + 1;
            R_LEFT <= R_LEFT - 1;
            R_STATE <= s_xlat;

          when s_zero =>                  -- clear the rest of the block
            if R_IDX = 256 then
              R_DONE <= '1';
              R_STATE <= s_idle;
            else
              BUF(to_integer(R_IDX(7 downto 0))) <= (others => '0');
              R_IDX <= R_IDX + 1;
            end if;
        end case;
      end if;
    end if;
  end process proc_regs;

  DMA_REQ <= '1' when R_STATE = s_req and R_LEFT /= 0 else '0';
  DMA_ADDR <= slv(R_PW(20 downto 1));
  RDATA <= BUF(to_integer(unsigned(RADDR)));
  DONE <= R_DONE;

end syn;
