# ngx — nginx 网站管理

适用于 Debian 13、apt nginx 1.26、certbot 4。Bash 单文件，中文界面，配色和 CJK 表格与 `fw` 一致。需要 root；依赖 Bash、Python 3.12+、openssl、curl、getent、iproute2、util-linux、tar 和 systemd。四份基础模板已内嵌，不依赖旁边的目录。

交互页面仅在终端输出且 `TERM` 非 `dumb` 时清屏，操作结果按 Enter 后返回；`NGX_NO_CLEAR=1` 禁用清屏，CLI 和管道输出不清屏。

## 安装与 EmbyHub

```bash
install -m755 ngx /usr/local/bin/ngx
ngx install
ngx cf update                  # 使用 Cloudflare 检测/模式前先更新范围
ngx add media --type emby --domain media.example.com \
  --port 10618 --upstream 127.0.0.1:18618 --email admin@example.com
```

`install` 在缺少 nginx/certbot 时通过 apt 安装，创建共享配置、ACME webroot 和 80 端口入口，启用 `certbot.timer`、每周运行的 `ngx-cf-update.timer`。CF 定时服务指向执行 `install` 的 ngx 文件；移动程序后重新执行 `ngx install`。首次获取 CF 范围需运行 `ngx cf update`。安装幂等。

Debian `default` 的启用入口保存在 `/etc/nginx/ngx-default.disabled`，原 `sites-available/default` 不删除；已被替换的 default 不会再次自动接管。如果之前已登记，状态显示停用。其他原站点保留。

EmbyHub 的应用设置需自行应用，ngx 只打印提示：

```dotenv
MEDIA_HTTP_TRUSTED_PROXIES=127.0.0.1,::1
```

“系统 → 设置 → 中心公网地址”和内置节点地址使用 `https://media.example.com:10618`。节点可通过 `cli node register-center --rotate` 重新注册，或在管理后台更新。

Emby 模板支持 HTTP/2、WebSocket、Range/If-Range，关闭代理缓冲和缓存，流式超时 3600 秒，上传限制 100m；仅压缩文本，不压缩视频。TLS 1.2/1.3，半年 HSTS，无 preload、无 CSP、无 OCSP stapling。应用自身发出的绝对 307 不重写。

## 命令示例

不带参数运行 `ngx` 进入网站面板。网站编号打开详情页；手写配置自动出现在列表中，无需手动接管。大于 9 的编号也可输入。

```text
  ngx 网站管理    nginx 运行中 · 2 个网站 · 一切正常
  ─────────────────────────────────────────────────────────
   网站       状态       域名                 证书             Cloudflare
   1 emby     ● 在线     emby.example.com     剩 89 天         灰云
   2 blog     ○ 已停用   blog.example.com     未启用 HTTPS     橙云
  ─────────────────────────────────────────────────────────
   1-9) 管理网站   n) 新建网站   c) Cloudflare
   d) 一键体检     b) 备份恢复   0) 退出
```

面板静默运行 doctor 检查，显示“一切正常”或问题数。启用网站会探测后端地址；证书不足 14 天标红。Cloudflare 状态实时获取并缓存 60 秒：有 Token 时读 DNS 记录，否则比较解析地址、CF 范围与本机公网 IP；无法判断显示 `—`。

```text
  emby · emby.example.com                         ● 在线
  后端地址 127.0.0.1:10618 · HTTPS 剩 89 天 · 灰云 · 今日请求 1,234
   1) 修改域名        5) 查看访问日志      9) 启用/停用网站
   2) 修改端口        6) 查看错误日志      x) 删除网站
   3) 修改后端地址    7) 访问统计          e) 手动编辑配置
   4) HTTPS 证书 ▸    8) 橙云/灰云切换     0) 返回
```

HTTPS 子菜单支持立即重新签发、模拟续期和开关 HTTPS；关闭时保留证书。手写配置用 `e` 编辑，或用 `u` 查看 diff 并升级为标准配置。`d` 将问题显示为“问题 → 怎么修”，可确认修复证书、realip、防火墙或 nginx 服务。`b` 提供普通备份、按日期和大小选择恢复、备份目录说明。

