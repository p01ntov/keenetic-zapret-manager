#!/bin/sh

# Optional networked integration test. It downloads the current upstream
# catalogs and the official multi-architecture nfqws package, then performs
# dry-run validation locally. It never connects to a router.

set -eu

PROJECT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LIVE_ROOT=${LIVE_ROOT:-/tmp/kzm-live-source-test}

case "$LIVE_ROOT" in
    /tmp/kzm-live-source-test*) rm -rf "$LIVE_ROOT" ;;
    *) echo "Unsafe LIVE_ROOT: $LIVE_ROOT" >&2; exit 1 ;;
esac

cleanup_live_test() {
    case "$LIVE_ROOT" in
        /tmp/kzm-live-source-test*) rm -rf "$LIVE_ROOT" ;;
    esac
}

trap cleanup_live_test EXIT HUP INT TERM
mkdir -p "$LIVE_ROOT"

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "unzip is required" >&2; exit 1; }

sh "$PROJECT_DIR/install.sh" --root "$LIVE_ROOT" >/dev/null
KZM_ROOT="$LIVE_ROOT" "$LIVE_ROOT/opt/bin/kzm" update

general_count=$(find "$LIVE_ROOT/opt/etc/kzapret-manager/strategies/general" -name '*.strategy' | awk 'END { print NR+0 }')
flowseal_count=$(find "$LIVE_ROOT/opt/etc/kzapret-manager/strategies/flowseal" -name '*.strategy' | awk 'END { print NR+0 }')
target_count=$(awk 'END { print NR+0 }' "$LIVE_ROOT/opt/etc/kzapret-manager/lists/test-targets.tsv")
[ "$general_count" -ge 10 ] || { echo "Too few v profiles: $general_count" >&2; exit 1; }
[ "$flowseal_count" -ge 20 ] || { echo "Too few Flowseal profiles: $flowseal_count" >&2; exit 1; }
[ "$target_count" -ge 50 ] || { echo "Too few test targets: $target_count" >&2; exit 1; }

curl -fsSL 'https://nfqws.github.io/nfqws-keenetic/all/Packages.gz' -o "$LIVE_ROOT/Packages.gz"
gzip -dc "$LIVE_ROOT/Packages.gz" > "$LIVE_ROOT/Packages"
package_filename=$(awk '
    $0 == "Package: nfqws-keenetic" { found=1; next }
    found && /^Filename: / { print $2; exit }
    found && /^$/ { exit }
' "$LIVE_ROOT/Packages")
case "$package_filename" in
    nfqws-keenetic_*.ipk) ;;
    *) echo "nfqws package was not found" >&2; exit 1 ;;
esac
case "$package_filename" in *[!A-Za-z0-9_.-]*) echo "Unsafe package name" >&2; exit 1 ;; esac

curl -fsSL "https://nfqws.github.io/nfqws-keenetic/all/$package_filename" -o "$LIVE_ROOT/nfqws.ipk"
mkdir -p "$LIVE_ROOT/ipk"
(
    cd "$LIVE_ROOT/ipk"
    tar -xzf "$LIVE_ROOT/nfqws.ipk"
    tar -xzf data.tar.gz
)
test_nfqws="$LIVE_ROOT/ipk/opt/tmp/nfqws_binary/nfqws-x86_64"
[ -x "$test_nfqws" ] || { echo "x86_64 nfqws was not extracted" >&2; exit 1; }

checked=0
for strategy_file in \
    "$LIVE_ROOT"/opt/etc/kzapret-manager/strategies/general/*.strategy \
    "$LIVE_ROOT"/opt/etc/kzapret-manager/strategies/flowseal/*.strategy; do
    [ -f "$strategy_file" ] || continue
    strategy_args=$(awk '/^--/ { printf "%s ", $0 }' "$strategy_file")
    # Word splitting is intentional: each validated line is one nfqws option.
    # shellcheck disable=SC2086
    "$test_nfqws" --dry-run --qnum=301 $strategy_args >/dev/null
    checked=$((checked + 1))
done

mkdir -p "$LIVE_ROOT/opt/usr/bin" "$LIVE_ROOT/opt/etc/nfqws"
cp "$test_nfqws" "$LIVE_ROOT/opt/usr/bin/nfqws"
chmod +x "$LIVE_ROOT/opt/usr/bin/nfqws"
cp "$LIVE_ROOT/ipk/opt/etc/nfqws/nfqws.conf" "$LIVE_ROOT/opt/etc/nfqws/nfqws.conf"

KZM_ROOT="$LIVE_ROOT" "$LIVE_ROOT/opt/bin/kzm" domain add video.example >/dev/null
KZM_ROOT="$LIVE_ROOT" "$LIVE_ROOT/opt/bin/kzm" network add 198.51.100.0/24 2001:db8::/32 >/dev/null
KZM_ROOT="$LIVE_ROOT" "$LIVE_ROOT/opt/bin/kzm" strategy set scope list >/dev/null
KZM_ROOT="$LIVE_ROOT" "$LIVE_ROOT/opt/bin/kzm" strategy set youtube off >/dev/null
KZM_ROOT="$LIVE_ROOT" "$LIVE_ROOT/opt/bin/kzm" apply >/dev/null
grep -q -- "--hostlist=$LIVE_ROOT/opt/etc/kzapret-manager/lists/user.list" "$LIVE_ROOT/opt/etc/nfqws/nfqws.conf"
grep -q -- "--ipset=$LIVE_ROOT/opt/etc/kzapret-manager/lists/user-ipset.list" "$LIVE_ROOT/opt/etc/nfqws/nfqws.conf"
grep -q -- '--ipset-ip=0.0.0.0' "$LIVE_ROOT/opt/etc/nfqws/nfqws.conf"

echo "Live integration passed: v=$general_count Flowseal=$flowseal_count targets=$target_count dry-run=$checked custom-targets=ok"
