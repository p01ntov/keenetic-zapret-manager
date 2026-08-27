#!/bin/sh

# Offline integration tests for the optional component manager.
#
# The test never talks to GitHub or a router.  Every curl request is routed to
# a strict local mock and every installed file lives below a fresh KZM_ROOT.

set -eu

PROJECT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=${TEST_ROOT:-}
KEEP_TEST_ROOT=${KEEP_TEST_ROOT:-0}
EXTRA_TEST_ROOTS=""

if [ -z "$TEST_ROOT" ]; then
    TEST_ROOT=$(mktemp -d /tmp/kzm-components-test.XXXXXX)
else
    test_parent=$(dirname -- "$TEST_ROOT")
    test_name=$(basename -- "$TEST_ROOT")
    test_parent=$(CDPATH='' cd -- "$test_parent" 2>/dev/null && pwd -P) || {
        echo "Unsafe TEST_ROOT parent: $TEST_ROOT" >&2
        exit 1
    }
    [ "$test_parent" = /tmp ] || {
        echo "TEST_ROOT parent must resolve exactly to /tmp: $TEST_ROOT" >&2
        exit 1
    }
    case "$test_name" in
        kzm-components-test.*) ;;
        *) echo "Unsafe TEST_ROOT basename: $test_name" >&2; exit 1 ;;
    esac
    TEST_ROOT="/tmp/$test_name"
    if [ -e "$TEST_ROOT" ] || [ -L "$TEST_ROOT" ]; then
        echo "TEST_ROOT already exists: $TEST_ROOT" >&2
        exit 1
    fi
    mkdir -p "$TEST_ROOT"
fi

cleanup() {
    if [ -f "$TEST_ROOT/test-owned-pids" ]; then
        while IFS= read -r test_pid; do
            case "$test_pid" in
                ''|*[!0-9]*|0|1) continue ;;
            esac
            kill "$test_pid" 2>/dev/null || true
        done < "$TEST_ROOT/test-owned-pids"
    fi
    if [ "$KEEP_TEST_ROOT" = 1 ]; then
        echo "Component test root kept at $TEST_ROOT" >&2
        return
    fi
    for extra_test_root in $EXTRA_TEST_ROOTS; do
        case "$extra_test_root" in
            /tmp/kzm-components-test.*) rm -rf "$extra_test_root" ;;
            *) echo "Refusing to clean unsafe extra TEST_ROOT: $extra_test_root" >&2 ;;
        esac
    done
    case "$TEST_ROOT" in
        /tmp/kzm-components-test.*) rm -rf "$TEST_ROOT" ;;
        *) echo "Refusing to clean unsafe TEST_ROOT: $TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    echo "components.sh: $*" >&2
    exit 1
}

assert_file() {
    [ -f "$1" ] || fail "expected file: $1"
}

assert_absent() {
    [ ! -e "$1" ] || fail "unexpected path: $1"
}

assert_contains() {
    grep -Eq -- "$2" "$1" || fail "$1 does not contain: $2"
}

assert_mode_600() {
    if [ "${MODE_CHECK_SUPPORTED:-1}" != 1 ]; then
        return 0
    fi
    mode=$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true)
    [ "$mode" = 600 ] || fail "$1 mode is ${mode:-unknown}, expected 600"
}

sha256_file() {
    sha256sum "$1" | awk '{ print $1 }'
}

wait_for_pid_exit() {
    waited=0
    while kill -0 "$1" 2>/dev/null; do
        [ "$waited" -lt 50 ] || return 1
        sleep 0.1
        waited=$((waited + 1))
    done
}

FIXTURES="$TEST_ROOT/fixtures"
MOCK_BIN="$TEST_ROOT/mock-bin"
MOCK_LOG="$TEST_ROOT/mock-curl.log"
LAUNCH_LOG="$TEST_ROOT/mock-launch.log"
mkdir -p "$FIXTURES" "$MOCK_BIN" "$TEST_ROOT/opt/etc/init.d" \
    "$TEST_ROOT/opt/etc/nfqws" "$TEST_ROOT/opt/usr/bin" "$TEST_ROOT/tmp"

mode_probe="$TEST_ROOT/mode-probe"
: > "$mode_probe"
chmod 600 "$mode_probe" 2>/dev/null || true
probe_mode=$(stat -c '%a' "$mode_probe" 2>/dev/null || stat -f '%Lp' "$mode_probe" 2>/dev/null || true)
if [ "$probe_mode" = 600 ]; then MODE_CHECK_SUPPORTED=1; else MODE_CHECK_SUPPORTED=0; fi
rm -f "$mode_probe"

# Any accidental contact with the working nfqws service makes the test fail.
cat > "$TEST_ROOT/opt/etc/init.d/S51nfqws" <<'EOF'
#!/bin/sh
case "${1:-}" in
    status) echo 'Service NFQWS is running'; exit 0 ;;
    start|stop|restart)
        echo "nfqws service mutated: $*" >> "${KZM_ROOT:?}/nfqws-restart.log"
        exit 97
        ;;
    *) exit 1 ;;
esac
EOF
chmod 755 "$TEST_ROOT/opt/etc/init.d/S51nfqws"

cat > "$MOCK_BIN/opkg" <<'EOF'
#!/bin/sh
echo "opkg called: $*" >> "${KZM_ROOT:?}/opkg.log"
case "$1" in
    print-architecture)
        printf 'arch all 1\narch aarch64-3.10 10\narch aarch64-3.10_kn 20\n'
        exit 0
        ;;
    status)
        [ "${2:-}" = nfqws-keenetic ] || exit 1
        printf 'Package: nfqws-keenetic\nVersion: 2.11.4\nStatus: install user installed\n'
        exit 0
        ;;
    list-installed)
        printf 'nfqws-keenetic - 2.11.4\n'
        exit 0
        ;;
