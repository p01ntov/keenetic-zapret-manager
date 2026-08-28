#!/bin/sh

set -u

KZM_ROOT=${KZM_ROOT:-}
KZM_PREFIX=${KZM_PREFIX:-/opt}
KZM_BASE=${KZM_BASE:-${KZM_ROOT}${KZM_PREFIX}}
KZM_ETC=${KZM_ETC:-$KZM_BASE/etc/kzapret-manager}
RUNNING_STATE=${KZM_RUNNING_STATE:-$KZM_ETC/running-state.conf}
IPTABLES=${KZM_IPTABLES:-iptables}
IP6TABLES=${KZM_IP6TABLES:-ip6tables}
CHAIN=KZM_QUIC_REJECT

say() {
    printf '%s\n' "$*"
}

die() {
    printf '[X] %s\n' "$*" >&2
    exit 1
}

mode_from_state() {
    state_file=$1
    state_mode=
    state_legacy=
    if [ -r "$state_file" ]; then
        state_mode=$(sed -n 's/^QUIC_MODE=//p' "$state_file" | sed -n '1p')
        state_legacy=$(sed -n 's/^QUIC_ENABLED=//p' "$state_file" | sed -n '1p')
    fi
    case "$state_mode" in
        bypass|block|off) printf '%s\n' "$state_mode" ;;
        '')
            if [ "$state_legacy" = 1 ]; then
                printf 'bypass\n'
            else
                printf 'off\n'
            fi
            ;;
        *) return 1 ;;
    esac
}

family_binary() {
    case "$1" in
        ipv4) printf '%s\n' "$IPTABLES" ;;
        ipv6) printf '%s\n' "$IP6TABLES" ;;
        *) return 1 ;;
    esac
}

family_reject_type() {
    case "$1" in
        ipv4) printf 'icmp-port-unreachable\n' ;;
        ipv6) printf 'icmp6-port-unreachable\n' ;;
        *) return 1 ;;
    esac
}

family_available() {
    family_command=$(family_binary "$1") || return 1
    command -v "$family_command" >/dev/null 2>&1
}

chain_exists() {
    chain_command=$1
    "$chain_command" -nL "$CHAIN" >/dev/null 2>&1
}

delete_jumps() {
    jump_command=$1
    for jump_chain in FORWARD INPUT; do
        while "$jump_command" -C "$jump_chain" -j "$CHAIN" >/dev/null 2>&1; do
            "$jump_command" -D "$jump_chain" -j "$CHAIN" >/dev/null 2>&1 || return 1
        done
    done
}

remove_family() {
    remove_family_name=$1
    family_available "$remove_family_name" || return 0
    remove_command=$(family_binary "$remove_family_name") || return 1
    delete_jumps "$remove_command" || return 1
    if chain_exists "$remove_command"; then
        "$remove_command" -F "$CHAIN" >/dev/null 2>&1 || return 1
        "$remove_command" -X "$CHAIN" >/dev/null 2>&1 || return 1
    fi
}

apply_family() {
    apply_family_name=$1
    family_available "$apply_family_name" || {
        [ "$apply_family_name" = ipv6 ] && return 0
        return 1
    }
    apply_command=$(family_binary "$apply_family_name") || return 1
    reject_type=$(family_reject_type "$apply_family_name") || return 1

    delete_jumps "$apply_command" || return 1
    if chain_exists "$apply_command"; then
        "$apply_command" -F "$CHAIN" >/dev/null 2>&1 || return 1
    else
        "$apply_command" -N "$CHAIN" >/dev/null 2>&1 || return 1
    fi
    "$apply_command" -A "$CHAIN" -p udp --dport 443 \
        -j REJECT --reject-with "$reject_type" >/dev/null 2>&1 || return 1
    if ! "$apply_command" -I FORWARD 1 -j "$CHAIN" >/dev/null 2>&1 || \
            ! "$apply_command" -I INPUT 1 -j "$CHAIN" >/dev/null 2>&1; then
        remove_family "$apply_family_name" >/dev/null 2>&1 || true
        return 1
    fi
}

apply_mode_family() {
    policy_mode=$1
    policy_family=$2
    case "$policy_mode" in
        block) apply_family "$policy_family" ;;
        bypass|off) remove_family "$policy_family" ;;
        *) return 1 ;;
    esac
}

apply_mode() {
    policy_mode=$1
    policy_family=${2:-all}
    case "$policy_mode" in bypass|block|off) ;; *) die "режим должен быть bypass, block или off" ;; esac
    case "$policy_family" in
        ipv4|ipv6)
            apply_mode_family "$policy_mode" "$policy_family" ||
                die "не удалось применить QUIC policy для $policy_family"
            ;;
        all)
            if ! apply_mode_family "$policy_mode" ipv4; then
                die "не удалось применить QUIC policy для IPv4"
            fi
            if ! apply_mode_family "$policy_mode" ipv6; then
                apply_mode_family off ipv4 >/dev/null 2>&1 || true
                die "не удалось применить QUIC policy для IPv6; IPv4-правило удалено"
            fi
            ;;
        *) die "семейство должно быть all, ipv4 или ipv6" ;;
    esac
}

family_status() {
    status_family=$1
    if ! family_available "$status_family"; then
        printf 'unavailable'
        return
    fi
    status_command=$(family_binary "$status_family") || return 1
    if chain_exists "$status_command" && \
            "$status_command" -C FORWARD -j "$CHAIN" >/dev/null 2>&1 && \
            "$status_command" -C INPUT -j "$CHAIN" >/dev/null 2>&1 && \
            "$status_command" -C "$CHAIN" -p udp --dport 443 \
                -j REJECT --reject-with "$(family_reject_type "$status_family")" >/dev/null 2>&1; then
        printf 'block'
    else
        printf 'off'
    fi
}

command_name=${1:-status}
case "$command_name" in
    apply)
        [ "$#" -ge 2 ] || die "apply требует режим"
        apply_mode "$2" "${3:-all}"
        ;;
    reconcile)
        running_mode=$(mode_from_state "$RUNNING_STATE") || die "некорректный QUIC_MODE в $RUNNING_STATE"
        apply_mode "$running_mode" "${2:-all}"
        ;;
    status)
        running_mode=$(mode_from_state "$RUNNING_STATE") || running_mode=invalid
        say "mode=$running_mode ipv4=$(family_status ipv4) ipv6=$(family_status ipv6)"
        ;;
    *) die "использование: quic-policy.sh apply MODE [all|ipv4|ipv6], reconcile [all|ipv4|ipv6] или status" ;;
esac
