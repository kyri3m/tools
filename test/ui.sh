#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317 # 动态导入 UI 函数；替身读取测试变量。
# 仅由 run.sh source，所有状态和函数副本均在隔离根内。
[[ -n ${NGX_ROOT:-} && $NGX_ROOT == "$TMP/root" ]] || { echo '请运行 bash test/run.sh' >&2; exit 2; }
sed '$d' "$BASE/ngx" > "$TMP/ui-ngx-functions"
sed '/^# ---------- 入口 ----------/,$d' "$BASE/fw" > "$TMP/ui-fw-functions"
sed -n '/^# ---------- 入口 ----------/,$p' "$BASE/fw" > "$TMP/ui-fw-entry"
cat > "$TMP/bin/nft" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/bin/nft"
mkdir -p "$TMP/fw-ui"
for file in ports blocklist allowlist; do : > "$TMP/fw-ui/$file"; done
# 伪 TTY 只通过测试函数注入；生产代码始终使用 [[ -t 1 ]]。
(
    set +e
    # shellcheck source=/dev/null
    source "$TMP/ui-ngx-functions"
    UI_MODE=1 TERM=xterm NGX_NO_CLEAR=0 UI_TEST_TTY=1
    ui_stdout_tty() { [[ $UI_TEST_TTY == 1 ]]; }
    clear() { [[ $* == -x ]] || return 1; printf '\e[H\e[2J\e[3J'; }
    ui_findings() { :; }
    site_names() { :; }
    service_cmd() { :; }
    load_site() { NAME=demo DOMAINS=demo.example.test TYPE=proxy TLS=off UPSTREAM=127.0.0.1:8080 DOCROOT='' PORT=443; }
    ui_status_label() { echo 在线; }
    ui_cert_label() { echo 未启用; }
    ui_cloud_state() { echo 灰云; }
    ui_today() { echo 0; }
    cf_record_data() { echo '[]'; }
    dns_site() { :; }
    STATE=$TMP/no-token-ui
    ui_dashboard > "$TMP/ui-ngx-dashboard"
    ui_site_render demo > "$TMP/ui-ngx-site"
    ui_cert demo <<< 0 > "$TMP/ui-ngx-cert"
    ui_add <<< 0 > "$TMP/ui-ngx-add"
    ui_cf_token <<< 0 > "$TMP/ui-ngx-token"
    ui_dns_add example.test <<< 0 > "$TMP/ui-ngx-dns-add" 2>&1
    ui_dns_record example.test '[{"id":"r1","name":"example.test","type":"TXT","content":"x","ttl":1}]' 1 <<< 0 > "$TMP/ui-ngx-record"
    ui_dns_zone zone1 example.test <<< 0 > "$TMP/ui-ngx-zone"
    ui_cloudflare <<< 0 > "$TMP/ui-ngx-cloudflare"
    ui_doctor > "$TMP/ui-ngx-doctor"
    ui_backup <<< 0 > "$TMP/ui-ngx-backup"
    NGX_NO_CLEAR=1 ui_dashboard > "$TMP/ui-ngx-disabled"
    TERM=dumb ui_dashboard > "$TMP/ui-ngx-dumb"
    UI_TEST_TTY=0 ui_dashboard > "$TMP/ui-ngx-piped"
    UI_MODE=0 ui_dashboard > "$TMP/ui-ngx-cli"
    # clear 不可用/不支持 -x 时使用指定的 ANSI 回退。
    clear() { return 1; }
    ui_dashboard > "$TMP/ui-ngx-fallback"
    # 真正的管道探测函数不能输出清屏码。
    ui_stdout_tty() { [[ -t 1 ]]; }
    ui_dashboard | cat > "$TMP/ui-ngx-real-pipe"
)
(
    set +e
    set +u # fw 原有 ask 的第三个参数为可选；测试不改变它。
    # shellcheck source=/dev/null
    source "$TMP/ui-fw-functions"
    PORTS=$TMP/fw-ui/ports BLOCKS=$TMP/fw-ui/blocklist ALLOWS=$TMP/fw-ui/allowlist
    FW_UI_MODE=1 TERM=xterm FW_NO_CLEAR=0 UI_TEST_TTY=1
    ui_stdout_tty() { [[ $UI_TEST_TTY == 1 ]]; }
    clear() { [[ $* == -x ]] || return 1; printf '\e[H\e[2J\e[3J'; }
    load_listeners() { LISTENERS=(); }
    f2b_banned() { :; }
    my_ips() { :; }
    for action in open close block unblock trust untrust; do
        "ui_$action" <<< '' > "$TMP/ui-fw-$action"
    done
    NGX_NO_CLEAR=1 ui_clear > "$TMP/ui-fw-other-env" # ngx 的开关不影响 fw。
    FW_NO_CLEAR=1 ui_open <<< '' > "$TMP/ui-fw-disabled"
    TERM=dumb ui_open <<< '' > "$TMP/ui-fw-dumb"
    UI_TEST_TTY=0 ui_open <<< '' > "$TMP/ui-fw-piped"
    FW_UI_MODE=0 ui_open <<< '' > "$TMP/ui-fw-cli"
    clear() { return 1; }
    ui_clear > "$TMP/ui-fw-fallback"
    ui_stdout_tty() { [[ -t 1 ]]; }
    ui_open <<< '' | cat > "$TMP/ui-fw-real-pipe"
)
# 一屏只清一次；禁用、dumb、CLI 和真实管道均不清屏。
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1]); clear='\x1b[H\x1b[2J\x1b[3J'
for app,screens in [('ngx','dashboard site cert add token dns-add record zone cloudflare doctor backup fallback'),('fw','open close block unblock trust untrust other-env fallback')]:
 for screen in screens.split():
  text=(root/f'ui-{app}-{screen}').read_text()
  assert text.count(clear)==1 and text.startswith(clear),(app,screen,repr(text))
 for screen in ('disabled','dumb','piped','cli','real-pipe'):
  text=(root/f'ui-{app}-{screen}').read_text()
  assert '\x1b[2J' not in text,(app,screen,repr(text))
