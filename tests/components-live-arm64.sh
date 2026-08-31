#!/bin/sh

# Optional networked ARM64 test. Run inside an aarch64 container (native or
# binfmt/QEMU). It downloads the real upstream assets, validates their GitHub
# digests and archive layouts through KZM, then checks each real binary opens
# its configured listener. It never connects to a router.

set -eu

PROJECT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LIVE_ROOT=${LIVE_ROOT:-/tmp/kzm-components-live}

# LIVE_ROOT is recursively removed below.  Validate its canonical parent and
# basename separately, then rebuild the path from those trusted components.
# A lexical prefix check alone would accept values such as
# /tmp/kzm-components-live/../../somewhere.
live_parent=$(dirname -- "$LIVE_ROOT")
live_name=$(basename -- "$LIVE_ROOT")
live_parent=$(CDPATH='' cd -- "$live_parent" 2>/dev/null && pwd -P) || {
    echo "Unsafe LIVE_ROOT parent: $LIVE_ROOT" >&2
    exit 1
}
[ "$live_parent" = /tmp ] || {
    echo "LIVE_ROOT parent must resolve exactly to /tmp: $LIVE_ROOT" >&2
    exit 1
}
case "$live_name" in
    kzm-components-live|kzm-components-live.*|kzm-components-live-*) ;;
    *) echo "Unsafe LIVE_ROOT basename: $live_name" >&2; exit 1 ;;
esac
LIVE_ROOT="/tmp/$live_name"

rm -rf "$LIVE_ROOT"
mkdir -m 700 "$LIVE_ROOT" || {
    echo "Cannot create LIVE_ROOT: $LIVE_ROOT" >&2
    exit 1
}

PIDS=""
cleanup() {
    for cleanup_pid in $PIDS; do
        kill "$cleanup_pid" 2>/dev/null || true
        wait "$cleanup_pid" 2>/dev/null || true
    done
    case "$LIVE_ROOT" in /tmp/kzm-components-live*) rm -rf "$LIVE_ROOT" ;; esac
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

case "$(uname -m)" in aarch64|arm64) ;; *) echo "ARM64 runtime required" >&2; exit 1 ;; esac
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }
command -v netstat >/dev/null 2>&1 || { echo "netstat is required" >&2; exit 1; }

sh "$PROJECT_DIR/install.sh" --root "$LIVE_ROOT" >/dev/null
export KZM_ROOT="$LIVE_ROOT"
MANAGER="$LIVE_ROOT/opt/libexec/kzm/component-manager.sh"

