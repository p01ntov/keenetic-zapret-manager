#!/bin/sh

# Offline transaction/upgrade-safety tests for install.sh. These tests never
# contact a router, start a service, or download anything.

set -eu

PROJECT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=${TEST_ROOT:-}
KEEP_TEST_ROOT=${KEEP_TEST_ROOT:-0}

if [ -z "$TEST_ROOT" ]; then
    TEST_ROOT=$(mktemp -d /tmp/kzm-install-upgrade.XXXXXX)
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
        kzm-install-upgrade.*) ;;
        *) echo "Unsafe TEST_ROOT basename: $test_name" >&2; exit 1 ;;
    esac
    TEST_ROOT="/tmp/$test_name"
    if [ -e "$TEST_ROOT" ] || [ -L "$TEST_ROOT" ]; then
        echo "TEST_ROOT already exists: $TEST_ROOT" >&2
        exit 1
    fi
    mkdir "$TEST_ROOT"
fi

cleanup() {
    if [ "$KEEP_TEST_ROOT" = 1 ]; then
        echo "Install upgrade test root kept at $TEST_ROOT" >&2
        return
    fi
    test_cleanup_name=${TEST_ROOT##*/}
    if [ "${TEST_ROOT%/*}" = /tmp ] && [ -d "$TEST_ROOT" ] && [ ! -L "$TEST_ROOT" ]; then
        case "$test_cleanup_name" in
            kzm-install-upgrade.*) rm -rf "$TEST_ROOT" ;;
            *) echo "Refusing to clean unsafe TEST_ROOT: $TEST_ROOT" >&2 ;;
        esac
    else
        echo "Refusing to clean unsafe TEST_ROOT: $TEST_ROOT" >&2
    fi
}
trap cleanup EXIT HUP INT TERM

fail() {
    echo "install-upgrade.sh: $*" >&2
    exit 1
}

sleep_briefly() {
    if command -v usleep >/dev/null 2>&1; then
        usleep 100000
    elif sleep 0.1 2>/dev/null; then
        :
    else
        sleep 1
    fi
}

path_exists() {
    [ -e "$1" ] || [ -L "$1" ]
}

assert_same() {
    cmp "$1" "$2" >/dev/null 2>&1 || fail "$1 differs from $2"
}

assert_executable() {
    if [ ! -f "$1" ] || [ ! -x "$1" ]; then
        fail "expected executable file: $1"
    fi
}

assert_absent() {
    ! path_exists "$1" || fail "unexpected path: $1"
}

assert_no_install_artifacts() {
    assert_absent "$TEST_ROOT/opt/.kzm-install.transaction"
    assert_absent "$TEST_ROOT/opt/.kzm-install.lock"
    for leftover in "$TEST_ROOT/opt/".kzm-install.lock.stale.* \
                    "$TEST_ROOT/opt/".kzm-install.discard.*; do
        ! path_exists "$leftover" || fail "stale install artifact remains: $leftover"
    done
}

write_preserved_file() {
    preserve_relative=$1
    preserve_target="$TEST_ROOT/opt/$preserve_relative"
    preserve_expected="$EXPECTED_DIR/$preserve_relative"
    mkdir -p "${preserve_target%/*}" "${preserve_expected%/*}"
    printf 'user-owned:%s\nsecond-line=do-not-replace\n' "$preserve_relative" > "$preserve_target"
    cp "$preserve_target" "$preserve_expected"
}

assert_preserved_files() {
    for preserve_relative in $PRESERVED_FILES; do
        assert_same "$EXPECTED_DIR/$preserve_relative" "$TEST_ROOT/opt/$preserve_relative"
    done
}

snapshot_file() {
    snapshot_relative=$1
    snapshot_name=$2
    cp "$TEST_ROOT/opt/$snapshot_relative" "$TEST_ROOT/$snapshot_name"
}

assert_snapshot() {
    snapshot_relative=$1
    snapshot_name=$2
    assert_same "$TEST_ROOT/$snapshot_name" "$TEST_ROOT/opt/$snapshot_relative"
}