PY
# 菜单动作：成功、错误和取消都必须在下一次清屏前显示暂停提示。
(
    set +e
    # shellcheck source=/dev/null
    source "$TMP/ui-ngx-functions"
    UI_MODE=1 TERM=xterm NGX_NO_CLEAR=0
    ui_stdout_tty() { return 0; }
    clear() { printf '\e[H\e[2J\e[3J'; }
    site_names() { :; }
    ui_findings() { :; }
    service_cmd() { :; }
    ui_run() { echo 'ACTION_SUCCESS'; return 0; }
    cf_token() { echo 'ACTION_ERROR'; return 1; }
    # 测试真正的 Cloudflare/Token 页面及其动作暂停，最后返回主菜单。
    STATE=$TMP/ui-token-state; mkdir -p "$STATE"; echo test_token_abcd > "$STATE/cloudflare.token"
    cf_zones() { printf 'z1\texample.test\n'; }
    cf_record_data() { echo '[]'; }
    ui_cloudflare <<'INPUT' > "$TMP/ui-ngx-actions"
s

t
2

0
INPUT
    # 网站动作确认取消：仍需暂停，不能立刻重画网站。
    STATE=$NGX_ROOT/etc/ngx
    ui_site emby <<'INPUT' > "$TMP/ui-ngx-cancel"
x
n

0
INPUT
    # 子页面加载失败：错误后暂停再画 Cloudflare/主菜单。
    STATE=$TMP/ui-token-state
    cf_record_data() { echo '[]'; }
    ui_dns_zone() { echo 'ACTION_ERROR'; return 1; }
    ui_cloudflare <<'INPUT' > "$TMP/ui-ngx-page-error"
1

0
INPUT
)
(
    set +e
    set +u
    # shellcheck source=/dev/null
    source "$TMP/ui-fw-functions"
    PORTS=$TMP/fw-ui/ports BLOCKS=$TMP/fw-ui/blocklist ALLOWS=$TMP/fw-ui/allowlist
    TERM=xterm FW_NO_CLEAR=0
    ui_stdout_tty() { return 0; }
    clear() { printf '\e[H\e[2J\e[3J'; }
    f2b_banned() { :; }
    load_listeners() { LISTENERS=(); }
    cmd_status() { echo 'ACTION_SUCCESS'; }
    cmd_log() { echo 'ACTION_ERROR'; return 1; }
    menu <<'INPUT' > "$TMP/ui-fw-actions"
1

8

2


0
INPUT
)
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1]); clear='\x1b[H\x1b[2J\x1b[3J'
for app in ('ngx','fw'):
 text=(root/f'ui-{app}-actions').read_text()
 for result in ('ACTION_SUCCESS','ACTION_ERROR'):
  tail=text.split(result,1)[1]; before_next=tail.split(clear,1)[0]
  assert '按回车返回' in before_next,(app,result,repr(text))
 assert text.count(clear)==(4 if app=='ngx' else 7),(app,repr(text))
text=(root/'ui-ngx-page-error').read_text()
assert '按回车返回' in text.split('ACTION_ERROR',1)[1].split(clear,1)[0]
# 取消后的暂停也必须位于下一个页面之前。
for file,title in [('ui-ngx-cancel','x) 删除网站'),('ui-fw-actions','■ 放行端口')]:
 text=(root/file).read_text(); assert '按回车返回' in text.split(title,1)[1].split(clear,1)[0],repr(text)
PY
# CLI 入口即使伪装成 TTY，也不能清屏或暂停。
run status
cp "$TMP/output" "$TMP/ui-ngx-status"
(
    set +e
    set +u
    # shellcheck source=/dev/null
    source "$TMP/ui-fw-functions"
    ui_stdout_tty() { return 0; }
    clear() { echo UNEXPECTED_CLEAR; }
    init_state() { :; }
    cmd_status() { echo CLI_STATUS; }
    set -- status
    # shellcheck source=/dev/null
    source "$TMP/ui-fw-entry"
) > "$TMP/ui-fw-status"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
for app in ('ngx','fw'):
 text=(Path(sys.argv[1])/f'ui-{app}-status').read_text()
 assert '\x1b[2J' not in text and 'UNEXPECTED_CLEAR' not in text and '按回车返回' not in text,text
PY
rm "$TMP/bin/nft"
report 'ngx / fw 每页一次清屏 / clear -x 回退 / TTY、TERM 和禁用开关 / CLI 与管道不清屏 / 成功、错误和取消先暂停再重绘'
