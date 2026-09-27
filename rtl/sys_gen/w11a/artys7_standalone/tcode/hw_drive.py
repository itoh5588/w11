#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Drive the w11 console (DL11 relayed by ti_w11 on tcp port 8000): boot
# 2.11BSD from the boot prompt and run shell commands, like simh_drive.py.
#   hw_drive.py <logfile> <cmdfile> [port]
# cmdfile lines:
#   <command>            sent with CR, then wait for the shell prompt
#   @boot [name]         wait for the boot prompt ':' and answer name/CR,
#                        then wait for the single user '#' and set PS1
#   @multi               ^D to multi user, wait for login:, log in as root
#   @send <text>         send text with CR, do not wait for the prompt
#   @ctrl <hex>          send a raw character
#   @wait <regex> <sec>  wait for text
#   @sleep <sec>
#   @halt                sync, sync, halt, wait for "halting"
import re, select, socket, sys, time

logf, cmdf = sys.argv[1:3]
port = int(sys.argv[3]) if len(sys.argv) > 3 else 8000
log = open(logf, "wb")
for i in range(30):
    try:
        s = socket.create_connection(("localhost", port))
        break
    except OSError:
        time.sleep(1)
buf = b""

def read_for(sec):
    global buf
    end = time.time() + sec
    while time.time() < end:
        r, _, _ = select.select([s], [], [], min(0.2, max(0.0, end - time.time())))
        if s in r:
            d = s.recv(4096)
            if not d:
                return False
            buf += d
            log.write(d); log.flush()
    return True

def expect(pat, sec):
    global buf
    rx = re.compile(pat.encode())
    end = time.time() + sec
    while time.time() < end:
        m = rx.search(buf)
        if m:
            buf = buf[m.end():]
            return True
        if not read_for(0.3):
            return False
    print("HW-E: timeout waiting for", pat)
    return False

def send(txt):                   # paced by the echo, the tty drops type-ahead
    for ch in txt.encode():
        s.send(bytes([ch]))
        read_for(0.02)

def cmd(c, sec=1800):
    send(c + "\r")
    return expect(r"\n@@# ", sec)

for line in open(cmdf):
    line = line.rstrip("\n")
    if not line.strip():
        continue
    w = line.split()
    if w[0] == "@boot":
        expect(r": ", 60)
        time.sleep(0.5)
        send((w[1] if len(w) > 1 else "") + "\r")
        expect(r"\n# ", 180)
        send("PS1='@@# '\r")
        expect(r"\n@@# ", 20)
    elif w[0] == "@multi":
        s.send(b"\x04")
        expect(r"login: ", 300)
        send("root\r")
        expect(r"\n# ", 60)
        send("PS1='@@# '\r")
        expect(r"\n@@# ", 20)
    elif w[0] == "@send":               # text + CR, no prompt expected
        send(line.split(" ", 1)[1] + "\r")
    elif w[0] == "@ctrl":
        s.send(bytes([int(w[1], 16)]))
    elif w[0] == "@wait":
        expect(w[1], float(w[2]))
    elif w[0] == "@sleep":
        read_for(float(w[1]))
    elif w[0] == "@halt":
        cmd("sync")
        cmd("sync")
        send("halt\r")
        expect(r"halting", 60)
        read_for(2)
    else:
        if not cmd(line):
            print("HW-E: no prompt after:", line)
log.close()
