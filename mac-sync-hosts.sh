#!/bin/sh
# Cloudflare Hosts Sync for macOS
#
# 从 GitHub 拉取 QNAP 的 hosts-map.tsv，校验精确 FQDN/IP，
# 清理已知旧脚本 Marker，并在写入前逐域名做真实 HTTPS 检测。
# 不测速，不修改 OpenSurge，也不覆盖其他 Hosts 内容。

set -eu
LC_ALL=C
export LC_ALL
umask 022

REPOSITORY=${CLOUDFLARE_HOSTS_REPO:-zyk1172/cloudflare-hosts-sync}
BRANCH=${CLOUDFLARE_HOSTS_BRANCH:-main}
FETCH_MODE=${CLOUDFLARE_HOSTS_FETCH_MODE:-auto}
RAW_BASE_URL=${CLOUDFLARE_HOSTS_RAW_BASE_URL:-https://raw.githubusercontent.com/$REPOSITORY/$BRANCH}
HOSTS_FILE=${CLOUDFLARE_HOSTS_FILE:-/etc/hosts}
BEGIN_MARKER=${CLOUDFLARE_HOSTS_BEGIN_MARKER:-'# CF-YX-MAC-SYNC-BEGIN'}
END_MARKER=${CLOUDFLARE_HOSTS_END_MARKER:-'# CF-YX-MAC-SYNC-END'}
LEGACY_BEGIN_MARKER=${CLOUDFLARE_HOSTS_LEGACY_BEGIN_MARKER:-'# BEGIN PT-CLOUDFLARE-MANAGED'}
LEGACY_END_MARKER=${CLOUDFLARE_HOSTS_LEGACY_END_MARKER:-'# END PT-CLOUDFLARE-MANAGED'}
VERIFY_BEFORE_APPLY=${CLOUDFLARE_HOSTS_VERIFY_BEFORE_APPLY:-true}
VERIFY_RETRIES=${CLOUDFLARE_HOSTS_VERIFY_RETRIES:-1}
VERIFY_CONNECT_TIMEOUT=${CLOUDFLARE_HOSTS_VERIFY_CONNECT_TIMEOUT:-4}
VERIFY_MAX_TIME=${CLOUDFLARE_HOSTS_VERIFY_MAX_TIME:-8}
REJECT_HTTP_CODES=${CLOUDFLARE_HOSTS_REJECT_HTTP_CODES:-000,403}

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
  CLOUDFLARE_HOSTS_FETCH_MODE   auto、api 或 raw，默认 auto
  CLOUDFLARE_HOSTS_RAW_BASE_URL 公开仓库时可覆盖 raw 基地址
  CLOUDFLARE_HOSTS_FILE
  CLOUDFLARE_HOSTS_VERIFY_BEFORE_APPLY  true/false，默认 true
  CLOUDFLARE_HOSTS_VERIFY_RETRIES       默认 1
  CLOUDFLARE_HOSTS_VERIFY_CONNECT_TIMEOUT 默认 4 秒
  CLOUDFLARE_HOSTS_VERIFY_MAX_TIME      默认 8 秒
  CLOUDFLARE_HOSTS_REJECT_HTTP_CODES    默认 000,403
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

run_privileged() {
    if [ "$RUN_AS_ROOT" -eq 1 ]; then
        as_root "$@"
    else
        "$@"
    fi
}

require_command awk
require_command cmp
require_command date
require_command mktemp
require_command sort
require_command stat

if [ ! -r "$HOSTS_FILE" ]; then
    die "Hosts file is not readable: $HOSTS_FILE"
fi

HOSTS_DIR=${HOSTS_FILE%/*}
[ "$HOSTS_DIR" = "$HOSTS_FILE" ] && HOSTS_DIR=.
RUN_AS_ROOT=0
if [ "$(id -u)" -ne 0 ] && { [ ! -w "$HOSTS_FILE" ] || [ ! -w "$HOSTS_DIR" ]; }; then
    RUN_AS_ROOT=1
fi

case "$FETCH_MODE" in
    auto|api|raw) ;;
    *) die "CLOUDFLARE_HOSTS_FETCH_MODE must be auto, api or raw" ;;
esac

case "$VERIFY_BEFORE_APPLY" in
    true|false) ;;
    *) die 'CLOUDFLARE_HOSTS_VERIFY_BEFORE_APPLY must be true or false' ;;
esac
case "$VERIFY_RETRIES" in
    ''|*[!0-9]*) die 'CLOUDFLARE_HOSTS_VERIFY_RETRIES must be a positive integer' ;;
esac
[ "$VERIFY_RETRIES" -ge 1 ] || die 'CLOUDFLARE_HOSTS_VERIFY_RETRIES must be at least 1'
case "$VERIFY_CONNECT_TIMEOUT" in
    ''|*[!0-9]*) die 'CLOUDFLARE_HOSTS_VERIFY_CONNECT_TIMEOUT must be an integer' ;;
esac
case "$VERIFY_MAX_TIME" in
    ''|*[!0-9]*) die 'CLOUDFLARE_HOSTS_VERIFY_MAX_TIME must be an integer' ;;
esac

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cloudflare-hosts-sync.XXXXXX") || die 'cannot create temporary directory'
cleanup() {
    rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

BLOCK_FILE="$TMP_DIR/hosts.block"
MAP_RECORDS_FILE="$TMP_DIR/map.records"
SORTED_RECORDS_FILE="$TMP_DIR/map.records.sorted"
VERIFY_LOG="$TMP_DIR/verify.log"
EXPECTED_FILE="$TMP_DIR/hosts.expected"
MAP_FILE="$TMP_DIR/hosts-map.tsv"
STATUS_FILE="$TMP_DIR/status.json"

fetch_repo_file() {
    fetch_path=$1
    fetch_output=$2
    case "$FETCH_MODE" in
        raw)
            require_command curl
            curl -fsSL --retry 2 "$RAW_BASE_URL/$fetch_path" > "$fetch_output"
            ;;
        api)
            require_command gh
            gh api -H 'Accept: application/vnd.github.raw' "/repos/$REPOSITORY/contents/$fetch_path?ref=$BRANCH" > "$fetch_output"
            ;;
        auto)
            if command -v curl >/dev/null 2>&1 && curl -fsSL --retry 2 "$RAW_BASE_URL/$fetch_path" > "$fetch_output" 2>/dev/null; then
                return 0
            fi
            if command -v gh >/dev/null 2>&1; then
                gh api -H 'Accept: application/vnd.github.raw' "/repos/$REPOSITORY/contents/$fetch_path?ref=$BRANCH" > "$fetch_output"
            else
                require_command curl
                curl -fsSL --retry 2 "$RAW_BASE_URL/$fetch_path" > "$fetch_output"
            fi
            ;;
    esac
}

if ! fetch_repo_file hosts-map.tsv "$MAP_FILE"; then
    die "cannot fetch hosts-map.tsv; private repositories require gh auth login, while anonymous raw mode requires a public repository"
fi
fetch_repo_file status.json "$STATUS_FILE" 2>/dev/null || true

REMOTE_EXPLICIT_EMPTY=0
if [ -s "$STATUS_FILE" ] &&
   grep -Eq '"schema"[[:space:]]*:[[:space:]]*[2-9][0-9]*' "$STATUS_FILE" &&
   grep -Eq '"domain_count"[[:space:]]*:[[:space:]]*0([,[:space:]]|$)' "$STATUS_FILE"; then
    REMOTE_EXPLICIT_EMPTY=1
fi

# latency / bandwidth 接受 VERIFIED 或 RETAINED；normal 接受 SELECTED。
# normal 表示由 CFST 直接按延迟选中，按策略定义不做本机 HTTPS 二次验证。
# 域名必须是精确 FQDN，禁止协议、路径、端口、通配符和空格；同一域名只取第一条。
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
        if (NF < 10 || !valid_domain($1) || !valid_ip($2) ||
            ($3 != "latency" && $3 != "bandwidth" && $3 != "normal") ||
            (($3 == "normal" && $10 != "SELECTED") ||
             ($3 != "normal" && $10 != "VERIFIED" && $10 != "RETAINED"))) {
            invalid=1
            next
        }
        if (!seen[$1]++) print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8 "\t" $9 "\t" $10
    }
    END { if (invalid) exit 2 }
' "$MAP_FILE" > "$MAP_RECORDS_FILE"; then
    die "hosts-map.tsv contains an invalid or unsupported record"
fi

LC_ALL=C sort -k1,1 "$MAP_RECORDS_FILE" > "$SORTED_RECORDS_FILE" || die 'cannot sort mappings'

http_code_is_rejected() {
    code=$1
    case ",$REJECT_HTTP_CODES," in
        *,"$code",*) return 0 ;;
        *) return 1 ;;
    esac
}

: > "$BLOCK_FILE"
: > "$VERIFY_LOG"
verified_count=0
rejected_count=0
normal_count=0

if [ "$MODE" = status ] || [ "$VERIFY_BEFORE_APPLY" = false ]; then
    awk -F '\t' '{ print $2 "\t" $1 }' "$SORTED_RECORDS_FILE" > "$BLOCK_FILE"
else
    if awk -F '\t' '$3 != "normal" { found=1 } END { exit(found ? 0 : 1) }' "$SORTED_RECORDS_FILE"; then
        require_command curl
    fi
    while IFS="$(printf '\t')" read -r domain ip group delay speed loss colo verified_at source_http_code status; do
        [ -n "$domain" ] || continue
        if [ "$group" = normal ]; then
            printf 'SKIP %s %s NORMAL selected_by_cfst\n' "$domain" "$ip" >> "$VERIFY_LOG"
            printf '%s\t%s\n' "$ip" "$domain" >> "$BLOCK_FILE"
            normal_count=$((normal_count + 1))
            continue
        fi
        attempt=1
        last_http_code=000
        last_reason=connection_or_tls_failure
        verified=0
        while [ "$attempt" -le "$VERIFY_RETRIES" ]; do
            curl_stderr="$TMP_DIR/curl.stderr"
            resolve_ip=$ip
            case "$resolve_ip" in
                *:*) resolve_ip="[$resolve_ip]" ;;
            esac
            last_http_code=$(curl --noproxy '*' -sS \
                --connect-timeout "$VERIFY_CONNECT_TIMEOUT" \
                --max-time "$VERIFY_MAX_TIME" \
                --resolve "$domain:443:$resolve_ip" \
                -o /dev/null -w '%{http_code}' \
                "https://$domain/" 2>"$curl_stderr" || true)
            [ -n "$last_http_code" ] || last_http_code=000
            if [ "$last_http_code" != 000 ] && ! http_code_is_rejected "$last_http_code"; then
                verified=1
                last_reason=http_response
                break
            fi
            if [ "$last_http_code" = 000 ]; then
                last_reason=$(tr '\n' ' ' < "$curl_stderr" | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c 1-180)
                [ -n "$last_reason" ] || last_reason=connection_or_tls_failure
            else
                last_reason=rejected_http_code
            fi
            if [ "$attempt" -lt "$VERIFY_RETRIES" ]; then
                sleep 1
            fi
            attempt=$((attempt + 1))
        done

        if [ "$verified" -eq 1 ]; then
            printf 'VERIFY %s %s HTTP=%s OK\n' "$domain" "$ip" "$last_http_code" >> "$VERIFY_LOG"
            printf '%s\t%s\n' "$ip" "$domain" >> "$BLOCK_FILE"
            verified_count=$((verified_count + 1))
        else
            printf 'VERIFY %s %s HTTP=%s FAIL %s\n' "$domain" "$ip" "$last_http_code" "$last_reason" >> "$VERIFY_LOG"
            rejected_count=$((rejected_count + 1))
        fi
    done < "$SORTED_RECORDS_FILE"
fi

LC_ALL=C sort -k2,2 "$BLOCK_FILE" -o "$BLOCK_FILE" || die 'cannot sort verified mappings'

if [ ! -s "$BLOCK_FILE" ] && [ "$REMOTE_EXPLICIT_EMPTY" -ne 1 ]; then
    die 'hosts-map.tsv has no verified mappings and status.json does not declare an explicit empty schema-2 map'
fi

# 用 awk 重建期望文件；新 Marker 外所有非旧内容原样保留。
# 已知旧脚本 PT-CLOUDFLARE-MANAGED 区域只在完整成对出现时移除；如果旧
# Marker 损坏或不成对，停止而不修改 Hosts。
if ! awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" \
    -v lb="$LEGACY_BEGIN_MARKER" -v le="$LEGACY_END_MARKER" \
    -v block="$BLOCK_FILE" '
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
    $0 == lb {
        if (legacy_inside || legacy_seen_begin) exit 14
        legacy_inside=1
        legacy_seen_begin=1
        next
    }
    $0 == le {
        if (!legacy_inside || legacy_seen_end) exit 15
        legacy_inside=0
        legacy_seen_end=1
        next
    }
    legacy_inside { next }
    inside { next }
    { print }
    END {
        if (inside) exit 12
        if (legacy_inside) exit 16
        if (!seen_begin) {
            print b
            print_block()
            print e
        } else if (!seen_end) exit 13
    }
' "$HOSTS_FILE" > "$EXPECTED_FILE"; then
    die "existing /etc/hosts contains a malformed or duplicate Mac sync Marker"
fi

printf 'GitHub source: %s\n' "$RAW_BASE_URL/hosts-map.tsv"
printf 'Accepted mappings: %s\n' "$(wc -l < "$BLOCK_FILE" | tr -d ' ')"
if [ "$REMOTE_EXPLICIT_EMPTY" -eq 1 ]; then
    printf 'Remote map state: explicit empty mapping set (schema >= 2)\n'
fi
printf 'Local Hosts Marker: %s\n' "$(grep -F -c "$BEGIN_MARKER" "$HOSTS_FILE" || true)"
printf 'Legacy PT Marker: %s\n' "$(grep -F -c "$LEGACY_BEGIN_MARKER" "$HOSTS_FILE" || true)"
if [ "$MODE" != status ] && [ "$VERIFY_BEFORE_APPLY" = true ]; then
    printf 'HTTPS verification: passed=%s rejected=%s normal_skipped=%s reject_http_codes=%s\n' "$verified_count" "$rejected_count" "$normal_count" "$REJECT_HTTP_CODES"
    if [ "$MODE" = dry-run ] || [ "$rejected_count" -gt 0 ]; then
        cat "$VERIFY_LOG"
    fi
fi

if [ "$MODE" = status ]; then
    if cmp -s "$HOSTS_FILE" "$EXPECTED_FILE"; then
        printf 'Hosts status: consistent\n'
    else
        printf 'Hosts status: drifted\n'
    fi
    cat "$STATUS_FILE" 2>/dev/null || true
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

if [ "$RUN_AS_ROOT" -eq 1 ]; then
    sudo -v || die 'sudo authorization failed'
fi

BACKUP_PATH="$HOSTS_FILE.cloudflare-yx-sync.$(date '+%Y%m%d-%H%M%S')"
run_privileged cp -p "$HOSTS_FILE" "$BACKUP_PATH" || die "cannot back up $HOSTS_FILE to $BACKUP_PATH"

HOST_MODE=$(stat -f '%Lp' "$HOSTS_FILE") || die 'cannot read Hosts mode'
HOST_OWNER=$(stat -f '%Su' "$HOSTS_FILE") || die 'cannot read Hosts owner'
HOST_GROUP=$(stat -f '%Sg' "$HOSTS_FILE") || die 'cannot read Hosts group'
run_privileged install -m "$HOST_MODE" -o "$HOST_OWNER" -g "$HOST_GROUP" "$EXPECTED_FILE" "$HOSTS_FILE" || {
    printf 'ERROR: Hosts update failed; backup remains at %s\n' "$BACKUP_PATH" >&2
    exit 1
}

printf 'Hosts updated from GitHub. Backup: %s\n' "$BACKUP_PATH"
