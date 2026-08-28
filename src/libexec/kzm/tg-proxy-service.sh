#!/bin/sh

# Minimal service supervisor for the TG proxy components installed by KZM.
# It intentionally does not use rc.func: every component has its own binary,
# pid file and lifecycle, so an action can never match nfqws or another proxy.

set -u
set -f
umask 077

KZM_ROOT="${KZM_ROOT:-}"
KZM_PREFIX="${KZM_PREFIX:-/opt}"
KZM_BASE="${KZM_BASE:-${KZM_ROOT}${KZM_PREFIX}}"
KZM_COMPONENT="${KZM_COMPONENT:-}"
KZM_PROC_ROOT="${KZM_PROC_ROOT:-/proc}"
KZM_NETSTAT="${KZM_NETSTAT:-netstat}"
KZM_IP_BIN="${KZM_IP_BIN:-ip}"

PATH="$KZM_BASE/usr/sbin:$KZM_BASE/usr/bin:$KZM_BASE/sbin:$KZM_BASE/bin:/opt/usr/sbin:/opt/usr/bin:/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

say() {
    printf '%s\n' "$*"
}

warn() {
    printf 'Внимание: %s\n' "$*" >&2
}

die() {
    printf 'Ошибка: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf 'Использование: KZM_COMPONENT=socks5|rust|mtproto %s start|stop|restart|status|active|barrier\n' "$0" >&2
}

case "$KZM_COMPONENT" in
    socks5|rust|mtproto) ;;
    *)
        usage
        die "не задан поддерживаемый KZM_COMPONENT"
        ;;
esac

case "${1:-}" in
    start|stop|restart|status|active|barrier) ACTION=$1 ;;
    *)
        usage
        exit 1
        ;;
esac

COMPONENT_DIR="$KZM_BASE/etc/kzapret-manager/components"
CONFIG_FILE="$COMPONENT_DIR/$KZM_COMPONENT.conf"
RUN_DIR="$KZM_BASE/var/run"
LOG_DIR="$KZM_BASE/var/log"
PID_FILE="$RUN_DIR/kzm-tg-$KZM_COMPONENT.pid"
LOG_FILE="$LOG_DIR/kzm-tg-$KZM_COMPONENT.log"
BINARY="$KZM_BASE/usr/bin/kzm-tg-$KZM_COMPONENT"
SERVICE_LOCK_DIR="$RUN_DIR/kzm-tg-$KZM_COMPONENT.service.lock"
SERVICE_LOCK_OWNER="$SERVICE_LOCK_DIR/owner"
MANAGER_LOCK_DIR="$RUN_DIR/kzm-tg-$KZM_COMPONENT.manage.lock"
MANAGER_LOCK_OWNER="$MANAGER_LOCK_DIR/owner"
MUTATION_LOCK_HELD=0
KZM_TEST_MODE=0

HOST=
PORT=
USERNAME=
PASSWORD=
SECRET=
POOL_SIZE=
MAX_CONNECTIONS=
DC_IP_DEFAULT=
RUST_DIRECT_DC4=4:149.154.167.220

allow_test_artifacts() {
    [ "$KZM_TEST_MODE" -eq 1 ]
}

production_mode() {
    [ -z "$KZM_ROOT" ] && [ "${KZM_ALLOW_TEST_ARTIFACTS:-0}" != 1 ]
}

initialize_test_mode() {
    [ "${KZM_ALLOW_TEST_ARTIFACTS:-0}" = 1 ] || return 0
    [ -n "$KZM_ROOT" ] || return 0
    [ "$KZM_BASE" = "$KZM_ROOT/opt" ] || return 0
    [ -d "$KZM_ROOT" ] || return 0
    _kzm_canonical_root=$(CDPATH='' cd -P -- "$KZM_ROOT" 2>/dev/null && pwd -P) || return 0
    case "$_kzm_canonical_root" in
        /tmp/kzm-components-test.*|/tmp/kzm-components-live*) ;;
        *) return 0 ;;
    esac
    [ -d "$KZM_BASE" ] || return 0
    _kzm_canonical_base=$(CDPATH='' cd -P -- "$KZM_BASE" 2>/dev/null && pwd -P) || return 0
    [ "$_kzm_canonical_base" = "$_kzm_canonical_root/opt" ] || return 0
    KZM_TEST_MODE=1
}

initialize_test_mode

read_lock_owner() {
    _kzm_owner_file=$1
    LOCK_OWNER_VALUE=
    [ ! -L "$_kzm_owner_file" ] || return 1
    [ -f "$_kzm_owner_file" ] || return 1
    LOCK_OWNER_VALUE=$(cat "$_kzm_owner_file" 2>/dev/null) || return 1
    case "$LOCK_OWNER_VALUE" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$LOCK_OWNER_VALUE" -gt 1 ] 2>/dev/null || return 1
}

lock_owner_alive() {
    kill -0 "$1" 2>/dev/null
}

remove_stale_lock() {
    _kzm_stale_dir=$1
    _kzm_stale_owner_file=$2
    _kzm_stale_expected=$3

    # Re-read immediately before removal.  Never unlink a lock that changed
    # owner between the liveness check and cleanup.
    read_lock_owner "$_kzm_stale_owner_file" || return 1
    [ "$LOCK_OWNER_VALUE" = "$_kzm_stale_expected" ] || return 1
    lock_owner_alive "$_kzm_stale_expected" && return 1
    rm -f "$_kzm_stale_owner_file" || return 1
    rmdir "$_kzm_stale_dir" 2>/dev/null || return 1
}

release_mutation_lock() {
    [ "$MUTATION_LOCK_HELD" -eq 1 ] || return 0
    if [ -d "$SERVICE_LOCK_DIR" ] && [ ! -L "$SERVICE_LOCK_DIR" ] && \
            read_lock_owner "$SERVICE_LOCK_OWNER" && \
            [ "$LOCK_OWNER_VALUE" = "$$" ]; then
        rm -f "$SERVICE_LOCK_OWNER" 2>/dev/null || true
        rmdir "$SERVICE_LOCK_DIR" 2>/dev/null || true
    fi
    MUTATION_LOCK_HELD=0
}

