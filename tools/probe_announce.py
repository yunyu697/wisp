"""抓取 Wisp 发出的组播 announce，逐字段对照 LocalSend 官方解析要求。

用法：先启动 wisp.exe，再运行 python probe_announce.py [秒数]
"""

import json
import socket
import struct
import sys
import time

MULTICAST = "224.0.0.167"
PORT = 53317
DURATION = float(sys.argv[1]) if len(sys.argv) > 1 else 10.0

# 官方 LocalSend 的枚举，值不在其中会直接抛异常、整条报文被丢弃。
DEVICE_TYPES = {"mobile", "desktop", "web", "headless", "server"}
PROTOCOLS = {"http", "https"}


def main():
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
    print(f"[UDP] 监听 {MULTICAST}:{PORT} 共 {DURATION:.0f}s", flush=True)

    deadline = time.time() + DURATION
    count = 0
    while time.time() < deadline:
        try:
            data, addr = sock.recvfrom(65535)
        except socket.timeout:
            continue
        count += 1
        text = data.decode("utf-8", "replace")
        try:
            msg = json.loads(text)
        except json.JSONDecodeError:
            print(f"[{count}] 非 JSON，来自 {addr}: {text[:120]!r}", flush=True)
            continue

        problems = []
        for key in ("alias", "version", "deviceModel", "deviceType", "fingerprint", "port", "protocol"):
            if key not in msg:
                problems.append(f"缺字段 {key}")
        if msg.get("deviceType") not in DEVICE_TYPES:
            problems.append(f"deviceType 非法: {msg.get('deviceType')!r}")
        if msg.get("protocol") not in PROTOCOLS:
            problems.append(f"protocol 非法: {msg.get('protocol')!r}")
        fp = msg.get("fingerprint", "")
        if not isinstance(fp, str) or len(fp) != 32:
            problems.append(f"fingerprint 长度异常: {len(fp)}")
        if not isinstance(msg.get("port"), int):
            problems.append(f"port 不是整数: {msg.get('port')!r}")
        if not isinstance(msg.get("version"), str):
            problems.append(f"version 不是字符串: {msg.get('version')!r}")

        verdict = "OK" if not problems else "!! " + "; ".join(problems)
        print(f"[{count}] 源 {addr[0]}:{addr[1]} -> {verdict}", flush=True)
        print(f"      {json.dumps(msg, ensure_ascii=False)}", flush=True)

    print(f"[UDP] 共收到 {count} 条报文", flush=True)


if __name__ == "__main__":
    main()
