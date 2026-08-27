#!/bin/sh

# A narrow, self-cleaning live nfqws test for Keenetic.
# It never installs a package, edits the production config or restarts a service.
# The temporary queue is attached ahead of the production POSTROUTING rules and
# marks handled packets so they cannot fall through into queue 200/300.

set -u

# Every runtime file is created by root.  Set this before creating the lock so
# an unprivileged /tmp user never gets a writable window into a live run.
umask 077

STATE_FILE=${CANARY_STATE_FILE:-/tmp/kzm-router-canary.state}
PID_FILE=${CANARY_PID_FILE:-}
WATCHDOG_PID_FILE=${CANARY_WATCHDOG_PID_FILE:-}
WATCHDOG_LOG=${CANARY_WATCHDOG_LOG:-/tmp/kzm-router-canary-watchdog.log}
LOCK_DIR=${CANARY_LOCK_DIR:-/tmp/kzm-router-canary.lock}
START_OWNER_FILE="$LOCK_DIR/start.owner"
PROC_ROOT=/proc
RUNTIME_UID=$(id -u 2>/dev/null || true)
POST_CHAIN=POSTROUTING
CANARY_CHAIN=KZM_CANARY
MIHOMO_CHAIN=MIHOMO_REDIRECT
SKIP_MARK=0x40000000/0x40000000
FINAL_MARK=0x60000000/0x60000000
OUT_CONNBYTES_ARGS="-m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes=1:8"

RUN_ID=
NFQWS_BIN_CANONICAL=
WATCHDOG_SCRIPT=
CANARY_PID=
CANARY_STARTTIME=
WATCHDOG_PID=
WATCHDOG_STARTTIME=
WATCHDOG_EXE=
MIHOMO_BYPASS=0
STATE_ERROR=

say() {
    printf '%s\n' "$*"
}

die() {
    printf 'CANARY ERROR: %s\n' "$*" >&2
    exit 1
}

valid_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
            }
        }
    '
}

valid_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

valid_bool() {
    case "$1" in
        0|1) return 0 ;;
        *) return 1 ;;
    esac
}

valid_ports() {
    printf '%s\n' "$1" | grep -Eq '^[0-9]+(:[0-9]+)?(,[0-9]+(:[0-9]+)?)*$' || return 1
    printf '%s\n' "$1" | awk -F '[:,]' '
        {
            for (i = 1; i <= NF; i++) {
                if ($i < 1 || $i > 65535) exit 1
            }
        }
    '
}

valid_interface() {
    case "$1" in
        ''|*[!A-Za-z0-9_.:+-]*) return 1 ;;
    esac
    [ "${#1}" -le 15 ]
}

valid_process_pid() {
    valid_uint "$1" || return 1
    [ "$1" -gt 1 ] 2>/dev/null
}

valid_run_id() {
    printf '%s\n' "$1" | awk -F. '
        NF == 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { ok=1 }
        END { exit(ok ? 0 : 1) }
    '
}

