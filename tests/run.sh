#!/bin/sh

set -eu

PROJECT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=${TEST_ROOT:-/tmp/kzm-test-root}

case "$TEST_ROOT" in
    /tmp/kzm-test-root*) rm -rf "$TEST_ROOT" ;;
    *) echo "Unsafe TEST_ROOT: $TEST_ROOT" >&2; exit 1 ;;
esac

mkdir -p "$TEST_ROOT/opt/etc/nfqws" "$TEST_ROOT/opt/etc/init.d" "$TEST_ROOT/opt/usr/bin"
cp "$PROJECT_DIR/tests/fixtures/nfqws.conf" "$TEST_ROOT/opt/etc/nfqws/nfqws.conf"

cat > "$TEST_ROOT/opt/etc/init.d/S51nfqws" <<'EOF'
#!/bin/sh
case "$1" in
    status) echo "Service NFQWS is running" ;;
    restart) echo "fixture restart" >> "${KZM_ROOT:?}/restart.log" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/opt/etc/init.d/S51nfqws"

cat > "$TEST_ROOT/opt/usr/bin/nfqws" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TEST_ROOT/opt/usr/bin/nfqws"

sh "$PROJECT_DIR/install.sh" --root "$TEST_ROOT" >/dev/null

[ -x "$TEST_ROOT/opt/libexec/kzm/router-canary.sh" ]
[ -x "$TEST_ROOT/opt/libexec/kzm/router-canary-matrix.sh" ]
[ -x "$TEST_ROOT/opt/libexec/kzm/router-canary-suite.sh" ]
[ -f "$TEST_ROOT/opt/share/kzm/canary-pass.strategy" ]
[ -f "$TEST_ROOT/opt/share/kzm/test-targets.base.tsv" ]
release_version=$(sed -n '1p' "$PROJECT_DIR/VERSION")
component_version=$(sed -n 's/^KZM_VERSION="\([^"]*\)"$/\1/p' \
    "$PROJECT_DIR/src/libexec/kzm/component-manager.sh")
[ "$release_version" = "0.8.1" ]
[ "$(KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" version)" = "$release_version" ]
[ "$component_version" = "$release_version" ]
[ -x "$TEST_ROOT/opt/libexec/kzm/mediatek-gro-fix.sh" ]
[ -x "$TEST_ROOT/opt/etc/init.d/S50kzm-gro-fix" ]
[ -x "$TEST_ROOT/opt/etc/ndm/netfilter.d/090-kzm-gro-fix.sh" ]
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" test status | grep -q 'Canary inactive'
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" status | grep -q 'YouTube:.*QUIC выключен'
for youtube_app_domain in youtube.com googlevideo.com youtubei.googleapis.com youtubei-att.googleapis.com youtube.googleapis.com ytimg.com ggpht.com; do
    grep -qx "$youtube_app_domain" "$TEST_ROOT/opt/etc/kzapret-manager/lists/youtube.list"
done
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" doctor > "$TEST_ROOT/doctor-initial.txt" 2>&1 || true
grep -q 'OK  основные домены браузера и приложения YouTube' "$TEST_ROOT/doctor-initial.txt"

# Canary cleanup must never trust a reused numeric PID. These tests use a
# no-op iptables shim and real /proc identities; no firewall rule is changed.
CANARY_TEST_DIR="$TEST_ROOT/canary-ownership"
CANARY_MOCK_BIN="$CANARY_TEST_DIR/bin"
CANARY_TEST_STATE="$CANARY_TEST_DIR/canary.state"
CANARY_TEST_LOCK="$CANARY_TEST_DIR/canary.lock"
CANARY_TEST_PID="$CANARY_TEST_DIR/canary.pid"
CANARY_TEST_WATCHDOG_PID="$CANARY_TEST_DIR/watchdog.pid"
CANARY_TEST_RUN_ID=1700000000.4242
CANARY_SCRIPT_CANONICAL=$(readlink -f "$PROJECT_DIR/tests/router-canary.sh")
CANARY_STRATEGY_CANONICAL=$(readlink -f "$PROJECT_DIR/src/share/kzm/canary-pass.strategy")
mkdir -p "$CANARY_MOCK_BIN"
cat > "$CANARY_MOCK_BIN/iptables" <<'EOF'
#!/bin/sh
if [ -n "${CANARY_IPTABLES_LOG:-}" ]; then
    printf '%s\n' "$*" >> "$CANARY_IPTABLES_LOG"
fi
case " $* " in
    *' -t nat -C MIHOMO_REDIRECT '*|*' -t nat -C '*' MIHOMO_REDIRECT '*)
        [ -n "${CANARY_NAT_RULE_MARKER:-}" ] && [ -f "$CANARY_NAT_RULE_MARKER" ]
        ;;
    *' -t nat -D MIHOMO_REDIRECT '*|*' -t nat -D '*' MIHOMO_REDIRECT '*)
        [ -n "${CANARY_NAT_RULE_MARKER:-}" ] || exit 1
        [ "${CANARY_NAT_DELETE_FAIL:-0}" -eq 0 ] || exit 1
        rm -f "$CANARY_NAT_RULE_MARKER"
        ;;
    *' -C '*) exit 1 ;;
    *' -nL KZM_CANARY '*) exit 1 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$CANARY_MOCK_BIN/iptables"
cat > "$CANARY_MOCK_BIN/iptables-save" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$CANARY_MOCK_BIN/iptables-save"

