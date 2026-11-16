#!/usr/bin/env python3
# Used by review-hardening-test.sh. Sends filler POSTs with a large request
# head to a.test's /echo (mod_reflector) and compares the echoed body with
# what was sent. Up to .8.peruser.dc the worker rebuilt the body from outside
# its buffer once the head passed ~18 KB. Prints one line per size; a head
# over the hand-off's bound must get a 413, and the server must still answer
# afterwards. Exit 0 = all intact, 1 = a difference.
import socket, sys

HOST, PORT = "127.0.0.1", 8080

def send_raw(payload, timeout=8.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect((HOST, PORT)); s.sendall(payload)
        out = b""
        try:
            while True:
                b = s.recv(65536)
                if not b: break
                out += b
        except socket.timeout:
            pass
        return out
    finally:
        s.close()

def build(host, header_target, body_len):
    body = bytes((0x30 + (i % 10)) for i in range(body_len))  # "0123456789..." filler, position-coded
    fixed = [("Host", host), ("Content-Length", str(body_len)),
             ("Content-Type", "application/octet-stream"), ("Connection", "close")]
    reqline = b"POST /echo HTTP/1.1"
    total = len(reqline) + 2 + sum(len(k)+2+len(v)+2 for k, v in fixed) + 2
    pads, n = [], 0
    while total < header_target:
        remain = header_target - total
        key = f"X-Pad-{n}"
        valsize = min(7000, max(1, remain - (len(key)+4)))
        pads.append((key, "A"*valsize)); total += len(key)+2+valsize+2; n += 1
        if valsize <= 1: break
    lines = [reqline] + [f"{k}: {v}".encode() for k, v in fixed+pads]
    head = b"\r\n".join(lines) + b"\r\n\r\n"
    return head + body, len(head), body

bad = 0
for ht in (15000, 18000, 19000, 19900):
    payload, wire, body = build("a.test", ht, 4000)
    resp = send_raw(payload)
    i = resp.find(b"\r\n\r\n")
    echo = resp[i+4:] if i >= 0 else b""
    status = resp.split(b" ")[1].decode() if resp[:4] == b"HTTP" else "???"
    if status == "200" and echo == body:
        print(f"head {wire} bytes, body 4000: status 200, echo INTACT")
    else:
        diff = next((k for k in range(min(len(echo), len(body))) if echo[k] != body[k]), None)
        print(f"head {wire} bytes, body 4000: status {status}, echo DIFFERS "
              f"(length {len(echo)}, first difference at {diff})")
        bad = 1
for ht in (20500, 26000):
    payload, wire, body = build("a.test", ht, 4000)
    resp = send_raw(payload)
    status = resp.split(b" ")[1].decode() if resp[:4] == b"HTTP" else "???"
    ok = status == "413"
    print(f"head {wire} bytes (over the bound): status {status} {'as expected' if ok else 'EXPECTED 413'}")
    bad |= 0 if ok else 1
payload, wire, body = build("a.test", 600, 4000)
resp = send_raw(payload)
ok = resp[:12] == b"HTTP/1.1 200" and resp[resp.find(b"\r\n\r\n")+4:] == body
print(f"small request afterwards: {'INTACT' if ok else 'BROKEN'}")
bad |= 0 if ok else 1
sys.exit(bad)
