-- SPDX-License-Identifier: GPL-3.0-or-later
-- ibd_dl11n with TXD looped back to RXD: registers, 7-bit transmit,
-- receive, interrupts and their acknowledge, overrun, BRESET, remote write.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;
use work.iblib.all;

entity tb_ibd_dl11n is
end tb_ibd_dl11n;

architecture sim of tb_ibd_dl11n is
  signal CLK : slbit := '0';
  signal RESET : slbit := '1';
  signal BRESET : slbit := '0';
  signal STOP_CLOCK : boolean := false;
  signal IB_MREQ : ib_mreq_type := ib_mreq_init;
  signal IB_SRES : ib_sres_type := ib_sres_init;
  signal EI_REQ_RX, EI_REQ_TX : slbit := '0';
  signal EI_ACK_RX, EI_ACK_TX : slbit := '0';
  signal SER : slbit := '1';
  constant rcsr : natural := 8#177560#;
  constant rbuf : natural := 8#177562#;
  constant xcsr : natural := 8#177564#;
  constant xbuf : natural := 8#177566#;
begin
  CLK <= not CLK after 5 ns when not STOP_CLOCK else '0';

  DUT: entity work.ibd_dl11n
    generic map (CLKDIV => 15)
    port map (CLK => CLK, RESET => RESET, BRESET => BRESET,
              IB_MREQ => IB_MREQ, IB_SRES => IB_SRES,
              EI_REQ_RX => EI_REQ_RX, EI_REQ_TX => EI_REQ_TX,
              EI_ACK_RX => EI_ACK_RX, EI_ACK_TX => EI_ACK_TX,
              I_RXD => SER, O_TXD => SER);

  proc_stim: process
    procedure ib(constant addr : in natural; constant we : in slbit;
                 constant data : in natural; variable dout : out slv16;
                 constant racc : in slbit := '0') is
    begin
      wait until falling_edge(CLK);
      IB_MREQ.aval <= '1';
      IB_MREQ.addr <= slv(to_unsigned(addr mod 8192, 13)(12 downto 1));
      IB_MREQ.din <= slv(to_unsigned(data, 16));
      IB_MREQ.be0 <= '1';
      IB_MREQ.be1 <= '1';
      IB_MREQ.racc <= racc;
      wait until falling_edge(CLK);
      IB_MREQ.we <= we;
      IB_MREQ.re <= not we;
      wait until rising_edge(CLK);
      assert IB_SRES.ack = '1' report "ibus not acked" severity failure;
      dout := IB_SRES.dout;
      wait until falling_edge(CLK);
      IB_MREQ <= ib_mreq_init;
    end procedure ib;
    procedure expect(constant addr, val : in natural; constant what : in string) is
      variable d : slv16;
    begin
      ib(addr, '0', 0, d);
      assert d = slv(to_unsigned(val, 16))
        report what & ": got " & integer'image(to_integer(unsigned(d)))
        severity failure;
    end procedure expect;
    procedure wait_for(signal s : in slbit; constant what : in string) is
    begin
      for i in 0 to 5000 loop
        wait until rising_edge(CLK);
        exit when s = '1';
      end loop;
      assert s = '1' report "timeout: " & what severity failure;
    end procedure wait_for;
    procedure ack(signal a : out slbit) is
    begin
      wait until falling_edge(CLK);
      a <= '1';
      wait until falling_edge(CLK);
      a <= '0';
    end procedure ack;
    variable d : slv16;
  begin
    wait for 30 ns;
    wait until falling_edge(CLK);
    RESET <= '0';

    expect(rcsr, 0, "RCSR reset");
    expect(xcsr, 8#200#, "XCSR reset");

    -- setting XIE while XRDY: transmit interrupt, cleared by acknowledge
    ib(xcsr, '1', 8#100#, d);
    wait_for(EI_REQ_TX, "tx interrupt on XIE");
    ack(EI_ACK_TX);
    assert EI_REQ_TX = '0' report "tx request not cleared" severity failure;

    -- send 0xC1: XRDY drops, 7-bit 0x41 comes back, XRDY and interrupt
    ib(xbuf, '1', 16#c1#, d);
    ib(xcsr, '0', 0, d);
    assert d(7) = '0' report "XRDY not cleared by XBUF" severity failure;
    wait_for(EI_REQ_TX, "tx interrupt after the character");
    ack(EI_ACK_TX);
    expect(xcsr, 8#300#, "XCSR after send");
    for i in 0 to 2000 loop wait until rising_edge(CLK); end loop;
    expect(rcsr, 8#200#, "RCSR RDONE");
    assert EI_REQ_RX = '0' report "rx request without RIE" severity failure;
    ib(rcsr, '1', 8#100#, d);              -- RIE while RDONE: interrupt
    wait_for(EI_REQ_RX, "rx interrupt on RIE");
    ack(EI_ACK_RX);
    expect(rbuf, 16#41#, "RBUF 7-bit data");
    expect(rcsr, 8#100#, "RDONE cleared by RBUF read");

    -- received character with RIE set: interrupt; two without read: OVR
    ib(xbuf, '1', 16#52#, d);
    wait_for(EI_REQ_RX, "rx interrupt on receive");
    ack(EI_ACK_RX);
    ib(xbuf, '1', 16#53#, d);
    for i in 0 to 3000 loop wait until rising_edge(CLK); end loop;
    expect(rbuf, 8#140000# + 16#53#, "RBUF OVR");

    -- remote writes are ignored, BRESET clears enables
    ib(xcsr, '1', 0, d, '1');
    expect(xcsr, 8#300#, "XCSR after remote write");
    wait until falling_edge(CLK);
    BRESET <= '1';
    wait until falling_edge(CLK);
    BRESET <= '0';
    expect(rcsr, 0, "RCSR after BRESET");
    expect(xcsr, 8#200#, "XCSR after BRESET");

    report "tb_ibd_dl11n completed" severity note;
    STOP_CLOCK <= true;
    wait;
  end process proc_stim;
end sim;
