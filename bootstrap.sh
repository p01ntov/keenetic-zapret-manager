#!/bin/sh

# Downloads one pinned KZM release into RAM and delegates all writes to the
# regular transactional installer. It never starts or restarts a service.

set -eu

umask 077

KZM_RELEASE_TAG=${KZM_RELEASE_TAG:-v0.8.1}
KZM_REPOSITORY=${KZM_REPOSITORY:-p01ntov/keenetic-zapret-manager}
KZM_ARCHIVE_NAME=keenetic-zapret-manager.tar.gz
KZM_CHECKSUM_NAME=$KZM_ARCHIVE_NAME.sha256
KZM_ARCHIVE_URL=${KZM_ARCHIVE_URL:-https://github.com/$KZM_REPOSITORY/releases/download/$KZM_RELEASE_TAG/$KZM_ARCHIVE_NAME}
KZM_CHECKSUM_URL=${KZM_CHECKSUM_URL:-https://github.com/$KZM_REPOSITORY/releases/download/$KZM_RELEASE_TAG/$KZM_CHECKSUM_NAME}

WORK_DIR=""
INSTALL_ROOT=""

usage() {
    cat <<'EOF'
Использование: sh bootstrap.sh [--root PATH]

Скачивает закреплённый релиз KZM, проверяет SHA-256 и запускает обычный
install.sh. Службы и сеть не перезапускаются.
EOF
}

say() {
    printf '%s\n' "$*"
}

die() {
    printf 'Ошибка загрузки KZM: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [ -n "$WORK_DIR" ]; then
        case "$WORK_DIR" in
            /tmp/kzm-bootstrap.*)
                if [ -d "$WORK_DIR" ] && [ ! -L "$WORK_DIR" ]; then
                    rm -rf "$WORK_DIR"
                fi
                ;;
        esac
    fi
}

fetch_file() {
    fetch_source=$1
    fetch_target=$2
    fetch_label=$3

    case "$fetch_source" in
        file://*)
            cp "${fetch_source#file://}" "$fetch_target" || \
                die "не удалось скопировать $fetch_label"
            return
            ;;
        /*)
            cp "$fetch_source" "$fetch_target" || \
                die "не удалось скопировать $fetch_label"
            return
            ;;
    esac

    if command -v curl >/dev/null 2>&1; then
        curl -fL --connect-timeout 30 --max-time 300 \
            "$fetch_source" -o "$fetch_target" || \
            die "не удалось скачать $fetch_label"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 30 -O "$fetch_target" "$fetch_source" || \
            die "не удалось скачать $fetch_label"
    else
        die "нужен curl или wget"
    fi
}

validate_release_identity() {
    case "$KZM_RELEASE_TAG" in
        ''|*[!A-Za-z0-9._-]*) die "некорректный release tag" ;;
    esac
    case "$KZM_RELEASE_TAG" in
        v[0-9]*) ;;
        *) die "release tag должен начинаться с v и номера версии" ;;
    esac
    case "$KZM_REPOSITORY" in
        */*) ;;
        *) die "некорректное имя GitHub-репозитория" ;;
    esac
    case "$KZM_REPOSITORY" in
        *[!A-Za-z0-9._/-]*|/*|*/|*/*/*) die "некорректное имя GitHub-репозитория" ;;
    esac
}

validate_archive_paths() {
    archive_list=$1
    [ -s "$archive_list" ] || die "архив релиза пуст"
    archive_count=$(awk 'END { print NR+0 }' "$archive_list")
    [ "$archive_count" -le 512 ] || die "в архиве релиза слишком много файлов"

    while IFS= read -r archive_name; do
        case "$archive_name" in .|./) continue ;; esac
        normalized=${archive_name#./}
        case "$normalized" in
            ''|/*|..|../*|*/..|*/../*|*\\*)
                die "небезопасный путь внутри архива: $archive_name"
                ;;
        esac
    done < "$archive_list"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --root)
            [ "$#" -ge 2 ] || die "--root требует путь"
            INSTALL_ROOT=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "неизвестный параметр: $1"
            ;;
    esac
done

validate_release_identity
for required_tool in awk cp mktemp rm sed sha256sum tar; do
    command -v "$required_tool" >/dev/null 2>&1 || \
        die "не найдена обязательная команда: $required_tool"
done

WORK_DIR=$(mktemp -d /tmp/kzm-bootstrap.XXXXXX) || \
    die "не удалось создать временный каталог в /tmp"
case "$WORK_DIR" in
    /tmp/kzm-bootstrap.*) ;;
    *) die "mktemp вернул небезопасный путь" ;;
esac
[ -d "$WORK_DIR" ] && [ ! -L "$WORK_DIR" ] || \
    die "временный каталог небезопасен"
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

archive_file="$WORK_DIR/$KZM_ARCHIVE_NAME"
checksum_file="$WORK_DIR/$KZM_CHECKSUM_NAME"
archive_list="$WORK_DIR/archive.list"
source_dir="$WORK_DIR/source"

say "Скачиваю Keenetic Zapret Manager $KZM_RELEASE_TAG..."
fetch_file "$KZM_ARCHIVE_URL" "$archive_file" "архив релиза"
fetch_file "$KZM_CHECKSUM_URL" "$checksum_file" "контрольную сумму"
[ -s "$archive_file" ] || die "скачан пустой архив"

expected_sha=$(awk '
    NR == 1 {
        value=tolower($1)
        if (length(value) == 64 && value !~ /[^0-9a-f]/) print value
        exit
    }
' "$checksum_file")
[ -n "$expected_sha" ] || die "файл контрольной суммы повреждён"
actual_sha=$(sha256sum "$archive_file" | awk '{ print tolower($1); exit }')
[ "$actual_sha" = "$expected_sha" ] || die "SHA-256 архива не совпал"

tar -tzf "$archive_file" > "$archive_list" 2>/dev/null || \
    die "релиз содержит повреждённый tar.gz"
validate_archive_paths "$archive_list"
mkdir "$source_dir" || die "не удалось подготовить каталог распаковки"
tar -xzf "$archive_file" -C "$source_dir" || die "не удалось распаковать релиз"

[ -f "$source_dir/install.sh" ] && [ ! -L "$source_dir/install.sh" ] || \
    die "в архиве нет безопасного install.sh"
[ -f "$source_dir/VERSION" ] && [ ! -L "$source_dir/VERSION" ] || \
    die "в архиве нет VERSION"
[ -d "$source_dir/src" ] && [ ! -L "$source_dir/src" ] || \
    die "в архиве нет каталога src"

release_version=$(sed -n '1p' "$source_dir/VERSION")
[ "v$release_version" = "$KZM_RELEASE_TAG" ] || \
    die "версия внутри архива не совпала с $KZM_RELEASE_TAG"

if [ -n "$INSTALL_ROOT" ]; then
    sh "$source_dir/install.sh" --root "$INSTALL_ROOT"
else
    sh "$source_dir/install.sh"
fi

say "KZM $release_version установлен из проверенного релиза GitHub."
