#!/bin/sh
set -e

DEB="$(ls -t packages/*.deb 2>/dev/null | head -n 1)"
if [ -z "$DEB" ]; then
    echo "没有找到 packages/*.deb，请先运行 ./build_rootless.sh"
    exit 1
fi

echo "安装 $DEB"
dpkg -i "$DEB"

echo "重启注入环境"
if command -v sbreload >/dev/null 2>&1; then
    sbreload
else
    killall -9 SpringBoard || true
fi
