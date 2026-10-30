"""模拟一个官方 LocalSend 客户端，验证 Wisp 的组播发现是否真的发得出去。

行为对齐 LocalSend 协议 v2.2：
1. UDP 绑定 53317 并加入组播组 224.0.0.167，监听对方的 announce；
2. 收到 announce 后用 HTTP POST /api/localsend/v2/register 单播回应；
3. 同时自己发一条 announce，让对方发现我。

用法：python probe_localsend.py [秒数]
"""

import json
import socket
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

MULTICAST = "224.0.0.167"
PORT = 53317
DURATION = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0

SELF = {
    "alias": "Probe Official",
    "version": "2.2",
    "deviceModel": "Probe",
    "deviceType": "desktop",
    "fingerprint": "PROBEFINGERPRINT0001",
    "port": PORT,
    "protocol": "http",
    "download": False,
    "announce": True,
}

seen = {}


def http_handler():
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length) if length else b""
            print(f"[HTTP] {self.path} <- {body[:200]!r}", flush=True)
            if "register" in self.path:
                payload = json.dumps({**SELF, "announce": False}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        def do_GET(self):
            payload = json.dumps({**SELF, "announce": False}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *args):
            pass

    server = HTTPServer(("0.0.0.0", PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main():
    http_server = http_handler()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except (AttributeError, OSError):
        pass
    sock.bind(("0.0.0.0", PORT))
    mreq = struct.pack("4s4s", socket.inet_aton(MULTICAST), socket.inet_aton("0.0.0.0"))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    sock.settimeout(1.0)
    print(f"[UDP] 已加入组播组 {MULTICAST}:{PORT}，监听 {DURATION:.0f}s", flush=True)

    # 自己发一条 announce，让对方发现我
    sock.sendto(json.dumps(SELF).encode(), (MULTICAST, PORT))
    print("[UDP] 已发出自己的 announce", flush=True)

    deadline = time.time() + DURATION
    while time.time() < deadline:
        try:
            data, addr = sock.recvfrom(65535)
        except socket.timeout:
            continue
        text = data.decode("utf-8", "replace").strip()
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError:
            print(f"[UDP] 非 JSON 报文 {addr}: {text[:200]!r}", flush=True)
            continue
        alias = parsed.get("alias", "?")
        if parsed.get("fingerprint") == SELF["fingerprint"]:
            continue
        if alias in seen:
            continue
        seen[alias] = parsed
        print(f"[UDP] 发现设备 {addr}: {json.dumps(parsed, ensure_ascii=False)}", flush=True)

    print(f"[UDP] 结束，共发现 {len(seen)} 台设备", flush=True)
    http_server.shutdown()


if __name__ == "__main__":
    main()