write_managed_sentinels() {
    printf '%s\n' '#!/bin/sh' 'echo old-entrypoint' > "$TEST_ROOT/opt/bin/kzm"
    chmod 755 "$TEST_ROOT/opt/bin/kzm"
    printf '%s\n' '#!/bin/sh' 'echo old-helper' > "$TEST_ROOT/opt/libexec/kzm/component-manager.sh"
    chmod 755 "$TEST_ROOT/opt/libexec/kzm/component-manager.sh"
    printf '%s\n' 'old-packaged-youtube' > "$TEST_ROOT/opt/share/kzm/youtube.list"
    printf '%s\n' 'custom-mobile.example' 'youtube.com' '# keep-this-comment' > \
        "$TEST_ROOT/opt/etc/kzapret-manager/lists/youtube.list"

    snapshot_file "bin/kzm" "snapshot-entrypoint"
    snapshot_file "libexec/kzm/component-manager.sh" "snapshot-helper"
    snapshot_file "share/kzm/youtube.list" "snapshot-share-youtube"
    snapshot_file "etc/kzapret-manager/lists/youtube.list" "snapshot-active-youtube"
}

assert_managed_sentinels() {
    assert_snapshot "bin/kzm" "snapshot-entrypoint"
    assert_snapshot "libexec/kzm/component-manager.sh" "snapshot-helper"
    assert_snapshot "share/kzm/youtube.list" "snapshot-share-youtube"
    assert_snapshot "etc/kzapret-manager/lists/youtube.list" "snapshot-active-youtube"
}

run_with_mocks() {
    PATH="$MOCK_BIN:$PATH" \
    KZM_TEST_REAL_MV="$REAL_MV" \
    KZM_TEST_REAL_CHMOD="$REAL_CHMOD" \
    KZM_TEST_REAL_CP="$REAL_CP" \
    KZM_TEST_MV_LOG="$MV_LOG" \
    "$@"
}

# Clean install: default config and executable entrypoint, no persistent backup.
sh "$PROJECT_DIR/install.sh" --root "$TEST_ROOT" >/dev/null
assert_same "$PROJECT_DIR/src/kzm.conf" "$TEST_ROOT/opt/etc/kzapret-manager/kzm.conf"
assert_executable "$TEST_ROOT/opt/bin/kzm"
assert_executable "$TEST_ROOT/opt/libexec/kzm/quic-policy.sh"
assert_executable "$TEST_ROOT/opt/etc/ndm/netfilter.d/091-kzm-quic-policy.sh"
assert_no_install_artifacts

EXPECTED_DIR="$TEST_ROOT/expected"
PRESERVED_FILES="
etc/kzapret-manager/kzm.conf
etc/kzapret-manager/state.conf
etc/kzapret-manager/configured-state.conf
etc/kzapret-manager/running-state.conf
etc/kzapret-manager/pending-changes
etc/kzapret-manager/lists/user.list
etc/kzapret-manager/lists/user-ipset.list
etc/kzapret-manager/lists/auto.list
etc/kzapret-manager/lists/exclude.list
etc/kzapret-manager/lists/test-targets.tsv
etc/kzapret-manager/components/socks5.conf
etc/kzapret-manager/components/rust.conf
etc/kzapret-manager/components/mtproto.conf
etc/kzapret-manager/components/socks5.source
etc/kzapret-manager/components/rust.autostart
etc/nfqws/domain_add.yaml
"

for preserve_relative in $PRESERVED_FILES; do
    write_preserved_file "$preserve_relative"
done

# The active list is intentionally missing most packaged domains and contains
# user data that must survive the non-destructive merge.
active_youtube="$TEST_ROOT/opt/etc/kzapret-manager/lists/youtube.list"
mkdir -p "${active_youtube%/*}"
printf '%s\n' 'custom-mobile.example' 'youtube.com' '# keep-this-comment' > "$active_youtube"

# Existing wrappers fail and write a marker if an installer ever executes one.
SERVICE_MARKER="$TEST_ROOT/service-action-was-called"
mkdir -p "$TEST_ROOT/opt/etc/init.d"
for component in socks5 mtproto; do
    wrapper="$TEST_ROOT/opt/etc/init.d/S99kzm-tg-$component"
    {
        printf '%s\n' '#!/bin/sh'
        printf "printf 'called\\n' >> '%s'\n" "$SERVICE_MARKER"
        printf '%s\n' 'exit 97'
    } > "$wrapper"
    chmod 755 "$wrapper"
done
assert_absent "$TEST_ROOT/opt/etc/init.d/S99kzm-tg-rust"

# Wrappers for deterministic staging/commit failures, signals, crashes, and a
# slow concurrent install. Every destructive injection fires at most once.
REAL_MV=$(command -v mv)
REAL_CHMOD=$(command -v chmod)
REAL_CP=$(command -v cp)
MOCK_BIN="$TEST_ROOT/mock-bin"
MV_LOG="$TEST_ROOT/mv.log"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/mv" <<'EOF'
#!/bin/sh
set -eu
last_argument=""
for argument in "$@"; do
    last_argument=$argument
