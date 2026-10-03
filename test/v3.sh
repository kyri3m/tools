#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317 # 动态导入的函数读取全局变量并调用测试替身。
# 仅由 run.sh source；所有测试使用它的隔离根与命令桩。
[[ -n ${NGX_ROOT:-} && $NGX_ROOT == "$TMP/root" ]] || { echo '请运行 bash test/run.sh' >&2; exit 2; }
cp "$TMP/bin/curl" "$TMP/bin/curl-old"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env python3
import sys,os,json
args=sys.argv[1:]; url=args[-1]; folder=os.environ['NGX_TEST']
if 'api.cloudflare.com/client/v4' not in url:
 os.execv(folder+'/bin/curl-old',[folder+'/bin/curl-old']+args)
config=sys.stdin.read() if '--config' in args else ''
# 只记录方法、URL 和 DNS 数据；不记录 Authorization。
method=args[args.index('-X')+1]; payload={}
if '--data-binary' in args: payload=json.loads(args[args.index('--data-binary')+1])
with open(folder+'/api-calls','a') as f: f.write(method+' '+url+' '+json.dumps(payload)+'\n')
mode=open(folder+'/api-mode').read().strip() if os.path.exists(folder+'/api-mode') else 'ok'
def emit(result,success=True,**extra): print(json.dumps(dict(success=success,result=result,**extra)))
if mode=='bad' or 'Bearer ' not in config: emit({},False); sys.exit()
if url.endswith('/user/tokens/verify'): emit({'status':'active'}); sys.exit()
if '/zones?' in url: emit([{'id':'zone1','name':'example.test'}]); sys.exit()
if mode=='no-dns': emit({},False); sys.exit()
path=folder+'/records.json'
records=json.load(open(path)) if os.path.exists(path) else []
if method=='GET':
 from urllib.parse import parse_qs,urlparse
 name=parse_qs(urlparse(url).query).get('name',[None])[0]
 emit([r for r in records if not name or r['name']==name]); sys.exit()
if method=='POST':
 payload['id']='r'+str(len(records)+1); records.append(payload); result=payload
elif method in ('PUT','PATCH'):
 id=url.split('/')[-1]; result=next(r for r in records if r['id']==id); result.update(payload)
elif method=='DELETE':
 id=url.split('/')[-1]; records=[r for r in records if r['id']!=id]; result={}
json.dump(records,open(path,'w')); emit(result)
STUB
chmod +x "$TMP/bin/curl"
V3_TOKEN='test_SECRET_token_1234'
printf bad > "$TMP/api-mode"
if printf '%s\n' "$V3_TOKEN" | "$BASE/ngx" cf token set > "$TMP/output" 2>&1; then echo 'bad Token 应失败'; exit 1; fi
[[ ! -e $NGX_ROOT/etc/ngx/cloudflare.token ]]
printf no-dns > "$TMP/api-mode"
if printf '%s\n' "$V3_TOKEN" | "$BASE/ngx" cf token set > "$TMP/output" 2>&1; then echo '缺少 DNS 权限应失败'; exit 1; fi
contains "$TMP/output" 'Zone.DNS Edit + Zone.Zone Read'
printf ok > "$TMP/api-mode"
printf '%s\n' "$V3_TOKEN" | "$BASE/ngx" cf token set > "$TMP/output" 2>&1
contains "$TMP/output" '…1234'
if grep -Fq "$V3_TOKEN" "$TMP/output"; then echo 'Token 设置输出泄漏'; exit 1; fi
[[ $(stat -c '%a:%u' "$NGX_ROOT/etc/ngx/cloudflare.token") == 600:0 ]]
run cf token test
run cf token zones
contains "$TMP/output" 'example.test'
report 'Token 验证 / 缺少 DNS 权限 / 隐藏输入 / 权限 0600 / zones'
run add v3 --type proxy --domain v3.example.test --port 12500 --no-tls
run dns set v3
contains "$TMP/api-calls" 'POST https://api.cloudflare.com/client/v4/zones/zone1/dns_records'
run dns set v3 --proxied on
contains "$TMP/api-calls" 'PUT https://api.cloudflare.com/client/v4/zones/zone1/dns_records/'
contains "$TMP/api-calls" '"proxied": true'
run dns list v3
contains "$TMP/output" 'v3.example.test'
report 'DNS A/AAAA 创建 / 更新 / proxied'
cat > "$NGX_ROOT/etc/nginx/sites-available/v3hand.conf" <<'CONF'
server { listen 12505; server_name hand.example.test; root /var/www/html; }
CONF
run adopt
# 导入同一单文件的函数，避免为测试增加生产命令。
sed '$d' "$BASE/ngx" > "$TMP/functions"
(
    # shellcheck source=/dev/null
    source "$TMP/functions"
    reachable() { echo ✓; }
    ui_dashboard
    ui_site_render v3
) > "$TMP/output" 2>&1
contains "$TMP/output" 'ngx 网站管理'
contains "$TMP/output" '● 在线'
contains "$TMP/output" '手写配置'
contains "$TMP/output" '今日请求'
contains "$TMP/output" '未启用 HTTPS'
if grep -Eq 'nginx version:|^active$|^enabled$|LISTEN|NEXT certbot.timer|模拟配置错误' "$TMP/output"; then echo 'UI 泄漏原始命令输出'; exit 1; fi
# 缓存 60 秒内不重复访问 API。
BEFORE=$(wc -l < "$TMP/api-calls")
(
    # shellcheck source=/dev/null
    source "$TMP/functions"
    ui_cloud_state v3.example.test
    ui_cloud_state v3.example.test
) > "$TMP/output"
[[ $(wc -l < "$TMP/api-calls") == "$BEFORE" ]]
report 'dashboard / 网站详情 / 手写标记 / 无原始输出 / CF 缓存'

