<h1 align="center">Keenetic Zapret Manager</h1>

<div align="center">

![Platform](https://img.shields.io/badge/Platform-Keenetic-00a0df)
![Environment](https://img.shields.io/badge/Environment-Entware-orange)
![Shell](https://img.shields.io/badge/Shell-POSIX%20sh-informational)
![License](https://img.shields.io/badge/License-MIT-success)

Менеджер `nfqws` для Keenetic, основанный на идеях и каталоге
[StressOzz/Zapret-Manager](https://github.com/StressOzz/Zapret-Manager)

</div>

---

Оригинальный [Zapret Manager](https://github.com/StressOzz/Zapret-Manager)
удобен, но рассчитан на OpenWrt. KZM появился как его адаптация для Keenetic с
Entware. Он загружает знакомые профили `v`, Flowseal, `Yv` и `Dv`, переводит их
в конфигурацию `nfqws-keenetic` и даёт управлять всем из одного SSH-меню.

Это не копия OpenWrt-скрипта. У Keenetic другая файловая система, запуск служб
и firewall, поэтому менеджер написан отдельно. От проекта StressOzz здесь —
идея, структура меню и импортируемый каталог стратегий. Keenetic-часть,
проверка конфигурации и безопасное применение сделаны специально для KZM.

> [!IMPORTANT]
> Не запускайте установочные команды из OpenWrt-версии на Keenetic. KZM не
> использует UCI и LuCI и не запускает upstream-установщик — он забирает только
> нужные данные и применяет их средствами Entware.

| | StressOzz/Zapret-Manager | Keenetic Zapret Manager |
|---|---|---|
| Платформа | OpenWrt | Keenetic + Entware |
| Движок | OpenWrt-пакеты Zapret/Zapret2 | `nfqws-keenetic` |
| Конфигурация | UCI и `/etc/config` | `/opt/etc/kzapret-manager` и `nfqws.conf` |
| Интерфейс | SSH, LuCI/браузер | SSH-меню и команда `kzm` |
| Применение | Меню оригинального скрипта | Предпросмотр, dry-run, явный перезапуск и автооткат |

## Оглавление

- [Возможности](#что-умеет-kzm)
- [Быстрый старт](#быстрый-старт)
- [Как применяются изменения](#что-именно-меняют-команды)
- [Свои сайты и IP-подсети](#свои-сайты-и-ip-подсети)
- [YouTube, Discord и QUIC](#youtube-discord-и-quic)
- [Проверка стратегий](#проверка-стратегий)
- [Telegram-прокси](#telegram-прокси)
- [Справочник команд](#справочник-команд)
- [Совместимость и требования](#совместимость-и-требования)
- [Дополнительная документация](#дополнительная-документация)

## Что умеет KZM

- обновлять стратегии `v1–v10`, профили Flowseal, YouTube `Yv` и
  `discord.media` `Dv` из исходных проектов;
- отдельно настраивать обычные сайты, YouTube, Discord voice/STUN, QUIC и
  игровой UDP;
- добавлять свои домены, IPv4/IPv6-адреса и CIDR-подсети;
- проверять стратегии до применения, не перезапуская основной `nfqws`;
- делать резервные копии конфига и откатывать неудачный запуск;
- устанавливать и обслуживать три необязательных Telegram-прокси;
- показывать и безопасно очищать журналы KZM и Mihomo.

Все пункты пользовательского меню выбираются цифрами. Текст нужно вводить
только там, где без него нельзя: например, при добавлении домена или IP-адреса.

> [!IMPORTANT]
> KZM работает с классическим пакетом `nfqws-keenetic`. Пакет
> `nfqws2-keenetic` использует другой формат стратегий и несовместим с ним.
> Если на роутере уже установлен `nfqws2`, сначала прочитайте
> [инструкцию по переходу](MIGRATION.md).

## Быстрый старт

### 1. Установите менеджер

Подключитесь к роутеру по SSH и скачайте свежую версию из GitHub:

```sh
KZM_TMP="$(mktemp -d /tmp/kzm-install.XXXXXX)" || exit 1
cd "$KZM_TMP" || exit 1
curl -fL https://github.com/p01ntov/keenetic-zapret-manager/releases/download/v0.8.1-beta/keenetic-zapret-manager.tar.gz -o kzm.tar.gz
tar -xzf kzm.tar.gz
sh install.sh
```

Если проект уже скачан на компьютер, можно вместо этого скопировать каталог на
роутер и запустить `sh install.sh` из него.

Установщик ставит только KZM. Он не удаляет другой движок, не запускает службы
и не перезапускает сеть — решение о переходе остаётся за вами.

### 2. Откройте меню

```sh
kzm
```

В главном меню находятся основные действия:

1. Zapret — стратегии, сайты и тесты.
2. Установка и удаление компонентов.
3. Управление Telegram-прокси.
4. Обновление уже установленных Telegram-прокси.
5. Полное состояние всех компонентов.

Если классический `nfqws-keenetic` ещё не установлен, откройте раздел
«Установка и удаление». При обнаружении `nfqws2-keenetic` менеджер остановится
и объяснит, что нужно сделать; сам он конфликтующий пакет не удаляет.

### 3. Обновите каталог и выберите стратегии

Откройте раздел Zapret и последовательно выберите:

1. «Обновить стратегии и файлы обхода».
2. «Меню стратегий».
3. Нужные профили для сайтов, YouTube и Discord.
4. «Применить выбранные настройки».

Выбор профиля ещё не меняет трафик. Это сделано специально, чтобы можно было
спокойно подготовить конфигурацию и проверить её перед запуском.

## Что именно меняют команды

В KZM выбор, запись и запуск разделены:

- `kzm update` только скачивает свежий каталог и fake-файлы;
- `kzm strategy set ...` сохраняет выбор пользователя;
- `kzm preview` показывает будущую цепочку `nfqws`;
- `kzm apply` записывает конфиг, но не перезапускает службу;
- `kzm service restart --yes` явно перезапускает `nfqws`;
- `kzm apply --restart --yes` записывает конфиг, запускает его и автоматически
  возвращает предыдущий вариант, если служба не поднялась.

Обновление каталога никогда не переписывает действующий `nfqws.conf` само по
себе. Новая версия стратегии начнёт работать только после применения и явного
перезапуска.

## Свои сайты и IP-подсети

Пользовательские цели добавляются из меню «Мои сайты и IP/подсети» или
командами:

```sh
kzm domain add example.org
kzm network add 203.0.113.7 198.51.100.0/24 2001:db8::/32
```

Домены и сети хранятся раздельно, но работают как «домен ИЛИ сеть». Добавленная
подсеть не означает перехват всего её трафика: KZM использует только порты
выбранной стратегии, обычно TCP/80 и TCP/443.

Область действия задаётся одним из трёх режимов:

- `all` — весь подходящий трафик, кроме списка исключений;
- `list` — только добавленные пользователем домены и сети;
- `auto` — пользовательские цели плюс автоматически обнаруженные домены.

Работающий классический `nfqws` перечитывает подключённые hostlist/ipset после
их изменения. Если активен `nfqws2`, KZM сохранит записи, но покажет, что они
пока не участвуют в обработке трафика.

## YouTube, Discord и QUIC

YouTube использует отдельные профили `Yv`. QUIC управляется отдельным
переключателем и затрагивает UDP/443 только для встроенного списка YouTube.
Если Mihomo уже блокирует UDP/443 правилом `REJECT`, это правило нужно
отключить в самом Mihomo — KZM не редактирует чужую конфигурацию.

Настройка Discord разделена на два независимых блока:

- голос/STUN и UDP-медиа на диапазонах `19294–19344` и `50000–50100`;
- TCP-доступ к `discord.media` на портах `2053`, `2083`, `2087`, `2096` и
  `8443` с отдельным профилем `Dv`.

Fake для Discord/STUN и стратегия `Dv` выбираются цифрами. Команда
`kzm update` заново читает доступные варианты из актуального каталога.

OpenWrt-скрипты `50-stun4all`, `50-quic4all`, `50-discord-media` и
`50-discord` напрямую не устанавливаются: они зависят от окружения OpenWrt,
которого на Keenetic нет. KZM переносит нужную логику на фильтры `nfqws` и
правила портов Keenetic. Подробности — в [DISCORD-QUIC.md](DISCORD-QUIC.md).

## Проверка стратегий

Сначала один раз подготовьте отдельный тестовый бинарник:

```sh
kzm test engine-update
```

KZM скачивает официальный пакет `nfqws-keenetic`, проверяет SHA-256 и извлекает
из него только бинарник для тестов. Пакет не устанавливается, а тестовый демон
не остаётся работать постоянно.

Основные варианты проверки:

```sh
kzm test suite current       # проверить текущий профиль
kzm test suite all           # сравнить v + Flowseal
kzm test suite v             # проверить только профили v
kzm test suite flowseal      # проверить только Flowseal
kzm test domain x.com ...    # проверить свои домены, максимум 25
```

Полный каталог объединяет адреса Zapret Manager и DPI-цели Hyperion. Его
актуальный размер показывается в меню. Сначала выполняется контроль без desync,
после чего каждая стратегия сравнивается именно с этим контролем. Итоговая
таблица сортируется от меньшего числа доступных целей к большему; подробности
сохраняются в:

```text
/opt/etc/kzapret-manager/results/last-strategy-test.csv
```

Во время такого теста основной Zapret продолжает работать. KZM не переписывает
его конфиг и не перезапускает службу. Временная очередь обрабатывает только
TCP/443, исходящий с самого роутера, поэтому трафик домашних устройств в неё
не попадает. У правил есть watchdog и `--queue-bypass`.

Одиночный `FAIL` ещё не доказывает блокировку: удалённый сервер может быть
недоступен сам по себе. Поэтому KZM рекомендует только стратегию, которая
открыла новые цели, не сломала доступные в контроле и действительно провела
пакеты через тестовую очередь.

### Проверка на конкретном устройстве

Для Discord и YouTube нужен реальный трафик приложения. Canary-тест действует
только на указанный IPv4 и автоматически снимается по таймеру:

```sh
kzm test voice start 192.168.1.108 120
kzm test quic start 192.168.1.108 120
kzm test youtube start 192.168.1.108 Yv08 120
kzm test status
kzm test stop
```

Указывайте IPv4 телефона из свойств его Wi-Fi-подключения. Перед проверкой
отключите на телефоне мобильную сеть и VPN, полностью перезапустите приложение
и откройте новое видео или заново войдите в голосовой канал. Старое соединение
в FastNAT может не попасть в тест.

KZM намеренно не создаёт IPv6-canary: адрес телефона и правила IPv6 заметно
различаются между прошивками Keenetic, а параллельный перехват сделал бы тест
рискованнее. При активном IPv6 менеджер выведет предупреждение, но менять его
не станет.

## Telegram-прокси

Telegram-прокси необязательны и не заменяют Zapret. Каждый из них работает
отдельным процессом со своим портом, конфигом и журналом:

- `rust` — TG WS Proxy Rust от valnesfjord, TCP/2443; рекомендуемый вариант;
- `socks5` — TG WS Proxy SOCKS5 от d0mhate, TCP/1080; экспериментальный;
- `mtproto` — TG WS Proxy MTProto от spatiumstas, TCP/1443;
  экспериментальный.

В версии 0.8.0 их установка поддерживается только на `aarch64`/`arm64`.
Менеджер привязывает прокси к приватному LAN IPv4 и не открывает его порт на
WAN. Ссылка подключения содержит пароль или MTProto-секрет, поэтому
показывается только по явному запросу пользователя.

Автоматического фонового обновления нет. Обновление запускается вручную через
меню или командой `kzm components update ...`. Оно не перезапускает `nfqws`,
firewall или сетевые интерфейсы.

Для загрузок проверяются архитектура, формат ELF и опубликованный SHA-256.
Временные архивы ограничены размером и распаковываются в RAM. Подробная схема,
настройки Rust и известные ограничения описаны в
[TG-PROXIES.md](TG-PROXIES.md).

## Журналы Mihomo и MetaCubeXD

MetaCubeXD хранит браузерный кэш на устройстве, где открыта панель, а не на
флешке роутера. На самой флешке обычно растут журналы Mihomo и KZM. Посмотреть
их размер и очистить только безопасные файлы можно командами:

```sh
kzm storage status
kzm storage cleanup --yes
```

Очистка обнуляет текущие `mihomo.log`/`kzapret-auto.log` и удаляет их ротации
`.1`. Она не останавливает службы и не трогает `cache.db`, конфиги, подписки,
rule-provider или файлы интерфейса MetaCubeXD.

## Справочник команд

<details>
<summary>Показать команды KZM</summary>

```text
kzm                         открыть общее числовое меню
kzm zapret                  открыть меню Zapret
kzm status                  показать состояние и выбранные профили
kzm doctor                  выполнить проверку без изменений
kzm update                  обновить каталоги и fake-файлы

kzm strategy list
kzm strategy set general v7
kzm strategy set general flow:general_ALT7
kzm strategy set youtube Yv08|off
kzm strategy set discord on|off
kzm strategy set discord-media Dv1|off
kzm strategy set discord-script 50-discord-media|off
kzm strategy set discord-fake stun.bin|off
kzm strategy set quic on|off
kzm strategy set game on|off
kzm strategy set scope all|list|auto

kzm domain add example.org
kzm domain remove example.org
kzm domain list
kzm network add 203.0.113.7 198.51.100.0/24 2001:db8::/32
kzm network remove 203.0.113.7
kzm network list

kzm preview
kzm apply
kzm apply --restart --yes
kzm service restart --yes
kzm backup list
kzm backup restore FILE
kzm cleanup --yes
kzm storage status
kzm storage cleanup --yes

kzm test engine-update
kzm test suite current|all|v|flowseal
kzm test domain x.com ...
kzm test general
kzm test voice start IP [SECONDS]
kzm test quic start IP [SECONDS]
kzm test youtube start IP PROFILE [SECONDS]
kzm test status|stop

kzm components status [rust|socks5|mtproto]
kzm components install rust [--yes]
kzm components update rust
kzm components start|stop|restart rust
kzm components link rust
kzm components remove rust --yes
```

В командах компонентов вместо `rust` можно указать `socks5` или `mtproto`.

</details>

## Совместимость и требования

- Keenetic с установленным Entware;
- классический `nfqws-keenetic` и конфиг
  `/opt/etc/nfqws/nfqws.conf`;
- `curl` для HTTPS-загрузок — предпочтительно; при его отсутствии KZM пробует
  `wget`;
- `aarch64`/`arm64` для установки Telegram-прокси в версии 0.8.0.

### MediaTek MT7981 и YouTube QUIC

На Keenetic с MT7981 включённый GRO может терять UDP-пакеты при прохождении
через NFQUEUE. В результате приложение YouTube, особенно Shorts, регулярно
останавливается на дозагрузку, хотя в браузере видео работает нормально.

Начиная с KZM 0.8.1 менеджер сам отключает GRO на интерфейсах моста `br0` при
запуске, перезапуске `nfqws` и пересборке правил firewall. Для этого нужен
`ethtool` из Entware:

```sh
opkg install ethtool
```

На других платформах аппаратная настройка не применяется.

Если системный `wget` вашей прошивки не справляется с HTTPS, установите
загрузчик из Entware:

```sh
opkg install curl
```

## Проверка проекта без роутера

Основные тесты работают в POSIX `sh`/BusyBox `ash` и используют только
временный каталог `/tmp/kzm-test-root`:

```sh
sh tests/run.sh
sh tests/install-upgrade.sh
sh tests/components.sh
```

Необязательная проверка импорта из актуальных upstream-репозиториев:

```sh
sh tests/integration-live.sh
```

Она предназначена для локальной машины или контейнера и не использует реальный
роутер.

## Происхождение и благодарности

Без [StressOzz/Zapret-Manager](https://github.com/StressOzz/Zapret-Manager)
этого проекта не было бы. Оттуда взяты сама идея менеджера, логика разделения
профилей и актуальный каталог стратегий. Спасибо StressOzz за оригинальный
проект и за то, что собрал разрозненные инструменты в понятный сценарий.

Ключевые внешние проекты:

- [bol-van/zapret](https://github.com/bol-van/zapret) — движок `nfqws`;
- [nfqws/nfqws-keenetic](https://github.com/nfqws/nfqws-keenetic) — интеграция
  классического `nfqws` с Keenetic;
- [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube)
  — дополнительные стратегии и fake-файлы;
- [valnesfjord/tg-ws-proxy-rs](https://github.com/valnesfjord/tg-ws-proxy-rs),
  [d0mhate/-tg-ws-proxy-Manager-go](https://github.com/d0mhate/-tg-ws-proxy-Manager-go)
  и [spatiumstas/tg-ws-proxy-go](https://github.com/spatiumstas/tg-ws-proxy-go)
  — необязательные Telegram-прокси.

О том, что именно загружается со стороны и под какими лицензиями, написано в
[THIRD_PARTY.md](THIRD_PARTY.md).

## Дополнительная документация

- [Переход с nfqws2 на классический nfqws](MIGRATION.md)
- [Discord, голос и QUIC](DISCORD-QUIC.md)
- [Telegram-прокси](TG-PROXIES.md)
- [Сторонние проекты и лицензии](THIRD_PARTY.md)

Проект распространяется по лицензии [MIT](LICENSE).