esac
exit 96
EOF
chmod 755 "$MOCK_BIN/opkg"

cat > "$MOCK_BIN/uname" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -m ]; then
    echo aarch64
else
    exec /usr/bin/uname "$@"
fi
EOF
chmod 755 "$MOCK_BIN/uname"

cat > "$MOCK_BIN/pidof" <<'EOF'
#!/bin/sh
[ "${1:-}" = nfqws ] || exit 1
printf '4321\n'
EOF
chmod 755 "$MOCK_BIN/pidof"

cat > "$MOCK_BIN/pgrep" <<'EOF'
#!/bin/sh
# Simulate a Keenetic pgrep implementation that rejects the `-x` form.
exit 2
EOF
chmod 755 "$MOCK_BIN/pgrep"

# Force the hexadecimal reader to reject malformed hexdump output, then fall
# back to the small BusyBox-compatible `od -b` interface. The wrapper rejects
# the GNU-only flags that caused component installation to fail on Keenetic.
cat > "$MOCK_BIN/hexdump" <<'EOF'
#!/bin/sh
printf 'broken*\nvalue\n'
EOF
chmod 755 "$MOCK_BIN/hexdump"

KZM_TEST_REAL_OD=$(command -v od) || fail "od is required for fixtures"
cat > "$MOCK_BIN/od" <<'EOF'
#!/bin/sh
[ "${1:-}" = -b ] || {
    echo "mock BusyBox od: unsupported option ${1:-}" >&2
    exit 2
}
shift
exec "${KZM_TEST_REAL_OD:?}" -b "$@"
EOF
chmod 755 "$MOCK_BIN/od"

cat > "$MOCK_BIN/ip" <<'EOF'
#!/bin/sh
if [ "$*" = '-o -4 addr show dev br0 scope global' ]; then
    printf '2: br0    inet 192.168.77.1/24 brd 192.168.77.255 scope global br0\n'
    exit 0
fi
if [ "$*" = '-o -4 addr show scope global' ]; then
    printf '2: br0    inet 192.168.77.1/24 brd 192.168.77.255 scope global br0\n'
    exit 0
fi
exit 1
EOF
chmod 755 "$MOCK_BIN/ip"

cat > "$MOCK_BIN/netstat" <<'EOF'
#!/bin/sh
[ "${1:-}" = -ltn ] || exit 2
printf 'Proto Recv-Q Send-Q Local Address Foreign Address State\n'
for listener in "${KZM_TEST_LISTEN_DIR:?}"/*; do
    [ -f "$listener" ] || continue
    port=${listener##*/}
    printf 'tcp 0 0 192.168.77.1:%s 0.0.0.0:* LISTEN\n' "$port"
done
EOF
chmod 755 "$MOCK_BIN/netstat"

make_proxy_fixture() {
    output=$1
    marker=$2
    version=$3
    cat > "$output" <<EOF
#!/bin/sh
# $marker
if [ "\${1:-}" = --version ]; then
    echo "tg-ws-proxy $version"
    exit 0
fi

if [ -n "\${KZM_TEST_LAUNCH_LOG:-}" ]; then
    {
        printf 'TG_PORT=%s\n' "\${TG_PORT:-}"
        printf 'TG_DEFAULT_DOMAINS=%s\n' "\${TG_DEFAULT_DOMAINS:-}"
        printf 'TG_NO_OUTBOUND_PROXY=%s\n' "\${TG_NO_OUTBOUND_PROXY:-}"
        printf 'TG_CF_PRIORITY=%s\n' "\${TG_CF_PRIORITY:-}"
        printf 'TG_CF_BALANCE=%s\n' "\${TG_CF_BALANCE:-}"
        for launch_arg in "\$@"; do
            printf 'ARG=%s\n' "\$launch_arg"
        done
    } >> "\$KZM_TEST_LAUNCH_LOG"
fi

proxy_port=\${TG_PORT:-}
while [ "\$#" -gt 0 ]; do
    case "\$1" in
        --port)
            [ "\$#" -ge 2 ] || exit 2
            proxy_port=\$2
            shift 2
            ;;
        *) shift ;;
    esac
done
[ -n "\$proxy_port" ] || exit 2

proxy_proc_dir="\${KZM_PROC_ROOT:?}/\$\$"
proxy_listener="\${KZM_TEST_LISTEN_DIR:?}/\$proxy_port"
mkdir -p "\$proxy_proc_dir"
MSYS=winsymlinks:nativestrict ln -s "\$0" "\$proxy_proc_dir/exe"
listener_delay=\${KZM_TEST_LISTENER_DELAY:-0}
case "\$listener_delay" in
    ''|*[!0-9]*) exit 2 ;;
    0) ;;
    *) sleep "\$listener_delay" ;;
esac
: > "\$proxy_listener"
printf '%s\n' "\$\$" >> "\${KZM_TEST_PID_LOG:?}"
cleanup_proxy_fixture() {
    rm -f "\$proxy_listener" "\$proxy_proc_dir/exe"
    rmdir "\$proxy_proc_dir" 2>/dev/null || true
    if [ "\${KZM_TEST_FORK_ON_TERM:-0}" = 1 ]; then
        KZM_TEST_FORK_ON_TERM=0 TG_PORT="\$proxy_port" \
            nohup "\$0" </dev/null >/dev/null 2>&1 &
        orphan_pid=\$!
        orphan_wait=0
        while [ ! -L "\${KZM_PROC_ROOT:?}/\$orphan_pid/exe" ] && \
                [ "\$orphan_wait" -lt 50 ]; do
            sleep 0.1
            orphan_wait=\$((orphan_wait + 1))
        done
    fi
    exit 0
}
trap cleanup_proxy_fixture TERM INT HUP
while :; do sleep 1; done
EOF
    chmod 755 "$output"
}