done
printf '%s\n' "$*" >> "${KZM_TEST_MV_LOG:?}"

if [ -n "${KZM_TEST_MV_FAIL_TARGET:-}" ] &&
   [ "$last_argument" = "$KZM_TEST_MV_FAIL_TARGET" ] &&
   [ ! -e "${KZM_TEST_MV_FAIL_MARKER:?}" ]; then
    : > "$KZM_TEST_MV_FAIL_MARKER"
    exit 73
fi

if [ -n "${KZM_TEST_MV_SIGNAL_TARGET:-}" ] &&
   [ "$last_argument" = "$KZM_TEST_MV_SIGNAL_TARGET" ] &&
   [ ! -e "${KZM_TEST_MV_SIGNAL_MARKER:?}" ]; then
    : > "$KZM_TEST_MV_SIGNAL_MARKER"
    "${KZM_TEST_REAL_MV:?}" "$@"
    kill -TERM "$PPID"
    exit 0
fi

if [ -n "${KZM_TEST_MV_KILL_TARGET:-}" ] &&
   [ "$last_argument" = "$KZM_TEST_MV_KILL_TARGET" ] &&
   [ ! -e "${KZM_TEST_MV_KILL_MARKER:?}" ]; then
    : > "$KZM_TEST_MV_KILL_MARKER"
    "${KZM_TEST_REAL_MV:?}" "$@"
    kill -KILL "$PPID"
    exit 0
fi

exec "${KZM_TEST_REAL_MV:?}" "$@"
EOF
chmod 755 "$MOCK_BIN/mv"

cat > "$MOCK_BIN/chmod" <<'EOF'
#!/bin/sh
set -eu
last_argument=""
for argument in "$@"; do
    last_argument=$argument
done
if [ -n "${KZM_TEST_CHMOD_FAIL_SUFFIX:-}" ]; then
    case "$last_argument" in
        *"$KZM_TEST_CHMOD_FAIL_SUFFIX") exit 74 ;;
    esac
fi
exec "${KZM_TEST_REAL_CHMOD:?}" "$@"
EOF
chmod 755 "$MOCK_BIN/chmod"

cat > "$MOCK_BIN/cp" <<'EOF'
#!/bin/sh
set -eu
last_argument=""
for argument in "$@"; do
    last_argument=$argument
done
if [ -n "${KZM_TEST_CP_SLEEP_SUFFIX:-}" ]; then
    case "$last_argument" in
        *"$KZM_TEST_CP_SLEEP_SUFFIX")
            if [ ! -e "${KZM_TEST_CP_SLEEP_MARKER:?}" ]; then
                : > "$KZM_TEST_CP_SLEEP_MARKER"
                sleep "${KZM_TEST_CP_SLEEP_SECONDS:-3}"
            fi
            ;;
    esac
fi
exec "${KZM_TEST_REAL_CP:?}" "$@"
EOF
chmod 755 "$MOCK_BIN/cp"

# A late staging error must not touch any managed target.
write_managed_sentinels
: > "$MV_LOG"
if PATH="$MOCK_BIN:$PATH" KZM_TEST_REAL_MV="$REAL_MV" KZM_TEST_MV_LOG="$MV_LOG" \
    KZM_TEST_REAL_CHMOD="$REAL_CHMOD" KZM_TEST_REAL_CP="$REAL_CP" \
    KZM_TEST_CHMOD_FAIL_SUFFIX="/share/kzm/youtube.list" \
    sh "$PROJECT_DIR/install.sh" --root "$TEST_ROOT" >/dev/null 2>&1; then
    fail "install unexpectedly succeeded after a staging failure"
fi
assert_managed_sentinels
assert_preserved_files
assert_absent "$SERVICE_MARKER"
assert_no_install_artifacts

# Successful upgrade preserves user state, merges missing packaged YouTube
# domains without deleting custom lines, refreshes wrappers as inert files,
# and commits bin/kzm after every other managed target.
: > "$MV_LOG"
run_with_mocks sh "$PROJECT_DIR/install.sh" --root "$TEST_ROOT" >/dev/null
assert_preserved_files
grep -Fqx 'custom-mobile.example' "$active_youtube" || fail "custom YouTube domain was removed"
grep -Fqx '# keep-this-comment' "$active_youtube" || fail "custom YouTube comment was removed"
while IFS= read -r packaged_domain; do
    [ -n "$packaged_domain" ] || continue
    domain_count=$(grep -Fxc "$packaged_domain" "$active_youtube" || :)
    [ "$domain_count" = 1 ] || fail "packaged domain not merged exactly once: $packaged_domain"
