-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Behavioral SD card in SPI mode, for simulation only.  Written from the
-- SD physical layer specification (simplified): CMD0, CMD8, CMD9, CMD10,
-- CMD12, CMD16, CMD17, CMD18, CMD55, ACMD41, CMD58; every command CRC7 is
-- checked.  CMD18 streams blocks until CMD12; CMD12 answers with a stuff
-- byte 0x3c (bit 7 clear, must be skipped), R1 and three busy bytes.
-- CMD24 receives token, 512 bytes and CRC16 (checked), answers the data
-- response 0x05 and busy bytes and keeps the block (up to 32 blocks), so
-- later reads return it.  CMD13 answers R2.
--
-- MODE: 0 no card (MISO stays high), 1 SDHC v2 (block addressing),
--       2 SDSC v1 (byte addressing, CMD8 illegal), 3 SDHC with a wrong data
--       CRC on CMD17/18, 4 SDHC answering CMD17/18 with error token 0x08,
--       5 SDHC rejecting write data (CRC error 0x0b), 6 SDHC with a write
--       error (data response 0x0d, CMD13 status 0x04).
-- Block data: byte i of block L is (L*37 + i) mod 256 xor 0x55*(i/256).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.slvtypes.all;

entity sdcard_spi_model is
  port (
    MODE : in natural;
    CS_N : in slbit;
    SCLK : in slbit;
    MOSI : in slbit;
    MISO : out slbit
  );
end sdcard_spi_model;

