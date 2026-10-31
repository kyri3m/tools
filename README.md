# tools

两个单文件工具，用中文界面管理服务器的防火墙（fw，Bash）和 nginx 网站（ngx，Python 标准库）。

| 工具 | 用途 | 手册 |
| --- | --- | --- |
| `fw` | 管理 nftables 端口、白名单、IP 封禁和拦截日志 | [fw 手册](docs/fw.md) |
| `ngx` | 一条命令把本机服务反代成 HTTPS 网站：自动 Cloudflare 解析、证书、nginx 配置 | [ngx 手册](docs/ngx.md) |

## 快速安装

fw 适用于 Debian 12/13（需要 nftables）；ngx 适用于 Debian / Ubuntu / RHEL 系，`ngx install` 会自动安装 nginx、certbot。

install.sh 顺带把系统上限调到够用：`fs.file-max`、inotify 实例/监听数、`nofile`（limits.d 和 systemd `DefaultLimitNOFILE`）都到 1048576 级别；只调高不调低，已配置过的不动。不想要就加 `TOOLS_NO_TUNE=1`。

```bash
# root 执行：安装 fw、ngx 并初始化 nginx（会补装 python3、nginx、certbot）
curl -fsSL https://raw.githubusercontent.com/kyri3m/tools/main/install.sh | sh

fw                 # 进入防火墙菜单，首次运行初始化规则
ngx cf token set   # 可选：有 Cloudflare 时，新建网站会自动解析 DNS
ngx add app.example.com 3000   # 反代本机 3000 端口
```


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
  ngx 2.0.0  ·  nginx 运行中  ·  Cloudflare 已连接

  #  网站  域名              后端    状态        HTTPS     DNS
  1  app   app.example.com   :3000   ● 在线      剩 89 天  灰云
  2  blog  blog.example.com  :8080   ● 后端不通  剩 61 天  橙云

  a 新建反代   s 扫描本机服务   c Cloudflare   d 体检   b 备份   q 退出
```

## 常见用法

```bash
fw open 8443 tcp                       # 放行 TCP 端口
fw block 203.0.113.10                   # 封禁来源 IP
ngx scan                               # 本机哪些端口在监听、还没反代
ngx add app.example.com 3000           # 解析 DNS + 申请证书 + 反代，一步完成
ngx route app add /api/ 3001           # 按路径分流
ngx cf proxied app on                  # 切换橙云，nginx 同步信任 CF 真实 IP
ngx doctor --fix                       # 体检并自动修复
ngx backup                             # 普通备份，默认排除 Token 和私钥
```

## 配合使用

ngx 新建网站时会检查 fw 是否已放行 80 和网站端口，经用户确认（或 `--open-firewall`）后调用 `fw open`；没有 fw 时退回 ufw，都没有则只做提示。也可以提前放行：

```bash
fw open 80 tcp
fw open 443 tcp
```

HTTP 验证需要 80 端口；设置了 Cloudflare Token 时改用 DNS 验证，不需要 80。云安全组和 NAT 需自行配置。

## 数据与安全

服务器状态分别保存在 `/etc/fw` 和 `/etc/ngx`；nginx 配置在 `/etc/nginx`，ngx 备份在 `/var/backups/ngx`。服务器状态和备份不得提交到仓库。

Cloudflare Token 保存在 `/etc/ngx/cloudflare.token`，仅 root 可读写（0600）；通过隐藏输入设置，不放进命令参数、日志或默认备份。`ngx backup --with-keys` 会包含 Token、证书和私钥，需妥善保管。

## 开发与测试

```bash
shellcheck fw test/run.sh
bash test/run.sh        # ngx 隔离测试：临时根目录 + certbot 桩 + 本地假 Cloudflare API
```

测试只在临时目录里运行，不修改真实服务器配置，也不访问真实 Cloudflare；需要本机有 nginx、python3、openssl。
