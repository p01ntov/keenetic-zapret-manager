#!/bin/sh

[ "$type" = "iptables" ] || exit 0
[ "$table" = "mangle" ] || exit 0
[ -x /opt/libexec/kzm/mediatek-gro-fix.sh ] || exit 0

/opt/libexec/kzm/mediatek-gro-fix.sh apply >/dev/null 2>&1 || true