check_manager_lock() {
    if [ ! -e "$MANAGER_LOCK_DIR" ] && [ ! -L "$MANAGER_LOCK_DIR" ]; then
        return 0
    fi
    [ ! -L "$MANAGER_LOCK_DIR" ] || die "блокировка менеджера является символической ссылкой: $MANAGER_LOCK_DIR"
    [ -d "$MANAGER_LOCK_DIR" ] || die "путь блокировки менеджера не является каталогом: $MANAGER_LOCK_DIR"
    read_lock_owner "$MANAGER_LOCK_OWNER" || die "у блокировки менеджера нет безопасного файла owner"
    _kzm_manager_owner=$LOCK_OWNER_VALUE
    _kzm_authorized_owner=${KZM_MANAGER_LOCK_PID:-}

    case "$_kzm_authorized_owner" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$_kzm_authorized_owner" -gt 1 ] 2>/dev/null && \
                    [ "$_kzm_authorized_owner" = "$_kzm_manager_owner" ]; then
                return 0
            fi
            ;;
    esac

    if ! lock_owner_alive "$_kzm_manager_owner"; then
        warn "удаляю устаревшую блокировку менеджера (PID $_kzm_manager_owner)"
        remove_stale_lock "$MANAGER_LOCK_DIR" "$MANAGER_LOCK_OWNER" "$_kzm_manager_owner" || \
            die "блокировка менеджера изменилась во время проверки"
        return 0
    fi
    die "компонент изменяется менеджером (PID $_kzm_manager_owner); операция запрещена"
}

acquire_mutation_lock() {
    mkdir -p "$RUN_DIR" || die "не удалось создать каталог PID: $RUN_DIR"
    [ ! -L "$RUN_DIR" ] || die "каталог PID не должен быть символической ссылкой: $RUN_DIR"
    [ -d "$RUN_DIR" ] || die "путь PID не является каталогом: $RUN_DIR"

    _kzm_lock_attempt=0
    _kzm_lock_max=3
    [ "$ACTION" = barrier ] && _kzm_lock_max=30
    while [ "$_kzm_lock_attempt" -lt "$_kzm_lock_max" ]; do
        if mkdir "$SERVICE_LOCK_DIR" 2>/dev/null; then
            if ! printf '%s\n' "$$" > "$SERVICE_LOCK_OWNER" || \
                    ! chmod 600 "$SERVICE_LOCK_OWNER"; then
                rm -f "$SERVICE_LOCK_OWNER" 2>/dev/null || true
                rmdir "$SERVICE_LOCK_DIR" 2>/dev/null || true
                die "не удалось записать блокировку сервиса"
            fi
            MUTATION_LOCK_HELD=1
            trap 'release_mutation_lock' 0
            trap 'exit 129' HUP
            trap 'exit 130' INT
            trap 'exit 143' TERM
            check_manager_lock
            return 0
        fi

        [ ! -L "$SERVICE_LOCK_DIR" ] || die "блокировка сервиса является символической ссылкой: $SERVICE_LOCK_DIR"
        [ -d "$SERVICE_LOCK_DIR" ] || die "путь блокировки сервиса небезопасен: $SERVICE_LOCK_DIR"
        if ! read_lock_owner "$SERVICE_LOCK_OWNER"; then
            # mkdir and owner creation are two operations. Give a concurrent
            # owner one short chance to finish instead of deleting its lock.
            sleep 1
            read_lock_owner "$SERVICE_LOCK_OWNER" || die "у блокировки сервиса нет безопасного файла owner"
        fi
        _kzm_service_owner=$LOCK_OWNER_VALUE
        if lock_owner_alive "$_kzm_service_owner"; then
            if [ "$ACTION" = barrier ]; then
                sleep 1
                _kzm_lock_attempt=$((_kzm_lock_attempt + 1))
                continue
            fi
            die "операция для $KZM_COMPONENT уже выполняется (PID $_kzm_service_owner)"
        fi
        warn "удаляю устаревшую блокировку сервиса (PID $_kzm_service_owner)"
        remove_stale_lock "$SERVICE_LOCK_DIR" "$SERVICE_LOCK_OWNER" "$_kzm_service_owner" || \
            die "блокировка сервиса изменилась во время проверки"
        _kzm_lock_attempt=$((_kzm_lock_attempt + 1))
    done
    die "не удалось получить блокировку сервиса"
}

log_event() {
    # Logs contain lifecycle metadata only. Proxy stdout is suppressed because
    # both MTProto implementations can print a connection link with the secret.
    [ -d "$LOG_DIR" ] || return 0
    if [ -L "$LOG_FILE" ]; then
        return 0
    fi
    if [ ! -e "$LOG_FILE" ]; then
        : > "$LOG_FILE" 2>/dev/null || return 0
        chmod 600 "$LOG_FILE" 2>/dev/null || true
    fi
    [ -f "$LOG_FILE" ] || return 0
    _kzm_log_time=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date 2>/dev/null || printf unknown)
    printf '%s %s\n' "$_kzm_log_time" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

prepare_runtime() {
    mkdir -p "$RUN_DIR" "$LOG_DIR" || die "не удалось создать каталоги PID/журналов"
    if [ -L "$LOG_FILE" ]; then
        die "журнал не должен быть символической ссылкой: $LOG_FILE"
    fi
    if [ -e "$LOG_FILE" ] && [ ! -f "$LOG_FILE" ]; then
        die "журнал не является обычным файлом: $LOG_FILE"
    fi
    : >> "$LOG_FILE" || die "не удалось открыть журнал: $LOG_FILE"
    chmod 600 "$LOG_FILE" || die "не удалось защитить журнал: $LOG_FILE"
}

config_error() {
    printf 'Ошибка конфига %s: %s\n' "$CONFIG_FILE" "$*" >&2
    return 1
}

