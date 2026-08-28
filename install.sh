#!/bin/sh

set -eu

umask 022

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT_PREFIX=""
TARGET=""
TARGET_IS_KEENETIC_LINK=0
LOCK_DIR=""
LOCK_HELD=0
LOCK_START=""
TXN_DIR=""
STAGE_DIR=""
TRANSACTION_OWNED=0
COMMIT_FILES=""
ENTRYPOINT_RELATIVE="bin/kzm"
EXIT_HANDLER_ACTIVE=0

usage() {
    cat <<'EOF'
Использование: sh install.sh [--root PATH]

Устанавливает только менеджер. Движки nfqws/nfqws2 не удаляет,
службы не запускает и не перезапускает.
EOF
}

die() {
    printf 'Ошибка установки: %s\n' "$*" >&2
    exit 1
}

path_exists() {
    [ -e "$1" ] || [ -L "$1" ]
}

validate_root_prefix() {
    if [ -z "$ROOT_PREFIX" ]; then
        TARGET=/opt
    else
        case "$ROOT_PREFIX" in
            /*) ;;
            *) die "--root должен быть абсолютным путём" ;;
        esac
        case "$ROOT_PREFIX" in
            /|*/|*//*|*/./*|*/../*|*/.|*/..|*[!A-Za-z0-9_./-]*)
                die "небезопасный путь --root: $ROOT_PREFIX"
                ;;
        esac
        [ -d "$ROOT_PREFIX" ] || die "--root не является каталогом: $ROOT_PREFIX"
        [ ! -L "$ROOT_PREFIX" ] || die "--root не должен быть символической ссылкой"
        root_physical=$(CDPATH='' cd -P -- "$ROOT_PREFIX" && pwd) || die "не удалось проверить --root"
        [ "$root_physical" = "$ROOT_PREFIX" ] || die "--root содержит символическую ссылку: $ROOT_PREFIX"
        TARGET="$ROOT_PREFIX/opt"
    fi

    if path_exists "$TARGET"; then
        [ -d "$TARGET" ] || die "путь установки не является каталогом: $TARGET"
        if [ -L "$TARGET" ]; then
            # Keenetic's Entware layout intentionally uses `/opt -> .`, with
            # the USB filesystem mounted as the shell root. Accept only that
            # exact production layout; --root tests and every other symlink
            # remain forbidden.
            [ -z "$ROOT_PREFIX" ] || die "путь установки не должен быть символической ссылкой: $TARGET"
            target_link=$(readlink "$TARGET" 2>/dev/null) || die "не удалось прочитать ссылку $TARGET"
            [ "$target_link" = . ] || die "неожиданная цель символической ссылки $TARGET"
            target_physical=$(CDPATH='' cd -P -- "$TARGET" && pwd) || die "не удалось проверить $TARGET"
            [ "$target_physical" = / ] || die "символическая ссылка $TARGET ведёт не в корень Entware"
            TARGET_IS_KEENETIC_LINK=1
        fi
    else
        mkdir -p "$TARGET" || die "не удалось создать $TARGET"
    fi

    target_physical=$(CDPATH='' cd -P -- "$TARGET" && pwd) || die "не удалось проверить $TARGET"
    if [ "$TARGET_IS_KEENETIC_LINK" -eq 1 ]; then
        [ "$target_physical" = / ] || die "символическая ссылка $TARGET изменилась во время проверки"
    else
        [ "$target_physical" = "$TARGET" ] || die "путь установки содержит символическую ссылку: $TARGET"
    fi
}

target_base_safe() {
    target_base=$1
    if [ "$TARGET_IS_KEENETIC_LINK" -eq 1 ] && [ "$target_base" = "$TARGET" ]; then
        [ -d "$target_base" ] && [ -L "$target_base" ] || return 1
        [ "$(readlink "$target_base" 2>/dev/null)" = . ] || return 1
        target_base_physical=$(CDPATH='' cd -P -- "$target_base" 2>/dev/null && pwd) || return 1
        [ "$target_base_physical" = / ]
    else
        [ -d "$target_base" ] && [ ! -L "$target_base" ]
    fi
}

