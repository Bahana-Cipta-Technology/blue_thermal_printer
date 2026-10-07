import socket, threading, sys, time, os
# Printer ESC/POS palsu: tiap port membalas query status DLE EOT n (10 04 n) dengan byte tetap.
PORTS = {19100: 0x12, 19101: 0x32, 19102: 0x16, 19103: 0x52, 19104: None}  # None = bisu
OUT = sys.argv[1]
def handle(conn, port):
    reply = PORTS[port]
    data = bytearray()
    conn.settimeout(0.2)
    last = time.time()
    try:
        while time.time() - last < 20:
            try:
                chunk = conn.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                break
            last = time.time()
            data += chunk
            # balas setiap DLE EOT n
            i = 0
            while True:
                i = chunk.find(b"\x10\x04", i)
                if i < 0 or i + 2 >= len(chunk): break
                if reply is not None:
                    conn.sendall(bytes([reply]))
                i += 3
    finally:
        with open(os.path.join(OUT, f"port{port}.bin"), "ab") as f:
            f.write(bytes(data)); f.write(b"\n===END-CONN===\n")
        conn.close()
def serve(port):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", port)); s.listen(5)
    while True:
        c, _ = s.accept()
        threading.Thread(target=handle, args=(c, port), daemon=True).start()
for p in PORTS: threading.Thread(target=serve, args=(p,), daemon=True).start()
print("fake printer ready", flush=True)
while True: time.sleep(1)
