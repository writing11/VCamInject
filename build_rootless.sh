#!/bin/sh
set -e

if [ -z "$THEOS" ]; then
    if [ -d "/var/jb/opt/theos" ]; then
        export THEOS="/var/jb/opt/theos"
    elif [ -d "/opt/theos" ]; then
        export THEOS="/opt/theos"
    else
        echo "未找到 Theos。请先在手机或 Mac 上安装 Theos。"
        exit 1
    fi
fi

echo "THEOS=$THEOS"
echo "开始 rootless 打包..."
THEOS_PACKAGE_SCHEME=rootless make clean package

echo ""
echo "完成。deb 文件在 packages 目录："
ls -lh packages/*.deb