architecture sim of sdcard_spi_model is
begin

  proc_card: process (CS_N, SCLK, MODE)
    type byte_array is array (natural range <>) of slv8;
    variable outq : byte_array(0 to 1023);
    variable qhead : natural := 0;
    variable qtail : natural := 0;
    variable obyte : slv8 := x"ff";
    variable ibyte : slv8 := x"ff";
    variable nbit : natural := 0;
    variable cmd : byte_array(0 to 5);
    variable ncmd : natural := 0;
    variable idle : boolean := true;
    variable ready : boolean := false;
    variable acmd : boolean := false;
    variable busycnt : natural := 3;
    variable last_mode : natural := 99;
    variable arg : unsigned(31 downto 0);
    variable blk : natural;
    variable crc : slv16;
    variable c40 : slv(39 downto 0);
    variable streaming : boolean := false;
    variable sblk : natural := 0;
    type store_type is array (0 to 31) of byte_array(0 to 511);
    type tag_type is array (0 to 31) of integer;
    variable store : store_type;
    variable tags : tag_type := (others => -1);
    variable nstore : natural := 0;
    variable wphase : natural := 0;     -- 0 cmd, 1 token, 2 data, 3 crc
    variable wlba : natural := 0;
    variable wcnt : natural := 0;
    variable wbuf : byte_array(0 to 511);
    variable wcrc : slv16;
    variable rcrc : slv16;

    procedure push(constant b : in slv8) is
    begin
      outq(qtail) := b;
      qtail := (qtail + 1) mod outq'length;
    end procedure push;

    function crc7(d : slv(39 downto 0)) return slv7 is
      variable c : slv7 := (others => '0');
      variable fb : slbit;
    begin
      for i in 39 downto 0 loop
        fb := c(6) xor d(i);
        c := c(5 downto 0) & '0';
        if fb = '1' then
          c := c xor "0001001";
        end if;
      end loop;
      return c;
    end function crc7;

    function crc16(c_in : slv16; d : slv8) return slv16 is
      variable c : slv16 := c_in;
      variable fb : slbit;
    begin
      for i in 7 downto 0 loop
        fb := c(15) xor d(i);
        c := c(14 downto 0) & '0';
        if fb = '1' then
          c := c xor x"1021";
        end if;
      end loop;
      return c;
    end function crc16;

    impure function blkbyte(l : natural; i : natural) return slv8 is
      variable v : slv8;
    begin
      for k in 0 to 31 loop               -- written blocks first
        if tags(k) = l then
          return store(k)(i);
        end if;
      end loop;
      v := slv(to_unsigned((l * 37 + i) mod 256, 8));
      if i >= 256 then
        v := v xor x"55";
      end if;
      return v;
    end function blkbyte;

    procedure keep_block is
      variable slot : integer := -1;
    begin
      for k in 0 to 31 loop
        if tags(k) = wlba then
          slot := k;
        end if;
      end loop;
      if slot < 0 then
        slot := nstore mod 32;
        nstore := nstore + 1;
      end if;
      tags(slot) := wlba;
      store(slot) := wbuf;
    end procedure keep_block;

    procedure push_block(constant n : in natural; constant l : in natural;
                         constant cid : in boolean;
                         constant badcrc : in boolean) is
      variable b : slv8;
    begin
      push(x"ff");
      push(x"ff");
      push(x"fe");
      crc := (others => '0');
      for i in 0 to n - 1 loop
        if cid then
          b := slv(to_unsigned(16#10# + i, 8));
        else
          b := blkbyte(l, i);
        end if;
        push(b);
        crc := crc16(crc, b);
      end loop;
      if badcrc then
        crc := not crc;
      end if;
      push(crc(15 downto 8));
      push(crc(7 downto 0));
    end procedure push_block;

    procedure r1(constant v : in slv8) is
    begin
      push(x"ff");                      -- NCR = 1
      push(v);
    end procedure r1;

    function r1idle return slv8 is
    begin
      if idle then
        return x"01";
      end if;
      return x"00";
    end function r1idle;

    procedure execute is
      variable idx : natural;
    begin
      idx := to_integer(unsigned(cmd(0)(5 downto 0)));
      c40(39 downto 32) := cmd(0);
      c40(31 downto 24) := cmd(1);
      c40(23 downto 16) := cmd(2);
      c40(15 downto 8) := cmd(3);
      c40(7 downto 0) := cmd(4);
      arg := unsigned(c40(31 downto 0));
      if cmd(5) /= crc7(c40) & '1' then
        r1(x"09");                      -- idle + com crc error
        acmd := false;
        return;
      end if;
      if acmd and idx = 41 then
        acmd := false;
        if busycnt > 0 then
          busycnt := busycnt - 1;
          r1(x"01");
        else
          idle := false;
          ready := true;
          r1(x"00");
        end if;
        return;
      end if;
      acmd := false;
      case idx is
        when 0 =>
          idle := true;
          ready := false;
          busycnt := 3;
          r1(x"01");
        when 8 =>
          if MODE = 2 then
            r1(x"05");                  -- illegal command
          else
            r1(r1idle);
            push(x"00");
            push(x"00");
            push(x"0" & slv(arg(11 downto 8)));
            push(slv(arg(7 downto 0)));
          end if;
        when 55 =>
          acmd := true;
          r1(r1idle);
        when 58 =>
          r1(r1idle);
          if ready and MODE /= 2 then
            push(x"c0");                -- power up done, CCS
          elsif ready then
            push(x"80");
          else
            push(x"00");
          end if;
          push(x"ff");
          push(x"80");
          push(x"00");
        when 16 =>
          r1(r1idle);
        when 9 | 10 =>
          r1(r1idle);
          push_block(16, 0, true, false);
        when 24 =>
          if not ready then
            r1(x"01");
          else
            r1(x"00");
            if MODE = 2 then
              wlba := to_integer(arg / 512);
            else
              wlba := to_integer(arg);
            end if;
            wphase := 1;
          end if;
        when 13 =>
          r1(r1idle);
          if MODE = 6 then
            push(x"04");
          else
            push(x"00");
          end if;
        when 12 =>
          streaming := false;
          qhead := qtail;               -- drop the rest of the stream
          push(x"3c");                  -- stuff byte
          push(x"00");                  -- R1
          push(x"00");                  -- busy
          push(x"00");
          push(x"00");
        when 18 =>
          if not ready then
            r1(x"01");
          else
            r1(x"00");
            if MODE = 2 then
              sblk := to_integer(arg / 512);
            else
              sblk := to_integer(arg);
            end if;
            if MODE = 4 then
              push(x"ff");
              push(x"08");
            else
              streaming := true;
            end if;
          end if;
        when 17 =>
          if not ready then
            r1(x"01");
          else
            r1(x"00");
            if MODE = 2 then
              blk := to_integer(arg / 512);
            else
              blk := to_integer(arg);
            end if;
            if MODE = 4 then
              push(x"ff");
              push(x"08");              -- error token: out of range
            else
              push_block(512, blk, false, MODE = 3);
            end if;
          end if;
        when others =>
          r1(x"04");                    -- illegal command
      end case;
    end procedure execute;

  begin
    if MODE /= last_mode then           -- (re)insert card
      last_mode := MODE;
      idle := true;
      ready := false;
      acmd := false;
      busycnt := 3;
      qhead := 0;
      qtail := 0;
      ncmd := 0;
      streaming := false;
      wphase := 0;
    end if;

    if MODE = 0 or CS_N = '1' then
      MISO <= '1';
      nbit := 0;
      if CS_N'event and CS_N = '1' then
        qhead := qtail;                 -- drop pending output
        ncmd := 0;
        streaming := false;
        wphase := 0;
      end if;
    elsif CS_N'event and CS_N = '0' then
      nbit := 0;
      obyte := x"ff";
      MISO <= '1';
    elsif rising_edge(SCLK) then
      ibyte := ibyte(6 downto 0) & MOSI;
      nbit := nbit + 1;
      if nbit = 8 then
        nbit := 0;
        if wphase = 1 then                -- CMD24: wait for the start token
          if ibyte = x"fe" then
            wphase := 2;
            wcnt := 0;
            wcrc := (others => '0');
          end if;
        elsif wphase = 2 then
          wbuf(wcnt) := ibyte;
          wcrc := crc16(wcrc, ibyte);
          wcnt := wcnt + 1;
          if wcnt = 512 then
            wphase := 3;
            wcnt := 0;
          end if;
        elsif wphase = 3 then
          rcrc := rcrc(7 downto 0) & ibyte;
          wcnt := wcnt + 1;
          if wcnt = 2 then
            wphase := 0;
            if rcrc /= wcrc or MODE = 5 then
              push(x"0b");                -- data rejected: CRC error
            elsif MODE = 6 then
              push(x"0d");                -- write error
            else
              keep_block;
              push(x"05");                -- data accepted
              push(x"00");                -- busy
              push(x"00");
              push(x"00");
              push(x"00");
            end if;
          end if;
        elsif ncmd = 0 then
          if ibyte(7 downto 6) = "01" then
            cmd(0) := ibyte;
            ncmd := 1;
          end if;
        else
          cmd(ncmd) := ibyte;
          ncmd := ncmd + 1;
          if ncmd = 6 then
            ncmd := 0;
            execute;
          end if;
        end if;
      end if;
    elsif falling_edge(SCLK) then
      if nbit = 0 then                  -- byte boundary: next output byte
        if qhead = qtail and streaming then
          push_block(512, sblk, false, MODE = 3);
          sblk := sblk + 1;
        end if;
        if qhead /= qtail then
          obyte := outq(qhead);
          qhead := (qhead + 1) mod outq'length;
        else
          obyte := x"ff";
        end if;
      else
        obyte := obyte(6 downto 0) & '1';
      end if;
      MISO <= obyte(7);
    end if;
  end process proc_card;

end sim;
