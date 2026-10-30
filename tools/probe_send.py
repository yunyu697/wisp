"""模拟发送方向本机 Wisp 发一个文件。

用法:
    python tools/probe_send.py [文件路径]

用途：验证「收到传输请求 → 托盘闪烁 + 桌面通知」链路。
运行后本机 Wisp 应该出现托盘图标闪烁和右下角通知；
在通知或主窗口里点「接收」后，脚本会继续上传并打印结果。
默认不自动接收（autoAccept=false），脚本会一直等用户表态，Ctrl+C 退出。
"""

import json
import socket
import sys
import time
import urllib.request

PORT = 53317

# 本机直连，绝不走系统代理——代理会把 127.0.0.1 也拦下返回 502。
_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def local_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('224.0.0.167', PORT))
        return s.getsockname()[0]
    finally:
        s.close()


def send(target_ip: str, path: str) -> None:
    with open(path, 'rb') as f:
        data = f.read()
    name = path.replace('\\', '/').rsplit('/', 1)[-1]

    payload = {
        'info': {
            'alias': '探针设备',
            'version': '2.2',
            'deviceModel': 'probe',
            'deviceType': 'desktop',
            'fingerprint': 'probe0fprint0123456789abcdef00',
            'port': PORT,
            'protocol': 'http',
            'download': True,
        },
        'files': {
            'f1': {'id': 'f1', 'fileName': name, 'size': len(data),
                   'fileType': 'application/octet-stream'},
        },
    }
    req = urllib.request.Request(
        f'http://{target_ip}:{PORT}/api/localsend/v2/prepare-upload',
        data=json.dumps(payload).encode('utf-8'),
        headers={'Content-Type': 'application/json'},
    )
    print('-> prepare-upload ...（请在 Wisp 的通知或窗口里选择接收）')
    try:
        with _opener.open(req, timeout=120) as resp:
            body = json.loads(resp.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        print(f'<- HTTP {e.code}（被拒绝）')
        return

    session_id = body['sessionId']
    token = body['files']['f1']
    print(f'<- 200 sessionId={session_id} 已获得令牌，开始上传')

    upload = urllib.request.Request(
        f'http://{target_ip}:{PORT}/api/localsend/v2/upload'
        f'?sessionId={session_id}&fileId=f1&token={token}',
        data=data,
        headers={'Content-Type': 'application/octet-stream'},
    )
    with _opener.open(upload, timeout=60) as resp:
        print(f'<- upload HTTP {resp.status} 完成')


def main() -> None:
    path = sys.argv[1] if len(sys.argv) > 1 else 'README.md'
    ip = local_ip()
    print(f'本机出口 IP: {ip}，目标: 127.0.0.1:{PORT}')
    send('127.0.0.1', path)


if __name__ == '__main__':
    main()