read_config() {
    HOST=
    PORT=
    USERNAME=
    PASSWORD=
    SECRET=
    POOL_SIZE=
    MAX_CONNECTIONS=
    DC_IP_DEFAULT=
    _kzm_seen_host=0
    _kzm_seen_port=0
    _kzm_seen_username=0
    _kzm_seen_password=0
    _kzm_seen_secret=0
    _kzm_seen_pool_size=0
    _kzm_seen_max_connections=0
    _kzm_seen_dc_ip_default=0
    _kzm_line_number=0

    [ -e "$CONFIG_FILE" ] || config_error "файл не найден" || return 1
    [ ! -L "$CONFIG_FILE" ] || config_error "символические ссылки запрещены" || return 1
    [ -f "$CONFIG_FILE" ] || config_error "это не обычный файл" || return 1
    [ -r "$CONFIG_FILE" ] || config_error "файл нельзя прочитать" || return 1

    _kzm_config_listing=$(LC_ALL=C ls -ld "$CONFIG_FILE" 2>/dev/null) || {
        config_error "не удалось проверить права"
        return 1
    }
    case "$_kzm_config_listing" in
        -rw-------\ *) ;;
        *)
            config_error "требуются права 600"
            return 1
            ;;
    esac

    # Do not source this file. Only a deliberately small KEY=value grammar is
    # accepted, making command substitutions and shell metacharacters inert.
    while IFS= read -r _kzm_line || [ -n "$_kzm_line" ]; do
        _kzm_line_number=$((_kzm_line_number + 1))
        case "$_kzm_line" in
            ''|'#'*) continue ;;
            HOST=*)
                [ "$_kzm_seen_host" -eq 0 ] || {
                    config_error "строка $_kzm_line_number: HOST указан дважды"
                    return 1
                }
                HOST=${_kzm_line#HOST=}
                _kzm_seen_host=1
                ;;
            PORT=*)
                [ "$_kzm_seen_port" -eq 0 ] || {
                    config_error "строка $_kzm_line_number: PORT указан дважды"
                    return 1
                }
                PORT=${_kzm_line#PORT=}
                _kzm_seen_port=1
                ;;
            USERNAME=*)
                [ "$KZM_COMPONENT" = socks5 ] || {
                    config_error "строка $_kzm_line_number: USERNAME не допустим для $KZM_COMPONENT"
                    return 1
                }
                [ "$_kzm_seen_username" -eq 0 ] || {
                    config_error "строка $_kzm_line_number: USERNAME указан дважды"
                    return 1
                }
                USERNAME=${_kzm_line#USERNAME=}
                _kzm_seen_username=1
                ;;
            PASSWORD=*)
                [ "$KZM_COMPONENT" = socks5 ] || {
                    config_error "строка $_kzm_line_number: PASSWORD не допустим для $KZM_COMPONENT"
                    return 1
                }
                [ "$_kzm_seen_password" -eq 0 ] || {
                    config_error "строка $_kzm_line_number: PASSWORD указан дважды"
                    return 1
                }
                PASSWORD=${_kzm_line#PASSWORD=}
                _kzm_seen_password=1
                ;;
            SECRET=*)
                [ "$KZM_COMPONENT" != socks5 ] || {
                    config_error "строка $_kzm_line_number: SECRET не допустим для socks5"
                    return 1
                }
                [ "$_kzm_seen_secret" -eq 0 ] || {
                    config_error "строка $_kzm_line_number: SECRET указан дважды"
                    return 1
                }
                SECRET=${_kzm_line#SECRET=}
                _kzm_seen_secret=1
                ;;
            POOL_SIZE=*)
                [ "$KZM_COMPONENT" = rust ] || {
                    config_error "строка $_kzm_line_number: POOL_SIZE не допустим для $KZM_COMPONENT"
                    return 1
                }
                [ "$_kzm_seen_pool_size" -eq 0 ] || {
                    config_error "строка $_kzm_line_number: POOL_SIZE указан дважды"
                    return 1
                }
                POOL_SIZE=${_kzm_line#POOL_SIZE=}
                _kzm_seen_pool_size=1
                ;;
            MAX_CONNECTIONS=*)
                [ "$KZM_COMPONENT" = rust ] || {
                    config_error "строка $_kzm_line_number: MAX_CONNECTIONS не допустим для $KZM_COMPONENT"
                    return 1
                }
                [ "$_kzm_seen_max_connections" -eq 0 ] || {
                    config_error "строка $_kzm_line_number: MAX_CONNECTIONS указан дважды"
                    return 1
                }
                MAX_CONNECTIONS=${_kzm_line#MAX_CONNECTIONS=}
                _kzm_seen_max_connections=1
                ;;
            DC_IP_DEFAULT=*)
                [ "$KZM_COMPONENT" = mtproto ] || {
                    config_error "строка $_kzm_line_number: DC_IP_DEFAULT не допустим для $KZM_COMPONENT"
                    return 1
                }
                [ "$_kzm_seen_dc_ip_default" -eq 0 ] || {
                    config_error "строка $_kzm_line_number: DC_IP_DEFAULT указан дважды"
                    return 1
                }
                DC_IP_DEFAULT=${_kzm_line#DC_IP_DEFAULT=}
                _kzm_seen_dc_ip_default=1
                ;;
            *)
                config_error "строка $_kzm_line_number: неизвестная или небезопасная запись"
                return 1
                ;;
        esac
    done < "$CONFIG_FILE"

    [ "$_kzm_seen_host" -eq 1 ] || config_error "нет HOST" || return 1
    [ "$_kzm_seen_port" -eq 1 ] || config_error "нет PORT" || return 1
    case "$KZM_COMPONENT" in
        socks5)
            [ "$_kzm_seen_username" -eq 1 ] || config_error "нет USERNAME" || return 1
            [ "$_kzm_seen_password" -eq 1 ] || config_error "нет PASSWORD" || return 1
            ;;
        rust)
            [ "$_kzm_seen_secret" -eq 1 ] || config_error "нет SECRET" || return 1
            [ "$_kzm_seen_pool_size" -eq 1 ] || config_error "нет POOL_SIZE" || return 1
            [ "$_kzm_seen_max_connections" -eq 1 ] || config_error "нет MAX_CONNECTIONS" || return 1
            ;;
        mtproto)
            [ "$_kzm_seen_secret" -eq 1 ] || config_error "нет SECRET" || return 1
            [ "$_kzm_seen_dc_ip_default" -eq 1 ] || config_error "нет DC_IP_DEFAULT" || return 1
            ;;
    esac
}

is_ipv4() {
    _kzm_ip=$1
    _kzm_old_ifs=$IFS
    IFS=.
    # Intentional IFS split into four octets; pathname expansion is disabled.
    # shellcheck disable=SC2086
    set -- $_kzm_ip
    IFS=$_kzm_old_ifs
    [ "$#" -eq 4 ] || return 1

    for _kzm_octet in "$@"; do
        case "$_kzm_octet" in
            0|[1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;;
            *) return 1 ;;
        esac
        [ "$_kzm_octet" -le 255 ] 2>/dev/null || return 1
    done

    return 0
}

is_lan_ipv4() {
    _kzm_ip=$1
    is_ipv4 "$_kzm_ip" || return 1
    _kzm_old_ifs=$IFS
    IFS=.
    # Intentional IFS split into four octets; pathname expansion is disabled.
    # shellcheck disable=SC2086
    set -- $_kzm_ip
    IFS=$_kzm_old_ifs

    case "$1" in
        10) return 0 ;;
        172)
            [ "$2" -ge 16 ] 2>/dev/null && [ "$2" -le 31 ] 2>/dev/null
            return $?
            ;;
        192)
            [ "$2" -eq 168 ] 2>/dev/null
            return $?
            ;;
        *) return 1 ;;
    esac
}