新建网站只询问类型、域名、端口、后端地址或目录、HTTPS。回车默认 EmbyHub、443、`127.0.0.1:10618`、启用 HTTPS；其他服务默认 `127.0.0.1:8080`，静态网页默认 `/var/www/<域名第一段>`。名称自动取域名第一段，重名加数字。Token 可管理域名时，询问是否将 A/AAAA 指向公网 IP、是否橙云，默认灰云，并用 DNS-01 签发；否则提示放行 80，使用 HTTP-01。结束显示 URL、证书、DNS、Cloudflare 状态和 EmbyHub 应用提示。CLI 的原有默认值保持不变。

| 命令 | 示例与用途 |
| --- | --- |
| `install` | `ngx install`：初始化与安装定时器 |
| `status` | `ngx status`：服务、worker、监听、站点、证书、上游、CF 状态和 fw |
| `add` | `ngx add web --type proxy --domain web.example.com --port 8443 --upstream 127.0.0.1:8080` |
| `add` 静态站点 | `ngx add docs --type static --domain docs.example.com --port 8081 --root /var/www/docs --no-tls` |
| `edit` | `EDITOR=nano ngx edit web`：编辑后校验与加载；EDITOR 是可执行文件名或路径，不是 shell 表达式 |
| `show` | `ngx show web`：带行号显示配置 |
| `enable` / `disable` | `ngx disable web`；`ngx enable web` |
| `set` | `ngx set web upstream 127.0.0.1:9000`；`ngx set web port 8444`；`ngx set web domain new.example.com` |
| `set cloudflare` | `ngx set web cloudflare on`；`ngx set web cloudflare on --cf-only`；`ngx set web cloudflare off` |
| `rm` | `ngx rm web --yes`：默认保留证书；`ngx rm web --yes --purge-cert` 同时清理证书 |
| `cert issue` | `ngx cert issue web --email admin@example.com`：用 webroot 签发/更新 lineage、保存 reload hook |
| `cert renew` | `ngx cert renew web --dry-run`：单网站模拟；`ngx cert renew --dry-run`：全部模拟；`ngx cert renew`：实际续期 |
| `cert list` | `ngx cert list`：域名、有效期和剩余天数 |
| `cert rm` | `ngx cert rm web --yes`：删除已不被该站点引用的证书 |
| `test` | `ngx test`：运行 nginx 配置检查 |
| `reload` / `restart` | `ngx reload`；`ngx restart`：先测试，失败恢复 |
| `logs` | `ngx logs web -f --error -n 100`；`ngx logs -n 50` |
| `top` | `ngx top web`：最近 1000 条；`ngx top web --since 1h`：最近一小时，支持 m/h/d |
| `backup` | `ngx backup`；`ngx backup --with-keys`：包含证书及私钥 |
| `restore` | `ngx restore /var/backups/ngx/20261002T120000-123.tar.gz` |
| `cf token` | `ngx cf token set`：隐藏输入；`test` 验证；`zones` 列域名；`rm` 删除 |
| `dns` | `list [zone或网站]` 查看域名全部解析；`set web` 更新公网 A/AAAA；`add/edit/rm` 管理解析 |
| `cert issue --dns` | `ngx cert issue web --dns`：Cloudflare DNS-01，不需要 80 |
| `cert off` | `ngx cert off web`：关闭 HTTPS，保留证书 |
| `cf update` | `ngx cf update`：校验并更新官方地址范围、realip 和限源配置 |
| `adopt` | `ngx adopt --dry-run`：仅预览；`ngx adopt`：立即扫描登记 |
| `convert` | `ngx convert legacy --type emby --port 10618 --upstream 127.0.0.1:18618 --yes` |
| `doctor` | `ngx doctor`：配置错误、重复域名、监听冲突、上游、证书、CF 和续期方式 |
| `help` | `ngx help`：简要用法 |

域名以逗号分隔。名称支持中文、字母、数字、下划线和连字符；80 专用于 ACME。上游支持 `host:port`、`[IPv6]:port` 和 `unix:/path`。`set` 重新生成整个受管配置，会覆盖手工编辑。新增 TLS 站点先启用 HTTP 验证配置，签发成功后切换 TLS。默认邮箱保存在 `/etc/ngx/config` 的 `EMAIL=`；没有邮箱时警告后使用 certbot 无邮箱注册选项。

防火墙仅调用 `fw status` / `fw open`，不编辑 nftables。交互模式询问是否放行；非交互需显式加 `--open-firewall`，例如 `ngx add web ... --open-firewall`。无法从 fw 输出确认放行时显示“未知”，不会假定可达。ACME 要求 TCP/80；还需自行配置云安全组和 NAT。