# 强制颜色，覆盖中英文、手写标记、不同状态及证书长度。
(
    # shellcheck source=/dev/null
    source "$TMP/functions"
    G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' D=$'\e[2m' BD=$'\e[1m' N=$'\e[0m'
    site_names() { printf '%s\n' emby 中文博客 short; }
    ui_findings() { :; }
    load_site() {
        NAME=$1 TYPE=proxy TLS=on
        case $1 in
            emby) DOMAINS=emby.example.com;;
            中文博客) DOMAINS=blog.example.com TYPE=adopted TLS=off;;
            short) DOMAINS=x.test;;
        esac
    }
    site_enabled() { [[ $NAME != 中文博客 ]]; }
    reachable() { if [[ $NAME == short ]]; then echo ✗; else echo ✓; fi; }
    cert_days() { if [[ $NAME == short ]]; then echo 10; else echo 89; fi; }
    ui_cloud_state() { if [[ $1 == blog.example.com ]]; then echo 橙云; else echo 灰云; fi; }
    ui_dashboard
) > "$TMP/colour-dashboard"
python3 - "$TMP/colour-dashboard" <<'PY'
import re,sys,unicodedata
raw=open(sys.argv[1]).read()
assert all(code in raw for code in ('\x1b[32m','\x1b[33m','\x1b[31m')),raw
text=re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]','',raw)
expected=[['网站','状态','域名','证书','Cloudflare'],
          ['1 emby','● 在线','emby.example.com','剩 89 天','灰云'],
          ['2 中文博客 手写配置','○ 已停用','blog.example.com','未启用 HTTPS','橙云'],
          ['3 short','● 后端不通','x.test','剩 10 天','灰云']]
rows=[line for line in text.splitlines() if any(line.startswith('   '+cells[0]) for cells in expected)]
assert len(rows)==len(expected),rows
def width(s):
 return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in s)
widths=[max(width(cells[i]) for cells in expected) for i in range(5)]
offsets=[3]
for w in widths[:-1]: offsets.append(offsets[-1]+w+2)
for line,cells in zip(rows,expected):
 starts=[width(line[:line.index(cell)]) for cell in cells]
 assert starts==offsets,(line,starts,offsets)
 # 精确验证两空格间隔和按可见宽度补齐，不能靠加宽表头对齐。
 assert line=='   '+'  '.join(cell+' '*(w-width(cell)) for cell,w in zip(cells,widths)),line
