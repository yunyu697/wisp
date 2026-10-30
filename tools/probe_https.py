"""确认接收端真的是 HTTPS：连 /api/localsend/v2/info 并把证书指纹打出来。

用法: python probe_https.py [ip] [port]
"""
import http.client
import ssl
import sys

ip = sys.argv[1] if len(sys.argv) > 1 else '127.0.0.1'
port = int(sys.argv[2]) if len(sys.argv) > 2 else 53317

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

try:
    conn = http.client.HTTPSConnection(ip, port, context=ctx, timeout=6)
    conn.request('GET', '/api/localsend/v2/info')
    resp = conn.getresponse()
    body = resp.read()[:200]
    peer = conn.sock.getpeercert(binary_form=True)
    import hashlib
    fp = ':'.join('%02X' % b for b in hashlib.sha256(peer).digest()) if peer else None
    print('HTTPS_OK status=%s bytes=%d' % (resp.status, len(body)))
    print('BODY=%s' % body.decode('utf-8', 'replace'))
    print('FINGERPRINT=%s' % fp)
    conn.close()
except Exception as exc:  # noqa: BLE001
    print('HTTPS_FAIL %s: %s' % (type(exc).__name__, exc))
    # 退回明文，看看是不是压根没起 TLS
    try:
        plain = http.client.HTTPConnection(ip, port, timeout=6)
        plain.request('GET', '/api/localsend/v2/info')
        r = plain.getresponse()
        print('PLAIN_OK status=%s （说明还在明文）' % r.status)
    except Exception as exc2:  # noqa: BLE001
        print('PLAIN_FAIL %s' % exc2)