validate_config() {
    is_lan_ipv4 "$HOST" || config_error "HOST должен быть LAN IPv4 (10/8, 172.16/12 или 192.168/16)" || return 1

    case "$PORT" in
        ''|*[!0-9]*|0|0*) config_error "PORT должен быть числом 1..65535 без начальных нулей"; return 1 ;;
    esac
    if [ "${#PORT}" -gt 5 ] || [ "$PORT" -gt 65535 ] 2>/dev/null; then
        config_error "PORT вне диапазона 1..65535"
        return 1
    fi
    [ "$PORT" -gt 1024 ] 2>/dev/null || {
        config_error "PORT должен быть непривилегированным (1025..65535)"
        return 1
    }

    case "$KZM_COMPONENT" in
        socks5)
            if [ "${#USERNAME}" -lt 1 ] || [ "${#USERNAME}" -gt 64 ]; then
                config_error "USERNAME должен иметь длину 1..64"
                return 1
            fi
            case "$USERNAME" in
                *[!A-Za-z0-9._~-]*) config_error "USERNAME содержит недопустимые символы"; return 1 ;;
            esac
            if [ "${#PASSWORD}" -lt 12 ] || [ "${#PASSWORD}" -gt 128 ]; then
                config_error "PASSWORD должен иметь длину 12..128"
                return 1
            fi
            case "$PASSWORD" in
                *[!A-Za-z0-9._~-]*) config_error "PASSWORD содержит недопустимые символы"; return 1 ;;
            esac
            ;;
        rust|mtproto)
            [ "${#SECRET}" -eq 32 ] || {
                config_error "SECRET должен состоять из 32 hex-символов (без dd/ee)"
                return 1
            }
            case "$SECRET" in
                *[!0-9A-Fa-f]*) config_error "SECRET должен быть hex-строкой"; return 1 ;;
            esac
            ;;
    esac

    if [ "$KZM_COMPONENT" = rust ]; then
        case "$POOL_SIZE" in
            ''|*[!0-9]*|0|0*) config_error "POOL_SIZE должен быть числом 1..64"; return 1 ;;
        esac
        if [ "${#POOL_SIZE}" -gt 2 ] || [ "$POOL_SIZE" -gt 64 ] 2>/dev/null; then
            config_error "POOL_SIZE вне диапазона 1..64"
            return 1
        fi
        case "$MAX_CONNECTIONS" in
            ''|*[!0-9]*|0|0*) config_error "MAX_CONNECTIONS должен быть числом 1..4096"; return 1 ;;
        esac
        if [ "${#MAX_CONNECTIONS}" -gt 4 ] || [ "$MAX_CONNECTIONS" -gt 4096 ] 2>/dev/null; then
            config_error "MAX_CONNECTIONS вне диапазона 1..4096"
            return 1
        fi
    fi
    if [ "$KZM_COMPONENT" = mtproto ]; then
        is_ipv4 "$DC_IP_DEFAULT" || {
            config_error "DC_IP_DEFAULT должен быть IPv4-адресом"
            return 1
        }
    fi
}

load_and_validate_config() {
    read_config || return 1
    validate_config || return 1
}

read_pid_file() {
    PID_VALUE=
    [ -f "$PID_FILE" ] || return 1
    [ ! -L "$PID_FILE" ] || return 1
    PID_VALUE=$(cat "$PID_FILE" 2>/dev/null) || return 1
    case "$PID_VALUE" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$PID_VALUE" -gt 1 ] 2>/dev/null || return 1
    return 0
}

pid_exists() {
    _kzm_pid=$1
    [ -d "$KZM_PROC_ROOT/$_kzm_pid" ] && kill -0 "$_kzm_pid" 2>/dev/null
}

pid_is_ours() {
    _kzm_pid=$1
    [ -L "$KZM_PROC_ROOT/$_kzm_pid/exe" ] || return 1
    _kzm_exe=$(readlink "$KZM_PROC_ROOT/$_kzm_pid/exe" 2>/dev/null) || return 1
    case "$_kzm_exe" in
        "$BINARY"|"$BINARY (deleted)") return 0 ;;
        *) ;;
    esac

    # Entware is mounted at /opt in userspace, while Keenetic may expose the
    # same executable through /proc/PID/exe without that mount prefix (for
    # example /opt/usr/bin/foo becomes /usr/bin/foo). Accept only the exact
    # canonical path of the expected regular, non-symlink binary; do not relax
    # ownership to a basename or command-line match in production.
    _kzm_binary_canonical=
    if [ -f "$BINARY" ] && [ ! -L "$BINARY" ]; then
        _kzm_binary_canonical=$(readlink -f "$BINARY" 2>/dev/null) || \
            _kzm_binary_canonical=
    fi
    case "$_kzm_binary_canonical" in
        /*)
            case "$_kzm_exe" in
                "$_kzm_binary_canonical"|"$_kzm_binary_canonical (deleted)") return 0 ;;
                *) ;;
            esac
            ;;
    esac

    # Test fixtures are executable shell scripts, therefore Linux exposes the
    # interpreter in /proc/PID/exe. Keep an exact executable + cmdline check,
    # and allow it only below a non-empty isolated KZM_ROOT.
    allow_test_artifacts || return 1
    case "$_kzm_exe" in
        */sh|*/dash|*/bash|*/busybox) ;;
        *) return 1 ;;
    esac
    [ -r "$KZM_PROC_ROOT/$_kzm_pid/cmdline" ] || return 1
    tr '\000' '\n' < "$KZM_PROC_ROOT/$_kzm_pid/cmdline" 2>/dev/null | \
        awk -v expected="$BINARY" 'NR <= 2 && $0 == expected { found = 1 } END { exit(found ? 0 : 1) }'
}

scan_owned_processes() {
    OWNED_PROCESS_COUNT=0
    OWNED_PROCESS_PID=
    # The script normally disables pathname expansion. Enable it only for the
    # trusted proc root enumeration and restore noglob before returning.
    set +f
    for _kzm_proc_dir in "$KZM_PROC_ROOT"/[0-9]*; do
        [ -d "$_kzm_proc_dir" ] || continue
        _kzm_scan_pid=${_kzm_proc_dir##*/}
        case "$_kzm_scan_pid" in
            ''|*[!0-9]*) continue ;;
        esac
        [ "$_kzm_scan_pid" -gt 1 ] 2>/dev/null || continue
        pid_exists "$_kzm_scan_pid" || continue
        pid_is_ours "$_kzm_scan_pid" || continue
        OWNED_PROCESS_COUNT=$((OWNED_PROCESS_COUNT + 1))
        OWNED_PROCESS_PID=$_kzm_scan_pid
    done
    set -f
}