canary_proc_starttime() {
    canary_test_stat=$(cat "/proc/$1/stat")
    canary_test_tail=${canary_test_stat##*) }
    # shellcheck disable=SC2086
    set -- $canary_test_tail
    printf '%s\n' "${20}"
}

write_canary_test_state() {
    canary_state_target=$1
    canary_state_exe=$2
    canary_state_pid=$3
    canary_state_started=$4
    canary_watchdog_pid=$5
    canary_watchdog_started=$6
    canary_watchdog_exe=$7
    canary_state_version=${8:-2}
    canary_protocol=${9:-udp}
    canary_mihomo_bypass=${10:-0}
    mkdir -p "$CANARY_TEST_LOCK"
    cat > "$canary_state_target" <<EOF
STATE_VERSION=$canary_state_version
RUN_ID=$CANARY_TEST_RUN_ID
NFQWS_BIN_CANONICAL=$canary_state_exe
WATCHDOG_SCRIPT=$CANARY_SCRIPT_CANONICAL
PID_FILE=$CANARY_TEST_PID
WATCHDOG_PID_FILE=$CANARY_TEST_WATCHDOG_PID
STRATEGY_FILE=$CANARY_STRATEGY_CANONICAL
TEST_LOCAL_IP=192.0.2.10
TEST_REMOTE_IP=0.0.0.0/0
TEST_PROTOCOL=$canary_protocol
TEST_PORTS=443
TEST_OUT_INTERFACE=eth0
QUEUE_NUM=301
TTL=120
CANARY_PID=$canary_state_pid
CANARY_STARTTIME=$canary_state_started
WATCHDOG_PID=$canary_watchdog_pid
WATCHDOG_STARTTIME=$canary_watchdog_started
WATCHDOG_EXE=$canary_watchdog_exe
EOF
    if [ "$canary_state_version" -eq 3 ]; then
        printf 'MIHOMO_BYPASS=%s\n' "$canary_mihomo_bypass" >> "$canary_state_target"
    fi
    chmod 600 "$canary_state_target"
}

run_canary_test_stop() {
    PATH="$CANARY_MOCK_BIN:$PATH" \
    CANARY_STATE_FILE="$CANARY_TEST_STATE" \
    CANARY_LOCK_DIR="$CANARY_TEST_LOCK" \
    CANARY_PID_FILE="$CANARY_TEST_PID" \
    CANARY_WATCHDOG_PID_FILE="$CANARY_TEST_WATCHDOG_PID" \
        "$PROJECT_DIR/tests/router-canary.sh" stop
}

# Both process records deliberately point at an unrelated live process. PID
# files are symlinks too: stop must neither follow them nor signal the PID.
sleep 300 &
canary_unrelated_pid=$!
canary_unrelated_started=$(canary_proc_starttime "$canary_unrelated_pid")
canary_unrelated_exe=$(readlink "/proc/$canary_unrelated_pid/exe")
printf 'do-not-touch\n' > "$CANARY_TEST_DIR/pid-target"
printf 'do-not-touch-watchdog\n' > "$CANARY_TEST_DIR/watchdog-target"
ln -s "$CANARY_TEST_DIR/pid-target" "$CANARY_TEST_PID"
ln -s "$CANARY_TEST_DIR/watchdog-target" "$CANARY_TEST_WATCHDOG_PID"
write_canary_test_state "$CANARY_TEST_STATE" /bin/false \
    "$canary_unrelated_pid" "$canary_unrelated_started" \
    "$canary_unrelated_pid" "$canary_unrelated_started" "$canary_unrelated_exe"
run_canary_test_stop >/dev/null
kill -0 "$canary_unrelated_pid"
[ "$(cat "$CANARY_TEST_DIR/pid-target")" = do-not-touch ]
[ "$(cat "$CANARY_TEST_DIR/watchdog-target")" = do-not-touch-watchdog ]
[ ! -e "$CANARY_TEST_PID" ] && [ ! -L "$CANARY_TEST_PID" ]
[ ! -e "$CANARY_TEST_WATCHDOG_PID" ] && [ ! -L "$CANARY_TEST_WATCHDOG_PID" ]
kill "$canary_unrelated_pid"
wait "$canary_unrelated_pid" 2>/dev/null || true

# A concurrent stop waits for the bounded start barrier instead of racing a
# starter between state creation and daemon/watchdog registration.
sleep 2 &
canary_starter_pid=$!
canary_starter_started=$(canary_proc_starttime "$canary_starter_pid")
sleep 300 &
canary_barrier_guard_pid=$!
canary_barrier_guard_started=$(canary_proc_starttime "$canary_barrier_guard_pid")
: > "$CANARY_TEST_PID"
: > "$CANARY_TEST_WATCHDOG_PID"
chmod 600 "$CANARY_TEST_PID" "$CANARY_TEST_WATCHDOG_PID"
write_canary_test_state "$CANARY_TEST_STATE" /bin/false \
    "$canary_barrier_guard_pid" "$canary_barrier_guard_started" '' '' ''
printf '%s %s\n' "$canary_starter_pid" "$canary_starter_started" > "$CANARY_TEST_LOCK/start.owner"
chmod 600 "$CANARY_TEST_LOCK/start.owner"
run_canary_test_stop >/dev/null
wait "$canary_starter_pid" 2>/dev/null || true
kill -0 "$canary_barrier_guard_pid"
kill "$canary_barrier_guard_pid"
wait "$canary_barrier_guard_pid" 2>/dev/null || true

# The same executable and canary-looking argv still are not owned when the
# recorded starttime differs; this models exact numeric PID reuse.
canary_shell_exe=$(readlink -f /bin/sh)
/bin/sh -c 'trap "" TERM; while :; do :; done' canary-reused \
    "--pidfile=$CANARY_TEST_PID" --qnum=301 &
canary_reused_pid=$!
canary_reused_started=$(canary_proc_starttime "$canary_reused_pid")
canary_wrong_started=$((canary_reused_started + 1))
printf '%s\n' "$canary_reused_pid" > "$CANARY_TEST_PID"
: > "$CANARY_TEST_WATCHDOG_PID"
write_canary_test_state "$CANARY_TEST_STATE" "$canary_shell_exe" \
    "$canary_reused_pid" "$canary_wrong_started" '' '' ''
run_canary_test_stop >/dev/null
kill -0 "$canary_reused_pid"
kill -KILL "$canary_reused_pid"
wait "$canary_reused_pid" 2>/dev/null || true

# An exact orphan without a usable pid record is found by executable + unique
# queue/pidfile signature. It ignores TERM, exercising the bounded KILL path.
/bin/sh -c 'trap "" TERM; while :; do :; done' canary-orphan \
    "--pidfile=$CANARY_TEST_PID" --qnum=301 &
canary_orphan_pid=$!
printf 'invalid\n' > "$CANARY_TEST_PID"
: > "$CANARY_TEST_WATCHDOG_PID"
write_canary_test_state "$CANARY_TEST_STATE" "$canary_shell_exe" '' '' '' '' ''
run_canary_test_stop >/dev/null
wait "$canary_orphan_pid" 2>/dev/null || true
if kill -0 "$canary_orphan_pid" 2>/dev/null; then
    echo "Exact orphan canary process survived cleanup" >&2
    exit 1
fi

# A symlinked state is never sourced or trusted, and therefore cannot trigger
# a signal or firewall operation.
sleep 300 &
canary_state_guard_pid=$!
canary_state_guard_started=$(canary_proc_starttime "$canary_state_guard_pid")
write_canary_test_state "$CANARY_TEST_DIR/state-target" /bin/false \
    "$canary_state_guard_pid" "$canary_state_guard_started" '' '' ''
ln -s "$CANARY_TEST_DIR/state-target" "$CANARY_TEST_STATE"
if run_canary_test_stop > "$CANARY_TEST_DIR/unsafe-state.out" 2>&1; then
    echo "Symlinked canary state was accepted" >&2
    exit 1
fi
grep -q 'unsafe state; no PID was signalled and no rule was changed' "$CANARY_TEST_DIR/unsafe-state.out"
kill -0 "$canary_state_guard_pid"
kill "$canary_state_guard_pid"
wait "$canary_state_guard_pid" 2>/dev/null || true
rm -f "$CANARY_TEST_STATE" "$CANARY_TEST_DIR/state-target"

# A regular state that is not owner-only is also untrusted.
sleep 300 &
canary_mode_guard_pid=$!
canary_mode_guard_started=$(canary_proc_starttime "$canary_mode_guard_pid")
write_canary_test_state "$CANARY_TEST_STATE" /bin/false \
    "$canary_mode_guard_pid" "$canary_mode_guard_started" '' '' ''
chmod 644 "$CANARY_TEST_STATE"
if run_canary_test_stop > "$CANARY_TEST_DIR/unsafe-mode.out" 2>&1; then
    echo "Group/world-readable canary state was accepted" >&2
    exit 1
fi
kill -0 "$canary_mode_guard_pid"
kill "$canary_mode_guard_pid"
wait "$canary_mode_guard_pid" 2>/dev/null || true
rm -f "$CANARY_TEST_STATE"
rm -rf "$CANARY_TEST_LOCK"

# A TCP live-canary may opt in to bypassing only Mihomo's transparent
# REDIRECT. Stop removes the exact per-client RETURN first and never flushes
# or deletes Mihomo's production chain. Version-2 state remains readable and
# never attempts a NAT change.
CANARY_IPTABLES_LOG="$CANARY_TEST_DIR/iptables.log"
CANARY_NAT_RULE_MARKER="$CANARY_TEST_DIR/mihomo-rule.present"
export CANARY_IPTABLES_LOG CANARY_NAT_RULE_MARKER
: > "$CANARY_IPTABLES_LOG"
: > "$CANARY_NAT_RULE_MARKER"
: > "$CANARY_TEST_PID"
: > "$CANARY_TEST_WATCHDOG_PID"
chmod 600 "$CANARY_TEST_PID" "$CANARY_TEST_WATCHDOG_PID"
write_canary_test_state "$CANARY_TEST_STATE" /bin/false '' '' '' '' '' 3 tcp 1
run_canary_test_stop >/dev/null
[ ! -e "$CANARY_NAT_RULE_MARKER" ]
grep -q -- '-t nat -C MIHOMO_REDIRECT -s 192.0.2.10 -d 0.0.0.0/0 -p tcp --dport 443 -j RETURN' "$CANARY_IPTABLES_LOG"
grep -q -- '-t nat -D MIHOMO_REDIRECT -s 192.0.2.10 -d 0.0.0.0/0 -p tcp --dport 443 -j RETURN' "$CANARY_IPTABLES_LOG"
if grep -Eq -- '-t nat -(F|X) MIHOMO_REDIRECT' "$CANARY_IPTABLES_LOG"; then
    echo "Canary modified the production Mihomo chain itself" >&2
    exit 1
fi
nat_delete_line=$(grep -n -- '-t nat -D MIHOMO_REDIRECT' "$CANARY_IPTABLES_LOG" | head -n 1 | cut -d: -f1)
mangle_delete_line=$(grep -n -- '-t mangle -D POSTROUTING' "$CANARY_IPTABLES_LOG" | head -n 1 | cut -d: -f1)
[ -n "$nat_delete_line" ] && [ -n "$mangle_delete_line" ] && [ "$nat_delete_line" -lt "$mangle_delete_line" ]

# A firewall deletion error is fail-closed: state and the marker stay in
# place, so an explicit retry can finish cleanup instead of losing ownership.
: > "$CANARY_IPTABLES_LOG"
: > "$CANARY_NAT_RULE_MARKER"
: > "$CANARY_TEST_PID"
: > "$CANARY_TEST_WATCHDOG_PID"
chmod 600 "$CANARY_TEST_PID" "$CANARY_TEST_WATCHDOG_PID"
write_canary_test_state "$CANARY_TEST_STATE" /bin/false '' '' '' '' '' 3 tcp 1
export CANARY_NAT_DELETE_FAIL=1
if run_canary_test_stop > "$CANARY_TEST_DIR/nat-delete-failure.out" 2>&1; then
    echo "Canary discarded state after a failed Mihomo bypass deletion" >&2
    exit 1
fi
[ -e "$CANARY_NAT_RULE_MARKER" ]
[ -e "$CANARY_TEST_STATE" ]
grep -q 'cleanup is incomplete; state retained' "$CANARY_TEST_DIR/nat-delete-failure.out"
unset CANARY_NAT_DELETE_FAIL
run_canary_test_stop >/dev/null
[ ! -e "$CANARY_NAT_RULE_MARKER" ]
[ ! -e "$CANARY_TEST_STATE" ]

# The watchdog also owns the same cleanup path. With no exact canary daemon
# left, it detects the failed run and restores Mihomo automatically.
: > "$CANARY_IPTABLES_LOG"
: > "$CANARY_NAT_RULE_MARKER"
: > "$CANARY_TEST_PID"
: > "$CANARY_TEST_WATCHDOG_PID"
chmod 600 "$CANARY_TEST_PID" "$CANARY_TEST_WATCHDOG_PID"
PATH="$CANARY_MOCK_BIN:$PATH" \
CANARY_STATE_FILE="$CANARY_TEST_STATE" \
CANARY_LOCK_DIR="$CANARY_TEST_LOCK" \
CANARY_PID_FILE="$CANARY_TEST_PID" \
CANARY_WATCHDOG_PID_FILE="$CANARY_TEST_WATCHDOG_PID" \
    "$CANARY_SCRIPT_CANONICAL" watchdog 120 "$CANARY_TEST_RUN_ID" &
canary_nat_watchdog_pid=$!
canary_nat_watchdog_started=$(canary_proc_starttime "$canary_nat_watchdog_pid")
canary_nat_watchdog_exe=$(readlink "/proc/$canary_nat_watchdog_pid/exe")
write_canary_test_state "$CANARY_TEST_STATE" /bin/false '' '' \
    "$canary_nat_watchdog_pid" "$canary_nat_watchdog_started" \
    "$canary_nat_watchdog_exe" 3 tcp 1
printf '%s %s %s\n' "$canary_nat_watchdog_pid" "$canary_nat_watchdog_started" \
    "$canary_nat_watchdog_exe" > "$CANARY_TEST_WATCHDOG_PID"
chmod 600 "$CANARY_TEST_WATCHDOG_PID"
wait "$canary_nat_watchdog_pid"
[ ! -e "$CANARY_NAT_RULE_MARKER" ]
[ ! -e "$CANARY_TEST_STATE" ]
grep -q -- '-t nat -D MIHOMO_REDIRECT -s 192.0.2.10 -d 0.0.0.0/0 -p tcp --dport 443 -j RETURN' "$CANARY_IPTABLES_LOG"

# The opt-in is fail-closed for UDP and does not get as far as any firewall
# command, protecting voice/QUIC canaries from an accidental TCP-only bypass.
: > "$CANARY_IPTABLES_LOG"
if PATH="$CANARY_MOCK_BIN:$PATH" \
    NFQWS_BIN=/bin/false \
    STRATEGY_FILE="$CANARY_STRATEGY_CANONICAL" \
    TEST_LOCAL_IP=192.0.2.10 \
    TEST_REMOTE_IP=0.0.0.0/0 \
    TEST_PROTOCOL=udp \
    TEST_PORT=443 \
    TEST_OUT_INTERFACE=eth0 \
    CANARY_MIHOMO_BYPASS=1 \
    CANARY_STATE_FILE="$CANARY_TEST_STATE" \
    CANARY_LOCK_DIR="$CANARY_TEST_LOCK" \
        "$PROJECT_DIR/tests/router-canary.sh" start > "$CANARY_TEST_DIR/udp-bypass.out" 2>&1; then
    echo "Mihomo TCP bypass was accepted for a UDP canary" >&2
    exit 1
fi
grep -q 'supported only for TCP canaries' "$CANARY_TEST_DIR/udp-bypass.out"
[ ! -s "$CANARY_IPTABLES_LOG" ]
unset CANARY_IPTABLES_LOG CANARY_NAT_RULE_MARKER
rm -rf "$CANARY_TEST_LOCK"

# The legacy Zapret-menu tests below exercise that submenu directly.  The
# production default is now the parent component menu and is covered by
# tests/components.sh.
export KZM_DEFAULT_COMMAND=zapret

printf '\n' | KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" > "$TEST_ROOT/main-menu.txt"
grep -q 'Меню стратегий' "$TEST_ROOT/main-menu.txt"
grep -q 'Меню тестирования стратегий' "$TEST_ROOT/main-menu.txt"
grep -q 'Применить выбранные настройки' "$TEST_ROOT/main-menu.txt"
grep -q 'Мои сайты и IP/подсети' "$TEST_ROOT/main-menu.txt"

printf '1\n\n\n' | KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" > "$TEST_ROOT/strategy-menu.txt"
grep -q 'область действия' "$TEST_ROOT/strategy-menu.txt"
grep -q 'Настроить Discord' "$TEST_ROOT/strategy-menu.txt"

printf '3\n\n\n' | KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" > "$TEST_ROOT/test-menu.txt"
grep -q 'Проверить текущую стратегию на полном списке' "$TEST_ROOT/test-menu.txt"
grep -q 'Найти лучшую стратегию v + Flowseal' "$TEST_ROOT/test-menu.txt"
grep -q 'Live-тест YouTube на телефоне: TCP-профиль или QUIC' "$TEST_ROOT/test-menu.txt"

cat > "$TEST_ROOT/opt/etc/kzapret-manager/kzm.conf" <<EOF
GENERAL_URL="file://$PROJECT_DIR/tests/fixtures/Strategies.md"
YOUTUBE_URL="file://$PROJECT_DIR/tests/fixtures/StrYoutube"
DISCORD_URL="file://$PROJECT_DIR/tests/fixtures/Zapret-Manager.sh"
DISCORD_STUN4ALL_URL="file://$PROJECT_DIR/tests/fixtures/50-stun4all"
DISCORD_QUIC4ALL_URL="file://$PROJECT_DIR/tests/fixtures/50-quic4all"
DISCORD_MEDIA_SCRIPT_URL="file://$PROJECT_DIR/tests/fixtures/50-discord-media"
DISCORD_LEGACY_SCRIPT_URL="file://$PROJECT_DIR/tests/fixtures/50-discord"
EXCLUDE_URL="file://$PROJECT_DIR/tests/fixtures/exclude.list"
FLOWSEAL_SOURCE_DIR="$PROJECT_DIR/tests/fixtures/flowseal"
TEST_SUITE_V2_URL="file://$PROJECT_DIR/tests/fixtures/suite.v2.json"
BOLVAN_FAKE_BASE_URL="file://$PROJECT_DIR/tests/fixtures/fake"
FLOWSEAL_FAKE_BASE_URL="file://$PROJECT_DIR/tests/fixtures/fake"
MIN_FULL_TEST_TARGETS=24
BACKUP_KEEP=3
EOF

mkdir -p "$TEST_ROOT/opt/etc/kzapret-manager/fake"
printf 'fake' > "$TEST_ROOT/opt/etc/kzapret-manager/fake/stun.bin"
printf 'fake' > "$TEST_ROOT/opt/etc/kzapret-manager/fake/tls_clienthello_www_google_com.bin"
printf 'fake' > "$TEST_ROOT/opt/etc/kzapret-manager/fake/quic_initial_www_google_com.bin"
printf 'fake' > "$TEST_ROOT/opt/etc/kzapret-manager/fake/tls_clienthello_4pda_to.bin"

KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" update >/tmp/kzm-test-update.log

[ -f "$TEST_ROOT/opt/etc/kzapret-manager/strategies/general/v7.strategy" ]
[ -f "$TEST_ROOT/opt/etc/kzapret-manager/strategies/flowseal/general.strategy" ]
[ -f "$TEST_ROOT/opt/etc/kzapret-manager/strategies/flowseal/general_ALT7.strategy" ]
[ ! -f "$TEST_ROOT/opt/etc/kzapret-manager/strategies/flowseal/general_ALT5.strategy" ]
[ "$(awk 'END { print NR+0 }' "$TEST_ROOT/opt/etc/kzapret-manager/lists/test-targets.tsv")" -eq 25 ]
[ -f "$TEST_ROOT/opt/etc/kzapret-manager/strategies/youtube/Yv08.strategy" ]
[ -f "$TEST_ROOT/opt/etc/kzapret-manager/strategies/extras/discord-voice.strategy" ]
[ -f "$TEST_ROOT/opt/etc/kzapret-manager/strategies/discord/Dv1.strategy" ]
[ -f "$TEST_ROOT/opt/etc/kzapret-manager/strategies/discord/Dv2.strategy" ]
[ -f "$TEST_ROOT/opt/etc/kzapret-manager/strategies/discord-scripts/sources.tsv" ]
grep -q '^50-discord-media|.*|native-alias|' "$TEST_ROOT/opt/etc/kzapret-manager/strategies/discord-scripts/sources.tsv"
[ ! -e "$TEST_ROOT/opt/etc/kzapret-manager/strategies/discord-scripts/50-stun4all.strategy" ]
[ ! -e "$TEST_ROOT/opt/etc/kzapret-manager/strategies/discord-scripts/50-discord.strategy" ]
[ -f "$TEST_ROOT/opt/etc/kzapret-manager/strategies/extras/game.strategy" ]

# A phone-only YouTube test must never default to the SSH computer address.
# Select Yv08 numerically, then leave the phone prompt empty so canary is not started.
mkdir -p "$TEST_ROOT/opt/etc/kzapret-manager/tools"
cp "$TEST_ROOT/opt/usr/bin/nfqws" "$TEST_ROOT/opt/etc/kzapret-manager/tools/nfqws"
chmod +x "$TEST_ROOT/opt/etc/kzapret-manager/tools/nfqws"
printf '3\n5\n1\n2\n\n\n\n\n' | SSH_CLIENT='192.0.2.55 2222 22' KZM_ROOT="$TEST_ROOT" \
    "$TEST_ROOT/opt/bin/kzm" > "$TEST_ROOT/youtube-phone-canary-menu.txt"
grep -q 'Проверить TCP-профиль YvNN' "$TEST_ROOT/youtube-phone-canary-menu.txt"
grep -q '1) Yv01' "$TEST_ROOT/youtube-phone-canary-menu.txt"
grep -q '2) Yv08' "$TEST_ROOT/youtube-phone-canary-menu.txt"
grep -q 'Нужен IPv4 телефона.*не IP компьютера с SSH' "$TEST_ROOT/youtube-phone-canary-menu.txt"
grep -q 'IPv4 телефона (Wi-Fi):' "$TEST_ROOT/youtube-phone-canary-menu.txt"
if grep -Fq 'IPv4 тестового устройства [192.0.2.55]' "$TEST_ROOT/youtube-phone-canary-menu.txt"; then
    echo "YouTube phone canary offered the SSH client IP" >&2
    exit 1
fi

general_menu_count=$(find "$TEST_ROOT/opt/etc/kzapret-manager/strategies/general" -type f -name 'v*.strategy' | awk 'END { print NR+0 }')
flow_alt_line=$(awk -F'|' '$1 == "general_ALT7" { print NR; exit }' "$TEST_ROOT/opt/etc/kzapret-manager/strategies/flowseal/index.tsv")
flow_alt_choice=$((general_menu_count + flow_alt_line))
printf '1\n1\nabc\n%s\n\n\n' "$flow_alt_choice" | KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" > "$TEST_ROOT/general-numbered-menu.txt"
grep -q 'Введите номер из списка' "$TEST_ROOT/general-numbered-menu.txt"
grep -q '^GENERAL_PROFILE=flow:general_ALT7$' "$TEST_ROOT/opt/etc/kzapret-manager/state.conf"

printf '1\n2\n1\n\n\n' | KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" > "$TEST_ROOT/youtube-off-menu.txt"
grep -q '^YOUTUBE_PROFILE=off$' "$TEST_ROOT/opt/etc/kzapret-manager/state.conf"
grep -q 'Включить обход YouTube QUIC' "$TEST_ROOT/youtube-off-menu.txt"
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" strategy set quic on >/dev/null
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" status | grep -q 'YouTube:.*TCP выключен; обход QUIC включён'
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" strategy set quic off >/dev/null
printf '1\n2\n3\n\n\n' | KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" > "$TEST_ROOT/youtube-numbered-menu.txt"
grep -q '^YOUTUBE_PROFILE=Yv08$' "$TEST_ROOT/opt/etc/kzapret-manager/state.conf"

printf '1\n3\n7\n3\n\n\n\n' | KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" > "$TEST_ROOT/discord-numbered-menu.txt"
grep -q '^DISCORD_MEDIA_PROFILE=Dv2$' "$TEST_ROOT/opt/etc/kzapret-manager/state.conf"
grep -q 'Меню настройки Discord' "$TEST_ROOT/discord-numbered-menu.txt"
grep -q '8) Меню выбора fake для discord,stun' "$TEST_ROOT/discord-numbered-menu.txt"
grep -q '9) Включить базовый обход Discord' "$TEST_ROOT/discord-numbered-menu.txt"

printf '1\n3\n1\n\n\n\n' | KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" > "$TEST_ROOT/discord-unsupported-menu.txt"
grep -q 'безопасный эквивалент без второй службы отсутствует' "$TEST_ROOT/discord-unsupported-menu.txt"
grep -q '^DISCORD_SCRIPT=off$' "$TEST_ROOT/opt/etc/kzapret-manager/state.conf"

printf '1\n3\n3\n1\n\n\n\n' | KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" > "$TEST_ROOT/discord-media-alias-menu.txt"
grep -q '^DISCORD_SCRIPT=50-discord-media$' "$TEST_ROOT/opt/etc/kzapret-manager/state.conf"
grep -q '^DISCORD_ENABLED=1$' "$TEST_ROOT/opt/etc/kzapret-manager/state.conf"

printf '1\n3\n8\n0\n\n\n\n' | KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" > "$TEST_ROOT/discord-fake-menu.txt"
grep -q '9) quic_initial_rutube_ru.bin' "$TEST_ROOT/discord-fake-menu.txt"
grep -q '^DISCORD_FAKE=off$' "$TEST_ROOT/opt/etc/kzapret-manager/state.conf"
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" strategy set discord-fake quic_initial_steamcommunity_com.bin >/dev/null
[ -s "$TEST_ROOT/opt/etc/kzapret-manager/fake/quic_initial_steamcommunity_com.bin" ]
grep -q '^DISCORD_FAKE=quic_initial_steamcommunity_com.bin$' "$TEST_ROOT/opt/etc/kzapret-manager/state.conf"
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" strategy set discord-fake stun.bin >/dev/null

if KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" strategy set discord-script 50-quic4all >/dev/null 2>&1; then
    echo "Unsafe 50-quic4all mapping was accepted" >&2
    exit 1
fi
grep -q '^DISCORD_SCRIPT=50-discord-media$' "$TEST_ROOT/opt/etc/kzapret-manager/state.conf"

printf '1\n3\n9\n\n\n\n' | KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" > "$TEST_ROOT/discord-toggle-menu.txt"
grep -q '^DISCORD_ENABLED=0$' "$TEST_ROOT/opt/etc/kzapret-manager/state.conf"
grep -q '^DISCORD_SCRIPT=off$' "$TEST_ROOT/opt/etc/kzapret-manager/state.conf"

KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" strategy set general flow:general_ALT7 >/dev/null
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" preview | grep -q -- '--dpi-desync-split-pos=2,sniext+1'
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" strategy set general v7 >/dev/null

KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" strategy set discord on >/dev/null
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" strategy set discord-media Dv2 >/dev/null
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" strategy set quic on >/dev/null
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" strategy set game on >/dev/null
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" preview > "$TEST_ROOT/preview.txt"

grep -q -- '--hostlist=.*/youtube.list' "$TEST_ROOT/preview.txt"
grep -q -- '--hostlist-exclude=.*/exclude.list' "$TEST_ROOT/preview.txt"
grep -q -- '--filter-l7=discord,stun' "$TEST_ROOT/preview.txt"
grep -q -- '--dpi-desync-fake-discord=.*/stun.bin' "$TEST_ROOT/preview.txt"
grep -q -- '--dpi-desync-fake-stun=.*/stun.bin' "$TEST_ROOT/preview.txt"
[ "$(grep -c -- '--filter-l7=discord,stun' "$TEST_ROOT/preview.txt")" -eq 1 ]
grep -q -- '--hostlist-domains=discord.media' "$TEST_ROOT/preview.txt"
grep -q -- '--dpi-desync-repeats=8' "$TEST_ROOT/preview.txt"
grep -q -- '--filter-udp=443' "$TEST_ROOT/preview.txt"
grep -q -- '--dpi-desync-fake-quic=.*/quic_initial_www_google_com.bin' "$TEST_ROOT/preview.txt"
grep -q -- '--filter-udp=1024-65535' "$TEST_ROOT/preview.txt"

KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" apply >/tmp/kzm-test-apply.log
[ ! -f "$TEST_ROOT/restart.log" ]
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" status | grep -q 'конфиг записан, перезапуск не подтверждён'
grep -q '^NFQWS_ARGS_CUSTOM=".*--filter-tcp=443' "$TEST_ROOT/opt/etc/nfqws/nfqws.conf"
grep -q '^TCP_PORTS="443,2053,2083,2087,2096,8443"' "$TEST_ROOT/opt/etc/nfqws/nfqws.conf"
grep -q '^UDP_PORTS="443,19294:19344,50000:50100,1024:65535"' "$TEST_ROOT/opt/etc/nfqws/nfqws.conf"
grep -q '^ISP_INTERFACE="ppp0"' "$TEST_ROOT/opt/etc/nfqws/nfqws.conf"

KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" service restart --yes >/dev/null
[ -f "$TEST_ROOT/restart.log" ]
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" status | grep -q 'Настройки:   применена'

mkdir -p "$TEST_ROOT/opt/var/log"
printf 'mihomo-log' > "$TEST_ROOT/opt/var/log/mihomo.log"
printf 'old-log' > "$TEST_ROOT/opt/var/log/mihomo.log.1"
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" storage status | grep -q 'Безопасно очищаемые журналы'
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" storage cleanup --yes >/dev/null
[ ! -s "$TEST_ROOT/opt/var/log/mihomo.log" ]
[ ! -e "$TEST_ROOT/opt/var/log/mihomo.log.1" ]

cat > "$TEST_ROOT/opt/etc/kzapret-manager/results/last-strategy-test.csv" <<'EOF'
strategy_id|strategy_label|target|ok|curl_rc|http_code|bytes|seconds|queue_packets
control|без обхода|blocked.example|0|28|000|0|7.0|4
control|без обхода|open.example|1|0|200|100|0.2|4
v7|v7|blocked.example|1|0|200|100|0.3|8
v7|v7|open.example|1|0|200|100|0.2|8
v8|v8|blocked.example|1|0|200|100|0.4|7
v8|v8|open.example|0|28|000|0|7.0|7
EOF
printf 'fixture test; 2026-08-26 12:00:00\n' > "$TEST_ROOT/opt/etc/kzapret-manager/results/last-strategy-test.meta"
printf '3\n8\n\n\n' | KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" > "$TEST_ROOT/result-menu.txt"
grep -q 'Контроль без обхода: 1/2' "$TEST_ROOT/result-menu.txt"
grep -q 'v7.*+1/-0.*ПОДХОДИТ' "$TEST_ROOT/result-menu.txt"
grep -q 'v8.*+1/-1.*С КОМПРОМИССОМ' "$TEST_ROOT/result-menu.txt"
grep -q 'FAIL не всегда означает блокировку' "$TEST_ROOT/result-menu.txt"
v8_summary_line=$(grep -n 'v8.*1/2.*+1/-1' "$TEST_ROOT/result-menu.txt" | head -n 1 | cut -d: -f1)
v7_summary_line=$(grep -n 'v7.*2/2.*+1/-0' "$TEST_ROOT/result-menu.txt" | head -n 1 | cut -d: -f1)
[ -n "$v8_summary_line" ] && [ -n "$v7_summary_line" ] && [ "$v8_summary_line" -lt "$v7_summary_line" ]

KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" domain add 'https://Example.org/path' sub.example.net >/dev/null
grep -qx 'example.org' "$TEST_ROOT/opt/etc/kzapret-manager/lists/user.list"
grep -qx 'sub.example.net' "$TEST_ROOT/opt/etc/kzapret-manager/lists/user.list"

if KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" domain add keep.example bad..example >/dev/null 2>&1; then
    echo "Invalid domain was accepted" >&2
    exit 1
fi
if grep -qx 'keep.example' "$TEST_ROOT/opt/etc/kzapret-manager/lists/user.list"; then
    echo "Domain batch was not atomic" >&2
    exit 1
fi

KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" network add \
    192.0.2.10 198.51.100.0/24 2001:DB8::1 2001:db8:abcd::/48 >/dev/null
grep -qx '192.0.2.10' "$TEST_ROOT/opt/etc/kzapret-manager/lists/user-ipset.list"
grep -qx '198.51.100.0/24' "$TEST_ROOT/opt/etc/kzapret-manager/lists/user-ipset.list"
grep -qx '2001:db8::1' "$TEST_ROOT/opt/etc/kzapret-manager/lists/user-ipset.list"
grep -qx '2001:db8:abcd::/48' "$TEST_ROOT/opt/etc/kzapret-manager/lists/user-ipset.list"

for invalid_network in 256.1.1.1 192.0.2.1/33 2001:db8::1/129 2001::db8::1 1.2.3.4/; do
    if KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" network add "$invalid_network" >/dev/null 2>&1; then
        echo "Invalid network was accepted: $invalid_network" >&2
        exit 1
    fi
done
if KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" network add 203.0.113.7 not-an-ip >/dev/null 2>&1; then
    echo "Partially invalid network batch was accepted" >&2
    exit 1
fi
if grep -qx '203.0.113.7' "$TEST_ROOT/opt/etc/kzapret-manager/lists/user-ipset.list"; then
    echo "Network batch was not atomic" >&2
    exit 1
fi

KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" strategy set scope list >/dev/null
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" preview > "$TEST_ROOT/scoped-preview.txt"
grep -q -- "--hostlist=$TEST_ROOT/opt/etc/kzapret-manager/lists/user.list" "$TEST_ROOT/scoped-preview.txt"
grep -q -- "--ipset=$TEST_ROOT/opt/etc/kzapret-manager/lists/user-ipset.list" "$TEST_ROOT/scoped-preview.txt"
grep -q -- '--ipset-ip=0.0.0.0' "$TEST_ROOT/scoped-preview.txt"
awk \
    -v host="--hostlist=$TEST_ROOT/opt/etc/kzapret-manager/lists/user.list" \
    -v ipset="--ipset=$TEST_ROOT/opt/etc/kzapret-manager/lists/user-ipset.list" '
    function finish() { if (has_host && has_ipset) bad=1; has_host=0; has_ipset=0 }
    $0 == "--new" { finish(); next }
    $0 == host { has_host=1 }
    $0 == ipset { has_ipset=1 }
    END { finish(); exit bad ? 1 : 0 }
' "$TEST_ROOT/scoped-preview.txt"

KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" strategy set scope auto >/dev/null
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" preview > "$TEST_ROOT/auto-preview.txt"
grep -q -- "--hostlist-auto=$TEST_ROOT/opt/etc/kzapret-manager/lists/auto.list" "$TEST_ROOT/auto-preview.txt"
grep -q -- "--ipset=$TEST_ROOT/opt/etc/kzapret-manager/lists/user-ipset.list" "$TEST_ROOT/auto-preview.txt"

printf '2\n4\n2\n\n\n' | KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" > "$TEST_ROOT/target-numbered-menu.txt"
grep -q '\[домен\] example.org' "$TEST_ROOT/target-numbered-menu.txt"
if grep -qx 'sub.example.net' "$TEST_ROOT/opt/etc/kzapret-manager/lists/user.list"; then
    echo "Numbered target removal selected the wrong entry" >&2
    exit 1
fi

KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" domain remove example.org >/dev/null
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" strategy set scope list >/dev/null
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" preview > "$TEST_ROOT/network-only-preview.txt"
if grep -q -- "--hostlist=$TEST_ROOT/opt/etc/kzapret-manager/lists/user.list" "$TEST_ROOT/network-only-preview.txt"; then
    echo "Network-only scope unexpectedly contains a user hostlist" >&2
    exit 1
fi
grep -q -- "--ipset=$TEST_ROOT/opt/etc/kzapret-manager/lists/user-ipset.list" "$TEST_ROOT/network-only-preview.txt"

KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" domain add example.org >/dev/null
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" strategy set scope all >/dev/null
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" preview > "$TEST_ROOT/all-preview.txt"
if grep -q -- "--ipset=$TEST_ROOT/opt/etc/kzapret-manager/lists/user-ipset.list" "$TEST_ROOT/all-preview.txt"; then
    echo "All-traffic scope unexpectedly contains a user ipset" >&2
    exit 1
fi
KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" strategy set scope list >/dev/null

if KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" strategy import evil "$PROJECT_DIR/tests/fixtures/evil.strategy" >/dev/null 2>&1; then
    echo "Unsafe strategy was accepted" >&2
    exit 1
fi

touch "$TEST_ROOT/opt/etc/init.d/S51nfqws2"
printf '5\n\n' | KZM_ROOT="$TEST_ROOT" "$TEST_ROOT/opt/bin/kzm" > "$TEST_ROOT/nfqws2-menu.txt"
grep -q 'KZM не будет автоматически заменять движок' "$TEST_ROOT/nfqws2-menu.txt"

cat > "$TEST_ROOT/mock-canary.sh" <<'EOF'
#!/bin/sh
case "$1" in
    start)
        if [ -n "${KZM_CANARY_CAPTURE:-}" ]; then
            {
                printf 'command=start\n'
                printf 'strategy=%s\n' "${STRATEGY_FILE:-}"
                printf 'local=%s\n' "${TEST_LOCAL_IP:-}"
                printf 'remote=%s\n' "${TEST_REMOTE_IP:-}"
                printf 'protocol=%s\n' "${TEST_PROTOCOL:-}"
                printf 'ports=%s\n' "${TEST_PORTS:-}"
                printf 'queue=%s\n' "${QUEUE_NUM:-}"
                printf 'ttl=%s\n' "${TTL:-}"
                printf 'mihomo_bypass=%s\n' "${CANARY_MIHOMO_BYPASS:-unset}"
            } > "$KZM_CANARY_CAPTURE"
        fi
        exit 0
        ;;
    stop|status) exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/mock-canary.sh"
