#!/bin/sh
# deb/rpm 包的启动包装：程序本体装在 /opt/wisp/。
exec /opt/wisp/wisp "$@"