PY
report '强制颜色 dashboard：ANSI/CJK 显示宽度 / 表头与每行列起点一致 / 两空格列间隔'
# 缺少续期 hook 只补现有配置；certbot 桩设置为失败以防误调用签发。
HOOK_CONFIG=$NGX_ROOT/etc/letsencrypt/renewal/ngx-emby.conf
cp "$HOOK_CONFIG" "$TMP/hook-original"
cp "$NGX_ROOT/etc/letsencrypt/live/ngx-emby/fullchain.pem" "$TMP/hook-cert"
cp "$NGX_ROOT/etc/letsencrypt/live/ngx-emby/privkey.pem" "$TMP/hook-key"
cat > "$HOOK_CONFIG" <<'CONF'
# 保留原有续期方式和域名映射
[renewalparams]
authenticator = webroot
[[webroot_map]]
newemby.example.test = /existing/webroot
CONF
cp "$HOOK_CONFIG" "$TMP/hook-missing"
sed -n '/^certbot /p' "$TMP/calls" > "$TMP/certbot-before-hook"
touch "$TMP/fail-cert"
(
    # shellcheck source=/dev/null
    source "$TMP/functions"
    reachable() { echo ✓; }
    ui_findings() {
        (UI_MODE=1; doctor || :) 2>&1 | sed -n 's/^  [!✘] //p' | ui_words |
            sed -n '/^emby 缺少续期 deploy hook/p'
    }
    confirm() { printf '%s\n' "$1"; return 0; }
    ui_doctor
    [[ -z $(ui_findings) ]]
) > "$TMP/output" 2>&1
contains "$TMP/output" '→ 补上续期加载 hook'
contains "$TMP/output" '是否修复 emby 的续期加载 hook？'
if grep -Eq '重新签发|cert issue' "$TMP/output"; then echo '续期 hook 修复不应重新签发'; exit 1; fi
contains "$HOOK_CONFIG" 'deploy_hook = systemctl reload nginx'
contains "$HOOK_CONFIG" 'authenticator = webroot'
contains "$HOOK_CONFIG" 'newemby.example.test = /existing/webroot'
python3 - "$HOOK_CONFIG" <<'PY'
import sys
text=open(sys.argv[1]).read()
assert text.index('deploy_hook =') < text.index('[[webroot_map]]')
PY
run cert hook emby
[[ $(grep -c '^deploy_hook =' "$HOOK_CONFIG") == 1 ]]
sed -n '/^certbot /p' "$TMP/calls" > "$TMP/certbot-after-hook"
cmp "$TMP/certbot-before-hook" "$TMP/certbot-after-hook"
cmp "$TMP/hook-cert" "$NGX_ROOT/etc/letsencrypt/live/ngx-emby/fullchain.pem"
cmp "$TMP/hook-key" "$NGX_ROOT/etc/letsencrypt/live/ngx-emby/privkey.pem"
# 已有自定义 hook 保留，检查加载 hook 不再误报；失败则恢复原配置。
cp "$TMP/hook-missing" "$HOOK_CONFIG"
sed -i '/^authenticator =/a deploy_hook = /usr/local/bin/notify' "$HOOK_CONFIG"
run cert hook emby
contains "$HOOK_CONFIG" 'deploy_hook = /usr/local/bin/notify; systemctl reload nginx'
cp "$TMP/hook-missing" "$HOOK_CONFIG"
touch "$TMP/fail-test"
reject cert hook emby
cmp "$TMP/hook-missing" "$HOOK_CONFIG"
rm "$TMP/fail-cert"
cp "$TMP/hook-original" "$HOOK_CONFIG"
report 'doctor 自动补续期 hook / 无 certbot 签发 / 证书不变 / 保留配置和自定义 hook / 幂等 / 失败回滚'