make_proxy_fixture "$FIXTURES/socks5-v1" KZM_SOCKS5_V1 1.0.0
make_proxy_fixture "$FIXTURES/socks5-v2" KZM_SOCKS5_V2 2.0.0
make_proxy_fixture "$FIXTURES/rust-v1.bin" KZM_RUST_V1 1.0.0
make_proxy_fixture "$FIXTURES/rust-v2.bin" KZM_RUST_V2 2.0.0
make_proxy_fixture "$FIXTURES/mtproto-v1.bin" KZM_MTPROTO_V1 0.1.0
make_proxy_fixture "$FIXTURES/mtproto-v2.bin" KZM_MTPROTO_V2 0.2.0

mkdir -p "$FIXTURES/rust-v1" "$FIXTURES/rust-v2"
cp "$FIXTURES/rust-v1.bin" "$FIXTURES/rust-v1/tg-ws-proxy"
cp "$FIXTURES/rust-v2.bin" "$FIXTURES/rust-v2/tg-ws-proxy"
tar -czf "$FIXTURES/rust-v1.tar.gz" -C "$FIXTURES/rust-v1" tg-ws-proxy
tar -czf "$FIXTURES/rust-v2.tar.gz" -C "$FIXTURES/rust-v2" tg-ws-proxy

make_ipk_fixture() {
    fixture_id=$1
    package_version=$2
    binary=$3
    package_name=${4:-tg-ws-proxy}
    package_arch=${5:-aarch64-3.10}
    work="$FIXTURES/ipk-$fixture_id"
    mkdir -p "$work/data/opt/bin" "$work/control" "$work/outer"
    cp "$binary" "$work/data/opt/bin/tg-ws-proxy"
    cat > "$work/control/control" <<EOF
Package: $package_name
Version: $package_version
Architecture: $package_arch
EOF
    printf '2.0\n' > "$work/outer/debian-binary"
    tar -czf "$work/outer/control.tar.gz" -C "$work/control" .
    tar -czf "$work/outer/data.tar.gz" -C "$work/data" .
    tar -czf "$FIXTURES/mtproto-$fixture_id.ipk" -C "$work/outer" \
        debian-binary control.tar.gz data.tar.gz
}

make_ipk_fixture v1 0.1.0 "$FIXTURES/mtproto-v1.bin"
make_ipk_fixture v2 0.2.0 "$FIXTURES/mtproto-v2.bin"
make_ipk_fixture bad-package 0.3.1 "$FIXTURES/mtproto-v2.bin" unexpected-package
make_ipk_fixture bad-architecture 0.3.2 "$FIXTURES/mtproto-v2.bin" tg-ws-proxy mipsel-3.4
make_ipk_fixture bad-version 9.9.9 "$FIXTURES/mtproto-v2.bin"

# These hostile archives contain `../../KZM_TRAVERSAL_SENTINEL` members. Keep
# only the unsafe tar payloads as small base64 fixtures so the suite itself
# needs only BusyBox tar; GNU tar --transform is deliberately not required.
command -v base64 >/dev/null 2>&1 || fail "base64 is required for fixtures"
base64 -d "$PROJECT_DIR/tests/fixtures/components-rust-traversal.tar.gz.b64" \
    > "$FIXTURES/rust-traversal.tar.gz" || fail "cannot decode Rust traversal fixture"
traversal_work="$FIXTURES/ipk-traversal"
mkdir -p "$traversal_work/control" "$traversal_work/outer"
cat > "$traversal_work/control/control" <<'EOF'
Package: tg-ws-proxy
Version: 9.9.9
Architecture: aarch64-3.10
EOF
printf '2.0\n' > "$traversal_work/outer/debian-binary"
tar -czf "$traversal_work/outer/control.tar.gz" -C "$traversal_work/control" .
base64 -d "$PROJECT_DIR/tests/fixtures/components-mtproto-data-traversal.tar.gz.b64" \
    > "$traversal_work/outer/data.tar.gz" || fail "cannot decode IPK traversal payload"
tar -czf "$FIXTURES/mtproto-traversal.ipk" -C "$traversal_work/outer" \
    debian-binary control.tar.gz data.tar.gz

cat > "$MOCK_BIN/curl" <<'EOF'
#!/bin/sh
set -eu

output=
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o|--output)
            [ "$#" -ge 2 ] || exit 2
            output=$2
            shift 2
            ;;
        -H|--header|-A|--user-agent|--connect-timeout|--max-time|--max-filesize|--retry|--retry-delay|-w|--write-out)
            [ "$#" -ge 2 ] || exit 2
            shift 2
            ;;
        --*=*|-*) shift ;;
        *) url=$1; shift ;;
    esac
done

[ -n "$url" ] || { echo 'mock curl: URL missing' >&2; exit 2; }
printf '%s\n' "$url" >> "${MOCK_LOG:?}"
case "$url" in
    https://mock.invalid/*) ;;
    *) echo "mock curl blocked non-mock URL: $url" >&2; exit 95 ;;
esac

emit_file() {
    if [ -n "$output" ]; then
        cp "$1" "$output"
    else
        cat "$1"
    fi
}