valid_absolute_path() {
    case "$1" in
        /*) ;;
        *) return 1 ;;
    esac
    case "$1" in
        *[!A-Za-z0-9_./:+@-]*) return 1 ;;
    esac
}

safe_regular_file() {
    [ -f "$1" ] && [ ! -L "$1" ]
}

secure_runtime_file() {
    safe_regular_file "$1" || return 1
    runtime_listing=$(ls -ldn "$1" 2>/dev/null) || return 1
    # Only the fixed metadata fields are consumed; the quoted path itself may
    # contain spaces and is irrelevant here.
    # shellcheck disable=SC2086
    set -- $runtime_listing
    [ "$#" -ge 4 ] || return 1
    [ "$1" = "-rw-------" ] && [ "$3" = "$RUNTIME_UID" ]
}

canonical_file() {
    canonical_candidate=$(readlink -f "$1" 2>/dev/null) || return 1
    [ -n "$canonical_candidate" ] || return 1
    [ -f "$canonical_candidate" ] || return 1
    printf '%s\n' "$canonical_candidate"
}

proc_executable() {
    proc_pid=$1
    valid_process_pid "$proc_pid" || return 1
    [ -L "$PROC_ROOT/$proc_pid/exe" ] || return 1
    readlink "$PROC_ROOT/$proc_pid/exe" 2>/dev/null
}

proc_starttime() {
    proc_pid=$1
    valid_process_pid "$proc_pid" || return 1
    [ -r "$PROC_ROOT/$proc_pid/stat" ] || return 1
    proc_stat=$(cat "$PROC_ROOT/$proc_pid/stat" 2>/dev/null) || return 1
    proc_stat_tail=${proc_stat##*) }
    [ "$proc_stat_tail" != "$proc_stat" ] || return 1
    # Field 22 in /proc/PID/stat is field 20 after the parenthesised comm.
    # Splitting here is safe: proc_stat_tail comes from the kernel and the
    # requested field is validated as an unsigned integer.
    # shellcheck disable=SC2086
    set -- $proc_stat_tail
    [ "$#" -ge 20 ] || return 1
    proc_started=${20}
    valid_uint "$proc_started" || return 1
    printf '%s\n' "$proc_started"
}

pid_alive() {
    valid_process_pid "$1" || return 1
    [ -d "$PROC_ROOT/$1" ] && kill -0 "$1" 2>/dev/null
}

cmdline_has_canary_signature() {
    signature_pid=$1
    [ -r "$PROC_ROOT/$signature_pid/cmdline" ] || return 1
    tr '\000' '\n' < "$PROC_ROOT/$signature_pid/cmdline" 2>/dev/null | awk \
        -v wanted_pidfile="--pidfile=$PID_FILE" \
        -v wanted_queue="--qnum=$QUEUE_NUM" '
            $0 == wanted_pidfile { have_pidfile=1 }
            $0 == wanted_queue { have_queue=1 }
            END { exit(have_pidfile && have_queue ? 0 : 1) }
        '
}

canary_process_is_ours() {
    owned_pid=$1
    owned_starttime=${2:-}
    pid_alive "$owned_pid" || return 1
    owned_exe=$(proc_executable "$owned_pid") || return 1
    [ "$owned_exe" = "$NFQWS_BIN_CANONICAL" ] || return 1
    current_starttime=$(proc_starttime "$owned_pid") || return 1
    if [ -n "$owned_starttime" ] && [ "$current_starttime" != "$owned_starttime" ]; then
        return 1
    fi
    cmdline_has_canary_signature "$owned_pid"
}

cmdline_has_watchdog_signature() {
    signature_pid=$1
    [ -r "$PROC_ROOT/$signature_pid/cmdline" ] || return 1
    tr '\000' '\n' < "$PROC_ROOT/$signature_pid/cmdline" 2>/dev/null | awk \
        -v wanted_script="$WATCHDOG_SCRIPT" \
        -v wanted_ttl="$TTL" \
        -v wanted_run="$RUN_ID" '
            $0 == wanted_script && stage == 0 { stage=1; next }
            stage == 1 && $0 == "watchdog" { stage=2; next }
            stage == 2 && $0 == wanted_ttl { stage=3; next }
            stage == 3 && $0 == wanted_run { stage=4; next }
            END { exit(stage == 4 ? 0 : 1) }
        '
}

watchdog_process_is_ours() {
    owned_pid=$1
    owned_starttime=$2
    valid_uint "$owned_starttime" || return 1
    pid_alive "$owned_pid" || return 1
    owned_exe=$(proc_executable "$owned_pid") || return 1
    [ -n "$WATCHDOG_EXE" ] && [ "$owned_exe" = "$WATCHDOG_EXE" ] || return 1
    current_starttime=$(proc_starttime "$owned_pid") || return 1
    [ "$current_starttime" = "$owned_starttime" ] || return 1
    cmdline_has_watchdog_signature "$owned_pid"
}

prepare_port_args() {
    case "$TEST_PORTS" in
        *[:,]*) OUT_PORT_ARGS="-m multiport --dports $TEST_PORTS" ;;
        *) OUT_PORT_ARGS="--dport $TEST_PORTS" ;;
    esac
}

route_interface() {
    route_target=$TEST_REMOTE_IP
    [ "$route_target" != 0.0.0.0/0 ] || route_target=1.1.1.1
    ip route get "$route_target" 2>/dev/null | awk '
        { for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }
    '
}

state_value() {
    state_key=$1
    awk -F= -v wanted="$state_key" '$1 == wanted { print substr($0, length($1) + 2); exit }' "$STATE_FILE"
}

load_state() {
    STATE_ERROR=
    if [ ! -e "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ]; then
        return 1
    fi
    if ! secure_runtime_file "$STATE_FILE"; then
        STATE_ERROR="state is not an owner-only regular non-symlink file"
        return 2
    fi
    if ! awk -F= '
        BEGIN {
            allowed["STATE_VERSION"]=1; allowed["RUN_ID"]=1;
            allowed["NFQWS_BIN_CANONICAL"]=1; allowed["WATCHDOG_SCRIPT"]=1;
            allowed["PID_FILE"]=1; allowed["WATCHDOG_PID_FILE"]=1;
            allowed["STRATEGY_FILE"]=1; allowed["TEST_LOCAL_IP"]=1;
            allowed["TEST_REMOTE_IP"]=1; allowed["TEST_PROTOCOL"]=1;
            allowed["TEST_PORTS"]=1; allowed["TEST_OUT_INTERFACE"]=1;
            allowed["QUEUE_NUM"]=1; allowed["TTL"]=1;
            allowed["CANARY_PID"]=1; allowed["CANARY_STARTTIME"]=1;
            allowed["WATCHDOG_PID"]=1; allowed["WATCHDOG_STARTTIME"]=1;
            allowed["WATCHDOG_EXE"]=1; allowed["MIHOMO_BYPASS"]=1
        }
        NF != 2 || !allowed[$1] || seen[$1]++ { bad=1 }
        END {
            for (key in allowed) {
                if (key != "MIHOMO_BYPASS" && !seen[key]) bad=1
            }
            if (value["STATE_VERSION"] == "3" && !seen["MIHOMO_BYPASS"]) bad=1
            if (value["STATE_VERSION"] == "2" && seen["MIHOMO_BYPASS"]) bad=1
            exit(bad ? 1 : 0)
        }
        { value[$1]=$2 }
    ' "$STATE_FILE"; then
        STATE_ERROR="state has an unexpected, duplicate or missing field"
        return 2
    fi

    state_version=$(state_value STATE_VERSION)
    RUN_ID=$(state_value RUN_ID)
    NFQWS_BIN_CANONICAL=$(state_value NFQWS_BIN_CANONICAL)
    WATCHDOG_SCRIPT=$(state_value WATCHDOG_SCRIPT)
    PID_FILE=$(state_value PID_FILE)
    WATCHDOG_PID_FILE=$(state_value WATCHDOG_PID_FILE)
    STRATEGY_FILE=$(state_value STRATEGY_FILE)
    TEST_LOCAL_IP=$(state_value TEST_LOCAL_IP)
    TEST_REMOTE_IP=$(state_value TEST_REMOTE_IP)
    TEST_PROTOCOL=$(state_value TEST_PROTOCOL)
    TEST_PORTS=$(state_value TEST_PORTS)
    TEST_OUT_INTERFACE=$(state_value TEST_OUT_INTERFACE)
    QUEUE_NUM=$(state_value QUEUE_NUM)
    TTL=$(state_value TTL)
    CANARY_PID=$(state_value CANARY_PID)
    CANARY_STARTTIME=$(state_value CANARY_STARTTIME)
    WATCHDOG_PID=$(state_value WATCHDOG_PID)
    WATCHDOG_STARTTIME=$(state_value WATCHDOG_STARTTIME)
    WATCHDOG_EXE=$(state_value WATCHDOG_EXE)
    if [ "$state_version" = 2 ]; then
        MIHOMO_BYPASS=0
    else
        MIHOMO_BYPASS=$(state_value MIHOMO_BYPASS)
    fi

    if { [ "$state_version" != 2 ] && [ "$state_version" != 3 ]; } || \
            ! valid_run_id "$RUN_ID" || \
            ! valid_absolute_path "$NFQWS_BIN_CANONICAL" || \
            ! valid_absolute_path "$WATCHDOG_SCRIPT" || \
            ! valid_absolute_path "$PID_FILE" || \
            ! valid_absolute_path "$WATCHDOG_PID_FILE" || \
            ! valid_absolute_path "$STRATEGY_FILE" || \
            ! valid_ipv4 "$TEST_LOCAL_IP" || \
            ! valid_ports "$TEST_PORTS" || ! valid_interface "$TEST_OUT_INTERFACE" || \
            ! valid_bool "$MIHOMO_BYPASS" || \
            ! valid_uint "$QUEUE_NUM" || ! valid_uint "$TTL"; then
        STATE_ERROR="state contains an invalid value"
        return 2
    fi
    case "$TEST_REMOTE_IP" in
        0.0.0.0/0) ;;
        *) valid_ipv4 "$TEST_REMOTE_IP" || { STATE_ERROR="state contains an invalid remote IPv4"; return 2; } ;;
    esac
    case "$TEST_PROTOCOL" in tcp|udp) ;; *) STATE_ERROR="state contains an invalid protocol"; return 2 ;; esac
    if [ "$MIHOMO_BYPASS" -eq 1 ] && [ "$TEST_PROTOCOL" != tcp ]; then
        STATE_ERROR="state enables the Mihomo bypass for a non-TCP test"
        return 2
    fi
    if [ "$QUEUE_NUM" -lt 1 ] || [ "$QUEUE_NUM" -gt 65535 ] || \
            [ "$TTL" -lt 15 ] || [ "$TTL" -gt 300 ]; then
        STATE_ERROR="state contains an out-of-range queue or TTL"
        return 2
    fi
    if [ -n "$CANARY_PID$CANARY_STARTTIME" ]; then
        if ! valid_process_pid "$CANARY_PID" || ! valid_uint "$CANARY_STARTTIME"; then
            STATE_ERROR="state contains an invalid canary identity"
            return 2
        fi
    fi
    if [ -n "$WATCHDOG_PID$WATCHDOG_STARTTIME$WATCHDOG_EXE" ]; then
        if ! valid_process_pid "$WATCHDOG_PID" || ! valid_uint "$WATCHDOG_STARTTIME" || \
                ! valid_absolute_path "$WATCHDOG_EXE"; then
            STATE_ERROR="state contains an invalid watchdog identity"
            return 2
        fi
    fi
}

write_state() {
    [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || return 1
    state_tmp="$LOCK_DIR/state.tmp.$$"
    {
        printf 'STATE_VERSION=3\n'
        printf 'RUN_ID=%s\n' "$RUN_ID"
        printf 'NFQWS_BIN_CANONICAL=%s\n' "$NFQWS_BIN_CANONICAL"
        printf 'WATCHDOG_SCRIPT=%s\n' "$WATCHDOG_SCRIPT"
        printf 'PID_FILE=%s\n' "$PID_FILE"
        printf 'WATCHDOG_PID_FILE=%s\n' "$WATCHDOG_PID_FILE"
        printf 'STRATEGY_FILE=%s\n' "$STRATEGY_FILE"
        printf 'TEST_LOCAL_IP=%s\n' "$TEST_LOCAL_IP"
        printf 'TEST_REMOTE_IP=%s\n' "$TEST_REMOTE_IP"
        printf 'TEST_PROTOCOL=%s\n' "$TEST_PROTOCOL"
        printf 'TEST_PORTS=%s\n' "$TEST_PORTS"
        printf 'TEST_OUT_INTERFACE=%s\n' "$TEST_OUT_INTERFACE"
        printf 'QUEUE_NUM=%s\n' "$QUEUE_NUM"
        printf 'TTL=%s\n' "$TTL"
        printf 'CANARY_PID=%s\n' "$CANARY_PID"
        printf 'CANARY_STARTTIME=%s\n' "$CANARY_STARTTIME"
        printf 'WATCHDOG_PID=%s\n' "$WATCHDOG_PID"
        printf 'WATCHDOG_STARTTIME=%s\n' "$WATCHDOG_STARTTIME"
        printf 'WATCHDOG_EXE=%s\n' "$WATCHDOG_EXE"
        printf 'MIHOMO_BYPASS=%s\n' "$MIHOMO_BYPASS"
    } > "$state_tmp" || {
        rm -f "$state_tmp" 2>/dev/null || true
        return 1
    }
    chmod 600 "$state_tmp" || {
        rm -f "$state_tmp" 2>/dev/null || true
        return 1
    }
    mv -f "$state_tmp" "$STATE_FILE" || {
        rm -f "$state_tmp" 2>/dev/null || true
        return 1
    }
    secure_runtime_file "$STATE_FILE"
}

write_runtime_file() {
    runtime_target=$1
    runtime_value=$2
    runtime_label=$3
    runtime_tmp="$LOCK_DIR/$runtime_label.tmp.$$"
    printf '%s\n' "$runtime_value" > "$runtime_tmp" || return 1
    chmod 600 "$runtime_tmp" || {
        rm -f "$runtime_tmp" 2>/dev/null || true
        return 1
    }
    mv -f "$runtime_tmp" "$runtime_target" || {
        rm -f "$runtime_tmp" 2>/dev/null || true
        return 1
    }
    secure_runtime_file "$runtime_target"
}

wait_for_start_phase() {
    if [ ! -e "$START_OWNER_FILE" ] && [ ! -L "$START_OWNER_FILE" ]; then
        return 0
    fi
    secure_runtime_file "$START_OWNER_FILE" || return 1
    IFS=' ' read -r start_owner_pid start_owner_started start_owner_extra < "$START_OWNER_FILE" || return 1
    [ -z "${start_owner_extra:-}" ] || return 1
    valid_process_pid "$start_owner_pid" || return 1
    valid_uint "$start_owner_started" || return 1
    [ "$start_owner_pid" = "$$" ] && return 0

    start_wait=0
    while [ "$start_wait" -lt 15 ]; do
        [ -e "$START_OWNER_FILE" ] || return 0
        current_owner_started=$(proc_starttime "$start_owner_pid" 2>/dev/null || true)
        if ! pid_alive "$start_owner_pid" || [ "$current_owner_started" != "$start_owner_started" ]; then
            break
        fi
        sleep 1
        start_wait=$((start_wait + 1))
    done
    if [ -e "$START_OWNER_FILE" ]; then
        current_owner_started=$(proc_starttime "$start_owner_pid" 2>/dev/null || true)
        if pid_alive "$start_owner_pid" && [ "$current_owner_started" = "$start_owner_started" ]; then
            return 1
        fi
        secure_runtime_file "$START_OWNER_FILE" || return 1
        [ "$(cat "$START_OWNER_FILE" 2>/dev/null)" = "$start_owner_pid $start_owner_started" ] || return 1
        rm -f "$START_OWNER_FILE" || return 1
    fi
}

# Port matcher fragments are validated by valid_ports before this function.
# shellcheck disable=SC2086
delete_rules() {
    delete_rc=0
    prepare_port_args
    if [ "$MIHOMO_BYPASS" -eq 1 ]; then
        # Restore the production transparent-proxy path first. This is an
        # exact rule deletion; the existing Mihomo chain is never flushed or
        # removed by the canary.
        if iptables -t nat -C "$MIHOMO_CHAIN" -s "$TEST_LOCAL_IP" -d "$TEST_REMOTE_IP" -p tcp $OUT_PORT_ARGS -j RETURN 2>/dev/null; then
            if ! iptables -t nat -D "$MIHOMO_CHAIN" -s "$TEST_LOCAL_IP" -d "$TEST_REMOTE_IP" -p tcp $OUT_PORT_ARGS -j RETURN; then
                delete_rc=1
            # A duplicate should be impossible because start rejects one. If
            # it appears, retain state for inspection instead of claiming a
            # complete rollback or deleting an unowned second rule.
            elif iptables -t nat -C "$MIHOMO_CHAIN" -s "$TEST_LOCAL_IP" -d "$TEST_REMOTE_IP" -p tcp $OUT_PORT_ARGS -j RETURN 2>/dev/null; then
                delete_rc=1
            elif ! iptables-save -t nat >/dev/null 2>&1; then
                delete_rc=1
            fi
        elif ! iptables-save -t nat >/dev/null 2>&1; then
            # Do not confuse a broken firewall command with an absent rule.
            # Keeping state makes a later explicit stop safe and retryable.
            delete_rc=1
        fi
    fi
    # Word splitting is intentional for the validated port matcher.
    while iptables -t mangle -C "$POST_CHAIN" -o "$TEST_OUT_INTERFACE" -s "$TEST_LOCAL_IP" -d "$TEST_REMOTE_IP" -p "$TEST_PROTOCOL" $OUT_PORT_ARGS -j "$CANARY_CHAIN" 2>/dev/null; do
        if ! iptables -t mangle -D "$POST_CHAIN" -o "$TEST_OUT_INTERFACE" -s "$TEST_LOCAL_IP" -d "$TEST_REMOTE_IP" -p "$TEST_PROTOCOL" $OUT_PORT_ARGS -j "$CANARY_CHAIN"; then
            delete_rc=1
            break
        fi
    done
    if iptables -t mangle -nL "$CANARY_CHAIN" >/dev/null 2>&1; then
        iptables -t mangle -F "$CANARY_CHAIN" 2>/dev/null || delete_rc=1
        iptables -t mangle -X "$CANARY_CHAIN" 2>/dev/null || delete_rc=1
    fi
    return "$delete_rc"
}

terminate_canary_pid() {
    terminate_pid=$1
    terminate_starttime=$2
    canary_process_is_ours "$terminate_pid" "$terminate_starttime" || return 0
    kill -TERM "$terminate_pid" 2>/dev/null || true
    terminate_wait=0
    while canary_process_is_ours "$terminate_pid" "$terminate_starttime" && \
            [ "$terminate_wait" -lt 5 ]; do
        sleep 1
        terminate_wait=$((terminate_wait + 1))
    done
    canary_process_is_ours "$terminate_pid" "$terminate_starttime" || return 0
    kill -KILL "$terminate_pid" 2>/dev/null || true
    terminate_wait=0
    while canary_process_is_ours "$terminate_pid" "$terminate_starttime" && \
            [ "$terminate_wait" -lt 3 ]; do
        sleep 1
        terminate_wait=$((terminate_wait + 1))
    done
    ! canary_process_is_ours "$terminate_pid" "$terminate_starttime"
}

scan_canary_processes() {
    CANARY_MATCHED_PIDS=
    CANARY_MATCH_COUNT=0
    for scan_dir in "$PROC_ROOT"/[0-9]*; do
        [ -d "$scan_dir" ] || continue
        scan_pid=${scan_dir##*/}
        valid_process_pid "$scan_pid" || continue
        canary_process_is_ours "$scan_pid" "" || continue
        # A matching recorded PID with another start time was reused. Never
        # turn signature-only orphan cleanup into a kill of that new process.
        if [ -n "$CANARY_PID" ] && [ "$scan_pid" = "$CANARY_PID" ] && \
                [ -n "$CANARY_STARTTIME" ]; then
            scan_started=$(proc_starttime "$scan_pid") || continue
            [ "$scan_started" = "$CANARY_STARTTIME" ] || continue
        fi
        CANARY_MATCH_COUNT=$((CANARY_MATCH_COUNT + 1))
        CANARY_MATCHED_PIDS="$CANARY_MATCHED_PIDS $scan_pid"
    done
}

