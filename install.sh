#!/bin/sh
# 在仓库目录里以 root 运行：sh install.sh   —— 安装 fw、ngx 并初始化 ngx
set -e
[ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }
cd "$(dirname "$0")"
if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null; then apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3 curl
    elif command -v dnf >/dev/null; then dnf install -y python3 curl
    else echo "请先安装 python3 和 curl"; exit 1; fi
fi
install -m 755 fw ngx /usr/local/bin/
/usr/local/bin/ngx install