is_allowed_relative() {
    allowed_relative=$1
    case "$allowed_relative" in
        bin/kzm|\
        share/kzm/state.default|\
        share/kzm/youtube.list|\
        share/kzm/canary-pass.strategy|\
        share/kzm/test-targets.base.tsv|\
        share/kzm/components/S99kzm-tg-socks5|\
        share/kzm/components/S99kzm-tg-rust|\
        share/kzm/components/S99kzm-tg-mtproto|\
        share/kzm/hardware/S50kzm-gro-fix|\
        share/kzm/hardware/090-kzm-gro-fix.sh|\
        share/kzm/hardware/091-kzm-quic-policy.sh|\
        etc/kzapret-manager/kzm.conf|\
        etc/kzapret-manager/kzm.conf.dist|\
        etc/kzapret-manager/lists/youtube.list|\
        etc/init.d/S99kzm-tg-socks5|\
        etc/init.d/S99kzm-tg-rust|\
        etc/init.d/S99kzm-tg-mtproto|\
        etc/init.d/S50kzm-gro-fix|\
        etc/ndm/netfilter.d/090-kzm-gro-fix.sh|\
        etc/ndm/netfilter.d/091-kzm-quic-policy.sh)
            return 0
            ;;
        libexec/kzm/*.sh|libexec/kzm/*.awk)
            allowed_base=${allowed_relative#libexec/kzm/}
            case "$allowed_base" in
                ''|*/*|.*|*[!A-Za-z0-9_.-]*) return 1 ;;
            esac
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

ensure_safe_tree() {
    tree_base=$1
    tree_relative=$2
    tree_create=$3
    tree_current=$tree_base
    tree_remaining=$tree_relative

    target_base_safe "$tree_current" || return 1
    while [ -n "$tree_remaining" ]; do
        case "$tree_remaining" in
            */*)
                tree_part=${tree_remaining%%/*}
                tree_remaining=${tree_remaining#*/}
                ;;
            *)
                tree_part=$tree_remaining
                tree_remaining=""
                ;;
        esac
        case "$tree_part" in
            ''|.|..|*[!A-Za-z0-9_.-]*) return 1 ;;
        esac
        tree_current="$tree_current/$tree_part"
        if path_exists "$tree_current"; then
            [ -d "$tree_current" ] && [ ! -L "$tree_current" ] || return 1
        elif [ "$tree_create" = 1 ]; then
            mkdir "$tree_current" || return 1
        else
            return 1
        fi
    done
}

