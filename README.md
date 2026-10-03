# tools

两个单文件 Bash 工具，用中文界面管理 Debian 服务器的防火墙和 nginx 网站。

| 工具 | 用途 | 手册 |
| --- | --- | --- |
| `fw` | 管理 nftables 端口、白名单、IP 封禁和拦截日志 | [fw 手册](docs/fw.md) |
| `ngx` | 管理 nginx 网站、HTTPS 证书、Cloudflare DNS 和备份 | [ngx 手册](docs/ngx.md) |

## 快速安装

适用于 Debian 12/13，需要 root 和 nftables；`ngx install` 会自动安装缺少的 nginx/certbot。ngx 的其他依赖和版本要求见手册。

```bash
gh repo clone kyri3m/tools
# 或：git clone git@github.com:kyri3m/tools.git
cd tools
# 以下命令以 root 执行
install -m755 fw ngx /usr/local/bin/
fw                 # 进入防火墙菜单，首次运行初始化规则
ngx install        # 安装依赖并初始化 nginx
ngx                # 进入网站面板
```

这是私有仓库，克隆前需有仓库访问权限；使用 gh 时先登录，使用 SSH 时先配置密钥。

## 主界面

`fw` 主菜单：

```text
  fw 防火墙管理   主机名
  ● 运行中  放行 3 个端口 · 白名单 1 · 黑名单 0 · fail2ban 封禁 2
  ──────────────────────────────────────
   1) 查看状态        6) 添加白名单
   2) 放行端口        7) 移出白名单
   3) 关闭端口        8) 拦截日志
   4) 封禁 IP         9) fail2ban 情况
   5) 解封 IP         r) 重新加载规则
   0) 退出
```

`ngx` 网站面板：

```text
  ngx 网站管理    nginx 运行中 · 2 个网站 · 一切正常
  ─────────────────────────────────────────────────────────
   网站    状态      域名              证书          Cloudflare
   1 emby  ● 在线    emby.example.com  剩 89 天      灰云
   2 blog  ○ 已停用  blog.example.com  未启用 HTTPS  橙云
  ─────────────────────────────────────────────────────────
   1-9) 管理网站   n) 新建网站   c) Cloudflare 设置
   d) 一键体检     b) 备份恢复   0) 退出
```

## 常见用法

```bash
fw open 8443 tcp                       # 放行 TCP 端口
fw block 203.0.113.10                   # 封禁来源 IP
ngx add web --type proxy --domain web.example.com --port 443 --upstream 127.0.0.1:8080  # 新建反向代理网站
ngx cf token set                       # 隐藏输入 Cloudflare Token
ngx                                    # 选网站 → 8，切换橙云/灰云（橙云用 Full (strict)）
ngx doctor                             # 一键体检
ngx backup                             # 普通备份，默认排除 Token 和私钥
```

## 配合使用

ngx 不会自行开放防火墙端口；需要用户确认或显式指定 `--open-firewall` 才会调用 fw。建议先用 fw 放行 HTTP/HTTPS，再创建网站：

```bash
fw open 80 tcp
fw open 443 tcp
```

HTTP-01 签发需要 80 端口；自定义网站端口也需放行，并自行配置云安全组和 NAT。

## 数据与安全

服务器状态分别保存在 `/etc/fw` 和 `/etc/ngx`；nginx 配置在 `/etc/nginx`，ngx 备份在 `/var/backups/ngx`。服务器状态和备份不得提交到仓库。

Cloudflare Token 保存在 `/etc/ngx/cloudflare.token`，仅 root 可读写（0600）；通过隐藏输入设置，不放进命令参数、日志或默认备份。`ngx backup --with-keys` 会包含 Token、证书和私钥，需妥善保管。

## 开发与测试

```bash
shellcheck fw ngx test/*.sh
bash test/run.sh
```

测试使用仓库内临时目录和命令桩，不修改真实服务器配置。`test/followup.sh` 和 `test/v3.sh` 由 `test/run.sh` source，切勿直接运行；测试所需依赖见 [ngx 手册](docs/ngx.md#隔离测试)。
