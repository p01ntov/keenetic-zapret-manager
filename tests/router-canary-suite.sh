#!/bin/sh

# Run a Zapret-Manager-style URL matrix through an isolated nfqws queue.
# The active service/configuration is never stopped, edited or restarted.

set -u

: "${CANARY_SCRIPT:?set CANARY_SCRIPT}"
: "${NFQWS_BIN:?set NFQWS_BIN}"
: "${CONTROL_STRATEGY:?set CONTROL_STRATEGY}"
: "${STRATEGY_INDEX:?set STRATEGY_INDEX}"
: "${TARGET_FILE:?set TARGET_FILE}"
: "${RESULT_FILE:?set RESULT_FILE}"
: "${TEST_LOCAL_IP:?set TEST_LOCAL_IP}"

QUEUE_NUM=${QUEUE_NUM:-301}
PARALLEL=${PARALLEL:-8}
CURL_TIMEOUT=${CURL_TIMEOUT:-7}
CANARY_TTL=${CANARY_TTL:-120}
CURL_BIN=${CURL_BIN:-$(command -v curl 2>/dev/null || true)}
CANARY_STATE_FILE=${CANARY_STATE_FILE:-/tmp/kzm-router-canary.state}
CANARY_FIREWALL_CHAIN=${CANARY_FIREWALL_CHAIN:-KZM_CANARY}

say() {
    printf '%s\n' "$*"
}

die() {
    printf 'SUITE ERROR: %s\n' "$*" >&2
    exit 1
}

valid_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

validate_inputs() {
    [ -x "$CANARY_SCRIPT" ] || die "canary script is not executable"
    [ -x "$NFQWS_BIN" ] || die "nfqws binary is not executable"
    [ -r "$CONTROL_STRATEGY" ] || die "control strategy is not readable"
    [ -s "$STRATEGY_INDEX" ] || die "strategy index is empty"
    [ -s "$TARGET_FILE" ] || die "target list is empty"
    if [ -z "$CURL_BIN" ] || [ ! -x "$CURL_BIN" ]; then
        die "curl is not executable"
    fi
    valid_uint "$QUEUE_NUM" || die "QUEUE_NUM must be a number"
    valid_uint "$PARALLEL" || die "PARALLEL must be a number"
    valid_uint "$CURL_TIMEOUT" || die "CURL_TIMEOUT must be a number"
    valid_uint "$CANARY_TTL" || die "CANARY_TTL must be a number"
    case "$QUEUE_NUM" in
        200|300) die "queue $QUEUE_NUM belongs to a production service" ;;
    esac
    if [ "$PARALLEL" -lt 1 ] || [ "$PARALLEL" -gt 16 ]; then
        die "PARALLEL must be 1..16"
    fi
    if [ "$CURL_TIMEOUT" -lt 2 ] || [ "$CURL_TIMEOUT" -gt 30 ]; then
        die "CURL_TIMEOUT must be 2..30"
    fi
    if [ "$CANARY_TTL" -lt 30 ] || [ "$CANARY_TTL" -gt 300 ]; then
        die "CANARY_TTL must be 30..300"
    fi
    [ ! -e "$CANARY_STATE_FILE" ] || die "another temporary canary is already active"

    awk -F'|' '
        NF != 2 { bad=1; next }
        $1 !~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/ { bad=1 }
        $2 !~ /^https:\/\/[A-Za-z0-9]/ || $2 ~ /[[:space:]|]/ { bad=1 }
        seen[$1]++ { bad=1 }
        END { exit bad || NR < 1 ? 1 : 0 }
    ' "$TARGET_FILE" || die "target list has an unsafe or malformed row"

    awk -F'|' '
        NF != 3 { bad=1; next }
        $1 !~ /^[A-Za-z0-9][A-Za-z0-9:_.-]*$/ { bad=1 }
        $2 == "" || $2 ~ /[|\r\n]/ { bad=1 }
        $3 == "" || $3 ~ /[|\r\n]/ { bad=1 }
        seen[$1]++ { bad=1 }
        END { exit bad || NR < 1 ? 1 : 0 }
    ' "$STRATEGY_INDEX" || die "strategy index has an unsafe or malformed row"

    while IFS='|' read -r check_id check_label check_path; do
        [ -r "$check_path" ] || die "strategy is not readable: $check_id ($check_label)"
    done < "$STRATEGY_INDEX"
}

