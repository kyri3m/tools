# fw — nftables 防火墙管理

单文件 Bash 脚本，中文界面。适用于 Debian 12/13（nftables）。需要 root。

交互页面仅在终端输出且 `TERM` 非 `dumb` 时清屏，操作结果按 Enter 后返回；`FW_NO_CLEAR=1` 禁用清屏，CLI 和管道输出不清屏。

## 安装

```bash
install -m755 fw /usr/local/bin/fw
fw            # 进入数字菜单
```

首次运行会自动检测 SSH 端口并放行，再生成 `/etc/nftables.conf` 并加载。

## 菜单

```
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

“放行端口”会列出正在监听但还没放行的公网端口，直接照着选即可。

## 命令行

| 命令 | 说明 |
| --- | --- |
| `fw status` | 查看状态（默认） |
| `fw open <端口> [tcp\|udp\|both] [备注]` | 放行端口，支持区间：`fw open 8000-8100` |
| `fw close <端口> [协议]` | 关闭端口 |
| `fw block <IP\|网段> [备注]` | 封禁来源 |
| `fw unblock <IP\|网段>` | 解封（也能解封 fail2ban 封的 IP） |
| `fw trust <IP\|网段> [备注]` | 加入白名单，始终放行所有端口 |
| `fw untrust <IP\|网段>` | 移出白名单 |
| `fw log [条数]` | 拦截日志和被探测最多的端口 |
| `fw bans` | fail2ban 封禁情况 |
| `fw reload` | 按 `/etc/fw/` 重新加载 |

所有修改立即生效并永久保存。

## 安全设计

- **防自锁**：SSH 端口受保护，不能关闭；检测不到 SSH 端口时拒绝初始化。
- **不碰别人的规则**：不使用 `flush ruleset`，只重建自己的表，Docker 和 fail2ban 的规则保持不变。
- **白名单同步 fail2ban**：白名单写入 `/etc/fail2ban/jail.d/fw-allowlist.local` 的 `ignoreip`，白名单 IP 不会被 fail2ban 封禁。
- Docker 发布的端口（docker-proxy）走 Docker 自己的链，不在“未放行”提示里出现；只想本机访问的服务请绑定 `127.0.0.1`。

## 数据位置

| 路径 | 内容 |
| --- | --- |
| `/etc/fw/ports` | 每行：`协议 端口[-端口] 备注` |
| `/etc/fw/allowlist` | 每行：`IP或网段 备注` |
| `/etc/fw/blocklist` | 每行：`IP或网段 备注` |
| `/etc/nftables.conf` | 由 fw 生成，勿手改 |
| `/etc/systemd/system/fw.service` | 由 fw 生成：开机加载规则（不用发行版的 nftables.service，它停止时会清空 Docker、fail2ban 的规则） |

这些是服务器自己的状态，不放进仓库。迁移服务器时复制 `/etc/fw/` 后执行 `fw reload`。
