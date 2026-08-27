#!/bin/sh

PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin
BRIDGE=${KZM_LAN_BRIDGE:-br0}
ETHTOOL=/opt/sbin/ethtool
[ -x "$ETHTOOL" ] || ETHTOOL=$(command -v ethtool 2>/dev/null || true)

affected_hardware() {
    [ -r /proc/device-tree/compatible ] || return 1
    tr '\000' '\n' < /proc/device-tree/compatible | grep -qx 'mediatek,mt7981'
}

apply_fix() {
    affected_hardware || return 0
    [ -n "$ETHTOOL" ] && [ -x "$ETHTOOL" ] || {
        printf '%s\n' 'MT7981 GRO-fix: установите пакет ethtool' >&2
        return 1
    }

    member_count=0
    failed=0
    for lower_path in "/sys/class/net/$BRIDGE"/lower_*; do
        [ -e "$lower_path" ] || continue
        member=${lower_path##*/}
        member=${member#lower_}
        case "$member" in
            ''|*[!A-Za-z0-9_.:-]*) continue ;;
        esac
        member_count=$((member_count + 1))
        "$ETHTOOL" -K "$member" gro off >/dev/null 2>&1 || failed=1
    done
    [ "$member_count" -gt 0 ] || {
        printf 'MT7981 GRO-fix: у моста %s нет интерфейсов\n' "$BRIDGE" >&2
        return 1
    }
    [ "$failed" -eq 0 ]
}

show_status() {
    if affected_hardware; then
        printf '%s\n' 'hardware=mediatek,mt7981'
    else
        printf '%s\n' 'hardware=not-affected'
        return 0
    fi
    [ -n "$ETHTOOL" ] && [ -x "$ETHTOOL" ] || {
        printf '%s\n' 'ethtool=missing'
        return 1
    }
    for lower_path in "/sys/class/net/$BRIDGE"/lower_*; do
        [ -e "$lower_path" ] || continue
        member=${lower_path##*/}
        member=${member#lower_}
        case "$member" in
            ''|*[!A-Za-z0-9_.:-]*) continue ;;
        esac
        gro_state=$(
            "$ETHTOOL" -k "$member" 2>/dev/null |
                awk -F': ' '$1 == "generic-receive-offload" { print $2; exit }'
        )
        printf '%s=%s\n' "$member" "${gro_state:-unknown}"
    done
}

case "${1:-apply}" in
    apply) apply_fix ;;
    status) show_status ;;
    *) printf 'Usage: %s {apply|status}\n' "$0" >&2; exit 2 ;;
esac
