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
 query=parse_qs(urlparse(url).query); name=query.get('name',[None])[0]
 rows=[r for r in records if not name or r['name']==name]
 size=int(query.get('per_page',['100'])[0]); page=int(query.get('page',['1'])[0])
 emit(rows[(page-1)*size:page*size],result_info={'total_pages':max(1,(len(rows)+size-1)//size)}); sys.exit()
if method=='POST':
 payload['id']='r'+str(max([int(r['id'][1:]) for r in records if r['id'].startswith('r') and r['id'][1:].isdigit()]+[0])+1); records.append(payload); result=payload
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

# DNS 管理测试使用独立记录集，结束后恢复网站原记录。
cp "$TMP/records.json" "$TMP/dns-original"
run dns list example.test
contains "$TMP/output" '类型'
contains "$TMP/output" '· 网站 v3'
run dns list
contains "$TMP/output" 'example.test'
run dns add a.example.test A 203.0.113.8 --ttl 60 --proxied on
run dns add aaaa.example.test AAAA 2001:db8::8
run dns add alias.example.test CNAME a.example.test
run dns add txt.example.test TXT 'value "quoted" with spaces'
run dns add flags.example.test TXT --dns
run dns edit flags.example.test TXT --content --yes
run dns rm flags.example.test TXT --yes
run dns add example.test MX mail.example.test --priority 20
run dns add _sip._tcp.example.test SRV '10 5 5060 sip.example.test'
run dns add example.test CAA '0 issue letsencrypt.org'
run dns add delegated.example.test NS ns.example.test
run dns list example.test
contains "$TMP/output" 'value "quoted" with spaces'
contains "$TMP/output" '10 5 5060 sip.example.test'
contains "$TMP/output" '0 issue letsencrypt.org'
contains "$TMP/output" '20 mail.example.test'
contains "$TMP/output" '自动'
contains "$TMP/output" '—'
python3 - "$TMP/records.json" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1]))
assert {r['type'] for r in rows}=={'A','AAAA','CNAME','TXT','MX','SRV','CAA','NS'}
assert next(r for r in rows if r['type']=='SRV')['data']==dict(service='_sip',proto='_tcp',name='example.test',priority=10,weight=5,port=5060,target='sip.example.test')
assert next(r for r in rows if r['type']=='CAA')['data']==dict(flags=0,tag='issue',value='letsencrypt.org')
PY
BEFORE=$(wc -l < "$TMP/api-calls")
reject dns add outside.invalid A 203.0.113.8
reject dns add 'bad".example.test' TXT injection
reject dns add a.example.test SOA bad
reject dns add a.example.test A '203.0.113.8","proxied":true'
reject dns add a.example.test A 2001:db8::8
reject dns add a.example.test AAAA 203.0.113.8
reject dns add a.example.test CNAME 'bad host'
reject dns add a.example.test CNAME 203.0.113.8
reject dns add a.example.test TXT $'control\ncharacter'
reject dns add a.example.test MX mail.example.test
reject dns add a.example.test MX mail.example.test --priority 65536
reject dns add a.example.test SRV '0 0 443 target.example.test'
reject dns add _sip._tcp.example.test SRV '0 0 bad target.example.test'
reject dns add a.example.test CAA '999 issue letsencrypt.org'
reject dns add a.example.test NS bad/hostname
reject dns add a.example.test TXT value --proxied on
reject dns add a.example.test A 203.0.113.8 --ttl 59
reject dns add a.example.test A 203.0.113.8 --ttl 86401
reject dns add a.example.test A 203.0.113.8 --ttl '1","content":"injected'
reject dns add a.example.test A 203.0.113.8 --proxied maybe
reject dns edit a.example.test A --id '../bad' --ttl 300
# 校验失败不能写入 API。
sed -n "$((BEFORE+1)),\$p" "$TMP/api-calls" > "$TMP/dns-invalid-calls"
if grep -Eq '^(POST|PATCH|PUT|DELETE) ' "$TMP/dns-invalid-calls"; then echo '无效输入写入 API'; exit 1; fi
run dns edit a.example.test A --content 203.0.113.9 --ttl 86400 --proxied off
run dns edit txt.example.test TXT --content 'new "quoted" value' --ttl 300
python3 - "$TMP/records.json" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1])); a=next(r for r in rows if r['name']=='a.example.test')
assert a['content']=='203.0.113.9' and a['ttl']==86400 and not a['proxied']
txt=next(r for r in rows if r['type']=='TXT'); assert txt['content']=='new "quoted" value' and txt['ttl']==300
PY
reject dns edit a.example.test A --ttl 30
run dns add a.example.test A 203.0.113.10
reject dns edit a.example.test A --ttl 300
contains "$TMP/output" '多个记录匹配'
contains "$TMP/output" '--id'
reject dns rm a.example.test A --yes
ID=$(python3 -c 'import json,sys; print(next(r for r in json.load(open(sys.argv[1])) if r["name"]=="a.example.test")["id"])' "$TMP/records.json")
run dns edit a.example.test A --id "$ID" --ttl 300
if printf 'n\n' | "$BASE/ngx" dns rm a.example.test A --id "$ID" > "$TMP/output" 2>&1; then echo '拒绝确认后不应删除'; exit 1; fi
printf 'y\n' | "$BASE/ngx" dns rm a.example.test A --id "$ID" > "$TMP/output" 2>&1
contains "$TMP/output" 'rm 成功'
run dns rm txt.example.test TXT --yes
if printf 'n\n' | "$BASE/ngx" dns edit v3.example.test A --content 203.0.113.5 > "$TMP/output" 2>&1; then echo '网站记录应要求确认'; exit 1; fi
contains "$TMP/output" '删除会使网站无法访问'
printf 'y\n' | "$BASE/ngx" dns edit v3.example.test A --content 203.0.113.5 > "$TMP/output" 2>&1
printf 'y\n' | "$BASE/ngx" dns edit v3.example.test A --proxied off > "$TMP/output" 2>&1
contains "$NGX_ROOT/etc/ngx/sites/v3.env" 'CLOUDFLARE=off'
printf 'y\n' | "$BASE/ngx" dns edit v3.example.test A --proxied on > "$TMP/output" 2>&1
contains "$NGX_ROOT/etc/ngx/sites/v3.env" 'CLOUDFLARE=on'
if printf 'n\n' | "$BASE/ngx" dns rm v3.example.test A > "$TMP/output" 2>&1; then echo '网站删除应确认'; exit 1; fi
contains "$TMP/output" '· 网站 v3'
contains "$TMP/output" '删除会使网站无法访问'
report 'DNS 全类型添加 / JSON 和类型校验 / 内容、TTL、代理编辑 / 重名 --id / 删除确认 / 网站警告和联动'
# 测 UI：域名列表、无 Token、向导默认值及编辑菜单。
(
    # shellcheck source=/dev/null
    source "$TMP/functions"
    pause() { :; }
    ui_cloudflare <<< 0
    ui_dns_add example.test <<'INPUT'
1
wizard



y
INPUT
    ui_dns_add example.test <<'INPUT'
5
@
mail.example.test
10

y
INPUT
    ui_dns_add example.test <<'INPUT'
6
CAA
example.test
0 issue letsencrypt.org

y
INPUT
) > "$TMP/output" 2>&1
contains "$TMP/output" 'Cloudflare · Token …1234'
contains "$TMP/output" '条解析'
contains "$TMP/output" 'wizard.example.test · A · add 成功'
contains "$TMP/output" 'example.test · MX · add 成功'
contains "$TMP/output" 'example.test · CAA · add 成功'
# 同 dashboard 的显示宽度对齐：中文 TXT、根域名和网站标记。
(
    # shellcheck source=/dev/null
    source "$TMP/functions"
    dns_site() { [[ $1 != example.test ]] || echo 中文网站; return 0; }
    dns_table example.test '[{"id":"align1","type":"TXT","name":"example.test","content":"中文 text","ttl":1},{"id":"align2","type":"A","name":"emby.example.test","content":"203.0.113.8","proxied":true,"ttl":300}]'
) > "$TMP/dns-alignment"
python3 - "$TMP/dns-alignment" <<'PY'
import sys,unicodedata
cells=[['序号','类型','名称','内容','代理','TTL'],['1','TXT','@ · 网站 中文网站','中文 text','—','自动'],['2','A','emby','203.0.113.8','橙云','300']]
def width(s):
 return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in s)
