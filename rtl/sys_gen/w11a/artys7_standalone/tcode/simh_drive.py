#!/usr/bin/env python3
# Drive SimH pdp11 (V3.8) through a pty: boot 2.11BSD from an image copy and
# run a list of shell commands at the single-user prompt.
#   simh_drive.py <image> <fpp|nofpp> <logfile> <cmdfile> [bootname]
# cmdfile: one command per line; lines "@wait <regex> <sec>" wait for text.
import os, pty, re, select, sys, time

img, fpp, logf, cmdf = sys.argv[1:5]
bootname = sys.argv[5] if len(sys.argv) > 5 else ""
ini = f"""set cpu 11/70
set cpu 4M
set cpu {fpp}
set rp0 rp07
attach rp0 {img}
boot rp0
"""
inif = logf + ".ini"
open(inif, "w").write(ini)
log = open(logf, "wb")
pid, fd = pty.fork()
if pid == 0:
    os.execvp("pdp11", ["pdp11", inif])
buf = b""

def read_for(sec):
    global buf
    end = time.time() + sec
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if fd in r:
            try:
                d = os.read(fd, 4096)
            except OSError:
                return False
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
        if not read_for(0.5):
            return False
    return False

def send(s):
    # one character at a time, paced by its echo: the guest tty drops
    # typed-ahead characters
    global buf
    for ch in s.encode():
        os.write(fd, bytes([ch]))
        r, _, _ = select.select([fd], [], [], 1.0)
        if fd in r:
            try:
                d = os.read(fd, 4096)
            except OSError:
                return
            buf += d
            log.write(d); log.flush()
        time.sleep(0.003)

ok = expect(r": $|: \Z", 60) or expect(r":", 5)
time.sleep(0.5)
send(bootname + "\r")
if not expect(r"\n# ", 180):
    print("SIMH-E: no single user prompt")
send("PS1='@@# '\r")                 # unique prompt, '# ' is also a comment
expect(r"\n@@# ", 20)
nosync = False
halted = False
for line in open(cmdf):
    line = line.rstrip("\n")
    if not line.strip():
        continue
    if line.startswith("@ctrl "):       # raw control character, no CR
        os.write(fd, bytes([int(line.split()[1], 16)]))
        continue
    if line.startswith("@halt"):         # sync, halt, wait for the stop
        for c in ("sync", "sync"):
            send(c + "\r")
            expect(r"\n@@# ", 60)
        send("halt\r")
        expect(r"HALT instruction", 60)
        nosync = True
        halted = True
        continue
    if line.startswith("@nosync"):
        nosync = True
        continue
    if line.startswith("@wait "):
        _, pat, sec = line.split(" ", 2)
        if not expect(pat, float(sec)):
            print(f"SIMH-E: timeout waiting for {pat}")
        continue
    send(line + "\r")
    if not expect(r"\n@@# ", 1800):
        print(f"SIMH-E: no prompt after: {line}")
for i in range(0 if nosync else 2):  # flush the buffer cache before quitting
    send("sync\r")
    expect(r"\n@@# ", 60)
time.sleep(2)
if not halted:
    send("\x05")                # ^E: back to the simulator
expect(r"sim> ", 10)
send("quit\r")
read_for(2)
log.close()