inspect_runtime_state() {
    # Exit codes are intentionally suitable for the read-only `active` action:
    # 0 one exact component process is alive, 1 none is alive, 2 unsafe or
    # ambiguous state. Config and listener health are deliberately irrelevant.
    ACTIVE_PID=
    ACTIVE_SOURCE=
    PID_FILE_STATE=absent
    PID_FILE_RECORDED=

    if [ -e "$PID_FILE" ] || [ -L "$PID_FILE" ]; then
        if [ -L "$PID_FILE" ] || [ ! -f "$PID_FILE" ]; then
            PID_FILE_STATE=unsafe
            return 2
        fi
        if ! read_pid_file; then
            PID_FILE_STATE=unsafe
            return 2
        fi
        PID_FILE_RECORDED=$PID_VALUE
        if pid_exists "$PID_VALUE"; then
            if pid_is_ours "$PID_VALUE"; then
                scan_owned_processes
                if [ "$OWNED_PROCESS_COUNT" -eq 1 ] && \
                        [ "$OWNED_PROCESS_PID" = "$PID_VALUE" ]; then
                    PID_FILE_STATE=current
                    ACTIVE_PID=$PID_VALUE
                    ACTIVE_SOURCE=pidfile
                    return 0
                fi
                PID_FILE_STATE=unsafe
                ACTIVE_SOURCE=ambiguous
                return 2
            fi
            PID_FILE_STATE=unsafe
            return 2
        fi
        PID_FILE_STATE=stale
    fi

    scan_owned_processes
    case "$OWNED_PROCESS_COUNT" in
        0) return 1 ;;
        1)
            ACTIVE_PID=$OWNED_PROCESS_PID
            ACTIVE_SOURCE=scan
            return 0
            ;;
        *)
            ACTIVE_SOURCE=ambiguous
            return 2
            ;;
    esac
}

recover_runtime_state() {
    inspect_runtime_state
    _kzm_runtime_status=$?
    case "$_kzm_runtime_status" in
        0)
            if [ "$ACTIVE_SOURCE" = scan ]; then
                if [ "$PID_FILE_STATE" = stale ]; then
                    warn "PID-файл устарел; найден точный процесс $ACTIVE_PID"
                    remove_stale_pid
                fi
                write_pid_file "$ACTIVE_PID" || die "не удалось восстановить PID-файл"
            fi
            return 0
            ;;
        1)
            if [ "$PID_FILE_STATE" = stale ]; then
                warn "удаляю устаревший PID-файл ($PID_FILE_RECORDED)"
                remove_stale_pid
            fi
            return 1
            ;;
        *)
            return 2
            ;;
    esac
}

active_service() {
    inspect_runtime_state
    return $?
}

write_pid_file() {
    _kzm_pid=$1
    _kzm_pid_tmp="$PID_FILE.tmp.$$"
    printf '%s\n' "$_kzm_pid" > "$_kzm_pid_tmp" || return 1
    chmod 600 "$_kzm_pid_tmp" || {
        rm -f "$_kzm_pid_tmp"
        return 1
    }
    mv -f "$_kzm_pid_tmp" "$PID_FILE" || {
        rm -f "$_kzm_pid_tmp"
        return 1
    }
}

port_is_listening() {
    _kzm_netstat_output=$("$KZM_NETSTAT" -ltn 2>/dev/null) || return 2
    printf '%s\n' "$_kzm_netstat_output" | awk -v wanted_host="$HOST" -v wanted_port="$PORT" '
        $1 ~ /^tcp/ && $NF == "LISTEN" {
            if ($4 == wanted_host ":" wanted_port) found = 1
        }
        END { exit(found ? 0 : 1) }
    '
}

port_conflicts() {
    _kzm_netstat_output=$("$KZM_NETSTAT" -ltn 2>/dev/null) || return 2
    printf '%s\n' "$_kzm_netstat_output" | awk -v wanted_port="$PORT" '
        $1 ~ /^tcp/ && $NF == "LISTEN" {
            address = $4
            sub(/^.*:/, "", address)
            if (address == wanted_port) found = 1
        }
        END { exit(found ? 0 : 1) }
    '
}

host_is_assigned_to_lan_bridge() {
    _kzm_ip_bin=$(command -v "$KZM_IP_BIN" 2>/dev/null) || return 2
    for _kzm_lan_bridge in br0 br-lan; do
        _kzm_ip_output=$("$_kzm_ip_bin" -o -4 addr show dev "$_kzm_lan_bridge" scope global 2>/dev/null || true)
        if printf '%s\n' "$_kzm_ip_output" | awk -v wanted_host="$HOST" '
            $3 == "inet" {
                split($4, parts, "/")
                if (parts[1] == wanted_host) found = 1
            }
            END { exit(found ? 0 : 1) }
        '; then
            return 0
        fi
    done
    return 1
}

remove_stale_pid() {
    if [ -L "$PID_FILE" ]; then
        die "PID-файл не должен быть символической ссылкой: $PID_FILE"
    fi
    rm -f "$PID_FILE" || die "не удалось удалить устаревший PID-файл"
}

remove_failed_launch_pid_file() {
    if [ ! -e "$PID_FILE" ] && [ ! -L "$PID_FILE" ]; then
        return 0
    fi
    if [ -L "$PID_FILE" ] || [ -f "$PID_FILE" ]; then
        rm -f "$PID_FILE"
        return $?
    fi
    return 1
}

retain_failed_launch_pid() {
    _kzm_retain_pid=$1
    if [ ! -e "$PID_FILE" ] && [ ! -L "$PID_FILE" ]; then
        write_pid_file "$_kzm_retain_pid" 2>/dev/null || return 1
        return 0
    fi
    if read_pid_file && [ "$PID_VALUE" = "$_kzm_retain_pid" ]; then
        chmod 600 "$PID_FILE" 2>/dev/null || return 1
        return 0
    fi
    # Preserve an unexpected path/value for investigation. In particular, do
    # not overwrite a PID file that may refer to an unrelated live process.
    return 1
}

