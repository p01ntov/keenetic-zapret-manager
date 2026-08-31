#!/bin/sh

set -u
umask 077

# Entware utilities are not guaranteed to be in root's non-interactive PATH.
# Resolve tools only after putting the standard Keenetic/Entware paths first.
PATH="/opt/usr/sbin:/opt/usr/bin:/opt/sbin:/opt/bin:${PATH:-/usr/sbin:/usr/bin:/sbin:/bin}"
export PATH

KZM_VERSION="0.8.4"
KZM_ROOT="${KZM_ROOT:-}"
KZM_PREFIX="${KZM_PREFIX:-/opt}"
KZM_BASE="${KZM_BASE:-${KZM_ROOT}${KZM_PREFIX}}"
KZM_ETC="${KZM_ETC:-$KZM_BASE/etc/kzapret-manager}"
KZM_LIBEXEC="${KZM_LIBEXEC:-$KZM_BASE/libexec/kzm}"
KZM_SHARE="${KZM_SHARE:-$KZM_BASE/share/kzm}"
KZM_BIN="${KZM_BIN:-$KZM_BASE/bin/kzm}"

COMPONENT_DIR="$KZM_ETC/components"
BIN_DIR="$KZM_BASE/usr/bin"
INIT_DIR="$KZM_BASE/etc/init.d"
RUN_DIR="$KZM_BASE/var/run"
LOG_DIR="$KZM_BASE/var/log"
SERVICE_HELPER="$KZM_LIBEXEC/tg-proxy-service.sh"
RELEASE_PARSER="$KZM_LIBEXEC/parse-github-release.awk"
NFQWS_BIN="${NFQWS_BIN:-$KZM_BASE/usr/bin/nfqws}"
NFQWS_INIT="${NFQWS_INIT:-$INIT_DIR/S51nfqws}"

GITHUB_API_BASE="${KZM_GITHUB_API_BASE:-https://api.github.com}"
CURL_BIN="${KZM_CURL_BIN:-$(command -v curl 2>/dev/null || true)}"
TAR_BIN="${KZM_TAR_BIN:-$(command -v tar 2>/dev/null || true)}"
SHA256_BIN="${KZM_SHA256_BIN:-$(command -v sha256sum 2>/dev/null || true)}"
IP_BIN="${KZM_IP_BIN:-$(command -v ip 2>/dev/null || true)}"
MAX_DOWNLOAD_BYTES="${KZM_MAX_DOWNLOAD_BYTES:-33554432}"
MAX_BINARY_BYTES="${KZM_MAX_BINARY_BYTES:-33554432}"
MAX_LIST_BYTES="${KZM_MAX_LIST_BYTES:-1048576}"

TMP_DIR=""
TMP_BASE=""
MANAGER_LOCK_DIR=""
MANAGER_LOCK_PID=""
RESOLVED_TAG=""
RESOLVED_ASSET=""
RESOLVED_DIGEST=""
RESOLVED_URL=""
RESOLVED_BINARY_SHA=""

UI_RESET=
UI_DIM=
UI_NUMBER=
UI_GOOD=
UI_BAD=
UI_WARN=

init_ui_colors() {
    case "${KZM_COLOR:-auto}" in
        always) ui_color_enabled=1 ;;
        never) ui_color_enabled=0 ;;
        auto)
            if [ -t 1 ] 2>/dev/null && [ -n "${TERM:-}" ] && [ "$TERM" != dumb ] && [ -z "${NO_COLOR:-}" ]; then
                ui_color_enabled=1
            else
                ui_color_enabled=0
            fi
            ;;
        *) ui_color_enabled=0 ;;
    esac
    [ "$ui_color_enabled" -eq 1 ] || return 0
    ui_escape=$(printf '\033')
    UI_RESET="${ui_escape}[0m"
    UI_DIM="${ui_escape}[2m"
    UI_NUMBER="${ui_escape}[36m"
    UI_GOOD="${ui_escape}[32m"
    UI_BAD="${ui_escape}[31m"
    UI_WARN="${ui_escape}[33m"
}

init_ui_colors

say() {
    printf '%s\n' "$*"
}

warn() {
    printf '%s[!]%s %s\n' "$UI_WARN" "$UI_RESET" "$*" >&2
}

die() {
    printf '%s[X]%s %s\n' "$UI_BAD" "$UI_RESET" "$*" >&2
    exit 1
}

menu_option() {
    menu_option_key=$1
    shift
    printf '  %s%s)%s %s\n' "$UI_NUMBER" "$menu_option_key" "$UI_RESET" "$*"
}

menu_back_option() {
    printf '  %sEnter)%s %s\n' "$UI_DIM" "$UI_RESET" "$*"
}

allow_test_artifacts() {
    [ "${KZM_ALLOW_TEST_ARTIFACTS:-0}" = "1" ] || return 1
    [ -n "$KZM_ROOT" ] && [ "$KZM_PREFIX" = /opt ] && [ "$KZM_BASE" = "$KZM_ROOT/opt" ] || return 1
    canonical_test_root=$(CDPATH='' cd -P "$KZM_ROOT" 2>/dev/null && pwd) || return 1
    [ "$canonical_test_root" = "$KZM_ROOT" ] || return 1
    [ -d "$KZM_BASE" ] || return 1
    canonical_test_base=$(CDPATH='' cd -P "$KZM_BASE" 2>/dev/null && pwd) || return 1
    [ "$canonical_test_base" = "$canonical_test_root/opt" ] || return 1
    test_root_parent=${KZM_ROOT%/*}
    test_root_name=${KZM_ROOT##*/}
    [ "$test_root_parent" = /tmp ] || return 1
    case "$test_root_name" in
        kzm-components-test.*|kzm-components-live|kzm-components-live.*|kzm-components-live-*) return 0 ;;
        *) return 1 ;;
    esac
}

validate_test_artifact_mode() {
    [ "${KZM_ALLOW_TEST_ARTIFACTS:-0}" = "1" ] || return 0
    allow_test_artifacts || \
        die "тестовые assets разрешены только внутри безопасного изолированного KZM_ROOT"
}

cleanup_tmp() {
    if [ -n "$TMP_DIR" ]; then
        case "$TMP_DIR" in
            "$TMP_BASE"/kzm-components.*)
                rm -rf "$TMP_DIR"
                ;;
        esac
    fi
    TMP_DIR=""
}

make_tmp() {
    cleanup_tmp
    if [ -n "$KZM_ROOT" ]; then
        TMP_BASE="$KZM_ROOT/tmp"
        mkdir -p "$TMP_BASE" || die "не удалось создать тестовый временный каталог"
    else
        # Production downloads must stay on tmpfs. In particular, ignore an
        # Entware TMPDIR=/opt/tmp so release assets cannot accumulate on flash.
        TMP_BASE=/tmp
    fi
    TMP_DIR=$(mktemp -d "$TMP_BASE/kzm-components.XXXXXX") || die "не удалось создать временный каталог"
    trap cleanup_all 0
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

cleanup_manager_lock() {
    [ -n "$MANAGER_LOCK_DIR" ] || return 0
    if [ -d "$MANAGER_LOCK_DIR" ] && [ ! -L "$MANAGER_LOCK_DIR" ] && \
            [ -f "$MANAGER_LOCK_DIR/owner" ] && [ ! -L "$MANAGER_LOCK_DIR/owner" ] && \
            [ "$(cat "$MANAGER_LOCK_DIR/owner" 2>/dev/null)" = "$MANAGER_LOCK_PID" ]; then
        rm -f "$MANAGER_LOCK_DIR/owner" || return 1
        rmdir "$MANAGER_LOCK_DIR" 2>/dev/null || return 1
    fi
    MANAGER_LOCK_DIR=""
    MANAGER_LOCK_PID=""
}

cleanup_all() {
    cleanup_tmp
    cleanup_manager_lock || true
}

acquire_manager_lock() {
    lock_component=$1
    [ -z "$MANAGER_LOCK_DIR" ] || die "внутренняя ошибка блокировки компонентов"
    ensure_layout
    lock_path="$RUN_DIR/kzm-tg-$lock_component.manage.lock"
    if ! mkdir "$lock_path" 2>/dev/null; then
        [ ! -L "$lock_path" ] || die "блокировка компонента является символической ссылкой"
        [ -d "$lock_path" ] || die "путь блокировки компонента небезопасен"
        [ ! -L "$lock_path/owner" ] || die "owner блокировки является символической ссылкой"
        lock_owner=$(cat "$lock_path/owner" 2>/dev/null || true)
        case "$lock_owner" in
            ''|*[!0-9]*)
                sleep 1
                [ ! -L "$lock_path/owner" ] || die "owner блокировки является символической ссылкой"
                lock_owner=$(cat "$lock_path/owner" 2>/dev/null || true)
                ;;
        esac
        case "$lock_owner" in
            ''|*[!0-9]*) die "у блокировки компонента нет безопасного owner" ;;
            *) if kill -0 "$lock_owner" 2>/dev/null; then lock_live=1; else lock_live=0; fi ;;
        esac
        if [ "$lock_live" -eq 1 ]; then
            die "для $(component_short_title "$lock_component") уже выполняется другая операция"
        fi
        [ "$(cat "$lock_path/owner" 2>/dev/null)" = "$lock_owner" ] || die "блокировка изменилась во время проверки"
        rm -f "$lock_path/owner" 2>/dev/null || die "не удалось убрать повреждённую блокировку"
        rmdir "$lock_path" 2>/dev/null || die "не удалось убрать повреждённую блокировку"
        mkdir "$lock_path" 2>/dev/null || die "не удалось занять блокировку компонента"
    fi
    printf '%s\n' "$$" > "$lock_path/owner" || {
        rmdir "$lock_path" 2>/dev/null || true
        die "не удалось записать владельца блокировки"
    }
    MANAGER_LOCK_DIR=$lock_path
    MANAGER_LOCK_PID=$$
    trap cleanup_all 0
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

