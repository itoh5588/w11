-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Native DL11 console (ibus, 177560, vectors 060/064, BR4) on a local UART,
-- for the standalone Arty S7 system: no rlink backend is involved.
--
-- Registers (DEC DL11):
--   RCSR 177560  bit7 RDONE (r), bit6 RIE (rw)
--   RBUF 177562  bits 7:0 data, bit14 OVR, bit15 ERR (OVR or frame error);
--                reading RBUF clears RDONE
--   XCSR 177564  bit7 XRDY (r), bit6 XIE (rw), bit2 MAINT (rw, no effect)
--   XBUF 177566  write: send the character; XRDY returns when it is sent
-- Interrupts: a request is set when RDONE (XRDY) rises while RIE (XIE) is
-- set, or when RIE (XIE) is set while RDONE (XRDY) is 1; it is cleared by
-- the interrupt acknowledge, by clearing the enable, and by reading RBUF
-- (writing XBUF).  BRESET clears RIE, XIE, RDONE and the requests.
-- With TO7BIT the transmitted characters have bit 7 cleared (2.11BSD sets a
-- parity bit on console output).  Remote (rlink) writes are ignored and
-- remote reads have no side effects.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;
use work.iblib.all;

entity ibd_dl11n is
  generic (
    IB_ADDR : slv16 := slv(to_unsigned(8#177560#, 16));
    CDWIDTH : positive := 13;
    CLKDIV : natural := 7811;           -- 75 MHz / 9600 - 1
    TO7BIT : boolean := true);
  port (
    CLK : in slbit;
    RESET : in slbit;
    BRESET : in slbit;
    IB_MREQ : in ib_mreq_type;
    IB_SRES : out ib_sres_type;
    EI_REQ_RX : out slbit;
    EI_REQ_TX : out slbit;
    EI_ACK_RX : in slbit;
    EI_ACK_TX : in slbit;
    I_RXD : in slbit;                   -- serial in (from the terminal)
    O_TXD : out slbit                   -- serial out (to the terminal)
  );
end ibd_dl11n;

architecture syn of ibd_dl11n is

  type regs_type is record
    ibsel : slbit;
    rdone : slbit;
    rie : slbit;
    rbuf : slv8;
    rovr : slbit;
    rferr : slbit;
    xrdy : slbit;
    xie : slbit;
    maint : slbit;
    xbuf : slv8;
    xpend : slbit;                      -- character waiting for the UART
    xsent : slbit;                      -- UART took it, wait for not busy
    rxireq : slbit;
    txireq : slbit;
  end record regs_type;

  constant regs_init : regs_type := (
    '0', '0', '0', (others => '0'), '0', '0', '1', '0', '0',
    (others => '0'), '0', '0', '0', '0');

  signal R_REGS : regs_type := regs_init;
  signal N_REGS : regs_type := regs_init;
  signal RXD_S : slv2 := "11";          -- input synchronizer
  signal RXDATA : slv8 := (others => '0');
  signal RXVAL : slbit := '0';
  signal RXERR : slbit := '0';
  signal TXDATA : slv8 := (others => '0');
  signal TXENA : slbit := '0';
  signal TXBUSY : slbit := '0';

begin

  UART : entity work.serport_uart_rxtx
    generic map (CDWIDTH => CDWIDTH)
    port map (
      CLK => CLK, RESET => RESET,
      CLKDIV => slv(to_unsigned(CLKDIV, CDWIDTH)),
      RXSD => RXD_S(1), RXDATA => RXDATA, RXVAL => RXVAL, RXERR => RXERR,
      RXACT => open, TXSD => O_TXD, TXDATA => TXDATA, TXENA => TXENA,
      TXBUSY => TXBUSY);

  proc_regs: process (CLK)
  begin
    if rising_edge(CLK) then
      RXD_S <= RXD_S(0) & I_RXD;
      if RESET = '1' then
        R_REGS <= regs_init;
      else
        R_REGS <= N_REGS;
      end if;
    end if;
  end process proc_regs;

  proc_next: process (R_REGS, IB_MREQ, BRESET, EI_ACK_RX, EI_ACK_TX, RXDATA,
                      RXVAL, RXERR, TXBUSY)
    variable r : regs_type := regs_init;
    variable n : regs_type := regs_init;
    variable idout : slv16 := (others => '0');
    variable iloc : slbit := '0';
    variable itxena : slbit := '0';
  begin
    r := R_REGS;
    n := R_REGS;
    idout := (others => '0');
    iloc := not IB_MREQ.racc;
    itxena := '0';

    n.ibsel := '0';
    if IB_MREQ.aval = '1' and
       IB_MREQ.addr(12 downto 3) = IB_ADDR(12 downto 3) then
      n.ibsel := '1';
    end if;

    -- ibus
    if r.ibsel = '1' then
      case IB_MREQ.addr(2 downto 1) is
        when "00" =>                    -- RCSR
          idout(7) := r.rdone;
          idout(6) := r.rie;
          if IB_MREQ.we = '1' and IB_MREQ.be0 = '1' and iloc = '1' then
            n.rie := IB_MREQ.din(6);
            if IB_MREQ.din(6) = '1' and r.rie = '0' and r.rdone = '1' then
              n.rxireq := '1';
            elsif IB_MREQ.din(6) = '0' then
              n.rxireq := '0';
            end if;
          end if;
        when "01" =>                    -- RBUF
          idout(15) := r.rovr or r.rferr;
          idout(14) := r.rovr;
          idout(7 downto 0) := r.rbuf;
          if IB_MREQ.re = '1' and iloc = '1' then
            n.rdone := '0';
            n.rovr := '0';
            n.rferr := '0';
            n.rxireq := '0';
          end if;
        when "10" =>                    -- XCSR
          idout(7) := r.xrdy;
          idout(6) := r.xie;
          idout(2) := r.maint;
          if IB_MREQ.we = '1' and IB_MREQ.be0 = '1' and iloc = '1' then
            n.xie := IB_MREQ.din(6);
            n.maint := IB_MREQ.din(2);
            if IB_MREQ.din(6) = '1' and r.xie = '0' and r.xrdy = '1' then
              n.txireq := '1';
            elsif IB_MREQ.din(6) = '0' then
              n.txireq := '0';
            end if;
          end if;
        when others =>                  -- XBUF
          if IB_MREQ.we = '1' and IB_MREQ.be0 = '1' and iloc = '1' then
            n.xbuf := IB_MREQ.din(7 downto 0);
            if TO7BIT then
              n.xbuf(7) := '0';
            end if;
            n.xpend := '1';
            n.xrdy := '0';
            n.txireq := '0';
          end if;
      end case;
    end if;

    -- receiver
    if RXVAL = '1' then
      if r.rdone = '1' then
        n.rovr := '1';
      end if;
      n.rbuf := RXDATA;
      n.rferr := RXERR;
      n.rdone := '1';
      if r.rie = '1' then
        n.rxireq := '1';
      end if;
    end if;

    -- transmitter: one character in the UART at a time
    if r.xpend = '1' and TXBUSY = '0' and r.xsent = '0' then
      itxena := '1';
      n.xpend := '0';
      n.xsent := '1';
    end if;
    if r.xsent = '1' and TXBUSY = '1' then
      n.xsent := '0';                   -- UART busy with it now
      n.xpend := '0';
    end if;
    if r.xrdy = '0' and r.xpend = '0' and r.xsent = '0' and TXBUSY = '0' then
      n.xrdy := '1';                    -- character sent
      if r.xie = '1' then
        n.txireq := '1';
      end if;
    end if;

    if EI_ACK_RX = '1' then
      n.rxireq := '0';
    end if;
    if EI_ACK_TX = '1' then
      n.txireq := '0';
    end if;

    if BRESET = '1' then
      n.rie := '0';
      n.xie := '0';
      n.rdone := '0';
      n.rovr := '0';
      n.rferr := '0';
      n.rxireq := '0';
      n.txireq := '0';
    end if;

    N_REGS <= n;

    IB_SRES.ack <= r.ibsel and (IB_MREQ.re or IB_MREQ.we);
    IB_SRES.busy <= '0';
    IB_SRES.dout <= idout;
    EI_REQ_RX <= r.rxireq;
    EI_REQ_TX <= r.txireq;
    TXDATA <= r.xbuf;
    TXENA <= itxena;
  end process proc_next;

end syn;