cleanup_failed_launch() {
    FAILED_LAUNCH_DETAIL=
    # With Rust, the pid can briefly execute /opt/bin/env before exec'ing the
    # canonical proxy binary. Also allow a just-backgrounded S-S-D child to
    # become visible in /proc before concluding that nothing was launched.
    _kzm_failed_probe=0
    while [ "$_kzm_failed_probe" -lt 3 ]; do
        scan_owned_processes
        [ "$OWNED_PROCESS_COUNT" -gt 0 ] && break
        if read_pid_file && pid_exists "$PID_VALUE" && pid_is_ours "$PID_VALUE"; then
            OWNED_PROCESS_COUNT=1
            OWNED_PROCESS_PID=$PID_VALUE
            break
        fi
        sleep 1
        _kzm_failed_probe=$((_kzm_failed_probe + 1))
    done
    scan_owned_processes
    case "$OWNED_PROCESS_COUNT" in
        0)
            if read_pid_file && pid_exists "$PID_VALUE"; then
                FAILED_LAUNCH_DETAIL="PID $PID_VALUE жив, но executable не совпадает; процесс не тронут, PID-файл сохранён"
                return 2
            fi
            if remove_failed_launch_pid_file; then
                return 0
            fi
            FAILED_LAUNCH_DETAIL="PID-файл небезопасен и оставлен для проверки"
            return 2
            ;;
        1) _kzm_failed_pid=$OWNED_PROCESS_PID ;;
        *)
            FAILED_LAUNCH_DETAIL="найдено несколько exact-процессов; сигналы не отправлены, PID-файл сохранён"
            return 2
            ;;
    esac

    if pid_exists "$_kzm_failed_pid" && pid_is_ours "$_kzm_failed_pid"; then
        kill -TERM "$_kzm_failed_pid" 2>/dev/null || true
    fi
    _kzm_failed_wait=0
    while pid_exists "$_kzm_failed_pid" && pid_is_ours "$_kzm_failed_pid" && \
            [ "$_kzm_failed_wait" -lt 8 ]; do
        sleep 1
        _kzm_failed_wait=$((_kzm_failed_wait + 1))
    done

    if pid_exists "$_kzm_failed_pid" && pid_is_ours "$_kzm_failed_pid"; then
        kill -KILL "$_kzm_failed_pid" 2>/dev/null || true
        _kzm_failed_wait=0
        while pid_exists "$_kzm_failed_pid" && pid_is_ours "$_kzm_failed_pid" && \
                [ "$_kzm_failed_wait" -lt 3 ]; do
            sleep 1
            _kzm_failed_wait=$((_kzm_failed_wait + 1))
        done
    fi

    # A PID can exit, be reused, or fork during either wait. A full exact-exe
    # scan is the final authority; the PID file is removed only when none of
    # this component's processes remain.
    scan_owned_processes
    if [ "$OWNED_PROCESS_COUNT" -eq 0 ]; then
        if remove_failed_launch_pid_file; then
            return 0
        fi
        FAILED_LAUNCH_DETAIL="процесс завершён, но небезопасный PID-файл оставлен"
        return 2
    fi
    if [ "$OWNED_PROCESS_COUNT" -eq 1 ]; then
        retain_failed_launch_pid "$OWNED_PROCESS_PID" || true
        FAILED_LAUNCH_DETAIL="exact-процесс $OWNED_PROCESS_PID не остановлен; PID-файл сохранён"
    else
        FAILED_LAUNCH_DETAIL="несколько exact-процессов не остановлены; PID-файл сохранён"
    fi
    return 2
}

fail_after_launch() {
    _kzm_launch_reason=$1
    log_event "$KZM_COMPONENT start failed: $_kzm_launch_reason"
    if cleanup_failed_launch; then
        die "$_kzm_launch_reason; дочерний процесс полностью остановлен"
    fi
    die "НЕБЕЗОПАСНО: $_kzm_launch_reason; $FAILED_LAUNCH_DETAIL"
}

confirm_busybox_start_stop_daemon() {
    _kzm_ssd_candidate=${KZM_START_STOP_DAEMON:-}
    if [ -z "$_kzm_ssd_candidate" ]; then
        _kzm_ssd_candidate=$(command -v start-stop-daemon 2>/dev/null) || \
            die "BusyBox start-stop-daemon не найден"
    fi
    [ -x "$_kzm_ssd_candidate" ] || die "start-stop-daemon не исполняемый: $_kzm_ssd_candidate"
    _kzm_ssd_help=$("$_kzm_ssd_candidate" --help 2>&1 || true)
    case "$_kzm_ssd_help" in
        *BusyBox*start-stop-daemon*) ;;
        *) die "отказ от запуска: start-stop-daemon не подтверждён как апплет BusyBox" ;;
    esac
    BUSYBOX_START_STOP_DAEMON=$_kzm_ssd_candidate
}

confirm_nobody_identity() {
    _kzm_nobody_uid=$(id -u nobody 2>/dev/null) || die "системный пользователь nobody не найден"
    case "$_kzm_nobody_uid" in
        ''|*[!0-9]*|0) die "системный пользователь nobody небезопасен" ;;
    esac

    _kzm_nobody_group=
    if command -v getent >/dev/null 2>&1; then
        _kzm_nobody_group=$(getent group nobody 2>/dev/null || true)
    fi
    if [ -z "$_kzm_nobody_group" ]; then
        for _kzm_group_file in /etc/group /opt/etc/group; do
            [ -r "$_kzm_group_file" ] || continue
            _kzm_nobody_group=$(awk -F: '$1 == "nobody" { print; exit }' "$_kzm_group_file" 2>/dev/null || true)
            [ -n "$_kzm_nobody_group" ] && break
        done
    fi
    case "$_kzm_nobody_group" in
        nobody:*) ;;
        *) die "системная группа nobody не найдена" ;;
    esac
}