cleanup_canary_processes() {
    cleanup_process_rc=0
    if [ -n "$CANARY_PID" ] && [ -n "$CANARY_STARTTIME" ]; then
        terminate_canary_pid "$CANARY_PID" "$CANARY_STARTTIME" || cleanup_process_rc=1
    fi

    # The daemon can lose its pidfile during a failed launch. The executable
    # plus the per-run queue/pidfile command line is its ownership identity.
    scan_canary_processes
    # Word splitting is intentional; scan_canary_processes emits only PIDs.
    # shellcheck disable=SC2086
    set -- $CANARY_MATCHED_PIDS
    for orphan_pid in "$@"; do
        orphan_started=$(proc_starttime "$orphan_pid") || continue
        terminate_canary_pid "$orphan_pid" "$orphan_started" || cleanup_process_rc=1
    done
    scan_canary_processes
    [ "$CANARY_MATCH_COUNT" -eq 0 ] || cleanup_process_rc=1
    return "$cleanup_process_rc"
}

terminate_watchdog() {
    [ -n "$WATCHDOG_PID" ] && [ -n "$WATCHDOG_STARTTIME" ] && \
        [ -n "$WATCHDOG_EXE" ] || return 0
    [ "$WATCHDOG_PID" = "$$" ] && return 0
    watchdog_process_is_ours "$WATCHDOG_PID" "$WATCHDOG_STARTTIME" || return 0
    kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
    watchdog_wait=0
    while watchdog_process_is_ours "$WATCHDOG_PID" "$WATCHDOG_STARTTIME" && \
            [ "$watchdog_wait" -lt 3 ]; do
        sleep 1
        watchdog_wait=$((watchdog_wait + 1))
    done
    watchdog_process_is_ours "$WATCHDOG_PID" "$WATCHDOG_STARTTIME" || return 0
    kill -KILL "$WATCHDOG_PID" 2>/dev/null || true
    watchdog_wait=0
    while watchdog_process_is_ours "$WATCHDOG_PID" "$WATCHDOG_STARTTIME" && \
            [ "$watchdog_wait" -lt 2 ]; do
        sleep 1
        watchdog_wait=$((watchdog_wait + 1))
    done
    ! watchdog_process_is_ours "$WATCHDOG_PID" "$WATCHDOG_STARTTIME"
}