variant=${MOCK_RELEASE_VARIANT:-v1}
repo=
case "$url" in
    */repos/d0mhate/-tg-ws-proxy-Manager-go/releases/latest) repo=socks5 ;;
    */repos/valnesfjord/tg-ws-proxy-rs/releases/latest) repo=rust ;;
    */repos/spatiumstas/tg-ws-proxy-go/releases/latest) repo=mtproto ;;
esac

if [ -n "$repo" ]; then
    case "$repo:$variant" in
        socks5:v1) tag=v1.0.0; name=tg-ws-proxy-openwrt-aarch64; asset="$FIXTURES/socks5-v1"; asset_url=https://mock.invalid/assets/socks5-v1 ;;
        socks5:v2|socks5:bad-sha) tag=v2.0.0; name=tg-ws-proxy-openwrt-aarch64; asset="$FIXTURES/socks5-v2"; asset_url=https://mock.invalid/assets/socks5-v2 ;;
        rust:v1) tag=v1.0.0; name=tg-ws-proxy-aarch64-unknown-linux-musl.tar.gz; asset="$FIXTURES/rust-v1.tar.gz"; asset_url=https://mock.invalid/assets/rust-v1 ;;
        rust:v2) tag=v2.0.0; name=tg-ws-proxy-aarch64-unknown-linux-musl.tar.gz; asset="$FIXTURES/rust-v2.tar.gz"; asset_url=https://mock.invalid/assets/rust-v2 ;;
        rust:bad-sha) tag=v3.0.0; name=tg-ws-proxy-aarch64-unknown-linux-musl.tar.gz; asset="$FIXTURES/rust-v2.tar.gz"; asset_url=https://mock.invalid/assets/rust-v2 ;;
        rust:traversal) tag=v9.9.9; name=tg-ws-proxy-aarch64-unknown-linux-musl.tar.gz; asset="$FIXTURES/rust-traversal.tar.gz"; asset_url=https://mock.invalid/assets/rust-traversal ;;
        mtproto:v1) tag=0.1.0; name=tg-ws-proxy_0.1.0_entware_aarch64-3.10.ipk; asset="$FIXTURES/mtproto-v1.ipk"; asset_url=https://mock.invalid/assets/mtproto-v1 ;;
        mtproto:v2|mtproto:bad-sha) tag=0.2.0; name=tg-ws-proxy_0.2.0_entware_aarch64-3.10.ipk; asset="$FIXTURES/mtproto-v2.ipk"; asset_url=https://mock.invalid/assets/mtproto-v2 ;;
        mtproto:bad-package) tag=0.3.1; name=tg-ws-proxy_0.3.1_entware_aarch64-3.10.ipk; asset="$FIXTURES/mtproto-bad-package.ipk"; asset_url=https://mock.invalid/assets/mtproto-bad-package ;;
        mtproto:bad-architecture) tag=0.3.2; name=tg-ws-proxy_0.3.2_entware_aarch64-3.10.ipk; asset="$FIXTURES/mtproto-bad-architecture.ipk"; asset_url=https://mock.invalid/assets/mtproto-bad-architecture ;;
        mtproto:bad-version) tag=0.3.3; name=tg-ws-proxy_0.3.3_entware_aarch64-3.10.ipk; asset="$FIXTURES/mtproto-bad-version.ipk"; asset_url=https://mock.invalid/assets/mtproto-bad-version ;;
        mtproto:traversal) tag=9.9.9; name=tg-ws-proxy_9.9.9_entware_aarch64-3.10.ipk; asset="$FIXTURES/mtproto-traversal.ipk"; asset_url=https://mock.invalid/assets/mtproto-traversal ;;
        *) echo "mock curl: unsupported $repo/$variant" >&2; exit 94 ;;
    esac
    digest=$(sha256sum "$asset" | awk '{ print $1 }')
    [ "$variant" != bad-sha ] || digest=0000000000000000000000000000000000000000000000000000000000000000
    response="${TMPDIR:-/tmp}/kzm-mock-release.$$.json"
    cat > "$response" <<JSON
{
  "tag_name": "$tag",
  "assets": [
    {
      "name": "$name",
      "browser_download_url": "$asset_url",
      "digest": "sha256:$digest"
    }
  ]
}
JSON
    emit_file "$response"
    rm -f "$response"
    exit 0
fi

case "$url" in
    https://mock.invalid/assets/socks5-v1) emit_file "$FIXTURES/socks5-v1" ;;
    https://mock.invalid/assets/socks5-v2) emit_file "$FIXTURES/socks5-v2" ;;
    https://mock.invalid/assets/rust-v1) emit_file "$FIXTURES/rust-v1.tar.gz" ;;
    https://mock.invalid/assets/rust-v2) emit_file "$FIXTURES/rust-v2.tar.gz" ;;
    https://mock.invalid/assets/rust-traversal) emit_file "$FIXTURES/rust-traversal.tar.gz" ;;
    https://mock.invalid/assets/mtproto-v1) emit_file "$FIXTURES/mtproto-v1.ipk" ;;
    https://mock.invalid/assets/mtproto-v2) emit_file "$FIXTURES/mtproto-v2.ipk" ;;
    https://mock.invalid/assets/mtproto-bad-package) emit_file "$FIXTURES/mtproto-bad-package.ipk" ;;
    https://mock.invalid/assets/mtproto-bad-architecture) emit_file "$FIXTURES/mtproto-bad-architecture.ipk" ;;
    https://mock.invalid/assets/mtproto-bad-version) emit_file "$FIXTURES/mtproto-bad-version.ipk" ;;
    https://mock.invalid/assets/mtproto-traversal) emit_file "$FIXTURES/mtproto-traversal.ipk" ;;
    *) echo "mock curl: unknown URL: $url" >&2; exit 93 ;;