ensure_layout() {
    mkdir -p "$COMPONENT_DIR" "$BIN_DIR" "$INIT_DIR" "$RUN_DIR" "$LOG_DIR" || die "не удалось создать каталоги компонентов"
    # A proxy runs as nobody and must be able to traverse the executable path.
    chmod 755 "$KZM_BASE/usr" "$BIN_DIR" || die "не удалось открыть путь бинарников для непривилегированного сервиса"
}

menu_clear() {
    if [ -t 1 ] && command -v clear >/dev/null 2>&1; then
        clear
    fi
}

menu_pause() {
    printf '\nНажмите Enter...'
    IFS= read -r _pause_value || true
}

confirm_numeric() {
    confirm_text=$1
    printf '%s\n\n' "$confirm_text"
    menu_option 1 "Да"
    menu_back_option "Нет"
    printf '\n'
    printf 'Выберите пункт: '
    IFS= read -r confirm_choice || return 1
    [ "$confirm_choice" = "1" ]
}

component_valid() {
    case "$1" in
        socks5|rust|mtproto) return 0 ;;
        *) return 1 ;;
    esac
}

component_title() {
    case "$1" in
        socks5) say "TG WS Proxy SOCKS5 - by d0mhate" ;;
        rust) say "TG WS Proxy Rust v2 - by p01ntov" ;;
        mtproto) say "TG WS Proxy MTProto - by spatiumstas" ;;
        *) say "$1" ;;
    esac
}

component_short_title() {
    case "$1" in
        socks5) say "TG SOCKS5" ;;
        rust) say "TG Rust MTProto" ;;
        mtproto) say "TG MTProto" ;;
        *) say "$1" ;;
    esac
}

component_binary() {
    say "$BIN_DIR/kzm-tg-$1"
}

component_config() {
    say "$COMPONENT_DIR/$1.conf"
}

component_source() {
    say "$COMPONENT_DIR/$1.source"
}

component_init() {
    say "$INIT_DIR/S99kzm-tg-$1"
}

component_autostart() {
    say "$COMPONENT_DIR/$1.autostart"
}

component_installed() {
    [ -x "$(component_binary "$1")" ] && [ -x "$(component_init "$1")" ] && [ -r "$(component_config "$1")" ]
}

sha256_text_valid() {
    complete_sha_value=$1
    case "$complete_sha_value" in ''|*[!0-9A-Fa-f]*) return 1 ;; esac
    [ "${#complete_sha_value}" -eq 64 ]
}

component_install_complete() {
    complete_component=$1
    component_installed "$complete_component" || return 1
    complete_source=$(component_source "$complete_component")
    [ -f "$complete_source" ] && [ ! -L "$complete_source" ] && [ -r "$complete_source" ] || return 1
    complete_repo=$(config_value REPO "$complete_source")
    complete_tag=$(config_value TAG "$complete_source")
    complete_asset=$(config_value ASSET "$complete_source")
    complete_sha=$(config_value SHA256 "$complete_source")
    complete_binary_sha=$(config_value BINARY_SHA256 "$complete_source")
    [ "$complete_repo" = "$(component_repo "$complete_component")" ] || return 1
    case "$complete_tag" in ''|*[!A-Za-z0-9._+-]*) return 1 ;; esac
    case "$complete_asset" in ''|*[!A-Za-z0-9._+-]*) return 1 ;; esac
    sha256_text_valid "$complete_sha" || return 1
    sha256_text_valid "$complete_binary_sha" || return 1
}

component_present() {
    present_component=$1
    present_binary=$(component_binary "$present_component")
    present_init=$(component_init "$present_component")
    present_config=$(component_config "$present_component")
    present_source=$(component_source "$present_component")
    present_autostart=$(component_autostart "$present_component")
    for present_path in \
        "$present_binary" "$present_binary".new.* "$present_binary".old.* \
        "$present_init" "$present_init".tmp.* \
        "$present_config" "$present_config".tmp.* \
        "$present_source" "$present_source".tmp.* \
        "$present_autostart" "$present_autostart".tmp.* \
        "$RUN_DIR/kzm-tg-$present_component.pid" "$RUN_DIR/kzm-tg-$present_component.pid".tmp.* \
        "$LOG_DIR/kzm-tg-$present_component.log"; do
        [ -e "$present_path" ] || [ -L "$present_path" ] || continue
        return 0
    done
    return 1
}

remove_component_artifacts() {
    artifact_component=$1
    artifact_binary=$(component_binary "$artifact_component")
    artifact_init=$(component_init "$artifact_component")
    artifact_config=$(component_config "$artifact_component")
    artifact_source=$(component_source "$artifact_component")
    artifact_autostart=$(component_autostart "$artifact_component")
    rm -f \
        "$artifact_binary" "$artifact_binary".new.* "$artifact_binary".old.* \
        "$artifact_init" "$artifact_init".tmp.* \
        "$artifact_config" "$artifact_config".tmp.* \
        "$artifact_source" "$artifact_source".tmp.* \
        "$artifact_autostart" "$artifact_autostart".tmp.* \
        "$RUN_DIR/kzm-tg-$artifact_component.pid" "$RUN_DIR/kzm-tg-$artifact_component.pid".tmp.* \
        "$LOG_DIR/kzm-tg-$artifact_component.log"
}

remove_stale_transaction_temps() {
    stale_component=$1
    stale_binary=$(component_binary "$stale_component")
    stale_init=$(component_init "$stale_component")
    stale_config=$(component_config "$stale_component")
    stale_source=$(component_source "$stale_component")
    stale_autostart=$(component_autostart "$stale_component")
    rm -f \
        "$stale_binary".new.* \
        "$stale_init".tmp.* \
        "$stale_config".tmp.* \
        "$stale_source".tmp.* \
        "$stale_autostart".tmp.* \
        "$RUN_DIR/kzm-tg-$stale_component.pid".tmp.*
}

remove_old_rollback_artifacts() {
    rollback_component=$1
    rollback_binary=$(component_binary "$rollback_component")
    rm -f "$rollback_binary".old.*
}

service_action() {
    service_component=$1
    service_command=$2
    component_valid "$service_component" || die "неизвестный компонент: $service_component"
    [ -x "$SERVICE_HELPER" ] || die "не найден $SERVICE_HELPER"
    KZM_COMPONENT="$service_component" KZM_ROOT="$KZM_ROOT" KZM_PREFIX="$KZM_PREFIX" \
        KZM_MANAGER_LOCK_PID="$MANAGER_LOCK_PID" "$SERVICE_HELPER" "$service_command"
}

component_running() {
    component_installed "$1" || return 1
    service_action "$1" status >/dev/null 2>&1
}

component_active_rc() {
    active_component=$1
    active_rc=0
    service_action "$active_component" active >/dev/null 2>&1 || active_rc=$?
    return "$active_rc"
}

manager_service_barrier() {
    barrier_component=$1
    service_action "$barrier_component" barrier >/dev/null || die "не удалось дождаться завершения другой операции компонента"
}

