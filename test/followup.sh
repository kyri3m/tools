#!/usr/bin/env bash
# 由 run.sh source，共用其隔离根、断言函数和桩。
# shellcheck disable=SC2016
# Safety: these tests write fixtures under $NGX_ROOT. Refuse to run without an
# isolated root, otherwise they would land in the real /etc (this happened once
# when followup.sh was run directly instead of being sourced by run.sh).
if [[ -z ${NGX_ROOT:-} || ${NGX_ROOT%/} == "" ]]; then
    echo "拒绝运行：未设置隔离的 NGX_ROOT（请执行 bash test/run.sh）" >&2
    exit 2
fi
cat > "$TMP/cf4" <<'RANGES'
173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22
RANGES
cat > "$TMP/cf6" <<'RANGES'
2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32
RANGES
run cf update
CF_CONF=$NGX_ROOT/etc/nginx/conf.d/ngx-cloudflare-realip.conf
contains "$CF_CONF" 'set_real_ip_from 173.245.48.0/20;'
contains "$CF_CONF" 'set_real_ip_from 2606:4700::/32;'
contains "$CF_CONF" 'real_ip_header CF-Connecting-IP;'
contains "$CF_CONF" 'real_ip_recursive on;'
contains "$CF_CONF" 'geo $realip_remote_addr $ngx_cf_peer'
contains "$NGX_ROOT/etc/systemd/system/ngx-cf-update.timer" 'OnCalendar=weekly'
contains "$TMP/calls" 'systemctl enable --now ngx-cf-update.timer'
cp "$NGX_ROOT/etc/systemd/system/ngx-cf-update.service" "$TMP/timer-before"
touch "$TMP/fail-reload"
reject install
cmp "$NGX_ROOT/etc/systemd/system/ngx-cf-update.service" "$TMP/timer-before"
cp "$NGX_ROOT/etc/ngx/cloudflare-ips.txt" "$TMP/old-ranges"
cp "$CF_CONF" "$TMP/old-realip"
cp "$TMP/cf4" "$TMP/valid4"
for bad_ranges in 'not a CIDR' '0.0.0.0/0' '173.245.48.1/20' '173.245.48.0/20'; do
    printf '%s\n' "$bad_ranges" > "$TMP/cf4"
    reject cf update
    cmp "$NGX_ROOT/etc/ngx/cloudflare-ips.txt" "$TMP/old-ranges"
    cmp "$CF_CONF" "$TMP/old-realip"
