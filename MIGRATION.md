# Переход с nfqws2 на классический zapret/nfqws

Этот документ — план для отдельного окна обслуживания. Команды ниже не
выполнялись на роутере при разработке и не запускаются `install.sh`.

Причина отдельного переключения: `nfqws2-keenetic` и `nfqws-keenetic`
конфликтуют как пакеты, а Lua-стратегии zapret2 несовместимы со стратегиями
`--dpi-desync` из StressOzz/Zapret-Manager.

## До переключения

Установить только менеджер, загрузить каталог и проверить результат:

```sh
sh install.sh
kzm update
kzm strategy set general v7
kzm strategy set youtube Yv08
kzm strategy set discord off
kzm strategy set discord-media Dv1
kzm strategy set quic off
kzm strategy set game off
kzm preview
```

Ни одна из этих команд не останавливает текущий `nfqws2`.

До переключения можно выполнить реальный ограниченный тест классических
стратегий, не устанавливая конфликтующий пакет:

```sh
kzm test engine-update
kzm test general
```

Тестовый бинарник извлекается отдельно, а каждый запрос проходит через
временную очередь с `queue-bypass` и watchdog. Активный движок и его конфиг
не меняются.

Сделать отдельную копию текущего движка:

```sh
stamp="$(date +%Y%m%d-%H%M%S)"
backup="/opt/etc/kzapret-manager/backups/nfqws2-$stamp"
mkdir -p "$backup"
cp -p /opt/etc/nfqws2/nfqws2.conf "$backup/" 2>/dev/null || true
cp -p /opt/etc/init.d/S51nfqws2 "$backup/" 2>/dev/null || true
cp -p /opt/etc/opkg/nfqws2-keenetic.conf "$backup/" 2>/dev/null || true
opkg list-installed > "$backup/opkg-list.txt"
echo "$backup"
```

## Переключение движка

Выполнять только при наличии локального доступа к Keenetic. Между остановкой
старого и запуском нового движка возможен краткий обрыв WAN-соединений.

Для маршрутизатора `aarch64`:

```sh
/opt/etc/init.d/S51nfqws2 stop
opkg remove nfqws2-keenetic
mkdir -p /opt/etc/opkg
echo "src/gz nfqws-keenetic https://nfqws.github.io/nfqws-keenetic/aarch64" > /opt/etc/opkg/nfqws-keenetic.conf
opkg update
opkg install nfqws-keenetic
```

Официальный пакет после установки запускает свою базовую конфигурацию. Затем
проверить и записать выбранную конфигурацию менеджера:

```sh
kzm doctor
kzm preview
kzm apply
```

`kzm apply` прогонит аргументы через настоящий `nfqws --dry-run`, сделает
резервную копию и запишет конфиг, но службу не перезапустит. Применение:

```sh
kzm service restart --yes
```

Для включения обхода Discord средствами zapret, а не Mihomo:

```sh
kzm strategy set discord on
kzm strategy set discord-media Dv1
kzm preview
kzm apply
kzm service restart --yes
```

Если нужен QUIC для YouTube, сначала убедиться, что Mihomo/фаервол не делает
`REJECT` для UDP/443, затем отдельно выбрать:

```sh
kzm strategy set quic on
kzm preview
kzm apply
kzm service restart --yes
```

Удаление конфликтующего правила Mihomo не входит в `kzm`: это отдельное
изменение, которое следует делать в том же окне обслуживания с локальным
доступом к роутеру.

## Откат

Не удалять каталог резервной копии `nfqws2-*`. При откате остановить
классический движок, вернуть пакет `nfqws2-keenetic`, затем восстановить его
конфиг из этой копии. При вопросе удаления `/opt/etc/nfqws` лучше сохранить
конфиг (`N`), пока переход окончательно не проверен.