(
    # shellcheck source=/dev/null
    source "$TMP/functions"
    ui_run() { printf 'CALL %s\n' "$*"; }
    main() { printf 'CALL %s\n' "$*"; }
    confirm() { return 0; }
    ui_site_action v3 1 <<< changed.example.test
    ui_site_action v3 2 <<< 12501
    ui_site_action v3 3 <<< 127.0.0.1:9090
    ui_site_action v3 5
    ui_site_action v3 6
    ui_site_action v3 7
    ui_site_action v3 9
    ui_site_action v3 x
    ui_site_action v3 e
    ui_cert v3 <<< 2
    ui_cert v3 <<< 4
) > "$TMP/output"
for expected in 'set v3 domain changed.example.test' 'set v3 port 12501' 'set v3 upstream 127.0.0.1:9090' 'logs v3 -n 50' 'logs v3 --error -n 50' 'top v3 --since 1d' 'disable v3' 'rm v3 --yes' 'edit v3' 'cert renew v3 --dry-run' 'cert off v3'; do contains "$TMP/output" "$expected"; done
# 不带 Token 的向导只询问必要项，回车采用 EmbyHub/443/10618/HTTPS。
(
    # shellcheck source=/dev/null
    source "$TMP/functions"
    STATE=$TMP/wizard-state
    ui_run() { printf 'CALL %s\n' "$*"; }
    load_site() { NAME=$1 TYPE=emby TLS=off DOMAINS=wizard.example.test PORT=443; }
    ui_cloud_state() { echo 灰云; }
    ui_add <<'INPUT'

wizard.example.test



INPUT
) > "$TMP/output"
contains "$TMP/output" 'add wizard --type emby --domain wizard.example.test --port 443 --upstream 127.0.0.1:10618'
contains "$TMP/output" '放行 80 端口'
report '详情动作映射 / 向导默认值'
# 两侧切换，失败时恢复已改 DNS。
(
    # shellcheck source=/dev/null
    source "$TMP/functions"
    ui_cloud_toggle v3
) > "$TMP/output" 2>&1
contains "$NGX_ROOT/etc/ngx/sites/v3.env" 'CLOUDFLARE=off'
contains "$TMP/output" '灰云'
(
    # shellcheck source=/dev/null
    source "$TMP/functions"
    ui_cloud_toggle v3
) > "$TMP/output" 2>&1
contains "$NGX_ROOT/etc/ngx/sites/v3.env" 'CLOUDFLARE=on'
contains "$TMP/output" '橙云'
touch "$TMP/fail-test"
if (
    # shellcheck source=/dev/null
    source "$TMP/functions"
    ui_cloud_toggle v3
) > "$TMP/output" 2>&1; then echo 'nginx 失败应恢复 DNS'; exit 1; fi
contains "$NGX_ROOT/etc/ngx/sites/v3.env" 'CLOUDFLARE=on'
python3 - "$TMP/records.json" <<'PY'
import json,sys
assert all(r['proxied'] for r in json.load(open(sys.argv[1])))
PY
report '橙云/灰云同时切换 DNS 与 nginx / nginx 失败恢复 DNS'
touch "$TMP/closed80"
run cert issue v3 --dns
contains "$TMP/calls" '--manual-auth-hook'
contains "$NGX_ROOT/etc/ngx/sites/v3.env" 'CERT_METHOD=dns'
contains "$NGX_ROOT/etc/letsencrypt/renewal/ngx-v3.conf" 'authenticator = manual'
contains "$NGX_ROOT/etc/letsencrypt/renewal/ngx-v3.conf" '_dns-cleanup'
run cert renew --dry-run
# 插件优先、临时凭据确实存在且为 0600，签发后删除，续期不引用临时文件。
cp "$TMP/bin/certbot" "$TMP/bin/certbot-old"
cat > "$TMP/bin/certbot" <<'STUB'
#!/usr/bin/env bash
if [[ $* == *plugins* ]]; then echo dns-cloudflare; exit; fi
args=("$@")
while (($#)); do
    if [[ $1 == --dns-cloudflare-credentials ]]; then
        [[ $(stat -c %a "$2") == 600 && -s $2 ]] || exit 1
        printf '%s\n' "$2" > "$NGX_TEST/credential-path"
    fi
    shift
done
"$NGX_TEST/bin/certbot-old" "${args[@]}" || exit 1
for ((i=0; i<${#args[@]}-1; i++)); do
    if [[ ${args[i]} == --cert-name ]]; then
        printf '[renewalparams]\n[[webroot_map]]\nv3.example.test = /old/root\n' >> "$NGX_ROOT/etc/letsencrypt/renewal/${args[i+1]}.conf"
    fi
done
STUB
chmod +x "$TMP/bin/certbot"
run cert issue v3 --dns
contains "$TMP/calls" '--dns-cloudflare-credentials'
[[ ! -e $(cat "$TMP/credential-path") ]]
python3 - "$NGX_ROOT/etc/letsencrypt/renewal/ngx-v3.conf" <<'PY'
import sys
text=open(sys.argv[1]).read()
assert text.index('manual_auth_hook =') < text.index('[[webroot_map]]')
PY
if grep -q dns_cloudflare_credentials "$NGX_ROOT/etc/letsencrypt/renewal/ngx-v3.conf"; then exit 1; fi
mv "$TMP/bin/certbot-old" "$TMP/bin/certbot"
rm "$TMP/closed80"
# 实际运行 manual hooks：隔离 sleep 桩，保留其他 TXT，只删本次挑战。
cat > "$TMP/bin/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/bin/sleep"
python3 - "$TMP/records.json" <<'PY'
import json,sys
path=sys.argv[1]; rows=json.load(open(path))
rows.append(dict(id='keep',type='TXT',name='_acme-challenge.v3.example.test',content='other-challenge',proxied=False))
json.dump(rows,open(path,'w'))
PY
CERTBOT_DOMAIN=v3.example.test CERTBOT_VALIDATION=test_validation "$BASE/ngx" _dns-auth > "$TMP/auth-output"
CERTBOT_DOMAIN=v3.example.test CERTBOT_VALIDATION=test_validation CERTBOT_AUTH_OUTPUT="$(cat "$TMP/auth-output")" "$BASE/ngx" _dns-cleanup > "$TMP/output"
python3 - "$TMP/records.json" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1]))
assert any(r.get('id')=='keep' for r in rows)
assert not any(r.get('content')=='test_validation' for r in rows)
PY
rm "$TMP/bin/sleep"
run disable v3
run set v3 domain disabled-v3.example.test
[[ ! -e $NGX_ROOT/etc/nginx/sites-enabled/ngx-v3.conf ]]
run cert issue v3 --dns
run enable v3
run set v3 domain v3.example.test
report 'DNS-01 manual hooks / 插件优先 / 临时凭据删除 / 持久续期 hooks / 无需 80'
run backup
V3_BACKUP=$(tail -n 1 "$TMP/output")
if tar -tzf "$V3_BACKUP" | grep -q 'cloudflare.token'; then echo '默认备份泄漏 Token'; exit 1; fi
run backup --with-keys
V3_KEYS=$(tail -n 1 "$TMP/output")
tar -tzf "$V3_KEYS" > "$TMP/members"
contains "$TMP/members" 'etc/ngx/cloudflare.token'
run restore "$V3_BACKUP"
[[ $(cat "$NGX_ROOT/etc/ngx/cloudflare.token") == "$V3_TOKEN" ]]
# 检查所有可能输出，不扫描授权存储的 Token 文件/含密钥备份。
if grep -Fq "$V3_TOKEN" "$TMP/output" "$TMP/calls" "$TMP/api-calls"; then echo 'Token 泄漏'; exit 1; fi
run cf token rm
[[ ! -e $NGX_ROOT/etc/ngx/cloudflare.token ]]
reject cf token test
(
    # shellcheck source=/dev/null
    source "$TMP/functions"
    confirm() { return 0; }
    ui_cloud_toggle v3
) > "$TMP/output" 2>&1
contains "$TMP/output" 'Cloudflare 控制台'
report 'Token 不出现在输出/参数/默认备份 / 恢复保留 Token / rm / 无 Token 切换提示'
run rm v3 --yes
rm "$NGX_ROOT/etc/nginx/sites-available/v3hand.conf" "$NGX_ROOT/etc/ngx/sites/v3hand.env"
mv "$TMP/bin/curl-old" "$TMP/bin/curl"
