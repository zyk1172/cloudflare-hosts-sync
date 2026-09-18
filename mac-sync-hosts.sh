#!/bin/sh
# Cloudflare Hosts Sync for macOS
#
# 从私有 GitHub 仓库拉取 QNAP 已验证的 hosts-map.tsv，校验精确 FQDN/IP，
# 然后只维护本机 /etc/hosts 的 CF-YX-MAC-SYNC Marker 区域。
# 不扫描 DNS，不测速，不修改 OpenSurge，也不覆盖其他 Hosts 内容。

set -eu
LC_ALL=C
export LC_ALL
umask 022

REPOSITORY=${CLOUDFLARE_HOSTS_REPO:-zyk1172/cloudflare-hosts-sync}
BRANCH=${CLOUDFLARE_HOSTS_BRANCH:-main}
SYNC_DIR=${CLOUDFLARE_HOSTS_DIR:-"$HOME/Library/Application Support/cloudflare-hosts-sync"}
HOSTS_FILE=${CLOUDFLARE_HOSTS_FILE:-/etc/hosts}
BEGIN_MARKER=${CLOUDFLARE_HOSTS_BEGIN_MARKER:-'# CF-YX-MAC-SYNC-BEGIN'}
END_MARKER=${CLOUDFLARE_HOSTS_END_MARKER:-'# CF-YX-MAC-SYNC-END'}

MODE=apply
case "${1:-}" in
    '') ;;
    --dry-run) MODE=dry-run ;;
    --status) MODE=status ;;
    --help|-h)
        cat <<'EOF'
Cloudflare Hosts Sync for macOS

用法:
  mac-sync-hosts.sh              拉取仓库并更新本机 /etc/hosts
  mac-sync-hosts.sh --dry-run   拉取并显示将要写入的内容，不修改 Hosts
  mac-sync-hosts.sh --status    显示仓库和本机 Marker 状态，不修改 Hosts

可选环境变量:
  CLOUDFLARE_HOSTS_REPO
  CLOUDFLARE_HOSTS_BRANCH
  CLOUDFLARE_HOSTS_DIR
  CLOUDFLARE_HOSTS_FILE
EOF
        exit 0
        ;;
    *)
        printf 'ERROR: unknown argument: %s\n' "$1" >&2
        exit 2
        ;;
esac

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

require_command awk
require_command cmp
require_command date
require_command git
require_command mktemp
require_command sort
require_command stat

if [ ! -r "$HOSTS_FILE" ]; then
    die "Hosts file is not readable: $HOSTS_FILE"
fi

mkdir -p "$(dirname "$SYNC_DIR")"

if [ ! -d "$SYNC_DIR/.git" ]; then
    if [ -e "$SYNC_DIR" ]; then
        die "sync directory exists but is not a Git checkout: $SYNC_DIR"
    fi
    if command -v gh >/dev/null 2>&1; then
        gh repo clone "$REPOSITORY" "$SYNC_DIR" >/dev/null || die "cannot clone private repository: $REPOSITORY"
    else
        die "gh is required for the first clone; install GitHub CLI and run gh auth login"
    fi
else
    git -C "$SYNC_DIR" fetch --quiet origin "$BRANCH" || die "cannot fetch GitHub repository"
    git -C "$SYNC_DIR" checkout -q "$BRANCH" || die "cannot checkout branch: $BRANCH"
    git -C "$SYNC_DIR" merge --ff-only "origin/$BRANCH" >/dev/null || die "local sync checkout is not a fast-forward; inspect: $SYNC_DIR"
fi

