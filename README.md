# Entropy VPN

Flutter Windows VPN client with:

- connect/disconnect screen
- input for `vless://`, `vmess://`, `trojan://`, `ss://`
- input for `http://` / `https://` subscription URLs
- explicit add flow for configs and subscriptions
- hourly auto-update for subscriptions plus manual refresh
- connection status
- selectable core: `Xray-core` or `Sing-box`
- Russian and English UI

## Current mode

This desktop wrapper supports Windows system proxy mode and TUN mode.

- `Sing-box` uses its built-in `set_system_proxy`
- `Xray-core` is started with local SOCKS/HTTP inbounds and the app temporarily switches the Windows proxy to the local HTTP port
- TUN mode uses the same selected core as the profile when that core supports the generated config: Xray profiles use Xray TUN, sing-box profiles use sing-box TUN. Profiles that need sing-box-only features still use sing-box. When TUN is enabled from a non-elevated Windows session, the app relaunches itself with Administrator rights before the connection starts

Commercial VPN clients usually avoid an elevated UI by installing a privileged Windows service. EntropyVPN currently uses the simpler v2rayN-style elevated-session model.

## Supported links

- `vless://`
- `vmess://`
- `trojan://`
- `ss://`
- `http://` / `https://` subscription URLs returning plain-text or base64 lists of supported links

When a subscription contains multiple supported profiles, the app loads them and lets you choose which one to connect.
Configs and subscriptions are added to the in-app list first, then connected from that saved list.

Common transports implemented in the wrapper:

- RAW/TCP
- WebSocket
- gRPC
- HTTPUpgrade
- HTTP transport for `Sing-box`

Notes:

- `REALITY` is supported for VLESS profiles
- `Shadowsocks` plugins are supported for `Sing-box`
- `Xray-core` currently rejects `Shadowsocks` plugin links and HTTP/QUIC transport in this wrapper

## Core binaries

Place the binaries here for development:

- `tools/cores/xray.exe`
- `tools/cores/sing-box.exe`
- `tools/cores/wintun.dll`

For a packaged Windows build, you can also place them next to the built app:

- `build/windows/x64/runner/Release/cores/xray.exe`
- `build/windows/x64/runner/Release/cores/sing-box.exe`
- `build/windows/x64/runner/Release/cores/wintun.dll`

## Run

```powershell
C:\flutter\bin\flutter.bat pub get
C:\flutter\bin\flutter.bat run -d windows
```

Server country detection uses IP2Location.io. Keyless lookups are supported, or
you can pass an API key for higher quota:

```powershell
C:\flutter\bin\flutter.bat run -d windows --dart-define=IP2LOCATION_API_KEY=your_key
```

## Build installer

This project includes an Inno Setup script for public Windows releases:

- `installer/entropy_vpn.iss`

To build a release installer:

1. Install Inno Setup 6: `https://jrsoftware.org/isinfo.php`
2. Build and package the app:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build_installer.ps1
```

The installer output is written to:

- `build\installer\EntropyVPN-Setup-<version>.exe`

## Build Android APKs

The Android release ships ARM APKs only, because the bundled Android core assets
are under `assets\cores\android\arm64-v8a` and
`assets\cores\android\armeabi-v7a`.

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build_android_release.ps1
```

That script builds the 64-bit and 32-bit APKs with:

```powershell
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64
```

Do not omit `--target-platform android-arm,android-arm64` when building split
APKs directly. Flutter's default split target list also asks for `android-x64`,
but this project does not package an x86_64 Android core.

## Environment requirement

Windows builds require Visual Studio with the `Desktop development with C++` workload.

In this workspace, `flutter analyze`, `flutter test`, and `flutter build windows` pass.
