#!/bin/sh
set -e

if [ -z "$THEOS" ]; then
    if [ -d "/var/jb/opt/theos" ]; then
        export THEOS="/var/jb/opt/theos"
    elif [ -d "/opt/theos" ]; then
        export THEOS="/opt/theos"
    else
        echo "未找到 Theos。请先安装 RootHide 环境可用的 Theos。"
        exit 1
    fi
fi

echo "THEOS=$THEOS"
echo "开始 RootHide 打包..."

if THEOS_PACKAGE_SCHEME=roothide make clean package; then
    echo ""
    echo "完成。deb 文件在 packages 目录："
    ls -lh packages/*.deb
else
    echo ""
    echo "你的 Theos 可能不支持 THEOS_PACKAGE_SCHEME=roothide。"
    echo "请升级 Theos，或先用 ./build_rootless.sh 打包后再用 RootHide/Bootstrap 自带的转换工具转换。"
    exit 1
fi