esac
EOF
chmod 755 "$MOCK_BIN/curl"

PATH="$MOCK_BIN:$PATH"
TMPDIR="$TEST_ROOT/tmp"
KZM_PROC_ROOT="$TEST_ROOT/mock-proc"
KZM_TEST_LISTEN_DIR="$TEST_ROOT/mock-listeners"
KZM_TEST_PID_LOG="$TEST_ROOT/test-owned-pids"
KZM_NETSTAT="$MOCK_BIN/netstat"
mkdir -p "$KZM_PROC_ROOT" "$KZM_TEST_LISTEN_DIR"
export PATH TMPDIR KZM_ROOT="$TEST_ROOT" KZM_GITHUB_API_BASE=https://mock.invalid \
    KZM_CURL_BIN="$MOCK_BIN/curl" KZM_ALLOW_TEST_ARTIFACTS=1 MOCK_LOG FIXTURES \
    KZM_PROC_ROOT KZM_TEST_LISTEN_DIR KZM_TEST_PID_LOG KZM_NETSTAT KZM_TEST_REAL_OD \
    KZM_TEST_LAUNCH_LOG="$LAUNCH_LOG"

# Test-only validation must never be enabled through a symlinked KZM_ROOT or
# through an isolated root whose opt directory escapes elsewhere. A regressed
# manager may create directories in the targets below, but they remain inside
# this disposable TEST_ROOT and never point at the host/router /opt.
REJECT_BIN="$TEST_ROOT/reject-bin"
mkdir -p "$REJECT_BIN"
cat > "$REJECT_BIN/uname" <<'EOF'
#!/bin/sh
[ "${1:-}" = -m ] && { echo x86_64; exit 0; }
exec /usr/bin/uname "$@"
EOF
chmod 755 "$REJECT_BIN/uname"

root_link_target="$TEST_ROOT/root-link-target"
root_link="/tmp/kzm-components-test.rootlink.$$"
mkdir -p "$root_link_target/opt"
ln -s "$root_link_target" "$root_link"
EXTRA_TEST_ROOTS="$EXTRA_TEST_ROOTS $root_link"

opt_link_target="$TEST_ROOT/opt-link-target"
opt_link_root="/tmp/kzm-components-test.optlink.$$"
mkdir -p "$opt_link_target" "$opt_link_root"
ln -s "$opt_link_target" "$opt_link_root/opt"
EXTRA_TEST_ROOTS="$EXTRA_TEST_ROOTS $opt_link_root"

for unsafe_root in "$root_link" "$opt_link_root"; do
    if PATH="$REJECT_BIN:/usr/bin:/bin" KZM_ROOT="$unsafe_root" KZM_PREFIX=/opt \
        KZM_ALLOW_TEST_ARTIFACTS=1 \
        sh "$PROJECT_DIR/src/libexec/kzm/component-manager.sh" install socks5 --yes \
        > "$TEST_ROOT/rejected-root-${unsafe_root##*.}.txt" 2>&1; then
        fail "test mode accepted a symlink-escaping KZM_ROOT: $unsafe_root"
    fi
    assert_contains "$TEST_ROOT/rejected-root-${unsafe_root##*.}.txt" 'aarch64 Keenetic'
done

sh "$PROJECT_DIR/install.sh" --root "$TEST_ROOT" >/dev/null

COMPONENT_MANAGER="$TEST_ROOT/opt/libexec/kzm/component-manager.sh"
PROXY_SERVICE="$TEST_ROOT/opt/libexec/kzm/tg-proxy-service.sh"
KZM="$TEST_ROOT/opt/bin/kzm"
[ -x "$COMPONENT_MANAGER" ] || fail "component-manager.sh was not installed"
[ -x "$PROXY_SERVICE" ] || fail "tg-proxy-service.sh was not installed"

# Both interactive levels must be navigable by numbers; users should not have
# to type internal component/profile identifiers.
printf '\n' | "$KZM" > "$TEST_ROOT/top-menu.txt"
assert_contains "$TEST_ROOT/top-menu.txt" '^ *1\).*Zapret'
assert_contains "$TEST_ROOT/top-menu.txt" '^ *2\).*(Установ|компонент)'
assert_contains "$TEST_ROOT/top-menu.txt" 'Zapret:.*установлен, запущен'
printf '2\n\n\n' | "$COMPONENT_MANAGER" menu > "$TEST_ROOT/install-menu.txt"
assert_contains "$TEST_ROOT/install-menu.txt" '^ *1\).*Zapret'
assert_contains "$TEST_ROOT/install-menu.txt" '^ *2\).*SOCKS5'
assert_contains "$TEST_ROOT/install-menu.txt" '^ *3\).*Rust'
assert_contains "$TEST_ROOT/install-menu.txt" '^ *4\).*MTProto'

component_binary() {
    case "$1" in
        socks5) echo "$TEST_ROOT/opt/usr/bin/kzm-tg-socks5" ;;
        rust) echo "$TEST_ROOT/opt/usr/bin/kzm-tg-rust" ;;
        mtproto) echo "$TEST_ROOT/opt/usr/bin/kzm-tg-mtproto" ;;
        *) return 1 ;;
    esac
}

