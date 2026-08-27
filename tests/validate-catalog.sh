#!/bin/sh

# Run after placing a real classic nfqws binary in the isolated test root.
# Every apply is local and uses nfqws --dry-run; no service is restarted.

set -u

TEST_ROOT=${1:-/tmp/kzm-real-root}
KZM="$TEST_ROOT/opt/bin/kzm"
FAILURES=0

run_apply() {
    kind=$1
    name=$2
    if KZM_ROOT="$TEST_ROOT" "$KZM" apply > /tmp/kzm-catalog-apply.log 2>&1; then
        echo "PASS $kind $name"
    else
        echo "FAIL $kind $name"
        cat /tmp/kzm-catalog-apply.log
        FAILURES=$((FAILURES + 1))
    fi
}

KZM_ROOT="$TEST_ROOT" "$KZM" strategy set youtube off >/dev/null
for strategy_file in "$TEST_ROOT"/opt/etc/kzapret-manager/strategies/general/*.strategy; do
    name=${strategy_file##*/}
    name=${name%.strategy}
    KZM_ROOT="$TEST_ROOT" "$KZM" strategy set general "$name" >/dev/null
    run_apply general "$name"
done

KZM_ROOT="$TEST_ROOT" "$KZM" strategy set general v7 >/dev/null
for strategy_file in "$TEST_ROOT"/opt/etc/kzapret-manager/strategies/youtube/*.strategy; do
    name=${strategy_file##*/}
    name=${name%.strategy}
    KZM_ROOT="$TEST_ROOT" "$KZM" strategy set youtube "$name" >/dev/null
    run_apply youtube "$name"
done

KZM_ROOT="$TEST_ROOT" "$KZM" strategy set youtube Yv08 >/dev/null
KZM_ROOT="$TEST_ROOT" "$KZM" strategy set discord on >/dev/null
for strategy_file in "$TEST_ROOT"/opt/etc/kzapret-manager/strategies/discord/*.strategy; do
    name=${strategy_file##*/}
    name=${name%.strategy}
    KZM_ROOT="$TEST_ROOT" "$KZM" strategy set discord-media "$name" >/dev/null
    run_apply discord "$name"
done

KZM_ROOT="$TEST_ROOT" "$KZM" strategy set discord-media Dv1 >/dev/null
KZM_ROOT="$TEST_ROOT" "$KZM" strategy set quic on >/dev/null
KZM_ROOT="$TEST_ROOT" "$KZM" strategy set game on >/dev/null
run_apply extras discord+quic+game

echo "Failures: $FAILURES"
exit "$FAILURES"