mkdir -p "$TEST_ROOT/mock-live-libexec"
cp "$TEST_ROOT/mock-canary.sh" "$TEST_ROOT/mock-live-libexec/router-canary.sh"
KZM_LIBEXEC="$TEST_ROOT/mock-live-libexec" KZM_ROOT="$TEST_ROOT" \
    "$TEST_ROOT/opt/bin/kzm" test status > "$TEST_ROOT/live-status-hint.txt"
grep -q 'pkts > 0.*IPv4-трафик' "$TEST_ROOT/live-status-hint.txt"
grep -q 'Автооткат.*kzm test stop' "$TEST_ROOT/live-status-hint.txt"

# The YouTube TCP live test passes only one client/TCP profile to the isolated
# canary, requests the optional exact Mihomo bypass only for detected topology,
# and never writes the production nfqws config or invokes its init script.
mkdir -p "$TEST_ROOT/mock-live-bin"
mkdir -p "$TEST_ROOT/mock-proc/net/netfilter"
: > "$TEST_ROOT/mock-proc/net/netfilter/nfnetlink_queue"
export KZM_PROC_ROOT="$TEST_ROOT/mock-proc"
cat > "$TEST_ROOT/mock-live-bin/iptables" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TEST_ROOT/mock-live-bin/iptables"
cp "$TEST_ROOT/opt/etc/nfqws/nfqws.conf" "$TEST_ROOT/nfqws-before-youtube-live.conf"
rm -f "$TEST_ROOT/restart.log" "$TEST_ROOT/youtube-live.capture"
PATH="$TEST_ROOT/mock-live-bin:$PATH" \
KZM_TEST_MIHOMO_TRANSPARENT=1 \
KZM_CANARY_CAPTURE="$TEST_ROOT/youtube-live.capture" \
KZM_LIBEXEC="$TEST_ROOT/mock-live-libexec" \
KZM_ROOT="$TEST_ROOT" \
    "$TEST_ROOT/opt/bin/kzm" test youtube start 192.0.2.108 Yv08 90 \
    > "$TEST_ROOT/youtube-live-output.txt"