component_marker() {
    case "$1:$2" in
        socks5:v1) echo KZM_SOCKS5_V1 ;; socks5:v2) echo KZM_SOCKS5_V2 ;;
        rust:v1) echo KZM_RUST_V1 ;; rust:v2) echo KZM_RUST_V2 ;;
        mtproto:v1) echo KZM_MTPROTO_V1 ;; mtproto:v2) echo KZM_MTPROTO_V2 ;;
        *) return 1 ;;
    esac
}

for component in socks5 rust mtproto; do
    MOCK_RELEASE_VARIANT=v1 "$COMPONENT_MANAGER" install "$component" --yes \
        > "$TEST_ROOT/install-$component.txt"
    binary=$(component_binary "$component")
    assert_file "$binary"
    assert_contains "$binary" "$(component_marker "$component" v1)"
    config="$TEST_ROOT/opt/etc/kzapret-manager/components/$component.conf"
    assert_file "$config"
    assert_mode_600 "$config"
    "$COMPONENT_MANAGER" status "$component" > "$TEST_ROOT/status-$component.txt"
done

# The recommended Rust route is deterministic even when the caller exports
# conflicting TG_* values: DC4 uses direct WS, while all other DCs use the
# fetched community Cloudflare list.  Record only non-secret launch metadata.
"$COMPONENT_MANAGER" stop rust >/dev/null
: > "$LAUNCH_LOG"
TG_DEFAULT_DOMAINS=false TG_NO_OUTBOUND_PROXY=false \
TG_CF_PRIORITY=true TG_CF_BALANCE=true \
KZM_TEST_WAIT_FOR_LISTENER=1 KZM_TEST_LISTENER_DELAY=6 \
    "$COMPONENT_MANAGER" start rust > "$TEST_ROOT/rust-profile-start.txt"
grep -Fqx 'TG_DEFAULT_DOMAINS=true' "$LAUNCH_LOG" || \
    fail "Rust did not enable community Cloudflare domains"
grep -Fqx 'TG_NO_OUTBOUND_PROXY=true' "$LAUNCH_LOG" || \
    fail "Rust inherited an outbound proxy policy"
grep -Fqx 'TG_CF_PRIORITY=false' "$LAUNCH_LOG" || \
    fail "Rust unexpectedly prioritised Cloudflare for DC4"
grep -Fqx 'TG_CF_BALANCE=false' "$LAUNCH_LOG" || \
    fail "Rust unexpectedly enabled Cloudflare balancing"
[ "$(grep -Fxc 'ARG=--dc-ip' "$LAUNCH_LOG")" -eq 1 ] || \
    fail "Rust must receive exactly one --dc-ip argument"
grep -Fqx 'ARG=4:149.154.167.220' "$LAUNCH_LOG" || \
    fail "Rust direct DC4 target is missing"
if grep -Eq '^ARG=2:' "$LAUNCH_LOG"; then
    fail "Rust profile unexpectedly retained the implicit DC2 target"
fi
if grep -q 'SECRET=' "$LAUNCH_LOG"; then
    fail "Rust launch test log exposed a secret"
fi

# An interrupted first install can leave a valid binary/config/process but no
# source metadata or autostart marker. The numbered install menu must offer a
# repair action instead of turning the same item into a destructive removal.
rm -f "$TEST_ROOT/opt/etc/kzapret-manager/components/rust.source"
"$COMPONENT_MANAGER" status rust > "$TEST_ROOT/rust-incomplete-status.txt"
assert_contains "$TEST_ROOT/rust-incomplete-status.txt" 'установка не завершена'
MOCK_RELEASE_VARIANT=v1 "$COMPONENT_MANAGER" menu > "$TEST_ROOT/rust-repair-menu.txt" <<'EOF'
2
3
1



EOF
assert_contains "$TEST_ROOT/rust-repair-menu.txt" 'Завершить установку TG WS Proxy Rust'
assert_contains "$TEST_ROOT/rust-repair-menu.txt" 'Завершить установку, проверить процесс'
assert_file "$TEST_ROOT/opt/etc/kzapret-manager/components/rust.source"
grep -Fqx 'TAG=v1.0.0' "$TEST_ROOT/opt/etc/kzapret-manager/components/rust.source" || \
    fail "repair did not restore Rust source metadata"

# Entware commonly exports TMPDIR=/opt/tmp. Simulate that flash-backed path
# below the isolated root and require both successful and rejected downloads
# to leave no kzm-components.* work directories there.
flash_tmp="$TEST_ROOT/opt/tmp"
mkdir -p "$flash_tmp"
TMPDIR="$flash_tmp" MOCK_RELEASE_VARIANT=v2 \
    "$COMPONENT_MANAGER" update socks5 --yes > "$TEST_ROOT/flash-tmp-update.txt"
if find "$flash_tmp" -maxdepth 1 -name 'kzm-components.*' -print | grep -q .; then
    fail "component update leaked a work directory into simulated /opt/tmp"
fi

# Updating replaces each binary atomically with the release whose digest was
# advertised by the local API fixture.
for component in socks5 rust mtproto; do
    MOCK_RELEASE_VARIANT=v2 "$COMPONENT_MANAGER" update "$component" --yes \
        > "$TEST_ROOT/update-$component.txt"
    binary=$(component_binary "$component")
    assert_contains "$binary" "$(component_marker "$component" v2)"
    assert_mode_600 "$TEST_ROOT/opt/etc/kzapret-manager/components/$component.conf"
done

# Digest failures are fail-closed: the installed executable is not touched.
rust_binary=$(component_binary rust)
rust_before=$(sha256_file "$rust_binary")
if TMPDIR="$flash_tmp" MOCK_RELEASE_VARIANT=bad-sha \
    "$COMPONENT_MANAGER" update rust --yes \
    > "$TEST_ROOT/bad-sha.txt" 2>&1; then
    fail "an asset with a mismatching GitHub SHA-256 digest was accepted"