launch_test_service() {
    command -v nohup >/dev/null 2>&1 || die "для тестового запуска нужен nohup"
    case "$KZM_COMPONENT" in
        socks5)
            nohup "$BINARY" \
                --mode socks5 \
                --host "$HOST" \
                --port "$PORT" \
                --username "$USERNAME" \
                --password "$PASSWORD" \
                </dev/null >/dev/null 2>&1 &
            ;;
        rust)
            TG_HOST="$HOST" \
            TG_PORT="$PORT" \
            TG_LINK_IP="$HOST" \
            TG_SECRET="$SECRET" \
            TG_POOL_SIZE="$POOL_SIZE" \
            TG_MAX_CONNECTIONS="$MAX_CONNECTIONS" \
            TG_NO_OUTBOUND_PROXY=true \
            TG_DEFAULT_DOMAINS=true \
            TG_CF_PRIORITY=false \
            TG_CF_BALANCE=false \
            TG_SKIP_TLS_VERIFY=false \
            TG_QUIET=true \
            RUST_LOG=warn \
                nohup "$BINARY" --dc-ip "$RUST_DIRECT_DC4" \
                    </dev/null >/dev/null 2>&1 &
            ;;
        mtproto)
            nohup "$BINARY" \
                --host "$HOST" \
                --port "$PORT" \
                --secret "$SECRET" \
                --dc-ip-default "$DC_IP_DEFAULT" \
                --no-cfproxy \
                --no-cfproxy-domain-refresh \
                </dev/null >/dev/null 2>&1 &
            ;;
    esac
    _kzm_new_pid=$!
    if ! write_pid_file "$_kzm_new_pid"; then
        if pid_is_ours "$_kzm_new_pid"; then
            kill -TERM "$_kzm_new_pid" 2>/dev/null || true
        fi
        die "не удалось записать PID-файл"
    fi
}

launch_production_service() {
    [ "$(id -u 2>/dev/null)" = 0 ] || die "production-сервис должен запускаться от root"
    confirm_busybox_start_stop_daemon
    confirm_nobody_identity

    # BusyBox creates the pid file while still privileged, then drops the
    # proxy process to nobody:nobody. The supervisor remains the only writer
    # of protected config/PID state.
    case "$KZM_COMPONENT" in
        socks5)
            if ! "$BUSYBOX_START_STOP_DAEMON" -S -b -m \
                    -p "$PID_FILE" -c nobody:nobody -x "$BINARY" -- \
                    --mode socks5 \
                    --host "$HOST" \
                    --port "$PORT" \
                    --username "$USERNAME" \
                    --password "$PASSWORD" \
                    </dev/null >/dev/null 2>&1; then
                fail_after_launch "BusyBox start-stop-daemon не смог запустить socks5"
            fi
            ;;
        rust)
            _kzm_rust_env=/opt/bin/env
            [ -x "$_kzm_rust_env" ] || die "для Rust-прокси нужен /opt/bin/env"
            if ! "$BUSYBOX_START_STOP_DAEMON" -S -b -m \
                    -p "$PID_FILE" -c nobody:nobody -x "$_kzm_rust_env" -- \
                    "TG_HOST=$HOST" \
                    "TG_PORT=$PORT" \
                    "TG_LINK_IP=$HOST" \
                    "TG_SECRET=$SECRET" \
                    "TG_POOL_SIZE=$POOL_SIZE" \
                    "TG_MAX_CONNECTIONS=$MAX_CONNECTIONS" \
                    TG_NO_OUTBOUND_PROXY=true \
                    TG_DEFAULT_DOMAINS=true \
                    TG_CF_PRIORITY=false \
                    TG_CF_BALANCE=false \
                    TG_SKIP_TLS_VERIFY=false \
                    TG_QUIET=true \
                    RUST_LOG=warn \
                    "$BINARY" --dc-ip "$RUST_DIRECT_DC4" \
                    </dev/null >/dev/null 2>&1; then
                fail_after_launch "BusyBox start-stop-daemon не смог запустить rust"
            fi
            ;;
        mtproto)
            if ! "$BUSYBOX_START_STOP_DAEMON" -S -b -m \
                    -p "$PID_FILE" -c nobody:nobody -x "$BINARY" -- \
                    --host "$HOST" \
                    --port "$PORT" \
                    --secret "$SECRET" \
                    --dc-ip-default "$DC_IP_DEFAULT" \
                    --no-cfproxy \
                    --no-cfproxy-domain-refresh \
                    </dev/null >/dev/null 2>&1; then
                fail_after_launch "BusyBox start-stop-daemon не смог запустить mtproto"
            fi
            ;;
    esac

    _kzm_pid_wait=0
    while ! read_pid_file && [ "$_kzm_pid_wait" -lt 3 ]; do
        sleep 1
        _kzm_pid_wait=$((_kzm_pid_wait + 1))
    done
    read_pid_file || fail_after_launch "BusyBox start-stop-daemon не записал безопасный PID-файл"
    chmod 600 "$PID_FILE" || fail_after_launch "не удалось защитить PID-файл"
    _kzm_new_pid=$PID_VALUE
}

start_service() {
    load_and_validate_config || return 1
    prepare_runtime

    [ -f "$BINARY" ] || die "бинарный файл не найден: $BINARY"
    [ ! -L "$BINARY" ] || die "бинарный файл не должен быть символической ссылкой: $BINARY"
    [ -x "$BINARY" ] || die "бинарный файл не исполняемый: $BINARY"
    if production_mode; then
        command -v "$KZM_NETSTAT" >/dev/null 2>&1 || die "для проверки порта нужен netstat"
        command -v "$KZM_IP_BIN" >/dev/null 2>&1 || die "для проверки LAN-адреса нужен ip"
    elif ! allow_test_artifacts; then
        die "для запуска в KZM_ROOT требуется KZM_ALLOW_TEST_ARTIFACTS=1"
    fi

    recover_runtime_state
    _kzm_runtime_status=$?
    case "$_kzm_runtime_status" in
        0)
            say "$KZM_COMPONENT: уже запущен (PID $ACTIVE_PID)"
            return 0
            ;;
        1) ;;
        *) die "небезопасное или неоднозначное состояние PID; запуск запрещён" ;;
    esac

    if production_mode; then
        host_is_assigned_to_lan_bridge
        _kzm_host_status=$?
        case "$_kzm_host_status" in
            0) ;;
            1) die "HOST $HOST не назначен интерфейсу br0 или br-lan" ;;
            *) die "не удалось проверить LAN-адрес $HOST" ;;
        esac

        port_conflicts
        _kzm_port_status=$?
        case "$_kzm_port_status" in
            0) die "TCP-порт $PORT уже занят; прокси не запущен" ;;
            1) ;;
            *) die "netstat не смог проверить TCP-порт $PORT" ;;
        esac
    fi

    # Child output is never persisted: upstream implementations can print
    # connection links containing credentials. Production uses BusyBox S-S-D
    # to drop privileges; only the isolated fixture mode retains nohup/root.
    if allow_test_artifacts; then
        launch_test_service
    else
        launch_production_service
    fi

    # Rust fetches the community Cloudflare list before binding its listener.
    # Its bounded connect/TLS/read stages can take about 30 seconds when the
    # source is unreachable, after which it falls back to a built-in list.
    # Keep checking ownership every second, but do not reject a healthy start
    # merely because that pre-bind fetch outlives the normal five-second wait.
    _kzm_start_deadline=5
    if [ "$KZM_COMPONENT" = rust ]; then
        _kzm_start_deadline=45
    fi
    _kzm_attempt=0
    while [ "$_kzm_attempt" -lt "$_kzm_start_deadline" ]; do
        sleep 1
        if ! pid_exists "$_kzm_new_pid" || ! pid_is_ours "$_kzm_new_pid"; then
            fail_after_launch "$KZM_COMPONENT завершился сразу после запуска"
        fi
        if allow_test_artifacts && [ "${KZM_TEST_WAIT_FOR_LISTENER:-0}" != 1 ]; then
            log_event "$KZM_COMPONENT started pid=$_kzm_new_pid listen-check=test-bypass"
            say "$KZM_COMPONENT: запущен (PID $_kzm_new_pid, тестовый режим)"
            return 0
        fi
        port_is_listening
        _kzm_port_status=$?
        if [ "$_kzm_port_status" -eq 0 ]; then
            log_event "$KZM_COMPONENT started pid=$_kzm_new_pid listen=$HOST:$PORT"
            say "$KZM_COMPONENT: запущен (PID $_kzm_new_pid, $HOST:$PORT)"
            return 0
        fi
        if [ "$_kzm_port_status" -eq 2 ]; then
            break
        fi
        _kzm_attempt=$((_kzm_attempt + 1))
    done

    fail_after_launch "$KZM_COMPONENT не открыл TCP-порт $PORT за $_kzm_start_deadline секунд"
}

