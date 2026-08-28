#!/bin/sh

# Offline bootstrap tests. Pass KZM_BOOTSTRAP_TEST_ARCHIVE and optionally
# KZM_BOOTSTRAP_TEST_CHECKSUM on targets whose tar cannot create archives.

set -eu

PROJECT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=${TEST_ROOT:-/tmp/kzm-bootstrap-test.release}
TEST_ARCHIVE=${KZM_BOOTSTRAP_TEST_ARCHIVE:-}
TEST_CHECKSUM=${KZM_BOOTSTRAP_TEST_CHECKSUM:-}

case "$TEST_ROOT" in
    /tmp/kzm-bootstrap-test.*) ;;
    *) echo "Unsafe TEST_ROOT: $TEST_ROOT" >&2; exit 1 ;;
esac
[ ! -e "$TEST_ROOT" ] && [ ! -L "$TEST_ROOT" ] || {
    echo "TEST_ROOT already exists: $TEST_ROOT" >&2
    exit 1
}
mkdir "$TEST_ROOT"

cleanup() {
    case "$TEST_ROOT" in
        /tmp/kzm-bootstrap-test.*)
            [ -d "$TEST_ROOT" ] && [ ! -L "$TEST_ROOT" ] && rm -rf "$TEST_ROOT"
            ;;
    esac
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    echo "bootstrap.sh test: $*" >&2
    exit 1
}

if [ -z "$TEST_ARCHIVE" ]; then
    TEST_ARCHIVE="$TEST_ROOT/release.tar.gz"
    tar -czf "$TEST_ARCHIVE" -C "$PROJECT_DIR" \
        VERSION install.sh bootstrap.sh src tests || fail "cannot create release fixture"
fi
[ -f "$TEST_ARCHIVE" ] && [ ! -L "$TEST_ARCHIVE" ] || \
    fail "release fixture is unsafe"

if [ -z "$TEST_CHECKSUM" ]; then
    TEST_CHECKSUM="$TEST_ROOT/release.tar.gz.sha256"
    fixture_sha=$(sha256sum "$TEST_ARCHIVE" | awk '{ print $1 }')
    printf '%s  keenetic-zapret-manager.tar.gz\n' "$fixture_sha" > "$TEST_CHECKSUM"
fi
[ -f "$TEST_CHECKSUM" ] && [ ! -L "$TEST_CHECKSUM" ] || \
    fail "checksum fixture is unsafe"

install_root="$TEST_ROOT/install-root"
mkdir "$install_root"
KZM_ARCHIVE_URL="file://$TEST_ARCHIVE" \
KZM_CHECKSUM_URL="file://$TEST_CHECKSUM" \
KZM_RELEASE_TAG=v0.8.3 \
    sh "$PROJECT_DIR/bootstrap.sh" --root "$install_root" \
    > "$TEST_ROOT/install.out"

[ -x "$install_root/opt/bin/kzm" ] || fail "kzm was not installed"
[ "$(KZM_ROOT="$install_root" "$install_root/opt/bin/kzm" version)" = 0.8.3 ] || \
    fail "installed version does not match"
grep -q 'установлен из проверенного релиза GitHub' "$TEST_ROOT/install.out" || \
    fail "bootstrap success message is missing"

bad_checksum="$TEST_ROOT/bad.sha256"
printf '%064d  keenetic-zapret-manager.tar.gz\n' 0 > "$bad_checksum"
bad_root="$TEST_ROOT/bad-root"
mkdir "$bad_root"
if KZM_ARCHIVE_URL="file://$TEST_ARCHIVE" \
        KZM_CHECKSUM_URL="file://$bad_checksum" \
        KZM_RELEASE_TAG=v0.8.3 \
        sh "$PROJECT_DIR/bootstrap.sh" --root "$bad_root" \
        > "$TEST_ROOT/bad-checksum.out" 2>&1; then
    fail "bootstrap accepted an invalid checksum"
fi
[ ! -e "$bad_root/opt" ] || fail "checksum failure changed the install root"
grep -q 'SHA-256 архива не совпал' "$TEST_ROOT/bad-checksum.out" || \
    fail "checksum failure was not explained"

echo "All bootstrap tests passed"