fi
assert_contains "$TEST_ROOT/bad-sha.txt" 'SHA-256'
[ "$(sha256_file "$rust_binary")" = "$rust_before" ] || \
    fail "SHA mismatch changed the installed Rust binary"
if find "$flash_tmp" -maxdepth 1 -name 'kzm-components.*' -print | grep -q .; then
    fail "rejected component update leaked a work directory into simulated /opt/tmp"
fi

# Archive members containing '..' must be rejected before extraction and must
# leave the old executable intact.
if MOCK_RELEASE_VARIANT=traversal "$COMPONENT_MANAGER" update rust --yes \
    > "$TEST_ROOT/rust-traversal.txt" 2>&1; then
    fail "Rust tar path traversal was accepted"
fi
[ "$(sha256_file "$rust_binary")" = "$rust_before" ] || \
    fail "rejected Rust archive changed the installed binary"

mtproto_binary=$(component_binary mtproto)
mtproto_before=$(sha256_file "$mtproto_binary")
for invalid_metadata in bad-package bad-architecture bad-version; do
    if MOCK_RELEASE_VARIANT=$invalid_metadata \
        "$COMPONENT_MANAGER" update mtproto --yes \
        > "$TEST_ROOT/mtproto-$invalid_metadata.txt" 2>&1; then
        fail "IPK with invalid $invalid_metadata metadata was accepted"
    fi
    [ "$(sha256_file "$mtproto_binary")" = "$mtproto_before" ] || \
        fail "rejected $invalid_metadata IPK changed the installed binary"
    case "$invalid_metadata" in
        bad-package) expected_error='IPK' ;;
        bad-architecture) expected_error='aarch64-3\.10' ;;
        bad-version) expected_error='release tag' ;;
    esac
    assert_contains "$TEST_ROOT/mtproto-$invalid_metadata.txt" "$expected_error"
done
if MOCK_RELEASE_VARIANT=traversal "$COMPONENT_MANAGER" update mtproto --yes \
    > "$TEST_ROOT/ipk-traversal.txt" 2>&1; then
    fail "IPK data.tar path traversal was accepted"
fi
[ "$(sha256_file "$mtproto_binary")" = "$mtproto_before" ] || \
    fail "rejected IPK changed the installed binary"
if find "$TEST_ROOT" -path "$FIXTURES" -prune -o \
    -name KZM_TRAVERSAL_SENTINEL -print | grep -q .; then
    fail "a hostile archive escaped its extraction directory"
fi

# Exercise the real PID-file implementation.  A stale/forged PID belonging to
# an unrelated process must never be killed.
"$COMPONENT_MANAGER" stop socks5 >/dev/null 2>&1 || true
"$COMPONENT_MANAGER" start socks5 > "$TEST_ROOT/service-start.txt"
pid_file="$TEST_ROOT/opt/var/run/kzm-tg-socks5.pid"
assert_file "$pid_file"
service_pid=$(sed -n '1p' "$pid_file")
case "$service_pid" in *[!0-9]*|'') fail "invalid service PID: $service_pid" ;; esac
kill -0 "$service_pid" 2>/dev/null || fail "service PID is not alive"
"$COMPONENT_MANAGER" status socks5 > "$TEST_ROOT/service-running.txt"
"$COMPONENT_MANAGER" stop socks5 > "$TEST_ROOT/service-stop.txt"
wait_for_pid_exit "$service_pid" || fail "proxy process did not stop"
assert_absent "$pid_file"

# Keenetic exposes Entware executables through /proc without the userspace
# /opt prefix. Reproduce that topology with a symlinked parent directory: the
# PID guard must accept the exact canonical executable, while retaining its
# full-path ownership check for start, status and stop.
alias_root="/tmp/kzm-components-test.alias.$$"
EXTRA_TEST_ROOTS="$EXTRA_TEST_ROOTS $alias_root"
alias_proc="$alias_root/mock-proc"
alias_listeners="$alias_root/mock-listeners"
alias_real_bin="$alias_root/opt/real-usr/bin"
alias_binary="$alias_root/opt/usr/bin/kzm-tg-rust"
alias_config="$alias_root/opt/etc/kzapret-manager/components/rust.conf"
alias_pid_file="$alias_root/opt/var/run/kzm-tg-rust.pid"
mkdir -p "$alias_proc" "$alias_listeners" "$alias_real_bin" \
    "$alias_root/opt/etc/kzapret-manager/components"
ln -s real-usr "$alias_root/opt/usr"
cat > "$alias_real_bin/kzm-tg-rust" <<'EOF'
#!/bin/sh
proxy_proc_dir="${KZM_PROC_ROOT:?}/$$"
mkdir -p "$proxy_proc_dir"
canonical_self=$(readlink -f "$0") || exit 2
MSYS=winsymlinks:nativestrict ln -s "$canonical_self" "$proxy_proc_dir/exe"
printf '%s\n' "$$" >> "${KZM_TEST_PID_LOG:?}"
cleanup_alias_fixture() {
    rm -f "$proxy_proc_dir/exe"
    rmdir "$proxy_proc_dir" 2>/dev/null || true
    exit 0
}
trap cleanup_alias_fixture TERM INT HUP
while :; do sleep 1; done
EOF
chmod 755 "$alias_real_bin/kzm-tg-rust"
printf '%s\n' \
    'HOST=192.168.77.1' \
    'PORT=2443' \
    'SECRET=0123456789abcdef0123456789abcdef' \
    'POOL_SIZE=2' \
    'MAX_CONNECTIONS=32' > "$alias_config"