# A Docker test container has no Keenetic br0/br-lan.  Pre-create configs with
# the container's real private address so release validation stays realistic
# without weakening the production LAN-interface guard.
live_host=$(hostname -i 2>/dev/null | awk '
    {
        for (i = 1; i <= NF; i++) {
            split($i, octet, ".")
            if (length(octet) != 4) continue
            if (octet[1] == 10 || (octet[1] == 192 && octet[2] == 168) ||
                    (octet[1] == 172 && octet[2] >= 16 && octet[2] <= 31)) {
                print $i
                exit
            }
        }
    }
')
[ -n "$live_host" ] || { echo "Container private IPv4 was not found" >&2; exit 1; }
component_config_dir="$LIVE_ROOT/opt/etc/kzapret-manager/components"
mkdir -p "$component_config_dir"
printf 'HOST=%s\nPORT=1080\nUSERNAME=telegram\nPASSWORD=0123456789abcdef0123456789abcdef\n' "$live_host" \
    > "$component_config_dir/socks5.conf"
printf 'HOST=%s\nPORT=2443\nSECRET=0123456789abcdef0123456789abcdef\nPOOL_SIZE=2\nMAX_CONNECTIONS=32\n' "$live_host" \
    > "$component_config_dir/rust.conf"
printf 'HOST=%s\nPORT=1443\nSECRET=0123456789abcdef0123456789abcdef\nDC_IP_DEFAULT=149.154.167.220\n' "$live_host" \
    > "$component_config_dir/mtproto.conf"
chmod 600 "$component_config_dir"/*.conf

# update on an empty isolated root performs all install-time validation but,
# unlike install, does not start the service. Direct starts below are used
# because /proc/PID/exe points at QEMU under Docker Desktop emulation.
for component in socks5 rust mtproto; do
    "$MANAGER" update "$component" --yes
done

config_value() {
    awk -F= -v key="$1" '$1 == key { print substr($0, length($1) + 2); exit }' "$2"
}

wait_listener() {
    listener_port=$1
    listener_pid=$2
    listener_limit=${3:-10}
    listener_wait=0
    while [ "$listener_wait" -lt "$listener_limit" ]; do
        kill -0 "$listener_pid" 2>/dev/null || return 1
        if netstat -ltn 2>/dev/null | awk -v port="$listener_port" '
            $1 ~ /^tcp/ && $NF == "LISTEN" {
                address=$4
                sub(/^.*:/, "", address)
                if (address == port) found=1
            }
            END { exit(found ? 0 : 1) }
        '; then
            return 0
        fi
        sleep 1
        listener_wait=$((listener_wait + 1))
    done
    return 1
}

stop_checked() {
    checked_pid=$1
    kill -TERM "$checked_pid" 2>/dev/null || true
    wait "$checked_pid" 2>/dev/null || true
    PIDS=$(printf '%s\n' "$PIDS" | awk -v pid="$checked_pid" '$0 != pid { print }')
}

socks_config="$LIVE_ROOT/opt/etc/kzapret-manager/components/socks5.conf"
socks_host=$(config_value HOST "$socks_config")
socks_port=$(config_value PORT "$socks_config")
socks_user=$(config_value USERNAME "$socks_config")
socks_password=$(config_value PASSWORD "$socks_config")
"$LIVE_ROOT/opt/usr/bin/kzm-tg-socks5" \
    --mode socks5 --host "$socks_host" --port "$socks_port" \
    --username "$socks_user" --password "$socks_password" \
    </dev/null >/dev/null 2>&1 &
socks_pid=$!
PIDS="$PIDS $socks_pid"
wait_listener "$socks_port" "$socks_pid" || { echo "SOCKS5 listener failed" >&2; exit 1; }
stop_checked "$socks_pid"

rust_config="$LIVE_ROOT/opt/etc/kzapret-manager/components/rust.conf"
rust_host=$(config_value HOST "$rust_config")
rust_port=$(config_value PORT "$rust_config")
rust_secret=$(config_value SECRET "$rust_config")
rust_pool=$(config_value POOL_SIZE "$rust_config")
rust_max=$(config_value MAX_CONNECTIONS "$rust_config")
TG_HOST="$rust_host" TG_LINK_IP="$rust_host" TG_PORT="$rust_port" \
TG_SECRET="$rust_secret" TG_POOL_SIZE="$rust_pool" TG_MAX_CONNECTIONS="$rust_max" \
TG_NO_OUTBOUND_PROXY=true TG_DEFAULT_DOMAINS=false \
TG_CF_DOMAIN=stopblocking.co.uk,kartoshka.co.uk,nebally.co.uk,pyatdesyatdva.co.uk,noskomnadzor.co.uk,sorokdva.co.uk,pyatdesyatodin.co.uk \
TG_CF_PRIORITY=true TG_CF_BALANCE=true TG_WS_CONNECT_TIMEOUT=3 TG_SKIP_TLS_VERIFY=false \
TG_QUIET=true RUST_LOG=warn \
    "$LIVE_ROOT/opt/usr/bin/kzm-tg-rust" \
        --dc-ip 2:149.154.167.220 --dc-ip 4:149.154.167.220 \
        </dev/null >/dev/null 2>&1 &
rust_pid=$!
PIDS="$PIDS $rust_pid"
wait_listener "$rust_port" "$rust_pid" 45 || { echo "Rust listener failed" >&2; exit 1; }
stop_checked "$rust_pid"

mtproto_config="$LIVE_ROOT/opt/etc/kzapret-manager/components/mtproto.conf"
mtproto_host=$(config_value HOST "$mtproto_config")
mtproto_port=$(config_value PORT "$mtproto_config")
mtproto_secret=$(config_value SECRET "$mtproto_config")
mtproto_dc=$(config_value DC_IP_DEFAULT "$mtproto_config")
"$LIVE_ROOT/opt/usr/bin/kzm-tg-mtproto" \
    --host "$mtproto_host" --port "$mtproto_port" --secret "$mtproto_secret" \
    --dc-ip-default "$mtproto_dc" </dev/null >/dev/null 2>&1 &
mtproto_pid=$!
PIDS="$PIDS $mtproto_pid"
wait_listener "$mtproto_port" "$mtproto_pid" || { echo "MTProto listener failed" >&2; exit 1; }
stop_checked "$mtproto_pid"

echo "Live ARM64 components passed: socks5, rust, mtproto"
