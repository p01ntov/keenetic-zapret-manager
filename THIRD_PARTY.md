# Third-party sources

- Strategy catalogs are downloaded at the user's request from
  `StressOzz/Zapret-Manager`. They are not bundled in this package. At the time
  this project was created, that repository did not contain a license file.
- The classic `nfqws` engine and its fake packet samples are provided by
  `bol-van/zapret` under the MIT license.
- The recommended Keenetic integration is `nfqws/nfqws-keenetic`, also under
  the MIT license.
- General TCP strategies and missing fake packet samples are downloaded from
  `Flowseal/zapret-discord-youtube`; they are not bundled here.
- The network test catalog combines the fixed targets used by
  `StressOzz/Zapret-Manager` with `hyperion-cs/dpi-checkers` suite.v2 data.

## Optional Telegram proxy components

Starting with KZM 0.8.0, the manager can download, at the user's explicit request, one of these upstream
release assets for `aarch64` Keenetic devices:

- `d0mhate/-tg-ws-proxy-Manager-go` — SOCKS5 mode; experimental because its WSS
  hop disables TLS certificate verification and the current published binary
  was built with a Go toolchain affected by known vulnerabilities fixed in
  later Go releases;
- `p01ntov/tg-ws-proxy-rs-private` — the recommended MTProto implementation,
  a focused MIT-licensed fork of `valnesfjord/tg-ws-proxy-rs`; TLS verification
  is enabled and KZM runs it as `nobody`, while the upstream documents possible
  memory growth;
- `spatiumstas/tg-ws-proxy-go` — experimental MTProto implementation; the
  current release uses an end-of-life Go toolchain and disables WSS TLS
  certificate verification.

These binaries are not bundled with KZM. KZM does not execute the projects'
OpenWrt installers, service scripts, package `postinst` hooks, or feed helpers.
It resolves an exact release asset through the GitHub Releases API and requires
the asset's published SHA-256 digest before installing it. Downloads are capped
at 32 MiB and staged under `/tmp`. The spatiumstas IPK is treated only as an
archive: paths and package metadata are validated and only the expected AArch64
binary is extracted.

No proxy is updated automatically. Each proxy binds to a private LAN IPv4 and
uses its own binary, configuration, PID file, log, and TCP port. Proxy lifecycle
operations do not restart nfqws, the firewall, or Keenetic network interfaces.
Connection secrets remain in mode-`0600` configuration files and are displayed
only by an explicit `kzm components link ...` request. See
[TG-PROXIES.md](TG-PROXIES.md) for the complete operational and security model.