chmod 600 "$alias_config"

KZM_COMPONENT=rust KZM_ROOT="$alias_root" KZM_ALLOW_TEST_ARTIFACTS=1 \
KZM_PROC_ROOT="$alias_proc" KZM_TEST_LISTEN_DIR="$alias_listeners" \
KZM_TEST_PID_LOG="$KZM_TEST_PID_LOG" \
    "$PROXY_SERVICE" start > "$TEST_ROOT/canonical-alias-start.txt"
assert_file "$alias_pid_file"
alias_pid=$(sed -n '1p' "$alias_pid_file")
case "$alias_pid" in *[!0-9]*|'') fail "invalid canonical-alias PID: $alias_pid" ;; esac
[ "$(readlink "$alias_proc/$alias_pid/exe")" = "$(readlink -f "$alias_binary")" ] || \
    fail "fixture did not expose the canonical executable"
[ "$(readlink "$alias_proc/$alias_pid/exe")" != "$alias_binary" ] || \
    fail "fixture did not reproduce the /opt path alias"
KZM_COMPONENT=rust KZM_ROOT="$alias_root" KZM_ALLOW_TEST_ARTIFACTS=1 \
KZM_PROC_ROOT="$alias_proc" KZM_TEST_LISTEN_DIR="$alias_listeners" \
KZM_TEST_PID_LOG="$KZM_TEST_PID_LOG" \
    "$PROXY_SERVICE" status > "$TEST_ROOT/canonical-alias-status.txt"
KZM_COMPONENT=rust KZM_ROOT="$alias_root" KZM_ALLOW_TEST_ARTIFACTS=1 \
KZM_PROC_ROOT="$alias_proc" KZM_TEST_LISTEN_DIR="$alias_listeners" \
KZM_TEST_PID_LOG="$KZM_TEST_PID_LOG" \
    "$PROXY_SERVICE" stop > "$TEST_ROOT/canonical-alias-stop.txt"
wait_for_pid_exit "$alias_pid" || fail "canonical-alias process did not stop"
assert_absent "$alias_pid_file"

# A successful stop requires a final full process scan, not merely the exit of
# the PID originally recorded. This fixture forks one exact replacement from
# its TERM trap; the first stop must fail closed, preserve the replacement PID
# and leave every component artifact intact. A second stop cleans it normally.
KZM_TEST_FORK_ON_TERM=1 "$COMPONENT_MANAGER" start socks5 \
    > "$TEST_ROOT/service-orphan-start.txt"
orphan_parent_pid=$(sed -n '1p' "$pid_file")
if "$COMPONENT_MANAGER" stop socks5 \
    > "$TEST_ROOT/service-orphan-stop.txt" 2>&1; then
    fail "service stop accepted an exact orphan left after the parent exited"
fi
assert_contains "$TEST_ROOT/service-orphan-stop.txt" 'exact-'
assert_file "$pid_file"
orphan_pid=$(sed -n '1p' "$pid_file")
case "$orphan_pid" in *[!0-9]*|'') fail "invalid recovered orphan PID: $orphan_pid" ;; esac
[ "$orphan_pid" != "$orphan_parent_pid" ] || fail "orphan PID was not recovered"
kill -0 "$orphan_pid" 2>/dev/null || fail "recovered orphan PID is not alive"
assert_file "$(component_binary socks5)"
assert_file "$TEST_ROOT/opt/etc/kzapret-manager/components/socks5.conf"
"$COMPONENT_MANAGER" stop socks5 > "$TEST_ROOT/service-orphan-cleanup.txt"
wait_for_pid_exit "$orphan_pid" || fail "recovered orphan did not stop"
assert_absent "$pid_file"

sleep 300 &
unrelated_pid=$!
printf '%s\n' "$unrelated_pid" >> "$KZM_TEST_PID_LOG"
printf '%s\n' "$unrelated_pid" > "$pid_file"
mkdir -p "$KZM_PROC_ROOT/$unrelated_pid"
MSYS=winsymlinks:nativestrict ln -s /bin/sleep "$KZM_PROC_ROOT/$unrelated_pid/exe"
"$COMPONENT_MANAGER" stop socks5 > "$TEST_ROOT/service-forged-pid.txt" 2>&1 || true
kill -0 "$unrelated_pid" 2>/dev/null || fail "service stop killed an unrelated PID"
kill "$unrelated_pid" 2>/dev/null || true
wait "$unrelated_pid" 2>/dev/null || true
rm -f "$KZM_PROC_ROOT/$unrelated_pid/exe" "$pid_file"
rmdir "$KZM_PROC_ROOT/$unrelated_pid" 2>/dev/null || true

# Removal is exact and per-component; it must not invoke or restart nfqws.
for component in socks5 rust mtproto; do
    "$COMPONENT_MANAGER" remove "$component" --yes > "$TEST_ROOT/remove-$component.txt"
    assert_absent "$(component_binary "$component")"
    assert_absent "$TEST_ROOT/opt/etc/kzapret-manager/components/$component.conf"
done

assert_absent "$TEST_ROOT/nfqws-restart.log"
if [ -s "$MOCK_LOG" ]; then
    if grep -Ev '^https://mock\.invalid/' "$MOCK_LOG" | grep -q .; then
        fail "a non-mock network URL was requested"
    fi
else
    fail "component downloads did not use the curl mock"
fi

echo "All component manager tests passed"