component_state_ru() {
    state_component=$1
    if ! component_installed "$state_component"; then
        if component_present "$state_component"; then
            say "установка повреждена"
        else
            say "не установлен"
        fi
    elif ! component_install_complete "$state_component"; then
        if component_running "$state_component"; then
            say "установка не завершена, процесс запущен"
        else
            say "установка не завершена"
        fi
    elif component_running "$state_component"; then
        source_tag=$(config_value TAG "$(component_source "$state_component")")
        [ -n "$source_tag" ] || source_tag="версия неизвестна"
        if [ -f "$(component_autostart "$state_component")" ]; then
            say "запущен, автозапуск включён ($source_tag)"
        else
            say "запущен до перезагрузки ($source_tag)"
        fi
    else
        source_tag=$(config_value TAG "$(component_source "$state_component")")
        [ -n "$source_tag" ] || source_tag="версия неизвестна"
        if [ -f "$(component_autostart "$state_component")" ]; then
            say "не запущен, автозапуск включён ($source_tag)"
        else
            say "установлен, остановлен ($source_tag)"
        fi
    fi
}

zapret_installed() {
    [ -x "$NFQWS_BIN" ] || [ -x "$NFQWS_INIT" ]
}

zapret_running() {
    # Some Keenetic BusyBox builds expose pgrep but reject `-x`. pidof is
    # available on the target and gives the exact process name we need.
    if command -v pidof >/dev/null 2>&1 && pidof nfqws >/dev/null 2>&1; then
        return 0
    fi
    if command -v pgrep >/dev/null 2>&1 && pgrep -x nfqws >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

zapret_state_ru() {
    if ! zapret_installed; then
        say "не установлен"
    elif zapret_running; then
        say "установлен, запущен"
    else
        say "установлен, не запущен"
    fi
}

component_state_ui() {
    state_ui_component=$1
    state_ui_text=$(component_state_ru "$state_ui_component")
    if ! component_installed "$state_ui_component"; then
        if component_present "$state_ui_component"; then
            printf '%s[X]%s %s' "$UI_BAD" "$UI_RESET" "$state_ui_text"
        else
            printf '%s[ ]%s %s' "$UI_DIM" "$UI_RESET" "$state_ui_text"
        fi
    elif ! component_install_complete "$state_ui_component"; then
        printf '%s[!]%s %s' "$UI_WARN" "$UI_RESET" "$state_ui_text"
    elif component_running "$state_ui_component"; then
        printf '%s[OK]%s %s' "$UI_GOOD" "$UI_RESET" "$state_ui_text"
    else
        printf '%s[!]%s %s' "$UI_WARN" "$UI_RESET" "$state_ui_text"
    fi
}

zapret_state_ui() {
    zapret_ui_text=$(zapret_state_ru)
    if ! zapret_installed; then
        printf '%s[ ]%s %s' "$UI_DIM" "$UI_RESET" "$zapret_ui_text"
    elif zapret_running; then
        printf '%s[OK]%s %s' "$UI_GOOD" "$UI_RESET" "$zapret_ui_text"
    else
        printf '%s[X]%s %s' "$UI_BAD" "$UI_RESET" "$zapret_ui_text"
    fi
}

config_value() {
    value_key=$1
    value_file=$2
    [ -r "$value_file" ] || return 0
    awk -F= -v key="$value_key" '
        $1 == key {
            value = substr($0, length($1) + 2)
            if (value ~ /^[A-Za-z0-9._:+@\/=-]*$/) print value
            exit
        }
    ' "$value_file"
}

detect_lan_ip() {
    lan_ip=""
    if [ -n "$IP_BIN" ] && [ -x "$IP_BIN" ]; then
        lan_ip=$("$IP_BIN" -o -4 addr show dev br0 scope global 2>/dev/null | awk 'NR == 1 { split($4, a, "/"); print a[1] }')
        if [ -z "$lan_ip" ]; then
            lan_ip=$("$IP_BIN" -o -4 addr show dev br-lan scope global 2>/dev/null | awk 'NR == 1 { split($4, a, "/"); print a[1] }')
        fi
    fi
    case "$lan_ip" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) say "$lan_ip" ;;
        *) return 1 ;;
    esac
}

file_size_bytes() {
    size_file=$1
    wc -c < "$size_file" 2>/dev/null | tr -d ' '
}

require_size_at_most() {
    size_file=$1
    size_limit=$2
    size_label=$3
    size_actual=$(file_size_bytes "$size_file")
    case "$size_actual" in ''|*[!0-9]*) die "не удалось определить размер: $size_label" ;; esac
    [ "$size_actual" -le "$size_limit" ] || die "$size_label превышает безопасный лимит $size_limit байт"
}

validate_resource_limits() {
    for resource_limit in "$MAX_DOWNLOAD_BYTES" "$MAX_BINARY_BYTES" "$MAX_LIST_BYTES"; do
        case "$resource_limit" in ''|*[!0-9]*|0) die "некорректный лимит размера" ;; esac
        [ "$resource_limit" -le 67108864 ] || die "лимит размера не может превышать 64 MiB"
    done
    DOWNLOAD_LIMIT_BLOCKS=$(( (MAX_DOWNLOAD_BYTES + 511) / 512 ))
    BINARY_LIMIT_BLOCKS=$(( (MAX_BINARY_BYTES + 511) / 512 ))
    LIST_LIMIT_BLOCKS=$(( (MAX_LIST_BYTES + 511) / 512 ))
    ( ulimit -f "$LIST_LIMIT_BLOCKS" ) 2>/dev/null || die "shell не поддерживает ограничение размера временных файлов"
}

limited_download_command() (
    ulimit -f "$DOWNLOAD_LIMIT_BLOCKS" 2>/dev/null || exit 125
    "$@"
)

limited_archive_command() (
    ulimit -f "$BINARY_LIMIT_BLOCKS" 2>/dev/null || exit 125
    "$@"
)

limited_list_command() (
    ulimit -f "$LIST_LIMIT_BLOCKS" 2>/dev/null || exit 125
    "$@"
)

hex_tokens_valid() {
    hex_expected_count=$1
    shift
    [ "$#" -eq "$hex_expected_count" ] || return 1
    for hex_token in "$@"; do
        case "$hex_token" in
            [0-9A-Fa-f][0-9A-Fa-f]) ;;
            *) return 1 ;;
        esac
    done
}

read_hex_bytes() {
    hex_read_count=$1
    hex_read_source=$2
    case "$hex_read_count" in ''|*[!0-9]*|0) return 1 ;; esac
    [ -r "$hex_read_source" ] || return 1

    # BusyBox hexdump supports this format and `-v` disables the `*` marker
    # used for repeated rows. Validate its output before trusting it because
    # implementations differ across Entware and desktop test environments.
    if command -v hexdump >/dev/null 2>&1; then
        hex_read_value=$(hexdump -v -n "$hex_read_count" -e '1/1 "%02x "' \
            "$hex_read_source" 2>/dev/null) || hex_read_value=""
        # shellcheck disable=SC2086
        set -- $hex_read_value
        if hex_tokens_valid "$hex_read_count" "$@"; then
            printf '%s\n' "$*"
            return 0
        fi
    fi

    # BusyBox od lacks GNU `-A`, `-N` and `-t`, but portable byte-octal mode
    # is available. Limit the input with dd, discard od offsets in awk and
    # convert each three-digit octet to the same two-digit hex representation.
    if command -v dd >/dev/null 2>&1 && command -v od >/dev/null 2>&1; then
        hex_read_value=$(
            dd if="$hex_read_source" bs=1 count="$hex_read_count" 2>/dev/null |
                od -b 2>/dev/null |
                awk '
                    function octet_to_decimal(value) {
                        return (substr(value, 1, 1) * 64) + \
                            (substr(value, 2, 1) * 8) + substr(value, 3, 1)
                    }
                    {
                        for (i = 2; i <= NF; i++) {
                            if ($i ~ /^[0-7][0-7][0-7]$/) {
                                printf "%02x ", octet_to_decimal($i)
                            }
                        }
                    }
                '
        ) || hex_read_value=""
        # shellcheck disable=SC2086
        set -- $hex_read_value
        if hex_tokens_valid "$hex_read_count" "$@"; then
            printf '%s\n' "$*"
            return 0
        fi
    fi

    return 1
}

