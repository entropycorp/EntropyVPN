Put core binaries in this folder.

Windows (loose, alongside this README):

- `xray.exe`
- `sing-box.exe`
- `wintun.dll` for Windows TUN mode

Linux (under `linux/`):

- `linux/xray`
- `linux/sing-box`

Mark Linux binaries executable (`chmod +x`) before building the bundle; the
install step preserves source permissions.

The Flutter app checks this directory first when starting a connection.
