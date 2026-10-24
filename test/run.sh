#!/usr/bin/env bash
# ngx 隔离测试：临时根目录 + certbot 桩 + 本地假 Cloudflare API，不碰真实 /etc 和真实 DNS。
# 需要 nginx（只用 nginx -t）、python3、openssl。用法：bash test/run.sh
set -uo pipefail
BASE=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
R=$TMP/root
PORT=18765
trap 'kill $CF_PID 2>/dev/null; rm -rf "$TMP"' EXIT
pass=0 fail=0
check() { if eval "$2"; then pass=$((pass+1)); echo "  ✔ $1"; else fail=$((fail+1)); echo "  ✘ $1"; fi; }

mkdir -p "$R/etc/nginx" "$R/run" "$R/var/log/nginx" "$R/var/www/site"
cp /etc/nginx/mime.types "$R/etc/nginx/" 2>/dev/null || touch "$R/etc/nginx/mime.types"
# RHEL 风格：nginx.conf 不含 sites-enabled，验证 ngx install 会补上
cat > "$R/etc/nginx/nginx.conf" <<EOF
pid $R/run/nginx.pid;
error_log $R/var/log/nginx/error.log;
events {}
http {
    include $R/etc/nginx/mime.types;
    access_log $R/var/log/nginx/access.log;
    include $R/etc/nginx/conf.d/*.conf;
}
EOF
cat > "$TMP/certbot" <<'EOF'
#!/bin/bash
echo "$*" >> "$(dirname "$0")/certbot.log"
cfg=$2; name=''; ds=()
while (($#)); do case $1 in --cert-name) name=$2; shift;; -d) ds+=("$2"); shift;; esac; shift; done
[[ ${FAIL:-0} == 1 ]] && { echo "Challenge failed"; exit 1; }
[[ -n $name ]] || exit 0
mkdir -p "$cfg/live/$name" "$cfg/renewal"; san=$(printf 'DNS:%s,' "${ds[@]}")
openssl req -x509 -newkey rsa:2048 -nodes -days 90 -subj "/CN=${ds[0]}" -addext "subjectAltName=${san%,}" \
    -keyout "$cfg/live/$name/privkey.pem" -out "$cfg/live/$name/fullchain.pem" 2>/dev/null
printf '[renewalparams]\nrenew_hook = systemctl reload nginx\n' > "$cfg/renewal/$name.conf"
EOF
chmod +x "$TMP/certbot"
sed "s/18765/$PORT/" "$BASE/test/fakecf.py" > "$TMP/fakecf.py"
python3 "$TMP/fakecf.py" 2>"$TMP/cf.log" & CF_PID=$!
sleep 1

export NGX_ROOT=$R NGX_CERTBOT=$TMP/certbot NGX_NO_CLEAR=1 NO_COLOR=1
ngx() { python3 "$BASE/ngx" "$@" < /dev/null; }
conf() { cat "$R/etc/nginx/sites-available/ngx-$1.conf"; }

echo '■ 安装'
ngx install >/dev/null
check 'install 补上 sites-enabled include' 'grep -q sites-enabled "$R/etc/nginx/nginx.conf"'
check '生成 ACME 兜底站点' '[[ -L $R/etc/nginx/sites-enabled/ngx-acme-80.conf ]]'
echo IPV4=203.0.113.7 > "$R/etc/ngx/config"

echo '■ 无 Token 新建'
ngx add plain.example.org 3000 -y --http >/dev/null 2>&1
check '站点已启用' '[[ -L $R/etc/nginx/sites-enabled/ngx-plain.conf ]]'
check '证书走 HTTP 验证' 'grep -q -- "--webroot" "$TMP/certbot.log"'
check '配置启用 TLS' 'conf plain | grep -q "listen 443 ssl"'

echo '■ 有 Token 新建：自动 DNS + DNS 验证'
echo faketoken_aaaaaaaaaaaaaaaaaaaa > "$R/etc/ngx/cloudflare.token"
export NGX_CF_API=http://127.0.0.1:$PORT/client/v4
ngx add app.example.com 5199 -y >/dev/null 2>&1
check '创建 A 记录' 'grep -q "POST /client/v4/zones/z1/dns_records" "$TMP/cf.log"'
check '证书走 DNS 验证' 'tail -1 "$TMP/certbot.log" | grep -q _dns-auth'
ngx add old.example.com 3000 -y >/dev/null 2>&1
check '修正指向别处的 A 记录' 'grep -q PATCH "$TMP/cf.log"'

echo '■ 校验与冲突'
check '重复域名被拒绝' '! ngx add app.example.com 3000 -y >/dev/null 2>&1'
check '注入字符被拒绝' '! ngx add x.example.com "a;b" -y >/dev/null 2>&1'
check '非 CF 端口不能开橙云' '! ngx add y.example.com 3000 --port 9443 --proxied -y >/dev/null 2>&1'

echo '■ 路由 / 访问控制 / 设置'
ngx route app add /api/ 127.0.0.1:3080/v1 >/dev/null
ngx route app add =/health 3000 >/dev/null
check '前缀路由' 'conf app | grep -q "location /api/"'
check '精确路由' 'conf app | grep -q "location = /health"'
check '路由改写路径' 'conf app | grep -q "proxy_pass http://127.0.0.1:3080/v1;"'
ngx set app body 1g >/dev/null && ngx allow app add 10.0.0.0/8 >/dev/null
echo test1234 | python3 "$BASE/ngx" auth app set admin >/dev/null
check '上传上限' 'conf app | grep -q "client_max_body_size 1g"'
check 'IP 白名单' 'conf app | grep -q "allow 10.0.0.0/8;"'
check '密码访问' 'conf app | grep -q auth_basic_user_file'
ngx set app headers off >/dev/null
check '关闭安全响应头' '! conf app | grep -q ngx-security'

echo '■ 失败回滚'
cp "$R/etc/nginx/sites-available/ngx-app.conf" "$TMP/before"
echo 'bogus_directive on;' > "$R/etc/ngx/custom/app.conf"
check '错误配置返回失败' '! ngx set app timeout 60 >/dev/null 2>&1'
check '配置恢复原样' 'cmp -s "$R/etc/nginx/sites-available/ngx-app.conf" "$TMP/before"'
check '元数据未被修改' 'grep -q "\"timeout\": 3600" "$R/etc/ngx/sites/app.json"'
rm "$R/etc/ngx/custom/app.conf"
check '证书失败返回非零' '! FAIL=1 ngx add bad.example.com 3000 -y >/dev/null 2>&1'
check '证书失败时拒绝握手而不是报错' 'conf bad | grep -q ssl_reject_handshake'

echo '■ 改域名 / 橙云'
ngx set app domain app.example.com,www.example.com -y >/dev/null 2>&1
check '新证书包含两个域名' 'tail -1 "$TMP/certbot.log" | grep -q "www.example.com"'
ngx cf proxied app on -y >/dev/null 2>&1
check '橙云后信任 CF 真实 IP' 'conf app | grep -q "X-Forwarded-For \$remote_addr"'
ngx set app cf-only on >/dev/null
check 'cf-only 门禁' 'conf app | grep -q ngx_cf_peer'

echo '■ DNS hook'
CERTBOT_DOMAIN=app.example.com CERTBOT_VALIDATION=abc_123 CERTBOT_REMAINING_CHALLENGES=1 python3 "$BASE/ngx" _dns-auth > "$TMP/id"
CERTBOT_DOMAIN=app.example.com CERTBOT_VALIDATION=abc_123 CERTBOT_AUTH_OUTPUT=$(cat "$TMP/id") python3 "$BASE/ngx" _dns-cleanup
check 'TXT 创建后被清理' 'grep -q DELETE "$TMP/cf.log"'

echo '■ 备份 / 恢复 / 删除'
ngx backup >/dev/null
ngx rm old -y >/dev/null
ngx restore "$(ls "$R"/var/backups/ngx/*.tar.gz | head -1)" -y >/dev/null
check '恢复后网站回来' '[[ -f $R/etc/ngx/sites/old.json ]]'
ngx rm bad --dns -y >/dev/null
check '删除网站和配置' '[[ ! -e $R/etc/nginx/sites-available/ngx-bad.conf ]]'

echo '■ 旧版数据迁移'
mkdir -p "$R/etc/ngx/sites"
printf 'TYPE=emby\nDOMAINS=media.example.com\nPORT=443\nUPSTREAM=127.0.0.1:10618\nDOCROOT=/var/www/html\nTLS=off\nCREATED=2026-01-01T00:00:00Z\nCLOUDFLARE=off\nCF_ONLY=off\nCERT_NAME=\n' > "$R/etc/ngx/sites/media.env"
printf 'server {\n    listen 443 ssl;\n    location = /pair {\n        proxy_pass http://127.0.0.1:1;\n    }\n    location / {\n    }\n}\n' > "$R/etc/nginx/sites-available/ngx-media.conf"
ngx ls >/dev/null 2>&1
check '迁移成 JSON' '[[ -f $R/etc/ngx/sites/media.json && ! -e $R/etc/ngx/sites/media.env ]]'
check '旧 emby 类型变成关闭安全头的普通反代' 'grep -q "\"headers\": false" "$R/etc/ngx/sites/media.json"'
check '手工 location 保留到自定义片段' 'grep -q "location = /pair" "$R/etc/ngx/custom/media.conf"'

check '最终配置通过 nginx -t' 'nginx -t -p "$R/" -c "$R/etc/nginx/nginx.conf" >/dev/null 2>&1'
echo
echo "通过 $pass，失败 $fail"
((fail == 0))
