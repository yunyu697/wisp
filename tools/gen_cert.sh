#!/usr/bin/env bash
# 生成 Wisp 用的自签证书（10 年有效期，无口令私钥）。
# 用法：bash tools/gen_cert.sh
set -euo pipefail

# Windows 的 Git Bash 会把 "/CN=..." 这类参数当路径转换成盘符路径，
# 关掉转换才能让 openssl 的 -subj 原样到达（其它平台无此变量，无害）。
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/assets/certs"
mkdir -p "$DIR"

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$DIR/key.pem" \
  -out "$DIR/cert.pem" \
  -subj "/CN=Wisp Local Transfer/O=Wisp" \
  -addext "subjectAltName=IP:127.0.0.1,DNS:localhost"

echo "已生成："
echo "  $DIR/cert.pem"
echo "  $DIR/key.pem"
echo
echo "证书指纹（用于两端互认）："
openssl x509 -in "$DIR/cert.pem" -noout -fingerprint -sha256