random_hex() {
    random_bytes=$1
    case "$random_bytes" in ''|*[!0-9]*|0) return 1 ;; esac
    random_hex_expected=$((random_bytes * 2))
    random_hex_value=""
    random_hex_attempt=0
    while [ "$random_hex_attempt" -lt 3 ]; do
        random_hex_attempt=$((random_hex_attempt + 1))
        random_hex_value=$(read_hex_bytes "$random_bytes" /dev/urandom 2>/dev/null | tr -d ' \n') || \
            random_hex_value=""
        case "$random_hex_value" in
            *[!0-9A-Fa-f]*) continue ;;
        esac
        if [ "${#random_hex_value}" -eq "$random_hex_expected" ]; then
            printf '%s' "$random_hex_value"
            return 0
        fi
    done
    return 1
}

private_ipv4_value_valid() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i=1; i<=4; i++) {
                if ($i !~ /^[0-9]+$/ || $i+0 > 255 || ($i ~ /^0[0-9]/)) exit 1
            }
            if ($1 == 10 || ($1 == 192 && $2 == 168) || ($1 == 172 && $2 >= 16 && $2 <= 31)) exit 0
            exit 1
        }
    '
}

port_value_valid() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

url_token_valid() {
    case "$1" in ''|*[!A-Za-z0-9._~-]*) return 1 ;; *) return 0 ;; esac
}

secret_hex_valid() {
    printf '%s\n' "$1" | awk 'length($0) == 32 && $0 ~ /^[0-9A-Fa-f]+$/ { ok=1 } END { exit(ok ? 0 : 1) }'
}

write_default_config() {
    config_component=$1
    config_path=$(component_config "$config_component")
    [ -e "$config_path" ] && return 0
    lan_ip=$(detect_lan_ip) || die "не удалось определить приватный LAN IPv4; конфиг не создан"
    config_tmp="$config_path.tmp.$$"
    case "$config_component" in
        socks5)
            password=$(random_hex 16) || die "не удалось создать пароль"
            {
                printf 'HOST=%s\n' "$lan_ip"
                printf 'PORT=1080\n'
                printf 'USERNAME=telegram\n'
                printf 'PASSWORD=%s\n' "$password"
            } > "$config_tmp" || {
                rm -f "$config_tmp" 2>/dev/null || true
                die "не удалось создать конфиг SOCKS5"
            }
            ;;
        rust)
            secret=$(random_hex 16) || die "не удалось создать секрет"
            {
                printf 'HOST=%s\n' "$lan_ip"
                printf 'PORT=2443\n'
                printf 'SECRET=%s\n' "$secret"
                printf 'POOL_SIZE=2\n'
                printf 'MAX_CONNECTIONS=32\n'
            } > "$config_tmp" || {
                rm -f "$config_tmp" 2>/dev/null || true
                die "не удалось создать конфиг Rust"
            }
            ;;
        mtproto)
            secret=$(random_hex 16) || die "не удалось создать секрет"
            {
                printf 'HOST=%s\n' "$lan_ip"
                printf 'PORT=1443\n'
                printf 'SECRET=%s\n' "$secret"
                printf 'DC_IP_DEFAULT=149.154.167.220\n'
            } > "$config_tmp" || {
                rm -f "$config_tmp" 2>/dev/null || true
                die "не удалось создать конфиг MTProto"
            }
            ;;
    esac
    chmod 600 "$config_tmp" || {
        rm -f "$config_tmp" 2>/dev/null || true
        die "не удалось защитить конфиг"
    }
    mv "$config_tmp" "$config_path" || {
        rm -f "$config_tmp" 2>/dev/null || true
        die "не удалось применить конфиг"
    }
}

download_file() {
    download_url=$1
    download_target=$2
    if [ -z "$CURL_BIN" ] || [ ! -x "$CURL_BIN" ]; then
        die "нужен curl"
    fi
    limited_download_command "$CURL_BIN" -fsSL --connect-timeout 15 --max-time 180 --max-filesize "$MAX_DOWNLOAD_BYTES" \
        -H 'Accept: application/vnd.github+json' -o "$download_target" "$download_url" || die "не удалось скачать $download_url"
    [ -s "$download_target" ] || die "скачан пустой файл"
    require_size_at_most "$download_target" "$MAX_DOWNLOAD_BYTES" "скачанный файл"
}

release_asset_matches() {
    match_component=$1
    match_asset=$2
    case "$match_component:$match_asset" in
        socks5:tg-ws-proxy-openwrt-aarch64) return 0 ;;
        rust:tg-ws-proxy-v2-aarch64-musl) return 0 ;;
        mtproto:tg-ws-proxy_*_entware_aarch64-3.10.ipk) return 0 ;;
        *) return 1 ;;
    esac
}

component_repo() {
    case "$1" in
        socks5) say "d0mhate/-tg-ws-proxy-Manager-go" ;;
        rust) say "p01ntov/tg-ws-proxy-rs-private" ;;
        mtproto) say "spatiumstas/tg-ws-proxy-go" ;;
    esac
}

resolve_from_json() {
    resolve_component=$1
    resolve_json=$2
    resolve_tsv="$TMP_DIR/releases.tsv"
    awk -f "$RELEASE_PARSER" "$resolve_json" > "$resolve_tsv" || return 1
    while IFS='|' read -r candidate_tag candidate_asset candidate_digest candidate_url; do
        release_asset_matches "$resolve_component" "$candidate_asset" || continue
        RESOLVED_TAG=$candidate_tag
        RESOLVED_ASSET=$candidate_asset
        RESOLVED_DIGEST=$candidate_digest
        RESOLVED_URL=$candidate_url
        return 0
    done < "$resolve_tsv"
    return 1
}

resolve_release() {
    resolve_component=$1
    [ -r "$RELEASE_PARSER" ] || die "не найден parser GitHub API"
    repo=$(component_repo "$resolve_component")
    api_json="$TMP_DIR/release.json"
    download_file "$GITHUB_API_BASE/repos/$repo/releases/latest" "$api_json"
    resolve_from_json "$resolve_component" "$api_json" || die "в последнем опубликованном релизе нет подходящего asset для aarch64"
    case "$RESOLVED_TAG" in ''|*[!A-Za-z0-9._+-]*) die "GitHub вернул небезопасный tag" ;; esac
    case "$RESOLVED_ASSET" in ''|*[!A-Za-z0-9._+-]*) die "GitHub вернул небезопасное имя asset" ;; esac
    case "$RESOLVED_DIGEST" in sha256:????????????????????????????????????????????????????????????????) ;; *) die "у asset нет корректного SHA-256 digest" ;; esac
    if [ "$GITHUB_API_BASE" = "https://api.github.com" ]; then
        expected_url="https://github.com/$repo/releases/download/$RESOLVED_TAG/$RESOLVED_ASSET"
        [ "$RESOLVED_URL" = "$expected_url" ] || die "GitHub вернул неожиданный URL asset"
    fi
}

