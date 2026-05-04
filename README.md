# EntropyVPN

EntropyVPN is an open-source VPN client for Windows and Android, built with
Flutter. It provides a clean interface for managing proxy/VPN profiles,
subscriptions, and connections powered by Xray-core and sing-box.

The project focuses on practical desktop and mobile VPN use: importing common
share links, keeping subscriptions updated, selecting profiles, and connecting
through system proxy or TUN modes where supported.

## Features

- Windows and Android client UI
- Support for `vless://`, `vmess://`, `trojan://`, and `ss://` profiles
- Support for HTTP/HTTPS subscription links
- Xray-core and sing-box runtime support
- System proxy and TUN connection modes
- Profile catalog with country detection and flag display
- Subscription refresh and saved profile management
- English and Russian localization

## Status

EntropyVPN is under active development. The Windows client currently supports
system proxy and TUN-based connections. The Android client includes bundled ARM
core assets for `arm64-v8a` and `armeabi-v7a` devices.

## Project

This repository contains the Flutter application, platform-specific Windows and
Android integration code, bundled UI assets, tests, and release packaging
scripts.

## License

EntropyVPN is licensed under the GNU General Public License v3.0. See
`LICENSE` for the full license text. Source code for release binaries is
available from this repository at the matching release tag.