grep -q 'Обнаружен прозрачный Mihomo' "$TEST_ROOT/youtube-live-output.txt"
grep -q 'без apply/restart' "$TEST_ROOT/youtube-live-output.txt"
grep -Fqx "strategy=$TEST_ROOT/opt/etc/kzapret-manager/strategies/youtube/Yv08.strategy" "$TEST_ROOT/youtube-live.capture"
grep -q '^local=192\.0\.2\.108$' "$TEST_ROOT/youtube-live.capture"
grep -q '^remote=0\.0\.0\.0/0$' "$TEST_ROOT/youtube-live.capture"
grep -q '^protocol=tcp$' "$TEST_ROOT/youtube-live.capture"
grep -q '^ports=443$' "$TEST_ROOT/youtube-live.capture"
grep -q '^queue=301$' "$TEST_ROOT/youtube-live.capture"
grep -q '^ttl=90$' "$TEST_ROOT/youtube-live.capture"
grep -q '^mihomo_bypass=1$' "$TEST_ROOT/youtube-live.capture"
cmp "$TEST_ROOT/nfqws-before-youtube-live.conf" "$TEST_ROOT/opt/etc/nfqws/nfqws.conf"
[ ! -e "$TEST_ROOT/restart.log" ]

rm -f "$TEST_ROOT/youtube-live.capture"
PATH="$TEST_ROOT/mock-live-bin:$PATH" \
KZM_CANARY_CAPTURE="$TEST_ROOT/youtube-live.capture" \
KZM_LIBEXEC="$TEST_ROOT/mock-live-libexec" KZM_ROOT="$TEST_ROOT" \
    "$TEST_ROOT/opt/bin/kzm" test youtube start 192.0.2.108 Yv08 45 >/dev/null