CANARY_STARTED=0
SUITE_TMP=

stop_own_canary() {
    if [ "$CANARY_STARTED" -eq 1 ]; then
        "$CANARY_SCRIPT" stop >/dev/null 2>&1 || true
        CANARY_STARTED=0
    fi
}

cleanup_suite() {
    stop_own_canary
    if [ -n "$SUITE_TMP" ]; then
        case "$SUITE_TMP" in
            /tmp/kzm-suite.*) rm -rf "$SUITE_TMP" ;;
        esac
    fi
}

queue_packet_count() {
    if [ -n "${CANARY_TEST_PACKET_COUNT:-}" ]; then
        case "$CANARY_TEST_PACKET_COUNT" in
            *[!0-9]*|'') printf '0\n' ;;
            *) printf '%s\n' "$CANARY_TEST_PACKET_COUNT" ;;
        esac
        return
    fi
    iptables -t mangle -nvL "$CANARY_FIREWALL_CHAIN" 2>/dev/null | awk -v queue="$QUEUE_NUM" '
        $3 == "NFQUEUE" && index($0, "NFQUEUE num " queue) { print $1; found=1; exit }
        END { if (!found) print 0 }
    '
}

run_target() {
    target_number=$1
    target_name=$2
    target_url=$3
    target_result="$SUITE_TMP/target.$target_number"
    curl_result=$(
        "$CURL_BIN" -4 -sS -L -o /dev/null \
            --connect-timeout 4 \
            --max-time "$CURL_TIMEOUT" \
            --speed-time 3 \
            --speed-limit 1 \
            --range 0-65535 \
            -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) curl/8.0' \
            -w '%{http_code}|%{size_download}|%{time_total}' \
            "$target_url" 2>/dev/null
    )
    curl_rc=$?
    case "$curl_result" in
        *'|'*'|'*)
            http_code=${curl_result%%|*}
            curl_tail=${curl_result#*|}
            bytes=${curl_tail%%|*}
            seconds=${curl_tail#*|}
            ;;
        *)
            http_code=000
            bytes=0
            seconds=0
            ;;
    esac
    case "$http_code" in ''|*[!0-9]*) http_code=000 ;; esac
    case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
    case "$seconds" in ''|*[!0-9.]*) seconds=0 ;; esac
    if [ "$curl_rc" -eq 0 ] && [ "$http_code" != 000 ]; then
        target_ok=1
    else
        target_ok=0
    fi
    printf '%s|%s|%s|%s|%s|%s\n' \
        "$target_name" "$target_ok" "$curl_rc" "$http_code" "$bytes" "$seconds" > "$target_result"
}

flush_batch() {
    wait
    flush_number=$BATCH_FIRST
    while [ "$flush_number" -le "$TARGET_NUMBER" ]; do
        target_row=$(cat "$SUITE_TMP/target.$flush_number") || die "one target result is missing"
        # Keep stdout useful during a long matrix without repeating every URL.
        # Per-target status and curl diagnostics remain in RESULT_FILE.
        printf '%s\n' "$target_row" >> "$SUITE_TMP/strategy.rows"
        flush_number=$((flush_number + 1))
    done
    BATCH_RUNNING=0
}

write_start_failure_rows() {
    failed_id=$1
    failed_label=$2
    while IFS='|' read -r failed_target _failed_url; do
        printf '%s|%s|%s|0|125|000|0|0|0\n' \
            "$failed_id" "$failed_label" "$failed_target" >> "$RESULT_FILE"
    done < "$TARGET_FILE"
}