widths=[max(width(row[i]) for row in cells) for i in range(6)]
expected=['   '+'  '.join(c+' '*(w-width(c)) for c,w in zip(row,widths)) for row in cells]
assert open(sys.argv[1]).read().splitlines()==expected
PY
# 101 条记录同时覆盖 API 分页和 UI 的第 20/21 条边界。
python3 - "$TMP/records.json" <<'PY'
import json,sys
json.dump([dict(id='page'+str(i),name='page'+str(i)+'.example.test',type='A',content='203.0.113.8',proxied=False,ttl=1) for i in range(1,102)],open(sys.argv[1],'w'))
PY
(
    # shellcheck source=/dev/null
    source "$TMP/functions"
    pause() { :; }
    ui_dns_zone zone1 example.test <<'INPUT'
n
21
3
300
p
0
INPUT
) > "$TMP/output" 2>&1
contains "$TMP/output" '2/6 页'
contains "$TMP/output" 'page20'
contains "$TMP/output" 'page21'
contains "$TMP/output" 'page40'
contains "$TMP/output" '修改内容'
contains "$TMP/api-calls" 'per_page=100&page=2'
python3 - "$TMP/records.json" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1])); assert len(rows)==101 and rows[20]['ttl']==300
PY
(
    # shellcheck source=/dev/null
    source "$TMP/functions"
    STATE=$TMP/no-token
    ui_cloudflare <<< 0
) > "$TMP/output" 2>&1
contains "$TMP/output" '还没添加 Token'
contains "$TMP/output" 't) 添加 Token'
contains "$TMP/output" 'My Profile → API Tokens'
contains "$TMP/output" 'Zone.DNS Edit + Zone.Zone Read'
if grep -Fq "$V3_TOKEN" "$TMP/output" "$TMP/api-calls"; then echo 'DNS UI Token 泄漏'; exit 1; fi
cp "$TMP/dns-original" "$TMP/records.json"
rm -rf "$NGX_ROOT/etc/ngx/cache"
report 'Cloudflare 域名列表 / 向导 A 默认 IP、MX 和 CAA / API 与 UI 分页 / 管理菜单 / 无 Token 提示 / Token 不泄漏'

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
reject dns list example.test
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