## Cloudflare Token 怎么创建

在 Cloudflare 控制台右上角个人资料 → API Tokens → Create Token，选择 Edit zone DNS 模板：

- 权限设为 **Zone / DNS / Edit** 和 **Zone / Zone / Read**。
- Zone Resources 仅选择需要管理的域名。
- 创建后复制 Token，运行 `ngx cf token set` 或在 `c` 菜单隐藏输入。不要使用 Global API Key。

添加时请求 `/user/tokens/verify`，分页列出可访问的 zones，并检查各 zone 能读取 DNS。读取成功不能证明编辑权限；实际写入时 API 会再次验证权限。无效 Token、无可用 zone、DNS 读取失败都不会替换原 Token。保存到 `/etc/ngx/cloudflare.token`，root 所有、0600，界面仅显示末四位。`ngx cf token test|zones|rm` 分别测试、列出域名、删除。删除后 DNS-01 续期需要重新添加 Token。

```bash
ngx cf token set                 # 隐藏输入，不要把 Token 放在命令参数里
ngx dns list web
ngx dns set web --proxied off     # 用本机公网 IPv4/IPv6 创建或更新 A/AAAA
ngx cert issue web --dns
ngx cert renew --dry-run
```

DNS set 默认保持已有记录的代理状态，新记录默认灰云；已有 CNAME 或同类型多个记录时要求先在控制台处理。详情页云朵切换使用 PATCH 保留 DNS 地址。橙云请使用 Full (strict)。

`c) Cloudflare` 显示 Token 末四位、每周 IP 同步状态和域名解析条数。`t` 管理 Token，`s` 同步 IP 段，域名序号进入解析页。解析表按可见字符宽度对齐，显示类型、短名称（根域名为 `@`）、内容、代理和 TTL，每页 20 条，`n/p` 翻页；序号在分页间连续。`a` 添加解析，回车采用根域名、A/AAAA 本机公网 IP、灰云和自动 TTL。名称可填相对名称或当前域名下的完整名称，相对名称自动补上当前域名。

```bash
ngx dns list                         # 查看所有授权域名的全部解析
ngx dns list example.com             # 也可填写该域名下的完整记录名称或 ngx 网站名称
ngx dns add emby.example.com A 203.0.113.5 --proxied off --ttl 300
ngx dns add example.com MX mail.example.com --priority 10
ngx dns add _sip._tcp.example.com SRV '10 5 5060 sip.example.com'
ngx dns add example.com CAA '0 issue letsencrypt.org'
ngx dns edit emby.example.com A --content 203.0.113.6 --ttl 1
ngx dns edit emby.example.com A --proxied on --id RECORD_ID
ngx dns rm emby.example.com A         # 展示记录后确认；--yes 跳过删除确认
```

CLI 添加、编辑、删除采用完整记录名称，必须在 Token 授权的域名内。支持 A、AAAA、CNAME、TXT、MX、SRV、CAA、NS；IP 和目标主机名按类型校验，TXT 保留引号和空格。SRV 名称采用 `_service._tcp/udp/tls.域名`，内容是 `priority weight port target`；CAA 是 `flags tag value`（tag 支持 issue、issuewild、iodef）。MX 新建必须指定 `--priority`（0–65535）；只有 A/AAAA/CNAME 支持橙云。TTL 为 `1`（自动）或 `60–86400` 秒。编辑未指定的字段保持原值；同名称、类型匹配多条时会列出记录和 ID，必须用 `--id` 选择，避免误改误删。

匹配 ngx 网站域名的记录标记 `· 网站 <名称>`。修改前警告并确认，删除明确提示会破坏访问（自动化删除可用 `--yes`）。切换关联记录的代理会询问是否通过网站云朵操作，让该网站全部域名的 DNS 和 nginx 一起切换，并复用失败回滚；非交互调用需提供确认输入。多个网站共用同一记录时，先分别在网站页调整。接管的手写网站须先升级为标准配置才能联动切换。

