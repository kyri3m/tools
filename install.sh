#!/bin/sh
# 安装 fw 和 ngx，并初始化 nginx。两种用法（root）：
#   curl -fsSL https://raw.githubusercontent.com/kyri3m/tools/main/install.sh | sh
#   在仓库目录里：sh install.sh
set -e
[ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }
if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null; then apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3 curl
    elif command -v dnf >/dev/null; then dnf install -y python3 curl
    elif command -v yum >/dev/null; then yum install -y python3 curl
    else echo "请先安装 python3 和 curl"; exit 1; fi
fi
dir=$(dirname "$0")
if [ ! -f "$dir/ngx" ] || [ ! -f "$dir/fw" ]; then
    # 通过管道运行：从 GitHub 下载
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    base=${TOOLS_URL:-https://raw.githubusercontent.com/kyri3m/tools/main}
    curl -fsSL "$base/ngx" -o "$dir/ngx"
    curl -fsSL "$base/fw" -o "$dir/fw"
fi
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$dir/ngx" || { echo "ngx 文件不完整"; exit 1; }
bash -n "$dir/fw" || { echo "fw 文件不完整"; exit 1; }
install -m 755 "$dir/fw" "$dir/ngx" /usr/local/bin/
echo "  ✔ 已安装 /usr/local/bin/fw 和 /usr/local/bin/ngx"

# 文件句柄 / inotify 上限：只调高不调低，已够大的项不写。TOOLS_NO_TUNE=1 跳过。
if [ "${TOOLS_NO_TUNE:-0}" != 1 ]; then
    tune=""
    for kv in fs.file-max=1048576 fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=1048576; do
        k=${kv%%=*}; v=${kv#*=}
        cur=$(sysctl -n "$k" 2>/dev/null || echo 0)
        [ "$cur" -lt "$v" ] 2>/dev/null && tune="$tune$k=$v
"
    done
    if [ -n "$tune" ]; then
        printf '%s' "$tune" > /etc/sysctl.d/90-tools-limits.conf
        sysctl -q -p /etc/sysctl.d/90-tools-limits.conf || true
    fi
    if [ "$(ulimit -Hn)" != unlimited ] && [ "$(ulimit -Hn)" -lt 1048576 ] && [ -d /etc/security/limits.d ] \
        && ! grep -rqs nofile /etc/security/limits.conf /etc/security/limits.d/; then
        printf '* soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576\n' \
            > /etc/security/limits.d/90-tools-nofile.conf
    fi
    if [ -d /run/systemd/system ] && ! grep -rqs '^DefaultLimitNOFILE' /etc/systemd/system.conf /etc/systemd/system.conf.d/; then
        mkdir -p /etc/systemd/system.conf.d
        printf '[Manager]\nDefaultLimitNOFILE=1048576\n' > /etc/systemd/system.conf.d/90-tools-nofile.conf
        systemctl daemon-reexec || true
    fi
    echo "  ✔ 文件句柄 / inotify 上限已检查"
fi
/usr/local/bin/ngx install