run_strategy() {
    strategy_id=$1
    strategy_label=$2
    strategy_path=$3
    strategy_position=$4
    strategy_total=$5
    strategy_kind=$6

    stop_own_canary
    if [ "$strategy_kind" = control ]; then
        say "Контрольный тест: без обхода"
    else
        say ""
        say "Тестируем стратегию: $strategy_label ($strategy_position/$strategy_total)"
    fi

    if ! NFQWS_BIN="$NFQWS_BIN" \
        STRATEGY_FILE="$strategy_path" \
        TEST_LOCAL_IP="$TEST_LOCAL_IP" \
        TEST_REMOTE_IP=0.0.0.0/0 \
        TEST_PROTOCOL=tcp \
        TEST_PORT=443 \
        INBOUND_ENABLED=0 \
        QUEUE_NUM="$QUEUE_NUM" \
        TTL="$CANARY_TTL" \
        "$CANARY_SCRIPT" start > "$SUITE_TMP/canary-start.log" 2>&1; then
        if [ "$strategy_kind" = control ]; then
            die "cannot start the isolated control queue"
        fi
        say "[ERROR] временная очередь не запустилась; стратегия пропущена"
        write_start_failure_rows "$strategy_id" "$strategy_label"
        return 0
    fi
    CANARY_STARTED=1

    : > "$SUITE_TMP/strategy.rows"
    TARGET_NUMBER=0
    BATCH_RUNNING=0
    while IFS='|' read -r target_name target_url; do
        TARGET_NUMBER=$((TARGET_NUMBER + 1))
        if [ "$BATCH_RUNNING" -eq 0 ]; then
            BATCH_FIRST=$TARGET_NUMBER
        fi
        run_target "$TARGET_NUMBER" "$target_name" "$target_url" &
        BATCH_RUNNING=$((BATCH_RUNNING + 1))
        if [ "$BATCH_RUNNING" -ge "$PARALLEL" ]; then
            flush_batch
        fi
    done < "$TARGET_FILE"
    if [ "$BATCH_RUNNING" -gt 0 ]; then
        flush_batch
    fi

    strategy_packets=$(queue_packet_count)
    case "$strategy_packets" in ''|*[!0-9]*) strategy_packets=0 ;; esac
    while IFS='|' read -r row_target row_ok row_rc row_http row_bytes row_seconds; do
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$strategy_id" "$strategy_label" "$row_target" "$row_ok" "$row_rc" \
            "$row_http" "$row_bytes" "$row_seconds" "$strategy_packets" >> "$RESULT_FILE"
    done < "$SUITE_TMP/strategy.rows"
    stop_own_canary

    if [ "$strategy_packets" -eq 0 ]; then
        say "[WARN] очередь 301 не увидела пакетов; результат этой строки нельзя использовать для выбора"
    fi
}

validate_inputs
SUITE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/kzm-suite.XXXXXX") || die "cannot create temporary directory"
trap cleanup_suite EXIT HUP INT TERM

TARGET_COUNT=$(awk 'END { print NR+0 }' "$TARGET_FILE")
STRATEGY_COUNT=$(awk 'END { print NR+0 }' "$STRATEGY_INDEX")
printf '%s\n' 'strategy_id|strategy_label|target|ok|curl_rc|http_code|bytes|seconds|queue_packets' > "$RESULT_FILE" || die "cannot create result file"

say "Целей для проверки: $TARGET_COUNT. Параллельных запросов: $PARALLEL."
say "Рабочая очередь и службы не переключаются; тест использует только очередь $QUEUE_NUM."
run_strategy control "без обхода" "$CONTROL_STRATEGY" 0 "$STRATEGY_COUNT" control

STRATEGY_NUMBER=0
while IFS='|' read -r strategy_id strategy_label strategy_path; do
    STRATEGY_NUMBER=$((STRATEGY_NUMBER + 1))
    run_strategy "$strategy_id" "$strategy_label" "$strategy_path" \
        "$STRATEGY_NUMBER" "$STRATEGY_COUNT" strategy
done < "$STRATEGY_INDEX"

trap - EXIT HUP INT TERM
cleanup_suite