DNS-01 优先使用已安装的 certbot Cloudflare 插件，以 0600 临时文件传凭据，签发后删除；没有插件时使用 ngx 内置 manual auth/cleanup hooks，创建独立 TXT、等待 60 秒传播、只清理本次挑战记录。`CERT_METHOD=dns` 保存在网站元数据中，后续域名修改继续用 DNS-01。续期配置统一使用持久的 ngx hooks 读取当前 Token，避免引用已删除的插件临时凭据；无需插件继续安装，也无需开放 80。ngx 可执行文件需要保持原路径，移动后重新 `cert issue --dns` 更新 hooks。Token 通过 curl 标准输入传递，不放在进程参数中。

## Cloudflare 橙云与灰云

```bash
ngx cf update
ngx add center --type emby --domain center.example.com --port 443 \
  --upstream 127.0.0.1:18618 --cloudflare --cf-only
ngx set center cloudflare off
```

每次 `status` / `doctor` 实时解析域名，与缓存的 CF 官方 CIDR 和本机公网 IP 比较：全部地址在 CF 范围内为“橙云”，全部直达本机公网 IP 为“灰云”，解析失败、其他服务商、混合地址或证据不足为“其他”。CLI status/doctor 的这项检查使用 DNS 推断。交互面板有 Token 时读取 Cloudflare API；详情页切换云朵会同时修改该网站所有域名的 DNS proxied 标记和 nginx 模式，nginx 失败会尝试恢复 DNS，并报告无法恢复的记录。没有 Token 时解释控制台操作，确认后仅改 nginx。范围缓存不存在时请先更新。

范围来自 `https://www.cloudflare.com/ips-v4` 和 `/ips-v6`，每行严格校验 CIDR、地址族，并要求至少 10 条不同 IPv4 和 1 条 IPv6 范围。下载、校验或 nginx 加载失败都保留旧文件。

realip 在 `/etc/nginx/conf.d/ngx-cloudflare-realip.conf` **全局生效**：只信任官方 CF 源地址，使用 `CF-Connecting-IP`。`cloudflare on` 控制受管站点的转发头：`X-Real-IP $remote_addr` 和覆盖式 `X-Forwarded-For $remote_addr`，避免直连者提供的 XFF 被传入应用；不会追加其原始 XFF。关闭该模式恢复普通代理的追加行为，但全局可信来源声明仍存在，外来站点也会受全局 realip 影响。

`--cf-only` 在服务器层包含 CF `allow` 列表和 `deny all`。由于 realip 会先改写 `$remote_addr`，内容 location 使用基于 **`$realip_remote_addr` 原始 TCP 对端**的 geo 检查，同时覆盖继承的地址 ACL，防止正常 CF 用户被误拦。HTTP 与 TLS 的 `/.well-known/acme-challenge/` 都显式 `allow all`，不走内容限源。CF IP 更新同时更新 realip、geo 和 ACL，无需重新生成站点。

注意：

- 橙云 SSL 模式必须是 **Full (strict)**。首次签发还没有有效源站证书时，建议临时灰云，签发成功后再橙云。
- HTTP-01 的 HTTP/TLS 验证路径都必须能到源站，不被 WAF、认证或缓存拦截。若 “Always Use HTTPS” 把挑战转向 443，源站必须有对应的 443 TLS 站点；只监听自定义端口不会自动获得 443 入口。
- CF 橙云允许的 HTTPS 端口为 443、2053、2083、2087、2096、8443；默认 Emby 10618 应使用灰云。
- CF 条款限制通过免费 CDN 传送大量视频。建议中心与播放节点分域：中心可橙云，`play.example.com` 灰云，类型 `emby`、同一上游，并在应用中配置节点公网地址。
- 模式开启但灰云本身无害；开启 `--cf-only` 后直连访问会被拒绝。`doctor` 和 add/set 后会输出相关提示。

## 自动接管与转换

每次运行都会扫描 `sites-enabled/`、`sites-available/`、`conf.d/*.conf`；`ngx adopt --dry-run` 不做自动登记，也不创建备份。包含 `# managed-by: ngx` 标记或已登记的文件会跳过，符号链接按原文件去重。纯 map/snippet 等无 server 的文件不当作站点。

登记时原文件不改、不移动：在 `/etc/ngx/sites/<名称>.env` 保存 `TYPE=adopted`、`FILE=原路径`、域名、监听/TLS、上游/root、证书、日志及启用入口；原件备份到 `/var/backups/ngx/adopted/`。元数据只解析，不 `source` 或执行。文件名转为有效名称，重名追加编号；多 server 文件作为一个管理单元。路径需能安全表示且原件位于 nginx 配置目录内；不安全路径会明确报告并跳过。

