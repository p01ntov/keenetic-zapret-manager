#!/bin/sh

# Keenetic supplies `type` and `table` to every netfilter hook.
# shellcheck disable=SC2154
[ "$table" = "filter" ] || exit 0
HELPER=${KZM_QUIC_POLICY_HELPER:-/opt/libexec/kzm/quic-policy.sh}
[ -x "$HELPER" ] || exit 0

# shellcheck disable=SC2154
case "$type" in
    iptables) family=ipv4 ;;
    ip6tables) family=ipv6 ;;
    *) exit 0 ;;
esac

"$HELPER" reconcile "$family" >/dev/null 2>&1 || true