stop_service() {
    recover_runtime_state
    _kzm_runtime_status=$?
    case "$_kzm_runtime_status" in
        0) _kzm_stop_pid=$ACTIVE_PID ;;
        1)
            say "$KZM_COMPONENT: не запущен"
            return 0
            ;;
        *) die "небезопасное или неоднозначное состояние PID; остановка запрещена" ;;
    esac

    # The state inspection and signal are separate syscalls. Re-check the
    # executable immediately before TERM so PID reuse can never target a
    # process that does not belong to this component.
    if ! pid_exists "$_kzm_stop_pid" || ! pid_is_ours "$_kzm_stop_pid"; then
        die "PID $_kzm_stop_pid изменился до отправки TERM; остановка запрещена"
    fi

    kill -TERM "$_kzm_stop_pid" 2>/dev/null || die "не удалось послать TERM процессу $_kzm_stop_pid"
    _kzm_wait=0
    while pid_exists "$_kzm_stop_pid" && [ "$_kzm_wait" -lt 8 ]; do
        sleep 1
        _kzm_wait=$((_kzm_wait + 1))
    done

    if pid_exists "$_kzm_stop_pid"; then
        # Re-check /proc immediately before KILL. If the PID was reused, leave
        # the new process untouched and keep the pid file for investigation.
        if ! pid_is_ours "$_kzm_stop_pid"; then
            die "PID $_kzm_stop_pid изменил владельца во время остановки; KILL не отправлен"
        fi
        warn "$KZM_COMPONENT не завершился по TERM; отправляю KILL точному PID $_kzm_stop_pid"
        kill -KILL "$_kzm_stop_pid" 2>/dev/null || die "не удалось послать KILL процессу $_kzm_stop_pid"
        _kzm_wait=0
        while pid_exists "$_kzm_stop_pid" && [ "$_kzm_wait" -lt 3 ]; do
            sleep 1
            _kzm_wait=$((_kzm_wait + 1))
        done
    fi

    if pid_exists "$_kzm_stop_pid"; then
        die "процесс $_kzm_stop_pid не завершился"
    fi

    # The original PID disappearing is not sufficient: a daemon can fork or
    # respawn an exact child while its parent exits. Never let update/remove
    # touch the binary until a full /proc scan proves that no owned process is
    # left. Preserve a single discovered PID so a later explicit stop can
    # recover it; multiple matches remain intentionally ambiguous.
    scan_owned_processes
    case "$OWNED_PROCESS_COUNT" in
        0) ;;
        1)
            write_pid_file "$OWNED_PROCESS_PID" || \
                die "после TERM остался exact-процесс $OWNED_PROCESS_PID; его PID-файл не удалось сохранить"
            die "после TERM остался exact-процесс $OWNED_PROCESS_PID; binary и файлы сохранены"
            ;;
        *)
            die "после TERM осталось несколько exact-процессов; binary и файлы сохранены"
            ;;
    esac
    rm -f "$PID_FILE" || die "не удалось удалить PID-файл"
    log_event "$KZM_COMPONENT stopped pid=$_kzm_stop_pid"
    say "$KZM_COMPONENT: остановлен"
}

status_service() {
    inspect_runtime_state
    _kzm_runtime_status=$?
    case "$_kzm_runtime_status" in
        0) _kzm_status_pid=$ACTIVE_PID ;;
        1)
            if [ "$PID_FILE_STATE" = stale ]; then
                warn "$KZM_COMPONENT: PID $PID_FILE_RECORDED не существует (PID-файл устарел)"
            else
                say "$KZM_COMPONENT: не запущен"
            fi
            return 1
            ;;
        *)
            warn "$KZM_COMPONENT: небезопасное или неоднозначное состояние PID"
            return 2
            ;;
    esac
    load_and_validate_config || return 1

    if allow_test_artifacts; then
        say "$KZM_COMPONENT: запущен (PID $_kzm_status_pid, тестовый режим)"
        return 0
    fi

    if command -v "$KZM_NETSTAT" >/dev/null 2>&1; then
        port_is_listening
        _kzm_port_status=$?
        case "$_kzm_port_status" in
            0)
                say "$KZM_COMPONENT: запущен (PID $_kzm_status_pid, $HOST:$PORT)"
                return 0
                ;;
            1)
                warn "$KZM_COMPONENT: PID $_kzm_status_pid запущен, но TCP-порт $PORT не слушается"
                return 1
                ;;
        esac
    fi
    warn "$KZM_COMPONENT: PID $_kzm_status_pid запущен; netstat недоступен"
    return 0
}

case "$ACTION" in
    start)
        acquire_mutation_lock
        start_service
        ;;
    stop)
        acquire_mutation_lock
        stop_service
        ;;
    restart)
        acquire_mutation_lock
        stop_service && start_service
        ;;
    barrier)
        # The component manager acquires manage.lock first, then calls this
        # barrier. Once it returns, every direct mutation that began before
        # manage.lock has completed; newer ones are rejected by that lock.
        acquire_mutation_lock
        ;;
    status) status_service ;;
    active) active_service ;;
esac