read_watchdog_record() {
    secure_runtime_file "$WATCHDOG_PID_FILE" || return 1
    IFS=' ' read -r record_pid record_started record_exe record_extra < "$WATCHDOG_PID_FILE" || return 1
    [ -z "${record_extra:-}" ] || return 1
    valid_process_pid "$record_pid" || return 1
    valid_uint "$record_started" || return 1
    valid_absolute_path "$record_exe" || return 1
    WATCHDOG_PID=$record_pid
    WATCHDOG_STARTTIME=$record_started
    WATCHDOG_EXE=$record_exe
}

remove_runtime_files() {
    if [ -n "$PID_FILE" ]; then
        rm -f "$PID_FILE" 2>/dev/null || true
    fi
    if [ -n "$WATCHDOG_PID_FILE" ]; then
        rm -f "$WATCHDOG_PID_FILE" 2>/dev/null || true
    fi
    rm -f "$STATE_FILE" 2>/dev/null || true
    if [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ]; then
        rm -f "$START_OWNER_FILE" 2>/dev/null || true
        rm -f "$LOCK_DIR"/*.tmp.* 2>/dev/null || true
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
}

cleanup_loaded_run() {
    cleanup_rc=0
    # Detach traffic first. queue-bypass keeps it flowing while the exact
    # process is terminated; an empty user chain returns to production rules.
    delete_rules || cleanup_rc=1
    cleanup_canary_processes || cleanup_rc=1
    if [ -z "$WATCHDOG_PID" ] && secure_runtime_file "$WATCHDOG_PID_FILE"; then
        read_watchdog_record || true
    fi
    terminate_watchdog || cleanup_rc=1

    if [ "$cleanup_rc" -ne 0 ]; then
        printf '%s\n' 'CANARY ERROR: cleanup is incomplete; state retained for a safe retry.' >&2
        return 1
    fi
    remove_runtime_files
    say "Canary stopped; temporary rules and exact-owned processes removed."
}

stop_canary() {
    if ! wait_for_start_phase; then
        printf '%s\n' 'CANARY ERROR: start is still running or its owner record is unsafe; nothing was changed.' >&2
        return 1
    fi
    load_state
    state_rc=$?
    case "$state_rc" in
        0) ;;
        1)
            if [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ]; then
                rmdir "$LOCK_DIR" 2>/dev/null || true
            fi
            say "Canary state is absent; nothing to stop."
            return 0
            ;;
        *)
            printf 'CANARY ERROR: unsafe state; no PID was signalled and no rule was changed (%s).\n' "$STATE_ERROR" >&2
            return 1
            ;;
    esac
    cleanup_loaded_run
}

start_canary() {
    if [ -e "$STATE_FILE" ] || [ -L "$STATE_FILE" ]; then
        die "a canary state already exists"
    fi
    if [ -e "$LOCK_DIR" ] || [ -L "$LOCK_DIR" ]; then
        die "a canary lock already exists; run test stop first"
    fi
    : "${NFQWS_BIN:?set NFQWS_BIN}"
    : "${STRATEGY_FILE:?set STRATEGY_FILE}"
    : "${TEST_LOCAL_IP:?set TEST_LOCAL_IP}"
    : "${TEST_REMOTE_IP:?set TEST_REMOTE_IP}"
    : "${TEST_PROTOCOL:?set TEST_PROTOCOL}"
    TEST_PORTS=${TEST_PORTS:-${TEST_PORT:-}}
    : "${TEST_PORTS:?set TEST_PORTS or TEST_PORT}"
    MIHOMO_BYPASS=${CANARY_MIHOMO_BYPASS:-0}
    QUEUE_NUM=${QUEUE_NUM:-301}
    TTL=${TTL:-60}
    TEST_OUT_INTERFACE=${TEST_OUT_INTERFACE:-$(route_interface)}

    [ -x "$NFQWS_BIN" ] || die "nfqws binary is not executable"
    NFQWS_BIN_CANONICAL=$(canonical_file "$NFQWS_BIN") || die "cannot canonicalize nfqws binary"
    STRATEGY_FILE=$(canonical_file "$STRATEGY_FILE") || die "cannot canonicalize strategy file"
    WATCHDOG_SCRIPT=$(canonical_file "$0") || die "cannot canonicalize canary script"
    valid_absolute_path "$NFQWS_BIN_CANONICAL" || die "nfqws path contains unsupported characters"
    valid_absolute_path "$STRATEGY_FILE" || die "strategy path contains unsupported characters"
    valid_absolute_path "$WATCHDOG_SCRIPT" || die "canary script path contains unsupported characters"
    [ -r "$STRATEGY_FILE" ] || die "strategy file is not readable"
    valid_ipv4 "$TEST_LOCAL_IP" || die "invalid TEST_LOCAL_IP"
    case "$TEST_REMOTE_IP" in
        0.0.0.0/0) ;;
        *) valid_ipv4 "$TEST_REMOTE_IP" || die "invalid TEST_REMOTE_IP" ;;
    esac
    case "$TEST_PROTOCOL" in tcp|udp) ;; *) die "TEST_PROTOCOL must be tcp or udp" ;; esac
    valid_bool "$MIHOMO_BYPASS" || die "CANARY_MIHOMO_BYPASS must be 0 or 1"
    if [ "$MIHOMO_BYPASS" -eq 1 ] && [ "$TEST_PROTOCOL" != tcp ]; then
        die "CANARY_MIHOMO_BYPASS is supported only for TCP canaries"
    fi
    valid_ports "$TEST_PORTS" || die "invalid TEST_PORTS"
    valid_uint "$QUEUE_NUM" || die "invalid QUEUE_NUM"
    valid_uint "$TTL" || die "invalid TTL"
    valid_interface "$TEST_OUT_INTERFACE" || die "invalid TEST_OUT_INTERFACE"
    ip link show "$TEST_OUT_INTERFACE" >/dev/null 2>&1 || die "missing interface $TEST_OUT_INTERFACE"
    if [ "$QUEUE_NUM" -lt 1 ] || [ "$QUEUE_NUM" -gt 65535 ]; then
        die "QUEUE_NUM out of range"
    fi
    case "$QUEUE_NUM" in
        200|300) die "queue $QUEUE_NUM is reserved for a production service" ;;
    esac
    if [ "$TTL" -lt 15 ] || [ "$TTL" -gt 300 ]; then
        die "TTL must be 15..300 seconds"
    fi
    if awk -v queue="$QUEUE_NUM" '$1 == queue { found=1 } END { exit found ? 0 : 1 }' /proc/net/netfilter/nfnetlink_queue 2>/dev/null; then
        die "queue $QUEUE_NUM is already occupied"
    fi
    if iptables-save -t mangle 2>/dev/null | grep -q -e "--queue-num $QUEUE_NUM"; then
        die "queue $QUEUE_NUM already has a firewall rule"
    fi
    iptables -t mangle -nL "$POST_CHAIN" >/dev/null 2>&1 || die "missing $POST_CHAIN"
    if iptables -t mangle -nL "$CANARY_CHAIN" >/dev/null 2>&1; then
        die "temporary chain $CANARY_CHAIN already exists"
    fi
    if [ "$MIHOMO_BYPASS" -eq 1 ]; then
        iptables -t nat -nL "$MIHOMO_CHAIN" >/dev/null 2>&1 || \
            die "missing transparent Mihomo chain $MIHOMO_CHAIN"
        if ! iptables-save -t nat 2>/dev/null | awk -v chain="$MIHOMO_CHAIN" '
            $1 == "-A" && $2 == chain {
                for (i = 3; i < NF; i++) {
                    if ($i == "-j" && $(i + 1) == "REDIRECT") found=1
                }
            }
            END { exit(found ? 0 : 1) }
        '; then
            die "$MIHOMO_CHAIN is not a transparent REDIRECT chain"
        fi
        prepare_port_args
        # Refuse an indistinguishable pre-existing rule: cleanup must only
        # remove the rule that this run added.
        # shellcheck disable=SC2086
        if iptables -t nat -C "$MIHOMO_CHAIN" -s "$TEST_LOCAL_IP" -d "$TEST_REMOTE_IP" -p tcp $OUT_PORT_ARGS -j RETURN 2>/dev/null; then
            die "an identical Mihomo bypass rule already exists"
        fi
    fi

    strategy_args=$(awk '/^--/ { printf "%s ", $0 }' "$STRATEGY_FILE")
    [ -n "$strategy_args" ] || die "strategy is empty"
    # Word splitting is intentional: every strategy line is one nfqws option.
    # shellcheck disable=SC2086
    "$NFQWS_BIN_CANONICAL" --dry-run --qnum="$QUEUE_NUM" $strategy_args >/dev/null || die "nfqws rejected strategy"

    RUN_ID="$(date +%s).$$"
    valid_run_id "$RUN_ID" || die "cannot create run identity"
    [ -n "$PID_FILE" ] || PID_FILE="$LOCK_DIR/nfqws.$RUN_ID.pid"
    [ -n "$WATCHDOG_PID_FILE" ] || WATCHDOG_PID_FILE="$LOCK_DIR/watchdog.$RUN_ID.pid"
    valid_absolute_path "$STATE_FILE" || die "state path contains unsupported characters"
    valid_absolute_path "$LOCK_DIR" || die "lock path contains unsupported characters"
    valid_absolute_path "$PID_FILE" || die "pidfile path contains unsupported characters"
    valid_absolute_path "$WATCHDOG_PID_FILE" || die "watchdog pidfile path contains unsupported characters"
    valid_absolute_path "$WATCHDOG_LOG" || die "watchdog log path contains unsupported characters"
    for runtime_path in "$PID_FILE" "$WATCHDOG_PID_FILE" "$WATCHDOG_LOG"; do
        [ ! -L "$runtime_path" ] || die "runtime path must not be a symlink: $runtime_path"
        [ ! -d "$runtime_path" ] || die "runtime path must not be a directory: $runtime_path"
    done
    if [ "$STATE_FILE" = "$PID_FILE" ] || [ "$STATE_FILE" = "$WATCHDOG_PID_FILE" ] || \
            [ "$STATE_FILE" = "$WATCHDOG_LOG" ] || [ "$PID_FILE" = "$WATCHDOG_PID_FILE" ] || \
            [ "$PID_FILE" = "$WATCHDOG_LOG" ] || [ "$WATCHDOG_PID_FILE" = "$WATCHDOG_LOG" ]; then
        die "canary runtime paths must be distinct"
    fi
    for runtime_path in "$STATE_FILE" "$PID_FILE" "$WATCHDOG_PID_FILE" "$WATCHDOG_LOG"; do
        [ "$runtime_path" != "$LOCK_DIR" ] || die "canary lock path must be a directory only"
    done

    mkdir "$LOCK_DIR" 2>/dev/null || die "cannot acquire canary lock"
    chmod 700 "$LOCK_DIR" || {
        rmdir "$LOCK_DIR" 2>/dev/null || true
        die "cannot protect canary lock"
    }
    start_owner_started=$(proc_starttime "$$") || {
        rmdir "$LOCK_DIR" 2>/dev/null || true
        die "cannot identify canary starter"
    }
    if ! write_runtime_file "$START_OWNER_FILE" "$$ $start_owner_started" start-owner; then
        rm -f "$LOCK_DIR/start-owner.tmp.$$" 2>/dev/null || true
        rmdir "$LOCK_DIR" 2>/dev/null || true
        die "cannot record canary starter"
    fi
    if ! write_state; then
        rm -f "$START_OWNER_FILE" 2>/dev/null || true
        rmdir "$LOCK_DIR" 2>/dev/null || true
        die "cannot write state"
    fi
    trap 'stop_canary >/dev/null 2>&1 || true' HUP INT TERM EXIT
    write_runtime_file "$PID_FILE" "" nfqws-pid || die "cannot prepare nfqws pidfile"
    write_runtime_file "$WATCHDOG_PID_FILE" "" watchdog-pid || die "cannot prepare watchdog pidfile"
    write_runtime_file "$WATCHDOG_LOG" "" watchdog-log || die "cannot prepare watchdog log"
    # shellcheck disable=SC2086
    "$NFQWS_BIN_CANONICAL" --daemon --pidfile="$PID_FILE" --qnum="$QUEUE_NUM" $strategy_args || die "cannot start nfqws"
    wait_step=0
    while [ "$wait_step" -lt 5 ]; do
        secure_runtime_file "$PID_FILE" && [ -s "$PID_FILE" ] && break
        sleep 1
        wait_step=$((wait_step + 1))
    done
    if ! secure_runtime_file "$PID_FILE" || [ ! -s "$PID_FILE" ]; then
        die "nfqws pidfile was not safely created"
    fi
    CANARY_PID=$(cat "$PID_FILE" 2>/dev/null || true)
    valid_process_pid "$CANARY_PID" || die "invalid nfqws pidfile"
    CANARY_STARTTIME=$(proc_starttime "$CANARY_PID") || die "cannot read nfqws process identity"
    canary_process_is_ours "$CANARY_PID" "$CANARY_STARTTIME" || die "nfqws pid does not belong to this canary run"
    write_state || die "cannot record nfqws process identity"

    nohup "$WATCHDOG_SCRIPT" watchdog "$TTL" "$RUN_ID" >> "$WATCHDOG_LOG" 2>&1 &
    WATCHDOG_PID=$!
    valid_process_pid "$WATCHDOG_PID" || die "invalid watchdog pid"
    watchdog_probe=0
    while [ "$watchdog_probe" -lt 5 ]; do
        WATCHDOG_STARTTIME=$(proc_starttime "$WATCHDOG_PID" 2>/dev/null || true)
        WATCHDOG_EXE=$(proc_executable "$WATCHDOG_PID" 2>/dev/null || true)
        if [ -n "$WATCHDOG_STARTTIME" ] && [ -n "$WATCHDOG_EXE" ] && \
                watchdog_process_is_ours "$WATCHDOG_PID" "$WATCHDOG_STARTTIME"; then
            break
        fi
        sleep 1
        watchdog_probe=$((watchdog_probe + 1))
    done
    watchdog_process_is_ours "$WATCHDOG_PID" "$WATCHDOG_STARTTIME" || die "watchdog identity could not be verified"
    write_runtime_file "$WATCHDOG_PID_FILE" "$WATCHDOG_PID $WATCHDOG_STARTTIME $WATCHDOG_EXE" watchdog-pid || \
        die "cannot record watchdog pid"
    write_state || die "cannot record watchdog process identity"

    iptables -t mangle -N "$CANARY_CHAIN" || die "cannot create $CANARY_CHAIN"
    # shellcheck disable=SC2086
    iptables -t mangle -A "$CANARY_CHAIN" -m mark ! --mark "$SKIP_MARK" $OUT_CONNBYTES_ARGS -j NFQUEUE --queue-num "$QUEUE_NUM" --queue-bypass || die "cannot add canary NFQUEUE rule"
    iptables -t mangle -A "$CANARY_CHAIN" -j MARK --set-xmark "$FINAL_MARK" || die "cannot add canary mark rule"
    iptables -t mangle -A "$CANARY_CHAIN" -j RETURN || die "cannot add canary return rule"
    prepare_port_args
    # Word splitting is intentional for the validated port matcher.
    # shellcheck disable=SC2086
    iptables -t mangle -I "$POST_CHAIN" 1 -o "$TEST_OUT_INTERFACE" -s "$TEST_LOCAL_IP" -d "$TEST_REMOTE_IP" -p "$TEST_PROTOCOL" $OUT_PORT_ARGS -j "$CANARY_CHAIN" || die "cannot attach canary chain"
    if [ "$MIHOMO_BYPASS" -eq 1 ]; then
        # The first RETURN skips only Mihomo's REDIRECT for new connections
        # from this client and these TCP ports. It does not accept traffic in
        # the filter table and cannot match the router's SSH port.
        # shellcheck disable=SC2086
        iptables -t nat -I "$MIHOMO_CHAIN" 1 -s "$TEST_LOCAL_IP" -d "$TEST_REMOTE_IP" -p tcp $OUT_PORT_ARGS -j RETURN || die "cannot attach the per-client Mihomo bypass"
    fi

    rm -f "$START_OWNER_FILE" || die "cannot release canary start barrier"
    trap - HUP INT TERM EXIT
    say "Canary active for $TEST_LOCAL_IP -> $TEST_REMOTE_IP via $TEST_OUT_INTERFACE $TEST_PROTOCOL/$TEST_PORTS on queue $QUEUE_NUM; TTL=${TTL}s."
}

status_canary() {
    load_state
    state_rc=$?
    case "$state_rc" in
        0) ;;
        1) say "Canary inactive."; return 1 ;;
        *) printf 'CANARY ERROR: unsafe state (%s).\n' "$STATE_ERROR" >&2; return 2 ;;
    esac
    say "Canary state: $TEST_LOCAL_IP -> $TEST_REMOTE_IP via $TEST_OUT_INTERFACE $TEST_PROTOCOL/$TEST_PORTS queue=$QUEUE_NUM"
    if [ "$MIHOMO_BYPASS" -eq 1 ]; then
        say "Mihomo bypass: $TEST_LOCAL_IP TCP/$TEST_PORTS in $MIHOMO_CHAIN (temporary)"
        iptables -t nat -nvL "$MIHOMO_CHAIN" --line-numbers 2>/dev/null | head -n 8
    fi
    scan_canary_processes
    say "Exact canary processes: $CANARY_MATCH_COUNT"
    grep "^[[:space:]]*${QUEUE_NUM}[[:space:]]" /proc/net/netfilter/nfnetlink_queue 2>/dev/null || true
    iptables -t mangle -nvL "$POST_CHAIN" --line-numbers | head -n 8
    iptables -t mangle -nvL "$CANARY_CHAIN" --line-numbers 2>/dev/null || true
}

watchdog_canary() {
    watchdog_ttl=${1:-60}
    watchdog_run_id=${2:-}
    valid_uint "$watchdog_ttl" || exit 1
    valid_run_id "$watchdog_run_id" || exit 1

    registration_wait=0
    while [ "$registration_wait" -lt 5 ]; do
        if load_state && [ "$RUN_ID" = "$watchdog_run_id" ] && \
                [ "$TTL" = "$watchdog_ttl" ] && [ "$WATCHDOG_PID" = "$$" ] && \
                watchdog_process_is_ours "$WATCHDOG_PID" "$WATCHDOG_STARTTIME"; then
            break
        fi
        sleep 1
        registration_wait=$((registration_wait + 1))
    done
    [ "$registration_wait" -lt 5 ] || exit 1

    watchdog_elapsed=0
    while [ "$watchdog_elapsed" -lt "$watchdog_ttl" ]; do
        sleep 2
        # Keep the validated identity snapshot. If the state disappears, the
        # watchdog can still clean this exact run rather than abandon it.
        if secure_runtime_file "$STATE_FILE"; then
            current_run_id=$(state_value RUN_ID)
            [ "$current_run_id" = "$watchdog_run_id" ] || exit 0
        fi
        scan_canary_processes
        if [ "$CANARY_MATCH_COUNT" -ne 1 ] || \
                ! canary_process_is_ours "$CANARY_PID" "$CANARY_STARTTIME"; then
            cleanup_loaded_run >/dev/null 2>&1 || true
            exit 0
        fi
        watchdog_elapsed=$((watchdog_elapsed + 2))
    done
    cleanup_loaded_run
}

case "${1:-}" in
    start) start_canary ;;
    stop) stop_canary ;;
    status) status_canary ;;
    watchdog) watchdog_canary "${2:-60}" "${3:-}" ;;
    *) die "usage: $0 start|status|stop" ;;
esac
