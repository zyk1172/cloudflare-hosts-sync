# Cloudflare Hosts Sync

这个私有仓库是 QNAP Cloudflare Hosts Manager 与 macOS 之间的同步边界。

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
        ├─ git fetch --ff-only
        ├─ 校验精确 FQDN、IP 和 VERIFIED 状态
        └─ 只更新本机 /etc/hosts 的 CF-YX-MAC-SYNC Marker
```

NAS 不会上传 yx-tools 的完整候选池、配置文件、日志、Tracker 凭据或 Token。仓库只保存逐域名的已验证映射和非敏感状态摘要。

macOS 端不会重新测速，也不会扫描 DNS；它只信任仓库中的 `VERIFIED` 映射。仓库应保持 Private。

## macOS 使用

首次准备：

```sh
gh auth login
gh repo clone zyk1172/cloudflare-hosts-sync
cd cloudflare-hosts-sync
chmod +x mac-sync-hosts.sh
./mac-sync-hosts.sh --dry-run
./mac-sync-hosts.sh
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

日后手工同步：

```sh
./mac-sync-hosts.sh
```

只查看状态：

```sh
./mac-sync-hosts.sh --status
```

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

只有 `status=VERIFIED` 或 `status=RETAINED` 的精确 FQDN 才会被 macOS 脚本应用。`RETAINED` 表示 NAS 本轮没有可靠的新候选，继续沿用上一次已应用映射。通配符、协议、路径、端口、空格和重复域名都会被拒绝。