prepare_destination() {
    prepare_relative=$1
    is_allowed_relative "$prepare_relative" || die "неразрешённый путь назначения: $prepare_relative"
    prepare_target="$TARGET/$prepare_relative"
    prepare_parent=${prepare_relative%/*}

    if path_exists "$prepare_target"; then
        [ ! -d "$prepare_target" ] || die "путь назначения является каталогом: $prepare_target"
    fi
    ensure_safe_tree "$TARGET" "$prepare_parent" 1 || die "небезопасный родитель пути: $prepare_target"
}

process_start_id() {
    process_pid=$1
    [ -r "/proc/$process_pid/stat" ] || return 1
    process_tail=$(sed 's/^.*) //' "/proc/$process_pid/stat") || return 1
    process_start=$(printf '%s\n' "$process_tail" | awk '{ print $20; exit }') || return 1
    case "$process_start" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$process_start"
}

read_lock_owner() {
    owner_file=$1
    [ -f "$owner_file" ] && [ ! -L "$owner_file" ] || return 1
    OWNER_PID=$(sed -n '1p' "$owner_file") || return 1
    OWNER_START=$(sed -n '2p' "$owner_file") || return 1
    OWNER_TARGET=$(sed -n '3p' "$owner_file") || return 1
    OWNER_EXTRA=$(sed -n '4p' "$owner_file") || return 1
    case "$OWNER_PID" in
        ''|*[!0-9]*) return 1 ;;
    esac
    case "$OWNER_START" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$OWNER_TARGET" = "$TARGET" ] || return 1
    [ -z "$OWNER_EXTRA" ] || return 1
}

lock_owner_is_live() {
    read_lock_owner "$LOCK_DIR/owner" || return 2
    kill -0 "$OWNER_PID" 2>/dev/null || return 1
    current_start=$(process_start_id "$OWNER_PID") || return 1
    [ "$current_start" = "$OWNER_START" ] || return 1
    return 0
}

remove_lock_directory() {
    remove_lock_path=$1
    case "$remove_lock_path" in
        "$TARGET/.kzm-install.lock"|"$TARGET/.kzm-install.lock.stale.$$" ) ;;
        *) return 1 ;;
    esac
    [ -d "$remove_lock_path" ] && [ ! -L "$remove_lock_path" ] || return 1
    if path_exists "$remove_lock_path/owner"; then
        [ -f "$remove_lock_path/owner" ] && [ ! -L "$remove_lock_path/owner" ] || return 1
        rm -f "$remove_lock_path/owner" || return 1
    fi
    rmdir "$remove_lock_path"
}

acquire_lock() {
    LOCK_DIR="$TARGET/.kzm-install.lock"
    lock_stale="$TARGET/.kzm-install.lock.stale.$$"
    incomplete_checks=0

    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        if [ ! -d "$LOCK_DIR" ] || [ -L "$LOCK_DIR" ]; then
            die "небезопасная блокировка установки: $LOCK_DIR"
        fi
        lock_status=0
        lock_owner_is_live || lock_status=$?
        case "$lock_status" in
            0) die "другая установка уже выполняется (PID $OWNER_PID)" ;;
            2)
                incomplete_checks=$((incomplete_checks + 1))
                if [ "$incomplete_checks" -lt 3 ]; then
                    sleep 1
                    continue
                fi
                ;;
            1) ;;
            *) die "не удалось проверить блокировку установки" ;;
        esac

        if [ -e "$lock_stale" ] || [ -L "$lock_stale" ]; then
            die "существует неожиданный путь $lock_stale"
        fi
        if mv "$LOCK_DIR" "$lock_stale" 2>/dev/null; then
            remove_lock_directory "$lock_stale" || die "устаревшая блокировка содержит неожиданные файлы: $lock_stale"
        fi
        incomplete_checks=0
    done

    LOCK_START=$(process_start_id "$$") || {
        rmdir "$LOCK_DIR" 2>/dev/null || :
        die "не удалось определить идентификатор процесса установщика"
    }
    if ! printf '%s\n%s\n%s\n' "$$" "$LOCK_START" "$TARGET" > "$LOCK_DIR/owner"; then
        rm -f "$LOCK_DIR/owner" 2>/dev/null || :
        rmdir "$LOCK_DIR" 2>/dev/null || :
        die "не удалось записать владельца блокировки"
    fi
    chmod 600 "$LOCK_DIR/owner" || {
        rm -f "$LOCK_DIR/owner" 2>/dev/null || :
        rmdir "$LOCK_DIR" 2>/dev/null || :
        die "не удалось защитить блокировку"
    }
    LOCK_HELD=1
}

release_lock() {
    [ "$LOCK_HELD" = 1 ] || return 0
    if read_lock_owner "$LOCK_DIR/owner" &&
       [ "$OWNER_PID" = "$$" ] && [ "$OWNER_START" = "$LOCK_START" ]; then
        rm -f "$LOCK_DIR/owner" || return 1
        rmdir "$LOCK_DIR" || return 1
    else
        return 1
    fi
    LOCK_HELD=0
}

safe_remove_transaction() {
    [ -n "$TXN_DIR" ] || return 0
    [ "$TXN_DIR" = "$TARGET/.kzm-install.transaction" ] || return 1
    path_exists "$TXN_DIR" || return 0
    [ -d "$TXN_DIR" ] && [ ! -L "$TXN_DIR" ] || return 1

    # Rename first: after a power loss, the canonical transaction is either
    # wholly present (and recoverable) or wholly absent. A partially removed
    # discard directory never blocks recovery of the next installation.
    discard_path="$TARGET/.kzm-install.discard.$$"
    [ ! -e "$discard_path" ] && [ ! -L "$discard_path" ] || return 1
    mv "$TXN_DIR" "$discard_path" || return 1
    rm -rf "$discard_path" || return 1
}

cleanup_discarded_transactions() {
    for discard_path in "$TARGET/".kzm-install.discard.*; do
        path_exists "$discard_path" || continue
        discard_suffix=${discard_path##*.kzm-install.discard.}
        case "$discard_suffix" in
            ''|*[!0-9]*) die "небезопасный временный путь: $discard_path" ;;
        esac
        if [ ! -d "$discard_path" ] || [ -L "$discard_path" ]; then
            die "небезопасный временный путь: $discard_path"
        fi
        rm -rf "$discard_path" || die "не удалось удалить $discard_path"
    done
}

read_transaction_state() {
    transaction_state_file="$TXN_DIR/state"
    [ -f "$transaction_state_file" ] && [ ! -L "$transaction_state_file" ] || return 1
    TRANSACTION_STATE=$(sed -n '1p' "$transaction_state_file") || return 1
    transaction_state_extra=$(sed -n '2p' "$transaction_state_file") || return 1
    [ -z "$transaction_state_extra" ] || return 1
    case "$TRANSACTION_STATE" in
        staging|committing|committed) return 0 ;;
        *) return 1 ;;
    esac
}

write_transaction_state() {
    new_state=$1
    case "$new_state" in
        staging|committing|committed) ;;
        *) return 1 ;;
    esac
    state_tmp="$TXN_DIR/state.tmp.$$"
    [ ! -e "$state_tmp" ] && [ ! -L "$state_tmp" ] || return 1
    printf '%s\n' "$new_state" > "$state_tmp" || return 1
    chmod 600 "$state_tmp" || {
        rm -f "$state_tmp" 2>/dev/null || :
        return 1
    }
    if ! mv -f "$state_tmp" "$TXN_DIR/state"; then
        rm -f "$state_tmp" 2>/dev/null || :
        return 1
    fi
}

read_journal_entry() {
    journal_entry=$1
    [ -f "$journal_entry" ] && [ ! -L "$journal_entry" ] || return 1
    JOURNAL_TYPE=""
    JOURNAL_RELATIVE=""
    JOURNAL_EXTRA=""
    read -r JOURNAL_TYPE JOURNAL_RELATIVE JOURNAL_EXTRA < "$journal_entry" || return 1
    case "$JOURNAL_TYPE" in O|N) ;; *) return 1 ;; esac
    [ -n "$JOURNAL_RELATIVE" ] && [ -z "$JOURNAL_EXTRA" ] || return 1
    is_allowed_relative "$JOURNAL_RELATIVE"
}

validate_journal() {
    journal_dir="$TXN_DIR/journal"
    rollback_dir="$TXN_DIR/rollback"
    [ -d "$journal_dir" ] && [ ! -L "$journal_dir" ] || return 1
    [ -d "$rollback_dir" ] && [ ! -L "$rollback_dir" ] || return 1
    journal_seen=" "
    journal_count=0

    for journal_entry in "$journal_dir"/*; do
        path_exists "$journal_entry" || continue
        journal_name=${journal_entry##*/}
        case "$journal_name" in
            [0-9][0-9][0-9][0-9][0-9][0-9].entry) ;;
            *) return 1 ;;
        esac
        read_journal_entry "$journal_entry" || return 1
        case "$journal_seen" in
            *" $JOURNAL_RELATIVE "*) return 1 ;;
        esac
        journal_seen="$journal_seen$JOURNAL_RELATIVE "
        journal_count=$((journal_count + 1))

        journal_parent=${JOURNAL_RELATIVE%/*}
        ensure_safe_tree "$TARGET" "$journal_parent" 0 || return 1
        ensure_safe_tree "$rollback_dir" "$journal_parent" 1 || return 1
        journal_target="$TARGET/$JOURNAL_RELATIVE"
        journal_backup="$rollback_dir/$JOURNAL_RELATIVE"
        if path_exists "$journal_target"; then
            [ ! -d "$journal_target" ] || return 1
        fi
        if path_exists "$journal_backup"; then
            [ ! -d "$journal_backup" ] || return 1
        fi
    done
    [ "$journal_count" -gt 0 ]
}

rollback_transaction() {
    validate_journal || return 1
    journal_dir="$TXN_DIR/journal"
    rollback_dir="$TXN_DIR/rollback"

    for journal_entry in "$journal_dir"/*; do
        read_journal_entry "$journal_entry" || return 1
        rollback_target="$TARGET/$JOURNAL_RELATIVE"
        rollback_saved="$rollback_dir/$JOURNAL_RELATIVE"
        case "$JOURNAL_TYPE" in
            O)
                if path_exists "$rollback_saved"; then
                    if path_exists "$rollback_target"; then
                        [ ! -d "$rollback_target" ] || return 1
                        rm -f "$rollback_target" || return 1
                    fi
                    mv "$rollback_saved" "$rollback_target" || return 1
                elif ! path_exists "$rollback_target"; then
                    return 1
                fi
                ;;
            N)
                if path_exists "$rollback_target"; then
                    [ ! -d "$rollback_target" ] || return 1
                    rm -f "$rollback_target" || return 1
                fi
                ;;
        esac
    done
    sync
    safe_remove_transaction
}

recover_abandoned_transaction() {
    TXN_DIR="$TARGET/.kzm-install.transaction"
    path_exists "$TXN_DIR" || return 0
    if [ ! -d "$TXN_DIR" ] || [ -L "$TXN_DIR" ]; then
        die "небезопасный путь незавершённой транзакции: $TXN_DIR"
    fi

    if read_transaction_state; then
        case "$TRANSACTION_STATE" in
            staging)
                safe_remove_transaction || die "не удалось удалить незавершённую подготовку"
                ;;
            committing)
                rollback_transaction || die "не удалось восстановить предыдущую установку"
                ;;
            committed)
                safe_remove_transaction || die "не удалось очистить завершённую транзакцию"
                ;;
        esac
    else
        die "повреждено состояние незавершённой транзакции; автоматическое удаление запрещено"
    fi
    TXN_DIR=""
}

handle_exit() {
    exit_status=$1
    [ "$EXIT_HANDLER_ACTIVE" = 0 ] || exit "$exit_status"
    EXIT_HANDLER_ACTIVE=1
    trap - 0 HUP INT TERM
    set +e

    if [ "$TRANSACTION_OWNED" = 1 ] && path_exists "$TXN_DIR"; then
        if read_transaction_state; then
            case "$TRANSACTION_STATE" in
                staging|committed)
                    safe_remove_transaction || exit_status=1
                    ;;
                committing)
                    rollback_transaction || {
                        printf '%s\n' "Ошибка установки: автоматический откат не завершён; транзакция сохранена в $TXN_DIR" >&2
                        exit_status=1
                    }
                    ;;
            esac
        else
            printf '%s\n' "Ошибка установки: состояние транзакции повреждено; она сохранена в $TXN_DIR" >&2
            exit_status=1
        fi
    fi
    TRANSACTION_OWNED=0
    release_lock || {
        printf '%s\n' "Ошибка установки: не удалось освободить блокировку $LOCK_DIR" >&2
        exit_status=1
    }
    exit "$exit_status"
}

begin_transaction() {
    TXN_DIR="$TARGET/.kzm-install.transaction"
    if [ -e "$TXN_DIR" ] || [ -L "$TXN_DIR" ]; then
        die "транзакция уже существует: $TXN_DIR"
    fi
    mkdir "$TXN_DIR" || die "не удалось создать транзакцию"
    chmod 700 "$TXN_DIR" || die "не удалось защитить транзакцию"
    mkdir "$TXN_DIR/stage" "$TXN_DIR/rollback" "$TXN_DIR/journal" || die "не удалось подготовить транзакцию"
    chmod 700 "$TXN_DIR/stage" "$TXN_DIR/rollback" "$TXN_DIR/journal" || die "не удалось защитить транзакцию"
    STAGE_DIR="$TXN_DIR/stage"
    TRANSACTION_OWNED=1
    write_transaction_state staging || die "не удалось записать состояние транзакции"
}

stage_file() {
    stage_source=$1
    stage_relative=$2
    stage_mode=$3
    is_allowed_relative "$stage_relative" || die "неразрешённый путь установки: $stage_relative"
    stage_target="$STAGE_DIR/$stage_relative"
    stage_parent_relative=${stage_relative%/*}

    if [ ! -f "$stage_source" ] || [ -L "$stage_source" ]; then
        die "не найден обычный исходный файл $stage_source"
    fi
    ensure_safe_tree "$STAGE_DIR" "$stage_parent_relative" 1 || die "не удалось создать staging для $stage_relative"
    if [ -e "$stage_target" ] || [ -L "$stage_target" ]; then
        die "дублирующийся staging-файл $stage_relative"
    fi
    cp "$stage_source" "$stage_target" || die "не удалось скопировать $stage_source"
    chmod "$stage_mode" "$stage_target" || die "не удалось установить права для $stage_relative"
    COMMIT_FILES="$COMMIT_FILES $stage_relative"
}

stage_youtube_merge() {
    active_relative="etc/kzapret-manager/lists/youtube.list"
    active_target="$TARGET/$active_relative"
    path_exists "$active_target" || return 0
    if [ ! -f "$active_target" ] || [ -L "$active_target" ]; then
        die "активный youtube.list должен быть обычным файлом"
    fi
    active_parent=${active_relative%/*}
    ensure_safe_tree "$TARGET" "$active_parent" 0 || die "небезопасный путь активного youtube.list"
    ensure_safe_tree "$STAGE_DIR" "$active_parent" 1 || die "не удалось подготовить обновление youtube.list"
    active_staged="$STAGE_DIR/$active_relative"

    awk '
        NR == FNR { seen[$0] = 1; print; next }
        $0 != "" && !seen[$0]++ { print }
    ' "$active_target" "$SCRIPT_DIR/src/share/kzm/youtube.list" > "$active_staged" ||
        die "не удалось объединить активный youtube.list"
    chmod 644 "$active_staged" || die "не удалось установить права активного youtube.list"
    if cmp "$active_target" "$active_staged" >/dev/null 2>&1; then
        rm -f "$active_staged" || die "не удалось очистить неизменённый youtube.list"
        return 0
    fi
    COMMIT_FILES="$COMMIT_FILES $active_relative"
}

build_journal() {
    journal_index=0
    journal_seen=" "
    for journal_relative in $COMMIT_FILES "$ENTRYPOINT_RELATIVE"; do
        is_allowed_relative "$journal_relative" || die "неразрешённый путь журнала: $journal_relative"
        case "$journal_seen" in
            *" $journal_relative "*) die "дублирующийся путь транзакции: $journal_relative" ;;
        esac
        journal_seen="$journal_seen$journal_relative "
        prepare_destination "$journal_relative"
        journal_target="$TARGET/$journal_relative"
        if path_exists "$journal_target"; then
            [ ! -d "$journal_target" ] || die "путь назначения является каталогом: $journal_target"
            journal_type=O
        else
            journal_type=N
        fi
        journal_index=$((journal_index + 1))
        journal_number=$(printf '%06d' "$journal_index")
        journal_tmp="$TXN_DIR/journal/$journal_number.tmp"
        journal_final="$TXN_DIR/journal/$journal_number.entry"
        printf '%s %s\n' "$journal_type" "$journal_relative" > "$journal_tmp" || die "не удалось записать журнал"
        chmod 600 "$journal_tmp" || die "не удалось защитить журнал"
        mv "$journal_tmp" "$journal_final" || die "не удалось зафиксировать журнал"
    done
    write_transaction_state committing || die "не удалось начать фиксацию транзакции"
    sync
}

commit_transaction() {
    for journal_entry in "$TXN_DIR/journal"/*; do
        read_journal_entry "$journal_entry" || die "повреждена запись транзакции: $journal_entry"
        commit_source="$STAGE_DIR/$JOURNAL_RELATIVE"
        commit_target="$TARGET/$JOURNAL_RELATIVE"
        commit_saved="$TXN_DIR/rollback/$JOURNAL_RELATIVE"
        commit_parent=${JOURNAL_RELATIVE%/*}

        if [ ! -f "$commit_source" ] || [ -L "$commit_source" ]; then
            die "не подготовлен файл $JOURNAL_RELATIVE"
        fi
        ensure_safe_tree "$TXN_DIR/rollback" "$commit_parent" 1 || die "не удалось подготовить откат $JOURNAL_RELATIVE"
        case "$JOURNAL_TYPE" in
            O)
                path_exists "$commit_target" || die "исчез старый файл $JOURNAL_RELATIVE"
                [ ! -d "$commit_target" ] || die "старый путь стал каталогом: $JOURNAL_RELATIVE"
                mv "$commit_target" "$commit_saved" || die "не удалось сохранить старый $JOURNAL_RELATIVE"
                ;;
            N)
                ! path_exists "$commit_target" || die "неожиданно появился $JOURNAL_RELATIVE"
                ;;
        esac
        mv "$commit_source" "$commit_target" || die "не удалось установить $JOURNAL_RELATIVE"
    done

    sync
    write_transaction_state committed || die "не удалось завершить транзакцию"
    sync
    safe_remove_transaction || die "не удалось удалить временный откат"
    TRANSACTION_OWNED=0
    TXN_DIR=""
    STAGE_DIR=""
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --root)
            [ "$#" -ge 2 ] || die "--root требует путь"
            ROOT_PREFIX=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "неизвестный параметр: $1"
            ;;
    esac
done

validate_root_prefix
trap 'handle_exit $?' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_lock
cleanup_discarded_transactions
recover_abandoned_transaction
begin_transaction

# Entrypoint is staged first but deliberately journaled and committed last.
stage_file "$SCRIPT_DIR/src/kzm" "$ENTRYPOINT_RELATIVE" 755
COMMIT_FILES=""

for stage_source in "$SCRIPT_DIR/src/libexec/kzm/"*.awk; do
    stage_file "$stage_source" "libexec/kzm/${stage_source##*/}" 644
