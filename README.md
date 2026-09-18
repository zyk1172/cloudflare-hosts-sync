# Cloudflare Hosts Sync

这个公开 raw 仓库是 QNAP Cloudflare Hosts Manager 与 macOS 之间的同步边界。

## 设计

```text
yx-tools Web（NAS 上按 Web 保存的配置测速）
        ↓
QNAP Cloudflare Hosts Manager
        ├─ 逐域名 HTTPS / Tracker announce 验证
        ├─ 更新 NAS /etc/hosts
        └─ 发布已验证的 hosts-map.tsv 到本仓库
                ↓
macOS mac-sync-hosts.sh
        ├─ 直接拉取 hosts-map.tsv（不 clone 仓库）
        ├─ 校验精确 FQDN、IP 和 VERIFIED/RETAINED 状态
        ├─ 清理已知旧 PT-CLOUDFLARE-MANAGED Marker
        ├─ 逐域名 HTTPS 检测，默认拒绝 HTTP 000/403
        └─ 只更新本机 /etc/hosts 的 CF-YX-MAC-SYNC Marker
```

NAS 不会上传 yx-tools 的完整候选池、配置文件、日志、Tracker 凭据或 Token。仓库只保存逐域名的已验证映射和非敏感状态摘要。

macOS 端不会重新测速，也不会扫描 DNS；它会对仓库映射逐域名执行一次真实 GET HTTPS 检测。默认拒绝 HTTP 000 和 403，避免把已知无法打开或无法做种的 IP 写入本机 Hosts。

## macOS 使用

脚本不需要建立本地 Git 项目，也不需要保存仓库工作副本。当前仓库公开，Mac 直接使用 raw 内容读取文件：

```sh
gh auth login
mkdir -p "$HOME/bin"
gh api -H 'Accept: application/vnd.github.raw' \
  '/repos/zyk1172/cloudflare-hosts-sync/contents/mac-sync-hosts.sh?ref=main' \
  > "$HOME/bin/cloudflare-hosts-sync"
chmod +x "$HOME/bin/cloudflare-hosts-sync"
"$HOME/bin/cloudflare-hosts-sync" --dry-run
"$HOME/bin/cloudflare-hosts-sync"
```

脚本需要 sudo 才能更新 `/etc/hosts`。它会在真正修改前创建：

```text
/etc/hosts.cloudflare-yx-sync-YYYYMMDD-HHMMSS
```

脚本只维护：

```text
# CF-YX-MAC-SYNC-BEGIN
...
# CF-YX-MAC-SYNC-END
```

本机其他 Hosts 内容、OpenSurge 配置和代理规则不会被修改。

首次升级时，脚本还会只删除以下已知旧入口区域（必须成对存在）：

```text
# BEGIN PT-CLOUDFLARE-MANAGED
...
# END PT-CLOUDFLARE-MANAGED
```

如果旧 Marker 不完整，脚本会停止，不会修改 Hosts。

日后手工同步：

```sh
"$HOME/bin/cloudflare-hosts-sync"
```

只查看状态：

```sh
"$HOME/bin/cloudflare-hosts-sync" --status
```

默认 `CLOUDFLARE_HOSTS_FETCH_MODE=auto`：先直接尝试 `raw.githubusercontent.com`；公开仓库可以显式使用：

```sh
CLOUDFLARE_HOSTS_FETCH_MODE=raw "$HOME/bin/cloudflare-hosts-sync"
```

当前仓库已经公开，Mac 定时执行时使用匿名 raw，不需要 GitHub CLI 凭据。

验证参数可以通过环境变量调整：

```sh
CLOUDFLARE_HOSTS_VERIFY_BEFORE_APPLY=true
CLOUDFLARE_HOSTS_VERIFY_RETRIES=1
CLOUDFLARE_HOSTS_VERIFY_CONNECT_TIMEOUT=4
CLOUDFLARE_HOSTS_VERIFY_MAX_TIME=8
CLOUDFLARE_HOSTS_REJECT_HTTP_CODES=000,403
```

验证失败的单个域名不会进入新的 Mac Marker；其它通过验证的域名仍会独立更新。

## 可选的 macOS 定时执行

可以把下面的命令交给 macOS 的 launchd 每 15 分钟执行一次：

```sh
/absolute/path/to/cloudflare-hosts-sync/mac-sync-hosts.sh >> "$HOME/Library/Logs/cloudflare-hosts-sync.log" 2>&1
```

不建议用 cron 保存 GitHub 凭据；使用 `gh auth` 和 macOS Keychain 管理认证。

## 数据格式

`hosts-map.tsv` 的列为：

```text
domain  ip  group  delay_ms  speed_mb_s  loss_percent  colo  verified_at  http_code  status
```

只有 `status=VERIFIED` 或 `status=RETAINED` 且通过 Mac 本地 HTTPS 检测的精确 FQDN 才会被应用。`RETAINED` 表示 NAS 本轮没有可靠的新候选，继续沿用上一次已应用映射。通配符、协议、路径、端口、空格和重复域名都会被拒绝。