verify_sha256() {
    verify_file=$1
    verify_expected=${2#sha256:}
    if [ -z "$SHA256_BIN" ] || [ ! -x "$SHA256_BIN" ]; then
        die "нужен sha256sum"
    fi
    verify_actual=$("$SHA256_BIN" "$verify_file" | awk '{ print tolower($1) }')
    verify_expected=$(printf '%s' "$verify_expected" | tr 'A-F' 'a-f')
    [ "$verify_actual" = "$verify_expected" ] || die "SHA-256 не совпал; файл не установлен"
}

archive_names_safe() {
    archive_list=$1
    [ -s "$archive_list" ] || return 1
    while IFS= read -r archive_name; do
        case "$archive_name" in .|./) continue ;; esac
        normalized=${archive_name#./}
        case "$normalized" in
            ''|/*|..|../*|*/..|*/../*|*\\*) return 1 ;;
        esac
    done < "$archive_list"
}

require_elf() {
    elf_file=$1
    if allow_test_artifacts; then
        return 0
    fi
    elf_header=$(read_hex_bytes 20 "$elf_file" 2>/dev/null) || elf_header=""
    # shellcheck disable=SC2086
    set -- $elf_header
    [ "$#" -eq 20 ] || die "asset содержит неполный ELF-заголовок"
    [ "$1$2$3$4" = "7f454c46" ] || die "asset не является ELF-бинарником"
    [ "$5" = "02" ] || die "asset не является ELF64"
    [ "$6" = "01" ] || die "asset имеет неподдерживаемый порядок байтов"
    if [ "${19}" != "b7" ] || [ "${20}" != "00" ]; then
        die "asset собран не для AArch64"
    fi
}

extract_binary() {
    extract_component=$1
    extract_archive=$2
    extract_target=$3
    case "$extract_component" in
        socks5)
            cp "$extract_archive" "$extract_target" || die "не удалось подготовить SOCKS5 binary"
            ;;
        rust)
            cp "$extract_archive" "$extract_target" || die "не удалось подготовить Rust binary"
            ;;
        mtproto)
            if [ -z "$TAR_BIN" ] || [ ! -x "$TAR_BIN" ]; then
                die "нужен tar"
            fi
            ipk_extract_option=-xf
            if limited_list_command "$TAR_BIN" -tf "$extract_archive" \
                    > "$TMP_DIR/ipk.list" 2> "$TMP_DIR/ipk.err"; then
                :
            elif limited_list_command "$TAR_BIN" -tzf "$extract_archive" \
                    > "$TMP_DIR/ipk.list" 2> "$TMP_DIR/ipk.err"; then
                ipk_extract_option=-xzf
            else
                die "повреждён или слишком большой IPK"
            fi
            [ ! -s "$TMP_DIR/ipk.err" ] || die "tar сообщил о небезопасном или нестандартном IPK"
            archive_names_safe "$TMP_DIR/ipk.list" || die "небезопасные пути внутри IPK"
            [ "$(awk 'END { print NR+0 }' "$TMP_DIR/ipk.list")" -le 16 ] || die "слишком много записей внутри IPK"
            awk '$0 == "control.tar.gz" || $0 == "./control.tar.gz" { count++ } END { exit(count == 1 ? 0 : 1) }' \
                "$TMP_DIR/ipk.list" || die "в IPK нет единственного control.tar.gz"
            awk '$0 == "data.tar.gz" || $0 == "./data.tar.gz" { count++ } END { exit(count == 1 ? 0 : 1) }' \
                "$TMP_DIR/ipk.list" || die "в IPK нет единственного data.tar.gz"
            mkdir -p "$TMP_DIR/ipk" "$TMP_DIR/control" "$TMP_DIR/data"
            limited_archive_command "$TAR_BIN" "$ipk_extract_option" "$extract_archive" -C "$TMP_DIR/ipk" control.tar.gz 2>/dev/null || \
                limited_archive_command "$TAR_BIN" "$ipk_extract_option" "$extract_archive" -C "$TMP_DIR/ipk" ./control.tar.gz || die "не удалось извлечь control.tar.gz"
            limited_archive_command "$TAR_BIN" "$ipk_extract_option" "$extract_archive" -C "$TMP_DIR/ipk" data.tar.gz 2>/dev/null || \
                limited_archive_command "$TAR_BIN" "$ipk_extract_option" "$extract_archive" -C "$TMP_DIR/ipk" ./data.tar.gz || die "не удалось извлечь data.tar.gz"
            if [ ! -f "$TMP_DIR/ipk/control.tar.gz" ] || [ -L "$TMP_DIR/ipk/control.tar.gz" ]; then
                die "небезопасный control.tar.gz внутри IPK"
            fi
            if [ ! -f "$TMP_DIR/ipk/data.tar.gz" ] || [ -L "$TMP_DIR/ipk/data.tar.gz" ]; then
                die "небезопасный data.tar.gz внутри IPK"
            fi
            limited_list_command "$TAR_BIN" -tzf "$TMP_DIR/ipk/control.tar.gz" > "$TMP_DIR/control.list" 2> "$TMP_DIR/control.err" || die "повреждён или слишком большой control.tar.gz"
            [ ! -s "$TMP_DIR/control.err" ] || die "tar сообщил о небезопасном control.tar.gz"
            archive_names_safe "$TMP_DIR/control.list" || die "небезопасные пути внутри control.tar.gz"
            [ "$(awk 'END { print NR+0 }' "$TMP_DIR/control.list")" -le 64 ] || die "слишком много записей внутри control.tar.gz"
            control_entry=$(awk '$0 == "./control" || $0 == "control" { print; exit }' "$TMP_DIR/control.list")
            [ -n "$control_entry" ] || die "в IPK нет control metadata"
            limited_archive_command "$TAR_BIN" -xzf "$TMP_DIR/ipk/control.tar.gz" -C "$TMP_DIR/control" "$control_entry" || die "не удалось извлечь control metadata"
            if [ ! -f "$TMP_DIR/control/control" ] || [ -L "$TMP_DIR/control/control" ]; then
                die "небезопасный control metadata"
            fi
            package_name=$(awk -F': *' '$1 == "Package" { print $2; exit }' "$TMP_DIR/control/control")
            package_arch=$(awk -F': *' '$1 == "Architecture" { print $2; exit }' "$TMP_DIR/control/control")
            package_version=$(awk -F': *' '$1 == "Version" { print $2; exit }' "$TMP_DIR/control/control")
            expected_package_version=$(printf '%s\n' "${RESOLVED_TAG#v}" | sed 's/-rev/-/')
            [ "$package_name" = "tg-ws-proxy" ] || die "IPK содержит неожиданный пакет"
            [ "$package_arch" = "aarch64-3.10" ] || die "IPK собран не для Entware aarch64-3.10"
            [ "$package_version" = "$expected_package_version" ] || die "версия внутри IPK не совпала с release tag"
            limited_list_command "$TAR_BIN" -tzf "$TMP_DIR/ipk/data.tar.gz" > "$TMP_DIR/data.list" 2> "$TMP_DIR/data.err" || die "повреждён или слишком большой data.tar.gz"
            [ ! -s "$TMP_DIR/data.err" ] || die "tar сообщил о небезопасном data.tar.gz"
            archive_names_safe "$TMP_DIR/data.list" || die "небезопасные пути внутри data.tar.gz"
            [ "$(awk 'END { print NR+0 }' "$TMP_DIR/data.list")" -le 256 ] || die "слишком много записей внутри data.tar.gz"
            awk '$0 == "./opt/bin/tg-ws-proxy" || $0 == "opt/bin/tg-ws-proxy" { count++ } END { exit(count == 1 ? 0 : 1) }' \
                "$TMP_DIR/data.list" || die "в IPK нет единственного ожидаемого binary"
            binary_entry=$(awk '$0 == "./opt/bin/tg-ws-proxy" || $0 == "opt/bin/tg-ws-proxy" { print; exit }' "$TMP_DIR/data.list")
            [ -n "$binary_entry" ] || die "в IPK нет ожидаемого binary"
            limited_archive_command "$TAR_BIN" -xzf "$TMP_DIR/ipk/data.tar.gz" -C "$TMP_DIR/data" "$binary_entry" || die "не удалось извлечь MTProto binary в пределах лимита"
            if [ ! -f "$TMP_DIR/data/opt/bin/tg-ws-proxy" ] || [ -L "$TMP_DIR/data/opt/bin/tg-ws-proxy" ]; then
                die "небезопасный MTProto binary"
            fi
            cp "$TMP_DIR/data/opt/bin/tg-ws-proxy" "$extract_target" || die "не удалось подготовить MTProto binary"
            ;;
    esac
    require_size_at_most "$extract_target" "$MAX_BINARY_BYTES" "распакованный binary"
    chmod 755 "$extract_target" || die "не удалось выставить права binary"
    require_elf "$extract_target"
}

install_init_wrapper() {
    wrapper_component=$1
    wrapper_source="$KZM_SHARE/components/S99kzm-tg-$wrapper_component"
    wrapper_target=$(component_init "$wrapper_component")
    [ -r "$wrapper_source" ] || die "не найден шаблон init для $wrapper_component"
    wrapper_tmp="$wrapper_target.tmp.$$"
    cp "$wrapper_source" "$wrapper_tmp" || {
        rm -f "$wrapper_tmp" 2>/dev/null || true
        die "не удалось скопировать init script"
    }
    chmod 755 "$wrapper_tmp" || {
        rm -f "$wrapper_tmp" 2>/dev/null || true
        die "не удалось выставить права init script"
    }
    mv "$wrapper_tmp" "$wrapper_target" || {
        rm -f "$wrapper_tmp" 2>/dev/null || true
        die "не удалось применить init script"
    }
}

write_source_metadata() {
    metadata_component=$1
    metadata_path=$(component_source "$metadata_component")
    metadata_tmp="$metadata_path.tmp.$$"
    {
        printf 'REPO=%s\n' "$(component_repo "$metadata_component")"
        printf 'TAG=%s\n' "$RESOLVED_TAG"
        printf 'ASSET=%s\n' "$RESOLVED_ASSET"
        printf 'SHA256=%s\n' "${RESOLVED_DIGEST#sha256:}"
        printf 'BINARY_SHA256=%s\n' "$RESOLVED_BINARY_SHA"
        printf 'INSTALLED_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || say unknown)"
    } > "$metadata_tmp" || {
        rm -f "$metadata_tmp" 2>/dev/null || true
        die "не удалось записать metadata"
    }
    chmod 600 "$metadata_tmp" || {
        rm -f "$metadata_tmp" 2>/dev/null || true
        die "не удалось защитить metadata"
    }
    mv "$metadata_tmp" "$metadata_path" || {
        rm -f "$metadata_tmp" 2>/dev/null || true
        die "не удалось применить metadata"
    }
}

enable_component_autostart() {
    autostart_component=$1
    autostart_path=$(component_autostart "$autostart_component")
    autostart_tmp="$autostart_path.tmp.$$"
    printf 'enabled\n' > "$autostart_tmp" || return 1
    chmod 600 "$autostart_tmp" || {
        rm -f "$autostart_tmp" 2>/dev/null || true
        return 1
    }
    mv "$autostart_tmp" "$autostart_path" || {
        rm -f "$autostart_tmp" 2>/dev/null || true
        return 1
    }
}

disable_component_autostart() {
    autostart_path=$(component_autostart "$1")
    rm -f "$autostart_path" || return 1
    [ ! -e "$autostart_path" ]
}

start_component() {
    lifecycle_component=$1
    component_valid "$lifecycle_component" || die "компоненты: socks5, rust или mtproto"
    component_installed "$lifecycle_component" || die "сначала установите компонент"
    ensure_layout
    acquire_manager_lock "$lifecycle_component"
    manager_service_barrier "$lifecycle_component"
    service_action "$lifecycle_component" start || die "прокси не запустился; проверьте конфиг и свободен ли его порт"
    if ! enable_component_autostart "$lifecycle_component"; then
        if ! service_action "$lifecycle_component" stop >/dev/null 2>&1; then
            die "прокси запущен, но запись автозапуска не удалась; процесс и PID сохранены для явного восстановления"
        fi
        disable_component_autostart "$lifecycle_component" >/dev/null 2>&1 || true
        die "прокси остановлен: не удалось включить его автозапуск"
    fi
    cleanup_all
    say "$(component_short_title "$lifecycle_component"): запущен; автозапуск включён."
}

stop_component() {
    lifecycle_component=$1
    component_valid "$lifecycle_component" || die "компоненты: socks5, rust или mtproto"
    component_installed "$lifecycle_component" || die "компонент не установлен"
    ensure_layout
    acquire_manager_lock "$lifecycle_component"
    manager_service_barrier "$lifecycle_component"
    service_action "$lifecycle_component" stop || die "прокси не остановлен; автозапуск не изменён"
    disable_component_autostart "$lifecycle_component" || die "прокси остановлен, но не удалось отключить автозапуск"
    cleanup_all
    say "$(component_short_title "$lifecycle_component"): остановлен; автозапуск отключён."
}

restart_component() {
    lifecycle_component=$1
    component_valid "$lifecycle_component" || die "компоненты: socks5, rust или mtproto"
    component_installed "$lifecycle_component" || die "компонент не установлен"
    ensure_layout
    acquire_manager_lock "$lifecycle_component"
    manager_service_barrier "$lifecycle_component"
    service_action "$lifecycle_component" restart || die "не удалось перезапустить прокси"
    cleanup_all
    say "$(component_short_title "$lifecycle_component"): перезапущен; настройка автозапуска не менялась."
}

install_component() {
    install_component_id=$1
    install_mode=${2:-install}
    component_valid "$install_component_id" || die "компоненты: socks5, rust или mtproto"
    validate_test_artifact_mode
    validate_resource_limits
    if [ -z "$CURL_BIN" ] || [ ! -x "$CURL_BIN" ]; then
        die "нужен curl"
    fi
    if [ -z "$SHA256_BIN" ] || [ ! -x "$SHA256_BIN" ]; then
        die "нужен sha256sum"
    fi
    case "$(uname -m 2>/dev/null)" in
        aarch64|arm64) ;;
        *) allow_test_artifacts || die "сейчас поддерживается только aarch64 Keenetic" ;;
    esac
    ensure_layout
    acquire_manager_lock "$install_component_id"
    manager_service_barrier "$install_component_id"
    remove_stale_transaction_temps "$install_component_id" || die "не удалось очистить незавершённую транзакцию компонента"
    make_tmp
    resolve_release "$install_component_id"
    old_tag=$(config_value TAG "$(component_source "$install_component_id")")
    old_sha=$(config_value SHA256 "$(component_source "$install_component_id")")
    old_binary_sha=$(config_value BINARY_SHA256 "$(component_source "$install_component_id")")
    new_sha=${RESOLVED_DIGEST#sha256:}
    if [ -n "$old_tag" ] && [ "$old_tag" = "$RESOLVED_TAG" ]; then
        if [ -n "$old_sha" ] && [ "$old_sha" != "$new_sha" ]; then
            die "upstream заменил asset внутри уже установленного tag $old_tag; обновление заблокировано до нового tag"
        fi
        if component_installed "$install_component_id" && [ -n "$old_sha" ] && [ "$old_sha" = "$new_sha" ] && [ -n "$old_binary_sha" ]; then
            installed_sha=$("$SHA256_BIN" "$(component_binary "$install_component_id")" 2>/dev/null | awk '{ print tolower($1) }')
            if [ "$installed_sha" = "$old_binary_sha" ]; then
                remove_old_rollback_artifacts "$install_component_id" || die "не удалось удалить устаревший rollback binary"
                say "$(component_title "$install_component_id"): уже установлена актуальная версия $old_tag."
                cleanup_all
                return 0
            fi
            warn "metadata актуальна, но установленный binary изменён; выполняется безопасная переустановка"
        fi
    fi
    archive="$TMP_DIR/$RESOLVED_ASSET"
    staged="$TMP_DIR/kzm-tg-$install_component_id"
    say "Источник: $(component_repo "$install_component_id")"
    say "Релиз:   $RESOLVED_TAG"
    say "Asset:    $RESOLVED_ASSET"
    download_file "$RESOLVED_URL" "$archive"
    verify_sha256 "$archive" "$RESOLVED_DIGEST"
    extract_binary "$install_component_id" "$archive" "$staged"
    RESOLVED_BINARY_SHA=$("$SHA256_BIN" "$staged" 2>/dev/null | awk '{ print tolower($1) }')
    case "$RESOLVED_BINARY_SHA" in
        *[!0-9a-f]*) die "не удалось вычислить SHA-256 распакованного binary" ;;
        ????????????????????????????????????????????????????????????????) ;;
        *) die "не удалось вычислить SHA-256 распакованного binary" ;;
    esac
    write_default_config "$install_component_id"
    install_init_wrapper "$install_component_id"

    target=$(component_binary "$install_component_id")
    target_new="$target.new.$$"
    target_old="$target.old.$$"
    was_active=0
    active_check_rc=0
    if component_active_rc "$install_component_id"; then
        was_active=1
    else
        active_check_rc=$?
        [ "$active_check_rc" -eq 1 ] || die "состояние процесса небезопасно или PID не принадлежит компоненту; binary не изменён"
    fi
    was_autostart=0
    [ -f "$(component_autostart "$install_component_id")" ] && was_autostart=1
    cp "$staged" "$target_new" || {
        rm -f "$target_new" 2>/dev/null || true
        die "не удалось перенести staged binary на /opt"
    }
    chmod 755 "$target_new" || {
        rm -f "$target_new" 2>/dev/null || true
        die "не удалось выставить права binary"
    }
    # Stop while /proc/PID/exe still resolves to the current canonical path.
    # Renaming a running executable first would make the ownership guard see
    # target.old.$$ and correctly refuse to kill it.
    if [ "$was_active" -eq 1 ]; then
        service_action "$install_component_id" stop || {
            rm -f "$target_new" || true
            die "не удалось остановить только обновляемый прокси"
        }
    fi
    if [ -e "$target" ]; then
        if ! mv "$target" "$target_old"; then
            rm -f "$target_new" 2>/dev/null || true
            if [ "$was_active" -eq 1 ]; then
                service_action "$install_component_id" start >/dev/null 2>&1 || \
                    die "binary не изменён, но прежний процесс не удалось вернуть после ошибки rollback"
            fi
            die "не удалось подготовить временный rollback; binary не изменён"
        fi
    fi
    if ! mv "$target_new" "$target"; then
        rm -f "$target_new" 2>/dev/null || true
        if [ -e "$target_old" ]; then
            mv "$target_old" "$target" || die "не удалось применить новый и восстановить предыдущий binary"
        fi
        if [ "$was_active" -eq 1 ]; then
            service_action "$install_component_id" start >/dev/null 2>&1 || \
                die "предыдущий binary восстановлен, но его процесс не перезапустился"
        fi
        die "не удалось применить новый binary; предыдущий binary и состояние запуска восстановлены"
    fi
    if [ "$install_mode" = "install" ] || [ "$was_active" -eq 1 ]; then
        if ! service_action "$install_component_id" start; then
            warn "новый binary не запустился"
            if ! service_action "$install_component_id" stop >/dev/null 2>&1; then
                die "новый процесс не удалось безопасно остановить; binary и PID сохранены для явного восстановления"
            fi
            if [ -e "$target_old" ]; then
                rm -f "$target" || die "не удалось удалить неработающий binary; rollback остановлен"
                mv "$target_old" "$target" || die "не удалось восстановить предыдущий binary"
                if [ "$was_active" -eq 1 ] && ! service_action "$install_component_id" start >/dev/null 2>&1; then
                    die "предыдущий binary восстановлен, но его процесс не перезапустился"
                fi
                die "обновление отменено, предыдущий binary и состояние запуска восстановлены"
            fi
            disable_component_autostart "$install_component_id" >/dev/null 2>&1 || true
            die "компонент установлен, но не запущен; проверьте конфиг и свободен ли его порт"
        fi
    fi
    if [ "$install_mode" = "install" ]; then
        if ! enable_component_autostart "$install_component_id"; then
            if ! service_action "$install_component_id" stop >/dev/null 2>&1; then
                die "компонент запущен, но автозапуск не записан; процесс и PID сохранены для явного восстановления"
            fi
            disable_component_autostart "$install_component_id" >/dev/null 2>&1 || true
            die "компонент остановлен: не удалось включить автозапуск"
        fi
    elif [ "$was_autostart" -eq 0 ]; then
        disable_component_autostart "$install_component_id" || die "не удалось сохранить выключенный автозапуск"
    fi
    write_source_metadata "$install_component_id"
    rm -f "$target_old" || die "новая версия работает, но не удалось удалить временный rollback binary"
    remove_old_rollback_artifacts "$install_component_id" || die "новая версия работает, но не удалось удалить устаревшие rollback binary"
    cleanup_all
    say "$(component_title "$install_component_id"): установлен ($RESOLVED_TAG)."
    say "nfqws, firewall и сеть Keenetic не перезапускались."
}

remove_component() {
    remove_component_id=$1
    component_valid "$remove_component_id" || die "компоненты: socks5, rust или mtproto"
    ensure_layout
    acquire_manager_lock "$remove_component_id"
    manager_service_barrier "$remove_component_id"
    if ! component_present "$remove_component_id"; then
        say "$(component_title "$remove_component_id"): уже не установлен."
        cleanup_all
        return 0
    fi
    remove_active=0
    remove_active_rc=0
    if component_active_rc "$remove_component_id"; then
        remove_active=1
    else
        remove_active_rc=$?
        [ "$remove_active_rc" -eq 1 ] || die "состояние процесса небезопасно или PID не принадлежит компоненту; файлы не удалены"
    fi
    if [ "$remove_active" -eq 1 ]; then
        service_action "$remove_component_id" stop >/dev/null 2>&1 || die "компонент не остановлен; его файлы не удалены"
    fi
    remove_component_artifacts "$remove_component_id" || die "не все файлы компонента удалось удалить"
    component_present "$remove_component_id" && die "после удаления остались файлы компонента"
    cleanup_all
    say "$(component_title "$remove_component_id"): удалён."
    say "Другие прокси, nfqws, firewall и сеть Keenetic не затрагивались."
}

install_zapret() {
    command -v opkg >/dev/null 2>&1 || die "opkg не найден"
    opkg update || die "opkg update завершился ошибкой"
    opkg install nfqws-keenetic || die "не удалось установить nfqws-keenetic"
    say "Классический nfqws-keenetic установлен."
}

remove_zapret() {
    command -v opkg >/dev/null 2>&1 || die "opkg не найден"
    opkg remove nfqws-keenetic || die "не удалось удалить nfqws-keenetic"
    say "Движок nfqws-keenetic удалён; сам KZM и пользовательские списки сохранены."
}

security_notice() {
    case "$1" in
        socks5)
            say "SOCKS5 доступен всей доверенной LAN и защищён логином/паролем."
            say "Экспериментально: upstream отключает проверку TLS-сертификата WSS, а опубликованный binary собран старой версией Go."
            say "Из-за интерфейса upstream логин и пароль передаются аргументами процесса."
            ;;
        rust)
            say "Рекомендуемый вариант: статический Rust v2 binary от p01ntov, TLS-проверка включена."
            say "Форк valnesfjord сокращает задержку холодного подключения и не меняет флаги запуска."
            say "Маршрут: проверенный Cloudflare shortlist с балансировкой; direct DC2/DC4 в резерве."
            say "Сервис работает от nobody и ограничен 32 соединениями; upstream сообщает о возможном росте памяти."
            ;;
        mtproto)
            say "Экспериментально: upstream использует EOL Go toolchain и отключает проверку TLS-сертификата WSS."
            say "Из-за интерфейса upstream секрет виден root в командной строке процесса."
            say "Автозагрузка изменяемого списка Cloudflare будет отключена."
            ;;
    esac
    say "Bind: только приватный LAN-IP; порты WAN и firewall менеджер не открывает."
}

status_command() {
    status_component=${1:-}
    if [ -n "$status_component" ]; then
        component_valid "$status_component" || die "компоненты: socks5, rust или mtproto"
        printf '%s: %s\n' "$(component_title "$status_component")" "$(component_state_ru "$status_component")"
        return 0
    fi
    printf 'Zapret (nfqws):       %s\n' "$(zapret_state_ru)"
    printf 'TG WS Proxy SOCKS5:  %s\n' "$(component_state_ru socks5)"
    printf 'TG WS Proxy Rust:    %s\n' "$(component_state_ru rust)"
    printf 'TG WS Proxy MTProto: %s\n' "$(component_state_ru mtproto)"
}

link_command() {
    link_component=$1
    component_valid "$link_component" || die "компоненты: socks5, rust или mtproto"
    link_config=$(component_config "$link_component")
    [ -r "$link_config" ] || die "компонент не настроен"
    link_host=$(config_value HOST "$link_config")
    link_port=$(config_value PORT "$link_config")
    private_ipv4_value_valid "$link_host" || die "в конфиге указан небезопасный HOST"
    port_value_valid "$link_port" || die "в конфиге указан некорректный PORT"
    case "$link_component" in
        socks5)
            link_user=$(config_value USERNAME "$link_config")
            link_password=$(config_value PASSWORD "$link_config")
            url_token_valid "$link_user" || die "USERNAME нельзя безопасно поместить в tg:// ссылку"
            url_token_valid "$link_password" || die "PASSWORD нельзя безопасно поместить в tg:// ссылку"
            say "tg://socks?server=$link_host&port=$link_port&user=$link_user&pass=$link_password"
            ;;
        rust|mtproto)
            link_secret=$(config_value SECRET "$link_config")
            secret_hex_valid "$link_secret" || die "повреждён SECRET в конфиге MTProto"
            say "tg://proxy?server=$link_host&port=$link_port&secret=dd$link_secret"
            ;;
    esac
}

action_with_confirmation() {
    action_component=$1
    action_name=$2
    case "$action_name" in
        install)
            security_notice "$action_component"
            if component_present "$action_component" && ! component_install_complete "$action_component"; then
                install_prompt="Завершить установку, проверить процесс и включить автозапуск для $(component_title "$action_component")?"
            else
                install_prompt="Установить, запустить и включить автозапуск только $(component_title "$action_component")?"
            fi
            confirm_numeric "$install_prompt" || { say "Установка отменена."; return 0; }
            install_component "$action_component" install
            ;;
        update)
            security_notice "$action_component"
            confirm_numeric "Проверить upstream и обновить только $(component_title "$action_component")?" || { say "Обновление отменено."; return 0; }
            install_component "$action_component" update
            ;;
        remove)
            confirm_numeric "Остановить и удалить $(component_title "$action_component"), включая его конфиг и ключ?" || { say "Удаление отменено."; return 0; }
            remove_component "$action_component"
            ;;
    esac
}

menu_action() {
    ( "$@" )
    menu_action_rc=$?
    if [ "$menu_action_rc" -ne 0 ]; then
        warn "операция завершилась ошибкой; меню продолжает работать"
    fi
    return 0
}

install_menu() {
    while :; do
        menu_clear
        printf 'Установка и удаление\n\n'
        if zapret_installed; then zapret_action="Удалить"; else zapret_action="Установить"; fi
        if ! component_present socks5; then socks_action="Установить"; elif component_install_complete socks5; then socks_action="Удалить"; else socks_action="Завершить установку"; fi
        if ! component_present rust; then rust_action="Установить"; elif component_install_complete rust; then rust_action="Удалить"; else rust_action="Завершить установку"; fi
        if ! component_present mtproto; then mtproto_action="Установить"; elif component_install_complete mtproto; then mtproto_action="Удалить"; else mtproto_action="Завершить установку"; fi
        menu_option 1 "$zapret_action Zapret (nfqws-keenetic)"
        menu_option 2 "$socks_action TG WS Proxy SOCKS5 - d0mhate [экспериментально]"
        menu_option 3 "$rust_action TG WS Proxy Rust v2 - p01ntov [рекомендуется]"
        menu_option 4 "$mtproto_action TG WS Proxy MTProto - spatiumstas [экспериментально]"
        menu_back_option "Назад"
        printf '\n'
        printf 'Выберите пункт: '
        IFS= read -r install_choice || return
        case "$install_choice" in
            1)
                if zapret_installed; then
                    if confirm_numeric "Удалить только nfqws-keenetic? Активный обход остановится."; then menu_action remove_zapret; else say "Удаление отменено."; fi
                else
                    if confirm_numeric "Установить nfqws-keenetic из уже настроенного Entware feed?"; then menu_action install_zapret; else say "Установка отменена."; fi
                fi
                menu_pause
                ;;
            2|3|4)
                case "$install_choice" in 2) selected=socks5 ;; 3) selected=rust ;; 4) selected=mtproto ;; esac
                if ! component_present "$selected"; then
                    menu_action action_with_confirmation "$selected" install
                elif component_install_complete "$selected"; then
                    menu_action action_with_confirmation "$selected" remove
                else
                    menu_action action_with_confirmation "$selected" install
                fi
                menu_pause
                ;;
            '') return ;;
            *) say "Введите номер из списка."; menu_pause ;;
        esac
    done
}

proxy_component_menu() {
    proxy_component=$1
    while :; do
        menu_clear
        printf '%s\n\n' "$(component_title "$proxy_component")"
        printf '  Состояние: %s\n' "$(component_state_ui "$proxy_component")"
        if [ "$proxy_component" = rust ]; then
            printf '  Маршрут: Cloudflare shortlist с балансировкой, direct DC2/DC4 в резерве\n'
        fi
        printf '\n'
        menu_option 1 "Запустить и включить автозапуск"
        menu_option 2 "Остановить и отключить автозапуск"
        menu_option 3 "Проверить и установить обновление"
        menu_option 4 "Показать ссылку подключения"
        menu_option 5 "Удалить"
        menu_back_option "Назад"
        printf '\n'
        printf 'Выберите пункт: '
        IFS= read -r proxy_choice || return
        case "$proxy_choice" in
            1)
                if component_installed "$proxy_component"; then menu_action start_component "$proxy_component"; else warn "сначала установите компонент"; fi
                menu_pause
                ;;
            2)
                if component_installed "$proxy_component"; then menu_action stop_component "$proxy_component"; else warn "компонент не установлен"; fi
                menu_pause
                ;;
            3)
                if component_installed "$proxy_component"; then menu_action action_with_confirmation "$proxy_component" update; else warn "сначала установите компонент"; fi
                menu_pause
                ;;
            4)
                if component_installed "$proxy_component"; then menu_action link_command "$proxy_component"; else warn "сначала установите компонент"; fi
                menu_pause
                ;;
            5)
                if component_present "$proxy_component"; then menu_action action_with_confirmation "$proxy_component" remove; else warn "компонент не установлен"; fi
                menu_pause
                return
                ;;
            '') return ;;
            *) say "Введите номер из списка."; menu_pause ;;
        esac
    done
}

proxy_menu() {
    while :; do
        menu_clear
        printf 'Telegram-прокси\n\n'
        menu_option 1 "TG WS Proxy SOCKS5 - $(component_state_ui socks5)"
        menu_option 2 "TG WS Proxy Rust v2 - $(component_state_ui rust)"
        menu_option 3 "TG WS Proxy MTProto - $(component_state_ui mtproto)"
        menu_back_option "Назад"
        printf '\n'
        printf 'Выберите пункт: '
        IFS= read -r proxy_menu_choice || return
        case "$proxy_menu_choice" in
            1) proxy_component_menu socks5 ;;
            2) proxy_component_menu rust ;;
            3) proxy_component_menu mtproto ;;
            '') return ;;
            *) say "Введите номер из списка."; menu_pause ;;
        esac
    done
}

update_installed_menu() {
    found=0
    for update_component in socks5 rust mtproto; do
        if component_installed "$update_component"; then
            found=1
            ( install_component "$update_component" update ) || return 1
        fi
    done
    [ "$found" -eq 1 ] || say "TG-прокси ещё не установлены."
}

main_menu() {
    while :; do
        menu_clear
        printf '╔════════════════════════════════════╗\n'
        printf '║       Keenetic Manager %-8s    ║\n' "$KZM_VERSION"
        printf '╚════════════════════════════════════╝\n\n'
        printf '  Zapret:          %s\n' "$(zapret_state_ui)"
        printf '  TG SOCKS5:       %s\n' "$(component_state_ui socks5)"
        printf '  TG Rust:         %s\n' "$(component_state_ui rust)"
        printf '  TG MTProto:      %s\n\n' "$(component_state_ui mtproto)"
        menu_option 1 "Zapret: стратегии, сайты и тесты"
        menu_option 2 "Установка и удаление"
        menu_option 3 "Telegram-прокси"
        menu_option 4 "Обновить установленные Telegram-прокси"
        menu_option 5 "Полное состояние"
        menu_back_option "Выход"
        printf '\n'
        printf 'Выберите пункт: '
        IFS= read -r main_choice || return
        case "$main_choice" in
            1) "$KZM_BIN" zapret ;;
            2) install_menu ;;
            3) proxy_menu ;;
            4)
                if confirm_numeric "Проверить upstream и обновить только уже установленные TG-прокси?"; then menu_action update_installed_menu; else say "Обновление отменено."; fi
                menu_pause
                ;;
            5) status_command; menu_pause ;;
            '') return ;;
            *) say "Введите номер из списка."; menu_pause ;;
        esac
    done
}

usage() {
    cat <<'EOF'
Использование: component-manager.sh COMMAND [COMPONENT] [--yes]

  menu
  status [socks5|rust|mtproto]
  install <socks5|rust|mtproto> [--yes]
  update <socks5|rust|mtproto> [--yes]
  remove <socks5|rust|mtproto> --yes
  start|stop|restart <socks5|rust|mtproto>
  link <socks5|rust|mtproto>

Команды TG-прокси не меняют nfqws, firewall или сетевые интерфейсы Keenetic.
EOF
}

main() {
    command_name=${1:-menu}
    [ "$#" -eq 0 ] || shift
    case "$command_name" in
        menu) main_menu ;;
        status) status_command "${1:-}" ;;
        install|update)
            [ "$#" -ge 1 ] || die "$command_name требует имя компонента"
            cli_component=$1
            cli_yes=${2:-}
            if [ "$cli_yes" = "--yes" ]; then
                install_component "$cli_component" "$command_name"
            else
                action_with_confirmation "$cli_component" "$command_name"
            fi
            ;;
        remove)
            [ "$#" -ge 1 ] || die "remove требует имя компонента"
            cli_component=$1
            cli_yes=${2:-}
            [ "$cli_yes" = "--yes" ] || die "remove требует явный --yes"
            remove_component "$cli_component"
            ;;
        start|stop|restart)
            [ "$#" -eq 1 ] || die "$command_name требует имя компонента"
            case "$command_name" in
                start) start_component "$1" ;;
                stop) stop_component "$1" ;;
                restart) restart_component "$1" ;;
            esac
            ;;
        link)
            [ "$#" -eq 1 ] || die "link требует имя компонента"
            link_command "$1"
            ;;
        help|--help|-h) usage ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