done
for stage_source in "$SCRIPT_DIR/src/libexec/kzm/"*.sh; do
    stage_file "$stage_source" "libexec/kzm/${stage_source##*/}" 755
done

stage_file "$SCRIPT_DIR/tests/router-canary.sh" "libexec/kzm/router-canary.sh" 755
stage_file "$SCRIPT_DIR/tests/router-canary-matrix.sh" "libexec/kzm/router-canary-matrix.sh" 755
stage_file "$SCRIPT_DIR/tests/router-canary-suite.sh" "libexec/kzm/router-canary-suite.sh" 755

stage_file "$SCRIPT_DIR/src/share/kzm/state.default" "share/kzm/state.default" 644
stage_file "$SCRIPT_DIR/src/share/kzm/youtube.list" "share/kzm/youtube.list" 644
stage_file "$SCRIPT_DIR/src/share/kzm/canary-pass.strategy" "share/kzm/canary-pass.strategy" 644
stage_file "$SCRIPT_DIR/src/share/kzm/test-targets.base.tsv" "share/kzm/test-targets.base.tsv" 644

for stage_source in "$SCRIPT_DIR/src/share/kzm/components/"*; do
    stage_file "$stage_source" "share/kzm/components/${stage_source##*/}" 755
done

stage_file "$SCRIPT_DIR/src/share/kzm/hardware/S50kzm-gro-fix" "share/kzm/hardware/S50kzm-gro-fix" 755
stage_file "$SCRIPT_DIR/src/share/kzm/hardware/090-kzm-gro-fix.sh" "share/kzm/hardware/090-kzm-gro-fix.sh" 755
stage_file "$SCRIPT_DIR/src/share/kzm/hardware/091-kzm-quic-policy.sh" "share/kzm/hardware/091-kzm-quic-policy.sh" 755
stage_file "$SCRIPT_DIR/src/share/kzm/hardware/S50kzm-gro-fix" "etc/init.d/S50kzm-gro-fix" 755
stage_file "$SCRIPT_DIR/src/share/kzm/hardware/090-kzm-gro-fix.sh" "etc/ndm/netfilter.d/090-kzm-gro-fix.sh" 755
stage_file "$SCRIPT_DIR/src/share/kzm/hardware/091-kzm-quic-policy.sh" "etc/ndm/netfilter.d/091-kzm-quic-policy.sh" 755