done < "$PROJECT_DIR/src/share/kzm/youtube.list"
assert_same "$PROJECT_DIR/src/kzm.conf" "$TEST_ROOT/opt/etc/kzapret-manager/kzm.conf.dist"

for component in socks5 mtproto; do
    assert_same "$PROJECT_DIR/src/share/kzm/components/S99kzm-tg-$component" \
        "$TEST_ROOT/opt/etc/init.d/S99kzm-tg-$component"
    assert_executable "$TEST_ROOT/opt/etc/init.d/S99kzm-tg-$component"
done
assert_absent "$TEST_ROOT/opt/etc/init.d/S99kzm-tg-rust"
assert_absent "$SERVICE_MARKER"
assert_same "$PROJECT_DIR/src/kzm" "$TEST_ROOT/opt/bin/kzm"
assert_executable "$TEST_ROOT/opt/bin/kzm"

last_managed_mv=$(awk -v target="$TEST_ROOT/opt/" '
    {
        destination=$NF
        if (index(destination, target) == 1 && index(destination, target ".kzm-install.") != 1)
            last=$0
    }
    END { print last }
' "$MV_LOG")
case "$last_managed_mv" in
    *" $TEST_ROOT/opt/bin/kzm") ;;
    *) fail "entrypoint was not the final managed rename: $last_managed_mv" ;;
esac
assert_no_install_artifacts

# A one-shot failure in the middle of sequential commit must restore every
# already-replaced file, including the merged active YouTube list.
write_managed_sentinels
FAIL_MARKER="$TEST_ROOT/mv-failed-once"
rm -f "$FAIL_MARKER"
: > "$MV_LOG"
if PATH="$MOCK_BIN:$PATH" KZM_TEST_REAL_MV="$REAL_MV" KZM_TEST_MV_LOG="$MV_LOG" \
    KZM_TEST_REAL_CHMOD="$REAL_CHMOD" KZM_TEST_REAL_CP="$REAL_CP" \
    KZM_TEST_MV_FAIL_TARGET="$active_youtube" KZM_TEST_MV_FAIL_MARKER="$FAIL_MARKER" \
    sh "$PROJECT_DIR/install.sh" --root "$TEST_ROOT" >/dev/null 2>&1; then
    fail "install unexpectedly succeeded after a mid-commit failure"
fi
assert_managed_sentinels
assert_preserved_files
assert_absent "$SERVICE_MARKER"
assert_no_install_artifacts

# TERM delivered just after a managed rename must execute the same rollback.
write_managed_sentinels
SIGNAL_MARKER="$TEST_ROOT/mv-signalled-once"
rm -f "$SIGNAL_MARKER"
: > "$MV_LOG"
if PATH="$MOCK_BIN:$PATH" KZM_TEST_REAL_MV="$REAL_MV" KZM_TEST_MV_LOG="$MV_LOG" \
    KZM_TEST_REAL_CHMOD="$REAL_CHMOD" KZM_TEST_REAL_CP="$REAL_CP" \
    KZM_TEST_MV_SIGNAL_TARGET="$TEST_ROOT/opt/share/kzm/youtube.list" \
    KZM_TEST_MV_SIGNAL_MARKER="$SIGNAL_MARKER" \
    sh "$PROJECT_DIR/install.sh" --root "$TEST_ROOT" >/dev/null 2>&1; then
    fail "install unexpectedly succeeded after TERM"
fi
assert_managed_sentinels
assert_preserved_files
assert_absent "$SERVICE_MARKER"
assert_no_install_artifacts

# SIGKILL simulates power loss: no trap can run. The following invocation must
# reclaim the stale lock and restore the previous release before doing any new
# commit. A forced staging failure lets us observe that recovered old release.
write_managed_sentinels
KILL_MARKER="$TEST_ROOT/mv-killed-once"
rm -f "$KILL_MARKER"
: > "$MV_LOG"
PATH="$MOCK_BIN:$PATH" KZM_TEST_REAL_MV="$REAL_MV" KZM_TEST_MV_LOG="$MV_LOG" \
KZM_TEST_REAL_CHMOD="$REAL_CHMOD" KZM_TEST_REAL_CP="$REAL_CP" \
KZM_TEST_MV_KILL_TARGET="$TEST_ROOT/opt/share/kzm/youtube.list" \
KZM_TEST_MV_KILL_MARKER="$KILL_MARKER" \
sh "$PROJECT_DIR/install.sh" --root "$TEST_ROOT" >/dev/null 2>&1 &
crashed_pid=$!
set +e
wait "$crashed_pid"
crashed_status=$?
set -e
[ "$crashed_status" -ne 0 ] || fail "SIGKILL simulation unexpectedly succeeded"
path_exists "$TEST_ROOT/opt/.kzm-install.transaction" || fail "crash transaction was not preserved"
path_exists "$TEST_ROOT/opt/.kzm-install.lock" || fail "crash lock was not preserved"

