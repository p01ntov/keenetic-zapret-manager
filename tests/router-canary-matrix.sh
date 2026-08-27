#!/bin/sh

# Sequentially test every strategy file against one forced IPv4 endpoint.
# Each attempt is isolated by router-canary.sh and is removed before the next.

set -u

: "${CANARY_SCRIPT:?set CANARY_SCRIPT}"
: "${NFQWS_BIN:?set NFQWS_BIN}"
: "${STRATEGY_DIR:?set STRATEGY_DIR}"
: "${TEST_LOCAL_IP:?set TEST_LOCAL_IP}"
: "${TEST_REMOTE_IP:?set TEST_REMOTE_IP}"
: "${TEST_HOST:?set TEST_HOST}"

TEST_PORT=${TEST_PORT:-443}
TEST_PATH=${TEST_PATH:-/}
QUEUE_NUM=${QUEUE_NUM:-301}
CURL_TIMEOUT=${CURL_TIMEOUT:-6}
ATTEMPTS=${ATTEMPTS:-1}

case "$ATTEMPTS" in
    ''|*[!0-9]*) echo "ATTEMPTS must be a number" >&2; exit 1 ;;
esac
if [ "$ATTEMPTS" -lt 1 ] || [ "$ATTEMPTS" -gt 5 ]; then
    echo "ATTEMPTS must be 1..5" >&2
    exit 1
fi

cleanup_attempt() {
    "$CANARY_SCRIPT" stop >/dev/null 2>&1 || true
}

trap cleanup_attempt EXIT HUP INT TERM

run_one() {
    strategy_name=$1
    strategy_file=$2
    strategy_attempt=$3
    cleanup_attempt

    if ! NFQWS_BIN="$NFQWS_BIN" \
        STRATEGY_FILE="$strategy_file" \
        TEST_LOCAL_IP="$TEST_LOCAL_IP" \
        TEST_REMOTE_IP="$TEST_REMOTE_IP" \
        TEST_PROTOCOL=tcp \
        TEST_PORT="$TEST_PORT" \
        INBOUND_ENABLED=0 \
        QUEUE_NUM="$QUEUE_NUM" \
        TTL=30 \
        "$CANARY_SCRIPT" start > "/tmp/kzm-canary-$strategy_name.log" 2>&1; then
        printf '%s,%s,start_failed,000,0,0,0\n' "$strategy_name" "$strategy_attempt"
        cleanup_attempt
        return
    fi

    curl_result=$(
        /opt/bin/curl -4 -sS -o /dev/null \
            --resolve "$TEST_HOST:$TEST_PORT:$TEST_REMOTE_IP" \
            --connect-timeout "$CURL_TIMEOUT" \
            --max-time "$CURL_TIMEOUT" \
            -w '%{http_code},%{time_appconnect},%{time_total}' \
            "https://$TEST_HOST:$TEST_PORT$TEST_PATH"
    )
    curl_rc=$?
    case "$curl_result" in
        *,*,*) ;;
        *) curl_result=000,0,0 ;;
    esac
    queue_packets=$(awk -v queue="$QUEUE_NUM" '$1 == queue { print $8 }' /proc/net/netfilter/nfnetlink_queue 2>/dev/null)
    queue_packets=${queue_packets:-0}
    printf '%s,%s,%s,%s,%s\n' "$strategy_name" "$strategy_attempt" "$curl_rc" "$curl_result" "$queue_packets"
    cleanup_attempt
}

printf 'strategy,attempt,curl_rc,http_code,tls_seconds,total_seconds,queue_packets\n'
if [ -n "${CONTROL_STRATEGY:-}" ] && [ -f "$CONTROL_STRATEGY" ]; then
    attempt=1
    while [ "$attempt" -le "$ATTEMPTS" ]; do
        run_one control "$CONTROL_STRATEGY" "$attempt"
        attempt=$((attempt + 1))
    done
fi
for strategy_file in "$STRATEGY_DIR"/*.strategy; do
    [ -f "$strategy_file" ] || continue
    strategy_name=${strategy_file##*/}
    strategy_name=${strategy_name%.strategy}
    attempt=1
    while [ "$attempt" -le "$ATTEMPTS" ]; do
        run_one "$strategy_name" "$strategy_file" "$attempt"
        attempt=$((attempt + 1))
    done
done

trap - EXIT HUP INT TERM