“接管”站点支持 status、show、edit、enable/disable、logs、top、backup/restore、doctor 和证书关联。读取时重新解析配置，外部编辑不会让显示永久停留在旧数据。日志读取明确声明或全局日志；`top` 按常见 combined 格式统计，无法解析的自定义格式行会跳过。conf.d 的显式停用将 `.conf` 改为 `.conf.disabled`；sites-enabled 的符号链接移除/重建。若启用目录内本来是实体文件，显式停用会把它保留到 sites-available，再以符号链接管理。单纯扫描不执行这些操作。

`set` 拒绝接管站点，提示 `edit` 或 `convert`；`rm` 也保留原件，需先停用或转换。转换从解析结果和覆盖选项生成完整候选配置，显示 unified diff，确认或 `--yes` 后才停用原站点、启用新配置。多上游、多证书等无法唯一选择时要求明确参数。转换按整个文件进行，复杂 location、rewrite、认证规则不会自动迁移，请检查 diff。原文件保留，测试/加载失败恢复原元数据、文件和启用状态；已转换原件不会再次接管。

证书路径在 `/etc/letsencrypt/live/<lineage>/` 下时关联既有 certbot lineage。`ngx cert issue <接管名>` 用 webroot 重新签发该 lineage，不修改原配置；原配置必须已把 HTTP/TLS 挑战路径映射到 `/var/www/ngx-acme`，否则 certbot 失败并回滚。`doctor` 检查 `authenticator = nginx`，建议改用 webroot，避免 nginx 插件自动改配置。

## 安全与备份

配置变更使用互斥锁，在受限权限临时目录保存修改前配置和证书，写入后先 `nginx -t` 再 reload。编辑、启停、转换、CF 更新和恢复失败时撤销磁盘改动并重新加载旧配置；恢复加载也失败会打印错误并保留快照路径。自动接管只是登记和备份，不改变运行配置，因此不为扫描触发 reload。不要同时使用其他工具编辑配置。

普通备份为 `/var/backups/ngx/<时间>-<PID>.tar.gz`，包含 `/etc/nginx` 和 `/etc/ngx`；默认排除 Token、临时凭据、界面缓存和私钥，不备份 Let's Encrypt 目录。普通备份恢复时保留当前 Token。`--with-keys` 加入 Token、Let's Encrypt 和私钥；归档权限 0600。事务回滚所需的临时快照包含私钥，成功后删除。

恢复仅应用受管文件和归档中登记的接管文件，保留其他文件；拒绝路径穿越、危险链接和非普通成员。恢复针对同一主机和相同路径，默认不含私钥的备份依赖现有证书/私钥。候选磁盘配置通过检查后才 reload，失败恢复修改前状态。

外部系统的副作用无法撤回：已签发的 CA 证书、ACME 账户/限额、已执行的 apt 安装，以及用户明确要求的 `fw open` 不随 nginx 配置回滚而撤销。nginx 文件恢复不等于撤销这些外部操作。工具不会改 EmbyHub 应用配置。

## 隔离测试

```bash
shellcheck ngx test/*.sh
bash test/run.sh
./ngx help
```

测试用工作目录内临时 `NGX_ROOT` 为所有配置路径加前缀，通过 PATH 提供 nginx/certbot/systemctl/fw/ss/curl/getent 桩；不安装全局依赖，不修改真实 `/etc`。NGX_ROOT 下拒绝调用系统目录中的 systemctl、fw 和 certbot。测试也将单文件复制到独立位置验证安装不依赖模板目录。

真实 nginx 使用临时主配置、自签证书、隔离日志和临时目录，覆盖普通 TLS、Cloudflare 与 cf-only。若监听 socket 探测失败，仅这部分输出 `SKIP 真实 nginx 校验（无 socket 权限）`；全部桩测试和后续证书清理测试仍执行。允许 socket 的环境会执行完整 `nginx -t -p ... -c ...`，失败不会被吞掉。

新增测试覆盖网站面板无原始命令输出、详情动作、向导默认值、Token 验证与保密、DNS 创建与更新、橙云双侧切换及失败恢复、DNS-01 插件与 hooks、默认备份排除 Token。`test/followup.sh` 和 `test/v3.sh` 仅由 `run.sh` source，请勿直接执行。
