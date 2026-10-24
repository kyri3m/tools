# ngx 手册

把本机服务反代成 HTTPS 网站：一条命令完成 **Cloudflare DNS 解析 → nginx 反代 → Let's Encrypt 证书**。

```bash
ngx add app.example.com 3000
```

这一条会：

1. 有 Cloudflare Token 时，自动把 `app.example.com` 解析到本机公网 IP（没有记录就创建，指错了就修正）
2. 生成 nginx 反代配置（WebSocket、真实 IP、HTTP→HTTPS 跳转都已配好）
3. 申请证书：有 Token 用 DNS 验证（不需要 80 端口，支持橙云和通配符），否则用 HTTP 验证并先自检
4. 校验并重载 nginx；任何一步失败，配置自动回滚
5. 本机有防火墙（`fw` / `ufw`）时提示放行端口

## 安装

root 运行（Debian / Ubuntu / RHEL 系）：

```bash
curl -fsSL https://raw.githubusercontent.com/kyri3m/tools/main/install.sh | sh   # 安装 fw、ngx 并初始化
ngx install --email you@example.com    # 证书到期通知邮箱（可选）
ngx cf token set                       # 可选：Cloudflare API Token
```

依赖：Python 3.8+（只用标准库）、nginx、certbot、curl、openssl。`ngx install` 会自动安装缺的包。

Cloudflare Token 创建：My Profile → API Tokens → Create Token → 模板「Edit zone DNS」。
权限：`Zone · DNS · Edit` + `Zone · Zone · Read`，资源只选需要的域名。

## 常用

```bash
ngx                                  # 交互菜单
ngx scan                             # 本机有哪些端口在监听、哪些还没反代
ngx add app.example.com 3000         # 反代本机 3000
ngx add a.com,www.a.com 8080         # 多个域名
ngx add files.example.com /srv/www   # 静态目录
ngx add app.example.com 3000 --proxied   # 橙云代理
ngx ls                               # 网站列表：在线状态、证书剩余天数、DNS 指向
ngx doctor --fix                     # 体检并自动修复
```

### 修改

```bash
ngx set app backend 3001             # 换后端
ngx set app domain app.example.com,api.example.com   # 换域名（自动补证书、解析）
ngx set app body 2g                  # 上传上限
ngx set app timeout 600              # 超时秒数
ngx set app buffering on             # 开启缓冲（默认关，适合流媒体和 SSE）
ngx set app headers off              # 不加安全响应头（应用自己设置时）
ngx set app port 8443                # 换监听端口
ngx set app tls off                  # 只用 HTTP
```

### 路由、访问控制

```bash
ngx route app add /api/ 3001         # /api/ 转发到另一个服务
ngx route app add =/health 3002      # 精确匹配
ngx route app add /v2/ 127.0.0.1:3001/api   # 改写前缀
ngx auth app set admin               # 密码访问
ngx allow app add 10.0.0.0/8         # IP 白名单
ngx set app cf-only on               # 只允许经 Cloudflare 访问
ngx edit app                         # 自定义 nginx 片段（重新生成时保留）
```

### Cloudflare / DNS

```bash
ngx cf proxied app on                # 切换橙云，nginx 同步信任 CF 真实 IP
ngx dns point app                    # 把网站域名解析到本机
ngx dns ls example.com               # 查看解析
ngx dns add txt.example.com TXT "v=spf1 -all"
ngx dns rm old.example.com A
```

### 证书、日志、备份

```bash
ngx cert list / ngx cert issue app [--force] / ngx cert renew --dry-run
ngx logs app -f / ngx logs app --error / ngx top app --since 6h
ngx backup [--with-keys] / ngx restore <文件>
```

`--with-keys` 会带上证书私钥和 Token，用于迁移到新服务器。

## 文件布局

| 路径 | 内容 |
|---|---|
| `/etc/ngx/sites/<网站>.json` | 网站元数据（唯一数据源） |
| `/etc/ngx/custom/<网站>.conf` | 自定义 nginx 片段 |
| `/etc/nginx/sites-available/ngx-<网站>.conf` | 生成的配置，不要手改 |
| `/etc/nginx/snippets/ngx-*.conf` | 共享片段（SSL、反代头、ACME） |
| `/etc/letsencrypt/live/ngx-<网站>/` | 证书 |

已有的手写 nginx 站点可用 `ngx adopt` 登记：能在列表里查看、启停、看日志，ngx 不会改动文件内容。

从 1.x（bash 版）升级：首次运行时会自动把旧元数据转成 JSON，旧配置里手工添加的 `location` 保留到自定义片段。