if PATH="$MOCK_BIN:$PATH" KZM_TEST_REAL_MV="$REAL_MV" KZM_TEST_MV_LOG="$MV_LOG" \
    KZM_TEST_REAL_CHMOD="$REAL_CHMOD" KZM_TEST_REAL_CP="$REAL_CP" \
    KZM_TEST_CHMOD_FAIL_SUFFIX="/share/kzm/youtube.list" \
    sh "$PROJECT_DIR/install.sh" --root "$TEST_ROOT" >/dev/null 2>&1; then
    fail "post-recovery staging failure unexpectedly succeeded"
fi
assert_managed_sentinels
assert_preserved_files
assert_absent "$SERVICE_MARKER"
assert_no_install_artifacts

# A stale, well-formed lock is reclaimed; no arbitrary lock contents are
# deleted. This is independent of crash recovery above.
mkdir "$TEST_ROOT/opt/.kzm-install.lock"
printf '%s\n%s\n%s\n' 99999999 1 "$TEST_ROOT/opt" > "$TEST_ROOT/opt/.kzm-install.lock/owner"
run_with_mocks sh "$PROJECT_DIR/install.sh" --root "$TEST_ROOT" >/dev/null
assert_no_install_artifacts
assert_absent "$SERVICE_MARKER"

# Recovery validates every journal target against a hard allowlist before it
# removes or restores anything. A forged traversal entry must fail closed.
outside_victim="$TEST_ROOT/outside-victim"
printf '%s\n' 'must-survive' > "$outside_victim"
malicious_txn="$TEST_ROOT/opt/.kzm-install.transaction"
mkdir "$malicious_txn" "$malicious_txn/stage" "$malicious_txn/rollback" "$malicious_txn/journal"
printf '%s\n' committing > "$malicious_txn/state"
printf '%s\n' 'O ../../outside-victim' > "$malicious_txn/journal/000001.entry"
if sh "$PROJECT_DIR/install.sh" --root "$TEST_ROOT" >/dev/null 2>&1; then
    fail "installer accepted a traversal path in the recovery journal"
fi
grep -qx 'must-survive' "$outside_victim" || fail "forged journal changed an outside file"
path_exists "$malicious_txn" || fail "unsafe transaction was deleted instead of failing closed"
assert_absent "$TEST_ROOT/opt/.kzm-install.lock"
rm -rf "$malicious_txn"

# While a real installer owns the lock, a second installer must fail without
# touching the in-flight transaction. The first installer then completes.
SLEEP_MARKER="$TEST_ROOT/cp-slept-once"
FIRST_LOG="$TEST_ROOT/first-install.log"
SECOND_LOG="$TEST_ROOT/second-install.log"
rm -f "$SLEEP_MARKER"
PATH="$MOCK_BIN:$PATH" KZM_TEST_REAL_MV="$REAL_MV" KZM_TEST_MV_LOG="$MV_LOG" \
KZM_TEST_REAL_CHMOD="$REAL_CHMOD" KZM_TEST_REAL_CP="$REAL_CP" \
KZM_TEST_CP_SLEEP_SUFFIX="/libexec/kzm/component-manager.sh" \
KZM_TEST_CP_SLEEP_MARKER="$SLEEP_MARKER" KZM_TEST_CP_SLEEP_SECONDS=3 \
sh "$PROJECT_DIR/install.sh" --root "$TEST_ROOT" >"$FIRST_LOG" 2>&1 &
first_pid=$!

lock_wait=0
while [ ! -f "$TEST_ROOT/opt/.kzm-install.lock/owner" ]; do
    lock_wait=$((lock_wait + 1))
    [ "$lock_wait" -lt 50 ] || fail "first installer did not acquire its lock"
    sleep_briefly
done
if sh "$PROJECT_DIR/install.sh" --root "$TEST_ROOT" >"$SECOND_LOG" 2>&1; then
    fail "concurrent installer unexpectedly succeeded"
fi
grep -q 'другая установка уже выполняется' "$SECOND_LOG" || fail "concurrent lock error was not reported"
wait "$first_pid" || fail "first concurrent installer did not complete"
assert_no_install_artifacts
assert_preserved_files
assert_absent "$SERVICE_MARKER"

echo "install-upgrade.sh: all tests passed"