# Existing user config is preserved; a fresh packaged copy is installed as .dist.
config_target="$TARGET/etc/kzapret-manager/kzm.conf"
if path_exists "$config_target"; then
    [ -f "$config_target" ] || die "kzm.conf существует, но не является обычным файлом"
    stage_file "$SCRIPT_DIR/src/kzm.conf" "etc/kzapret-manager/kzm.conf.dist" 644
else
    stage_file "$SCRIPT_DIR/src/kzm.conf" "etc/kzapret-manager/kzm.conf" 644
fi

# Existing init wrappers are refreshed as files only. No wrapper is executed.
for component in socks5 rust mtproto; do
    wrapper_relative="etc/init.d/S99kzm-tg-$component"
    if [ -f "$TARGET/$wrapper_relative" ]; then
        stage_file "$SCRIPT_DIR/src/share/kzm/components/S99kzm-tg-$component" "$wrapper_relative" 755
    fi
done

# Add missing packaged YouTube domains without deleting user lines or applying rules.
stage_youtube_merge

build_journal
commit_transaction

printf 'Keenetic Zapret Manager установлен в %s.\n' "$TARGET"
printf '%s\n' 'Ни одна служба не запускалась и не перезапускалась.'
printf 'Открыть общее меню: %s/bin/kzm\n' "$TARGET"