MAP_FILE="$SYNC_DIR/hosts-map.tsv"
[ -r "$MAP_FILE" ] || die "repository does not contain hosts-map.tsv"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cloudflare-hosts-sync.XXXXXX") || die 'cannot create temporary directory'
cleanup() {
    rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

BLOCK_FILE="$TMP_DIR/hosts.block"
RAW_BLOCK_FILE="$TMP_DIR/hosts.block.raw"
EXPECTED_FILE="$TMP_DIR/hosts.expected"

# 只接受 Hosts Manager 的 VERIFIED 或 RETAINED 记录。RETAINED 表示本轮没有
# 可靠的新候选，所以沿用上一次已应用映射。域名必须是精确 FQDN，禁止协议、
# 路径、端口、通配符和空格；同一域名只取第一条，避免生成冲突 Hosts。
if ! awk -F '\t' '
    function valid_domain(d) {
        return d ~ /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$/
    }
    function valid_ip(v, n, a, i) {
        if (v ~ /^[0-9]+(\.[0-9]+){3}$/) {
            n=split(v,a,".")
            for (i=1; i<=n; i++) if ((a[i]+0) > 255) return 0
            return 1
        }
        return v ~ /^[0-9A-Fa-f:]+$/ && v ~ /:/
    }
    /^[[:space:]]*#/ || NF == 0 { next }
    {
        if (NF < 10 || !valid_domain($1) || !valid_ip($2) || ($3 != "latency" && $3 != "bandwidth") || ($10 != "VERIFIED" && $10 != "RETAINED")) {
            invalid=1
            next
        }
        if (!seen[$1]++) print $2 "\t" $1
    }
    END { if (invalid) exit 2 }
' "$MAP_FILE" > "$RAW_BLOCK_FILE"; then
    die "hosts-map.tsv contains an invalid or unsupported record"
fi

LC_ALL=C sort -k2,2 "$RAW_BLOCK_FILE" > "$BLOCK_FILE" || die 'cannot sort verified mappings'

[ -s "$BLOCK_FILE" ] || die 'hosts-map.tsv has no verified mappings'

# 用 awk 重建期望文件；Marker 外所有内容原样保留。Marker 缺失时追加到末尾。
if ! awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" -v block="$BLOCK_FILE" '
    function print_block( line) {
        while ((getline line < block) > 0) print line
        close(block)
    }
    $0 == b {
        if (inside || seen_begin) exit 10
        print b
        print_block()
        inside=1
        seen_begin=1
        next
    }
    $0 == e {
        if (!inside || seen_end) exit 11
        print e
        inside=0
        seen_end=1
        next
    }
    inside { next }
    { print }
    END {
        if (inside) exit 12
        if (!seen_begin) {
            print b
            print_block()
            print e
        } else if (!seen_end) exit 13
    }
' "$HOSTS_FILE" > "$EXPECTED_FILE"; then
    die "existing /etc/hosts contains a malformed or duplicate Mac sync Marker"
fi

printf 'GitHub repository: %s (%s)\n' "$REPOSITORY" "$BRANCH"
printf 'Accepted mappings: %s\n' "$(wc -l < "$BLOCK_FILE" | tr -d ' ')"
printf 'Local Hosts Marker: %s\n' "$(grep -F -c "$BEGIN_MARKER" "$HOSTS_FILE" || true)"

if [ "$MODE" = status ]; then
    if cmp -s "$HOSTS_FILE" "$EXPECTED_FILE"; then
        printf 'Hosts status: consistent\n'
    else
        printf 'Hosts status: drifted\n'
    fi
    cat "$SYNC_DIR/status.json" 2>/dev/null || true
    exit 0
fi

if [ "$MODE" = dry-run ]; then
    printf '%s\n' '将写入的 Mac Marker 内容：'
    sed -n "/^$BEGIN_MARKER$/,/^$END_MARKER$/p" "$EXPECTED_FILE"
    if cmp -s "$HOSTS_FILE" "$EXPECTED_FILE"; then
        printf '%s\n' '结果：无需修改 /etc/hosts'
    else
        printf '%s\n' '结果：会修改 /etc/hosts（dry-run 未执行）'
    fi
    exit 0
fi

if cmp -s "$HOSTS_FILE" "$EXPECTED_FILE"; then
    printf '%s\n' 'No changes required.'
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    sudo -v || die 'sudo authorization failed'
fi

BACKUP_PATH="$HOSTS_FILE.cloudflare-yx-sync.$(date '+%Y%m%d-%H%M%S')"
as_root cp -p "$HOSTS_FILE" "$BACKUP_PATH" || die "cannot back up $HOSTS_FILE to $BACKUP_PATH"

HOST_MODE=$(stat -f '%Lp' "$HOSTS_FILE") || die 'cannot read Hosts mode'
HOST_OWNER=$(stat -f '%Su' "$HOSTS_FILE") || die 'cannot read Hosts owner'
HOST_GROUP=$(stat -f '%Sg' "$HOSTS_FILE") || die 'cannot read Hosts group'
as_root install -m "$HOST_MODE" -o "$HOST_OWNER" -g "$HOST_GROUP" "$EXPECTED_FILE" "$HOSTS_FILE" || {
    printf 'ERROR: Hosts update failed; backup remains at %s\n' "$BACKUP_PATH" >&2
    exit 1
}

printf 'Hosts updated from GitHub. Backup: %s\n' "$BACKUP_PATH"
