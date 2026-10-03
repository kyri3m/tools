#!/usr/bin/env bash
# shellcheck disable=SC2016 # nginx 变量必须按字面值验证。
# 无 bats；所有数据位于工作目录下的临时根，系统命令使用 PATH 桩。
set -euo pipefail
export LC_ALL=C.UTF-8
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
REAL_NGINX=$(command -v nginx)
TMP=$(mktemp -d "$BASE/test/.run.XXXXXXXX")
trap 'rm -rf -- "$TMP"' EXIT
export NGX_ROOT=$TMP/root
export NGX_TEST=$TMP
mkdir -p "$TMP/bin" "$NGX_ROOT/etc/nginx/sites-enabled" "$NGX_ROOT/etc/nginx/sites-available"
export PATH="$TMP/bin:$PATH"
cat > "$TMP/bin/nginx" <<'STUB'
#!/usr/bin/env bash
printf 'nginx %s\n' "$*" >> "$NGX_TEST/calls"
if [[ ${1:-} == -v ]]; then echo 'nginx version: nginx/1.26.3'; exit; fi
if [[ -f $NGX_TEST/fail-test && ${1:-} == -t ]]; then rm "$NGX_TEST/fail-test"; echo '模拟配置错误' >&2; exit 1; fi
if [[ ${1:-} == -T ]]; then cat "$NGX_ROOT"/etc/nginx/sites-enabled/*.conf "$NGX_ROOT"/etc/nginx/conf.d/*.conf; fi
exit 0
STUB
cat > "$TMP/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$NGX_TEST/calls"
if [[ -f $NGX_TEST/fail-reload && ${1:-} == reload ]]; then rm "$NGX_TEST/fail-reload"; echo '模拟 reload 失败' >&2; exit 1; fi
case ${1:-} in is-active) echo active;; is-enabled) echo enabled;; list-timers) echo 'NEXT certbot.timer';; esac
STUB
cat > "$TMP/bin/fw" <<'STUB'
#!/usr/bin/env bash
printf 'fw %s\n' "$*" >> "$NGX_TEST/calls"
if [[ $1 == status ]]; then
    echo '  协议 端口 监听程序 备注'
    [[ -f $NGX_TEST/closed80 ]] || echo '  tcp 80 nginx ACME'
    echo '  tcp 10618 nginx EmbyHub'
    if [[ -f $NGX_TEST/opened ]]; then cat "$NGX_TEST/opened"; fi
elif [[ $1 == open ]]; then
    echo "tcp $2 nginx 测试" >> "$NGX_TEST/opened"
fi
STUB
cat > "$TMP/bin/ss" <<'STUB'
#!/usr/bin/env bash
if [[ -f $NGX_TEST/listeners ]]; then cat "$NGX_TEST/listeners"; fi
exit 0
STUB
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
case ${*: -1} in
    https://www.cloudflare.com/ips-v4) [[ ! -f $NGX_TEST/fail-download ]] || exit 22; cat "$NGX_TEST/cf4";;
    https://www.cloudflare.com/ips-v6) cat "$NGX_TEST/cf6";;
    *) if [[ $1 == -4 ]]; then echo 203.0.113.5; else echo 2001:db8::5; fi;;
esac
STUB
cat > "$TMP/bin/getent" <<'STUB'
#!/usr/bin/env bash
if [[ -f $NGX_TEST/bad-dns ]]; then echo '203.0.113.6 STREAM example.test';
elif [[ -f $NGX_TEST/dns ]] && awk -v d="$2" '$1==d {f=1} END {exit !f}' "$NGX_TEST/dns"; then
    awk -v d="$2" '$1==d {print $2, "STREAM", d}' "$NGX_TEST/dns"
else echo '203.0.113.5 STREAM example.test'; fi
STUB
cat > "$TMP/bin/certbot" <<'STUB'
#!/usr/bin/env bash
set -e
printf 'certbot %s\n' "$*" >> "$NGX_TEST/calls"
[[ ! -f $NGX_TEST/fail-cert ]] || exit 1
name='' action=''
while (($#)); do
    case $1 in --cert-name) name=$2; shift 2;; certonly|delete|renew|certificates) action=$1; shift;; *) shift;; esac
done
if [[ $action == certonly ]]; then
    mkdir -p "$NGX_ROOT/etc/letsencrypt/live/$name" "$NGX_ROOT/etc/letsencrypt/renewal"
    cp "$NGX_TEST/cert.pem" "$NGX_ROOT/etc/letsencrypt/live/$name/fullchain.pem"
    cp "$NGX_TEST/key.pem" "$NGX_ROOT/etc/letsencrypt/live/$name/privkey.pem"
    echo 'deploy_hook = systemctl reload nginx' > "$NGX_ROOT/etc/letsencrypt/renewal/$name.conf"
elif [[ $action == delete ]]; then rm -rf "$NGX_ROOT/etc/letsencrypt/live/$name"; fi
STUB
cat > "$TMP/bin/editor" <<'STUB'
#!/usr/bin/env bash
printf '\n# 编辑器测试\n' >> "$1"
STUB
chmod +x "$TMP/bin/"*
export EDITOR=$TMP/bin/editor
openssl req -x509 -nodes -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 30 -subj /CN=emby.example.test > "$TMP/openssl.log" 2>&1
printf '# 外部站点\n' > "$NGX_ROOT/etc/nginx/sites-available/foreign"
printf '# Debian 默认站点\n' > "$NGX_ROOT/etc/nginx/sites-available/default"
ln -s ../sites-available/default "$NGX_ROOT/etc/nginx/sites-enabled/default"
run() { "$BASE/ngx" "$@" > "$TMP/output" 2>&1 || { cat "$TMP/output"; return 1; }; }
reject() { if "$BASE/ngx" "$@" > "$TMP/output" 2>&1; then echo "应拒绝：$*"; exit 1; fi; }
contains() { grep -Fq -- "$2" "$1" || { echo "未找到：$2 ($1)"; cat "$1"; exit 1; }; }
report() { printf 'PASS %s\n' "$*"; }
cp "$BASE/ngx" "$TMP/standalone-ngx"
"$TMP/standalone-ngx" install > "$TMP/standalone.log" 2>&1
run help
contains "$TMP/output" 'ngx —— nginx 管理'
run install
[[ -L $NGX_ROOT/etc/nginx/ngx-default.disabled && ! -L $NGX_ROOT/etc/nginx/sites-enabled/default ]]
run install
report 'help / install 幂等 / default 备份'
run add emby --type emby --domain emby.example.test,media.example.test --email admin@example.test
CONF=$NGX_ROOT/etc/nginx/sites-available/ngx-emby.conf
contains "$CONF" 'listen 10618 ssl;'
contains "$CONF" 'http2 on;'
contains "$CONF" 'https://$host:10618$request_uri'
contains "$NGX_ROOT/etc/nginx/snippets/ngx-proxy.conf" 'proxy_set_header Range $http_range;'
contains "$TMP/output" 'MEDIA_HTTP_TRUSTED_PROXIES= 应用直接跑在本机填 127.0.0.1,::1'
contains "$TMP/output" 'compose 网络的网关'
contains "$TMP/output" '中心公网地址：https://emby.example.test:10618'
# EmbyHub sets its own security headers; nginx must not add conflicting copies.
if grep -Fq 'ngx-security.conf' "$CONF"; then echo 'emby 站点不应包含 ngx-security.conf'; exit 1; fi
contains "$CONF" 'EmbyHub 自带安全响应头'
contains "$TMP/calls" '--deploy-hook systemctl reload nginx'
contains "$NGX_ROOT/etc/ngx/config" 'EMAIL=admin@example.test'
run add proxy --type proxy --domain proxy.example.test --port 10800 --upstream localhost:9000 --no-tls
contains "$NGX_ROOT/etc/nginx/sites-available/ngx-proxy.conf" 'ngx-security.conf'
run add std443 --type emby --domain std443.example.test --port 443
contains "$NGX_ROOT/etc/nginx/sites-available/ngx-std443.conf" 'return 301 https://$host$request_uri;'
contains "$TMP/output" '中心公网地址：https://std443.example.test'
if grep -Fq 'host:443' "$NGX_ROOT/etc/nginx/sites-available/ngx-std443.conf"; then echo '443 跳转不应带 :443'; exit 1; fi
run rm std443 --yes
run add 静态站点 --type static --domain static.example.test --port 10801 --root /var/www/site --no-tls
contains "$NGX_ROOT/etc/nginx/sites-available/ngx-静态站点.conf" 'try_files $uri $uri/ =404;'
run status
contains "$TMP/output" '静态站点'
contains "$TMP/output" 'foreign（外部）'
contains "$TMP/output" 'certbot.timer'
report 'emby TLS / proxy / static / 中文状态'
for domain in 'bad;name' 'a..test' '-a.test' 'a_.test' 'a.test,' 'a.test b.test' $'a.test\nb.test'; do
    reject add bad --domain "$domain" --port 12000 --no-tls
done
for upstream in 'host:0' 'host:65536' 'host:3;foo' $'host:3\nfoo' 'unix:/tmp/a;foo' 'unix:/tmp/../x' 'http://host:80'; do
    reject add bad --domain good.example.test --port 12000 --upstream "$upstream" --no-tls
done
for port in 0 80 65536 080 1x; do reject add bad --domain good.example.test --port "$port" --no-tls; done
reject add ../bad --domain good.example.test --no-tls
reject add bad --domain good.example.test --root '/tmp/a"x' --no-tls
reject add bad --domain good.example.test --type other --no-tls
reject add bad --domain good.example.test --email 'bad;mail'
[[ ! -f $NGX_ROOT/etc/ngx/sites/bad.env ]]
report '注入与输入校验'
reject add conflict --domain conflict.example.test --port 10800 --no-tls
reject add conflict --domain PROXY.EXAMPLE.TEST --port 12000 --no-tls
printf 'LISTEN 0 128 0.0.0.0:12000 0.0.0.0:* users:(("other",pid=99,fd=4))\n' > "$TMP/listeners"
reject add conflict --domain conflict.example.test --port 12000 --no-tls
rm "$TMP/listeners"
report '元数据端口 / 域名 / 非 nginx 监听冲突'
cp "$CONF" "$TMP/original"
cp "$NGX_ROOT/etc/ngx/sites/emby.env" "$TMP/meta"
touch "$TMP/fail-test"
reject set emby port 12001
cmp "$CONF" "$TMP/original"
cmp "$NGX_ROOT/etc/ngx/sites/emby.env" "$TMP/meta"
contains "$TMP/output" '模拟配置错误'
contains "$TMP/output" '已恢复'
touch "$TMP/fail-reload"
reject set emby upstream 127.0.0.1:19999
cmp "$CONF" "$TMP/original"
touch "$TMP/fail-test"
reject add fail --domain fail.example.test --port 12000 --no-tls
[[ ! -e $NGX_ROOT/etc/ngx/sites/fail.env && ! -e $NGX_ROOT/etc/nginx/sites-enabled/ngx-fail.conf ]]
touch "$TMP/fail-cert"
reject add fail --domain fail.example.test --port 12000
rm "$TMP/fail-cert"
[[ ! -e $NGX_ROOT/etc/ngx/sites/fail.env ]]
touch "$TMP/bad-dns"
reject cert issue emby
rm "$TMP/bad-dns"
contains "$TMP/output" 'Cloudflare 灰云'
cmp "$CONF" "$TMP/original"
report 'nginx test / reload / certbot / DNS 失败回滚'
run disable proxy
[[ ! -e $NGX_ROOT/etc/nginx/sites-enabled/ngx-proxy.conf ]]
run set proxy port 10802
[[ ! -e $NGX_ROOT/etc/nginx/sites-enabled/ngx-proxy.conf ]]
run enable proxy
[[ -L $NGX_ROOT/etc/nginx/sites-enabled/ngx-proxy.conf ]]
run set proxy upstream unix:/run/backend.sock
contains "$NGX_ROOT/etc/nginx/sites-available/ngx-proxy.conf" "proxy_pass http://unix:$NGX_ROOT/run/backend.sock:;"
run set proxy upstream 127.0.0.1:9000
run set proxy domain new.example.test
run set emby domain newemby.example.test
run edit proxy
contains "$NGX_ROOT/etc/nginx/sites-available/ngx-proxy.conf" '# 编辑器测试'
cp "$NGX_ROOT/etc/nginx/sites-available/ngx-proxy.conf" "$TMP/proxy-before"
touch "$TMP/fail-test"
reject edit proxy
cmp "$NGX_ROOT/etc/nginx/sites-available/ngx-proxy.conf" "$TMP/proxy-before"
run show proxy
contains "$TMP/output" 'server_name new.example.test;'
run cert list
contains "$TMP/output" '剩余'
run cert renew --dry-run
reject cert rm emby --yes
report 'enable / disable / set / edit / show / cert 管理'
# 非交互不自动放行；显式选项会调用 fw。
if grep -q '^fw open' "$TMP/calls"; then echo '非交互意外开放防火墙'; exit 1; fi
run add firewall --domain firewall.example.test --port 12002 --no-tls --open-firewall
contains "$TMP/calls" 'fw open 12002 tcp ngx firewall'
run rm firewall --yes
report '防火墙仅显式放行'
run backup
ARCHIVE=$(tail -n 1 "$TMP/output")
tar -tzf "$ARCHIVE" > "$TMP/members"
contains "$TMP/members" 'etc/nginx/'
if grep -q 'privkey' "$TMP/members"; then echo '默认备份含私钥'; exit 1; fi
run backup --with-keys
KEY_ARCHIVE=$(tail -n 1 "$TMP/output")
tar -tzf "$KEY_ARCHIVE" > "$TMP/members"
contains "$TMP/members" 'privkey.pem'
run rm proxy --yes
[[ ! -f $NGX_ROOT/etc/ngx/sites/proxy.env ]]
run restore "$ARCHIVE"
[[ -f $NGX_ROOT/etc/ngx/sites/proxy.env ]]
contains "$NGX_ROOT/etc/nginx/sites-available/foreign" '# 外部站点'
run set proxy port 10803
cp "$NGX_ROOT/etc/nginx/sites-available/ngx-proxy.conf" "$TMP/proxy-before"
touch "$TMP/fail-test"
reject restore "$ARCHIVE"
cmp "$NGX_ROOT/etc/nginx/sites-available/ngx-proxy.conf" "$TMP/proxy-before"
python3 - "$TMP/evil.tar.gz" <<'PY'
import tarfile,io,sys
with tarfile.open(sys.argv[1],'w:gz') as t:
    m=tarfile.TarInfo('../../escape'); m.size=4; t.addfile(m,io.BytesIO(b'evil'))
PY
reject restore "$TMP/evil.tar.gz"
[[ ! -e $TMP/escape ]]
report 'backup 私钥策略 / restore / 失败回滚 / 恶意归档拒绝'
mkdir -p "$NGX_ROOT/var/log/nginx"
printf '127.0.0.1 - - [%s] "GET /hello HTTP/1.1" 200 42 "-" "agent" 0.1 0.1 200 "-"\n' "$(date '+%d/%b/%Y:%H:%M:%S %z')" > "$NGX_ROOT/var/log/nginx/ngx-proxy.access.log"
run logs proxy -n 1
contains "$TMP/output" '/hello'
run top proxy --since 1h
contains "$TMP/output" '请求数： 1'
contains "$TMP/output" '字节： 42'
run top proxy
contains "$TMP/output" '/hello'
# doctor 上游离线应返回非零，但必须完成诊断。
reject doctor
contains "$TMP/output" '上游不可达'
report 'logs / top / doctor'
# shellcheck source=test/followup.sh
source "$BASE/test/followup.sh"
# shellcheck source=test/v3.sh
source "$BASE/test/v3.sh"
# 用真实 nginx 解析所有模板、TLS、IPv6、静态站点、proxy；绝不 reload 系统服务。
cat > "$TMP/nginx.conf" <<CONF
user root;
pid $TMP/nginx.pid;
error_log $TMP/error.log;
events { worker_connections 64; }
http {
    access_log $TMP/access.log;
    client_body_temp_path $TMP/client;
    proxy_temp_path $TMP/proxy;
    fastcgi_temp_path $TMP/fastcgi;
    uwsgi_temp_path $TMP/uwsgi;
    scgi_temp_path $TMP/scgi;
    include $NGX_ROOT/etc/nginx/conf.d/ngx-*.conf;
    include $NGX_ROOT/etc/nginx/sites-enabled/ngx-*.conf;
}
CONF
if python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(); s.close()' 2>/dev/null; then
"$REAL_NGINX" -t -p "$TMP/" -c "$TMP/nginx.conf" > "$TMP/real-nginx.log" 2>&1 || { cat "$TMP/real-nginx.log"; exit 1; }
cat "$TMP/real-nginx.log"
report '真实 nginx -t -p 临时目录 -c 临时主配置（TLS 自签证书）'
else
    echo 'SKIP 真实 nginx 校验（无 socket 权限）'
fi
run rm emby --yes
[[ -f $NGX_ROOT/etc/letsencrypt/live/ngx-emby/privkey.pem ]]
run cert rm emby --yes
[[ ! -e $NGX_ROOT/etc/letsencrypt/live/ngx-emby ]]
run add purge --domain purge.example.test --port 12004
run rm purge --yes --purge-cert
[[ ! -e $NGX_ROOT/etc/letsencrypt/live/ngx-purge ]]
report '删除默认留证 / 显式清理证书'
printf '\n全部测试通过。\n'