grep -q '^ttl=45$' "$TEST_ROOT/youtube-live.capture"
grep -q '^mihomo_bypass=0$' "$TEST_ROOT/youtube-live.capture"

rm -f "$TEST_ROOT/youtube-live.capture"
if PATH="$TEST_ROOT/mock-live-bin:$PATH" \
    KZM_CANARY_CAPTURE="$TEST_ROOT/youtube-live.capture" \
    KZM_LIBEXEC="$TEST_ROOT/mock-live-libexec" KZM_ROOT="$TEST_ROOT" \
    "$TEST_ROOT/opt/bin/kzm" test youtube start 192.0.2.108 off 90 >/dev/null 2>&1; then
    echo "YouTube live test accepted profile off" >&2
    exit 1
fi
[ ! -e "$TEST_ROOT/youtube-live.capture" ]
if PATH="$TEST_ROOT/mock-live-bin:$PATH" \
    KZM_CANARY_CAPTURE="$TEST_ROOT/youtube-live.capture" \
    KZM_LIBEXEC="$TEST_ROOT/mock-live-libexec" KZM_ROOT="$TEST_ROOT" \
    "$TEST_ROOT/opt/bin/kzm" test youtube start 192.0.2.108 Yv08 301 >/dev/null 2>&1; then
    echo "YouTube live test accepted TTL above the canary limit" >&2
    exit 1