done
cp "$TMP/valid4" "$TMP/cf4"
touch "$TMP/fail-download"
reject cf update
rm "$TMP/fail-download"
cmp "$NGX_ROOT/etc/ngx/cloudflare-ips.txt" "$TMP/old-ranges"
touch "$TMP/fail-test"
reject cf update
cmp "$NGX_ROOT/etc/ngx/cloudflare-ips.txt" "$TMP/old-ranges"
cmp "$CF_CONF" "$TMP/old-realip"
report 'CF CIDR 校验 / 下载失败 / nginx 失败均保留旧地址与配置'
cat > "$TMP/dns" <<'DNS'
orange.example.test 173.245.48.5
orange6.example.test 2606:4700::1234
other.example.test 192.0.2.44
mixed.example.test 173.245.48.5
mixed.example.test 192.0.2.44
DNS
run add cf --domain orange.example.test,orange6.example.test --port 443 --cloudflare --cf-only
CF_SITE=$NGX_ROOT/etc/nginx/sites-available/ngx-cf.conf
contains "$CF_SITE" 'proxy_set_header X-Forwarded-For $remote_addr;'
contains "$NGX_ROOT/etc/nginx/snippets/ngx-proxy.conf" 'proxy_set_header X-Real-IP $remote_addr;'
contains "$NGX_ROOT/etc/nginx/snippets/ngx-cloudflare-allow.conf" 'allow 173.245.48.0/20;'
contains "$NGX_ROOT/etc/nginx/snippets/ngx-cloudflare-allow.conf" 'deny all;'
contains "$CF_SITE" 'if ($ngx_cf_peer = 0) { return 403; }'
[[ $(grep -c 'include .*ngx-acme.conf;' "$CF_SITE") == 2 ]]
[[ $(grep -c 'include .*ngx-cloudflare-allow.conf;' "$CF_SITE") == 2 ]]
contains "$NGX_ROOT/etc/nginx/snippets/ngx-acme.conf" 'allow all;'
contains "$TMP/output" 'Full (strict)'
contains "$TMP/output" 'Cloudflare 条款限制'
contains "$TMP/output" 'play.orange.example.test'
run set cf cloudflare off
contains "$TMP/output" '橙云但 Cloudflare 模式关闭'
contains "$CF_SITE" 'proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;'
run set cf cloudflare on --cf-only
contains "$CF_SITE" 'proxy_set_header X-Forwarded-For $remote_addr;'
contains "$CF_SITE" 'ngx-cloudflare-allow.conf;'
run add cfonly --type proxy --domain cfonly.example.test --port 2053 --cf-only
contains "$TMP/output" 'Cloudflare 模式开启但当前灰云'
run add orangebad --domain orange6.example.test --port 10620 --no-tls > /dev/null 2>&1 && { echo '域名重复应拒绝'; exit 1; }
# 使用新域名以避免与 cf 站点发生域名冲突。
echo 'orangemedia.example.test 173.245.48.6' >> "$TMP/dns"
run add orangebad --domain orangemedia.example.test --port 10620 --no-tls
contains "$TMP/output" '橙云不代理 HTTPS 端口 10620'
contains "$TMP/output" '橙云但 Cloudflare 模式关闭'
run add other --type static --domain other.example.test,mixed.example.test --port 12011 --no-tls
run status
contains "$TMP/output" 'orange.example.test：橙云'
contains "$TMP/output" 'orange6.example.test：橙云'
contains "$TMP/output" 'cfonly.example.test：灰云'
contains "$TMP/output" 'other.example.test：其他'
contains "$TMP/output" 'mixed.example.test：其他'
reject doctor
contains "$TMP/output" '橙云不代理 HTTPS 端口 10620'
contains "$TMP/output" 'Full (strict)'
report '橙/灰/其他检测 / 限源与 ACME / 覆盖 XFF / 视频、端口、SSL 警告'
# 外来 TLS 配置与 certbot lineage，接管不改原配置。
mkdir -p "$NGX_ROOT/etc/letsencrypt/live/legacy.example.test" "$NGX_ROOT/etc/letsencrypt/renewal"
cp "$TMP/cert.pem" "$NGX_ROOT/etc/letsencrypt/live/legacy.example.test/fullchain.pem"
cp "$TMP/key.pem" "$NGX_ROOT/etc/letsencrypt/live/legacy.example.test/privkey.pem"
printf 'authenticator = nginx\n' > "$NGX_ROOT/etc/letsencrypt/renewal/legacy.example.test.conf"
FOREIGN=$NGX_ROOT/etc/nginx/sites-available/legacy.conf
cat > "$FOREIGN" <<CONF
server {
    listen 8444 ssl;
    server_name legacy.example.test;
    ssl_certificate $NGX_ROOT/etc/letsencrypt/live/legacy.example.test/fullchain.pem;
    ssl_certificate_key $NGX_ROOT/etc/letsencrypt/live/legacy.example.test/privkey.pem;
    access_log $NGX_ROOT/var/log/nginx/legacy.access.log;
    error_log $NGX_ROOT/var/log/nginx/legacy.error.log;
    location / { proxy_pass http://127.0.0.1:9010; }
}
CONF
ln -s ../sites-available/legacy.conf "$NGX_ROOT/etc/nginx/sites-enabled/legacy.conf"
cat > "$NGX_ROOT/etc/nginx/conf.d/existing.conf" <<'CONF'
server {
    listen 12012;
    server_name existing.example.test;
    location / { proxy_pass http://127.0.0.1:9020; }
}
CONF
cp "$FOREIGN" "$TMP/foreign-original"
run adopt --dry-run
contains "$TMP/output" '接管预览：legacy'
contains "$TMP/output" '接管预览：existing'
[[ ! -e $NGX_ROOT/etc/ngx/sites/legacy.env && ! -e $NGX_ROOT/etc/ngx/sites/existing.env ]]
run status
contains "$TMP/output" '已接管 legacy'
contains "$TMP/output" '已接管 existing'
contains "$TMP/output" '接管'
contains "$NGX_ROOT/etc/ngx/sites/legacy.env" 'TYPE=adopted'
contains "$NGX_ROOT/etc/ngx/sites/legacy.env" 'UPSTREAM=127.0.0.1:9010'
contains "$NGX_ROOT/etc/ngx/sites/legacy.env" 'CERT_NAME=legacy.example.test'
contains "$NGX_ROOT/etc/ngx/sites/legacy.env" 'LISTENS=8444 ssl'
cmp "$FOREIGN" "$TMP/foreign-original"
[[ $(find "$NGX_ROOT/var/backups/ngx/adopted" -name 'legacy-*.conf' | wc -l) == 1 ]]
run adopt
if grep -q '已接管' "$TMP/output"; then echo '重复接管'; exit 1; fi
run help
if grep -q '已接管' "$TMP/output"; then echo '自动接管不幂等'; exit 1; fi
run disable legacy
[[ ! -L $NGX_ROOT/etc/nginx/sites-enabled/legacy.conf && -f $FOREIGN ]]
run enable legacy
[[ -L $NGX_ROOT/etc/nginx/sites-enabled/legacy.conf ]]
run disable existing
[[ -f $NGX_ROOT/etc/nginx/conf.d/existing.conf.disabled && ! -f $NGX_ROOT/etc/nginx/conf.d/existing.conf ]]
run status
run enable existing
[[ -f $NGX_ROOT/etc/nginx/conf.d/existing.conf && ! -f $NGX_ROOT/etc/nginx/conf.d/existing.conf.disabled ]]
reject set legacy port 8445
contains "$TMP/output" 'ngx edit legacy 或 ngx convert legacy'
run show legacy
contains "$TMP/output" 'legacy.example.test'
run edit legacy
contains "$FOREIGN" '# 编辑器测试'
cp "$FOREIGN" "$TMP/edited-foreign"
touch "$TMP/fail-test"
reject edit legacy
cmp "$FOREIGN" "$TMP/edited-foreign"
touch "$TMP/fail-test"
reject disable existing
[[ -f $NGX_ROOT/etc/nginx/conf.d/existing.conf ]]
report '接管 dry-run / 自动扫描 / 解析 / 幂等 / 两种 enable-disable / 编辑回滚 / set 拒绝'
cp "$NGX_ROOT/var/log/nginx/ngx-proxy.access.log" "$NGX_ROOT/var/log/nginx/legacy.access.log"
run logs legacy -n 1
contains "$TMP/output" '/hello'
run top legacy --since 1h
contains "$TMP/output" '请求数： 1'
run cert list
contains "$TMP/output" 'legacy.example.test'
reject doctor
contains "$TMP/output" 'authenticator = nginx'
contains "$TMP/output" '切换 webroot'
run cert issue legacy
contains "$TMP/calls" '--cert-name legacy.example.test'
contains "$NGX_ROOT/etc/letsencrypt/renewal/legacy.example.test.conf" 'deploy_hook = systemctl reload nginx'
cmp "$FOREIGN" "$TMP/edited-foreign"
run backup
ADOPTED_BACKUP=$(tail -n 1 "$TMP/output")
run disable existing
run edit legacy
run restore "$ADOPTED_BACKUP"
cmp "$FOREIGN" "$TMP/edited-foreign"
[[ -f $NGX_ROOT/etc/nginx/conf.d/existing.conf && ! -f $NGX_ROOT/etc/nginx/conf.d/existing.conf.disabled ]]
[[ -L $NGX_ROOT/etc/nginx/sites-enabled/legacy.conf ]]
report '接管日志 / top / certbot 关联 / nginx authenticator 提示 / backup-restore'
reject convert legacy --type proxy < /dev/null
cmp "$FOREIGN" "$TMP/edited-foreign"
[[ -L $NGX_ROOT/etc/nginx/sites-enabled/legacy.conf && ! -f $NGX_ROOT/etc/nginx/sites-available/ngx-legacy.conf ]]
touch "$TMP/fail-test"
reject convert legacy --type proxy --yes
contains "$TMP/output" '--- '
contains "$TMP/output" '+++ ngx-legacy.conf（候选）'
contains "$TMP/output" '已恢复'
cmp "$FOREIGN" "$TMP/edited-foreign"
[[ -L $NGX_ROOT/etc/nginx/sites-enabled/legacy.conf ]]
[[ ! -f $NGX_ROOT/etc/nginx/sites-available/ngx-legacy.conf ]]
contains "$NGX_ROOT/etc/ngx/sites/legacy.env" 'TYPE=adopted'
run convert legacy --type proxy --yes
contains "$TMP/output" '+++ ngx-legacy.conf（候选）'
[[ ! -L $NGX_ROOT/etc/nginx/sites-enabled/legacy.conf && -L $NGX_ROOT/etc/nginx/sites-enabled/ngx-legacy.conf ]]
cmp "$FOREIGN" "$TMP/edited-foreign"
contains "$NGX_ROOT/etc/nginx/sites-available/ngx-legacy.conf" 'ssl_certificate '
contains "$NGX_ROOT/etc/ngx/sites/legacy.env" 'TYPE=proxy'
run adopt
if grep -q '已接管' "$TMP/output"; then echo '转换原件被重复接管'; exit 1; fi
run convert existing --type proxy --no-tls --yes
[[ -f $NGX_ROOT/etc/nginx/conf.d/existing.conf.disabled && -L $NGX_ROOT/etc/nginx/sites-enabled/ngx-existing.conf ]]
report 'convert diff / 测试失败完整回滚 / TLS lineage 复用 / conf.d 转换'