fi
[ ! -e "$TEST_ROOT/youtube-live.capture" ]
cat > "$TEST_ROOT/mock-curl.sh" <<'EOF'
#!/bin/sh
printf '200|128|0.10'
EOF
chmod +x "$TEST_ROOT/mock-curl.sh"
printf 'v7|v7|%s\n' "$PROJECT_DIR/tests/fixtures/pass.strategy" > "$TEST_ROOT/suite-index.tsv"
CANARY_SCRIPT="$TEST_ROOT/mock-canary.sh" \
NFQWS_BIN="$TEST_ROOT/opt/usr/bin/nfqws" \
CONTROL_STRATEGY="$PROJECT_DIR/src/share/kzm/canary-pass.strategy" \
STRATEGY_INDEX="$TEST_ROOT/suite-index.tsv" \
TARGET_FILE="$PROJECT_DIR/tests/fixtures/test-targets.tsv" \
RESULT_FILE="$TEST_ROOT/suite-result.tsv" \
TEST_LOCAL_IP=192.0.2.1 \
CURL_BIN="$TEST_ROOT/mock-curl.sh" \
CANARY_STATE_FILE="$TEST_ROOT/canary.state" \
CANARY_TEST_PACKET_COUNT=12 \
"$PROJECT_DIR/tests/router-canary-suite.sh" > "$TEST_ROOT/suite-output.txt"
grep -q 'Контрольный тест: без обхода' "$TEST_ROOT/suite-output.txt"
grep -q 'Тестируем стратегию: v7 (1/1)' "$TEST_ROOT/suite-output.txt"
if grep -Eq '^\[( OK |FAIL)\]|^Результат (контроля|теста):' "$TEST_ROOT/suite-output.txt"; then
    echo "Suite progress output contains redundant per-target results" >&2
    exit 1
fi
[ "$(awk 'END { print NR+0 }' "$TEST_ROOT/suite-result.tsv")" -eq 5 ]

echo "All kzm tests passed"
