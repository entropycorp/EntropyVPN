# EntropyVPN In-App Auto-Updater

Replaces the old "open the GitHub releases page" flow with an in-app updater
that downloads only the files that changed and applies them with no UAC prompt.

The privileged Windows service (`entropy_vpn_service.exe`, runs as SYSTEM) does
all the GitHub I/O and file replacement. The Flutter UI just sends IPC commands
and polls for progress. No UAC because SYSTEM already owns Program Files.

**No signing / encryption.** Each release ships a `manifest.json` of every
file + its SHA-256. SHA-256 is used only to tell which files changed and to
catch corrupt downloads — not as a signature. Trust rests on HTTPS to GitHub.

## Status (2026-05-19)

Built and compiles (`flutter build windows` passes; `entropy_vpn_service.exe`
and `entropy_vpn_updater.exe` both build). The release pipeline runs end to end.

**Not yet verified on a real install** — needs manual testing:
- the full download → apply → service-restart cycle;
- the service self-update handoff via `entropy_vpn_updater.exe`;
- UI termination + file swap while the app is running.

## How a release is built

`tools/build_installer.ps1` (run with `-PublishRelease` to also push to GitHub):

1. `flutter build windows`
2. `tools/build_release_manifest.ps1` — walks `build/windows/x64/runner/Release/`,
   writes `manifest.json` + `blobs.pack` (every unique file's content
   concatenated, deduplicated by SHA-256), and drops a copy of `manifest.json`
   into the Release dir so the installer ships it.
3. Inno Setup builds the installer.
4. `-PublishRelease` → `gh release create` uploads three assets: the installer,
   `manifest.json`, and `blobs.pack`.

The file-exclude list lives once in `tools/release_exclude_globs.txt` and is
read by both the manifest generator and `installer/entropy_vpn.iss`, so the
installer and the manifest can't drift apart.

`manifest.json`:

```json
{
  "schema": 2,
  "version": "1.8.0",
  "generated_at": "2026-05-19T12:34:56Z",
  "files": [
    {"path": "entropy_vpn.exe", "size": 649216,
     "sha256": "abc...", "pack_offset": 0}
  ]
}
```

`pack_offset` is the file's byte offset into `blobs.pack`. The byte range to
fetch is `[pack_offset, pack_offset + size)`. Multiple manifest entries with
the same `sha256` share a single offset (dedup'd at pack build time).

## How an update is applied

The service runs a small background state machine
(`Idle → Checking → Downloading → Ready → Applying`):

1. **Check** — `GET .../releases/latest`, download `manifest.json`. A 1-hour
   rate-limit gate protects the unauthenticated GitHub API (bypassed by
   `--force`).
2. **Diff** — hash each installed file, compare to the manifest, collect
   mismatches/missing files.
3. **Download** — for each changed file, issue an HTTP `Range` request against
   `blobs.pack` for exactly `[pack_offset, pack_offset + size)` bytes; stream
   the slice to `<install_dir>/.update_staging/<sha256>.bin`, verifying its
   SHA-256. A hash mismatch fails the whole update. Staged blobs survive a
   crash and resume on the next check. Users with a tiny delta download only
   the bytes their changed files occupy in the pack, not the whole 100+ MB
   pack file.
4. **Apply** (on `update_apply`) — close the UI, back up each old file into
   `.rollback/`, swap in the staged file with `MoveFileEx`. Any failure rolls
   everything back. `installed_manifest.json` records the new state.
5. **Service self-update** — the service can't overwrite its own running exe,
   so when it changes the service stages `entropy_vpn_service.exe.new`, spawns
   `entropy_vpn_updater.exe`, and stops itself; the helper waits, swaps the
   binary, and restarts the service via the SCM.

After the swap, the service (or `entropy_vpn_updater.exe` for the service-
self-update case) relaunches the UI via `WTSQueryUserToken` +
`CreateProcessAsUserW` so the new `entropy_vpn.exe` comes back up on the
logged-in user's desktop. Best-effort: if the relaunch fails the user can
still open the app manually, but the normal flow is "Install and restart" →
brief flash → updated app reopens on its own.

## Files

Service-side C++ (`windows/runner/`):

| File | Responsibility |
|---|---|
| `entropy_vpn_service_updater.*` | State machine, IPC entry points, threads |
| `entropy_vpn_service_manifest.*` | JSON parser, manifest parse, version compare |
| `entropy_vpn_service_http.*` | WinHTTP GET / streamed download |
| `entropy_vpn_service_sha256.*` | SHA-256 (Windows BCrypt) over buffers/files |
| `entropy_vpn_service_apply.*` | Atomic file swap + rollback |
| `entropy_vpn_service_log.*` | `<install_dir>\service.log`, 1 MB rolling |
| `entropy_vpn_updater.cpp` | Standalone helper exe for the service self-update |

IPC commands (`commands.cpp` + `protocol.cpp`): `update_check_now` (arg
`force`), `update_status`, `update_apply`. `update_status` returns
`state`, `progressBytes`, `totalBytes`, `availableVersionB64`, `errorB64`,
`lastCheckUnix`. The updater's mutex is separate from `g_core_mutex`.

UI-side Dart:

| File | Change |
|---|---|
| `services/app_update_service.dart` | `WindowsUpdateStatus` / `WindowsUpdateState` types |
| `services/core_runtime_service_windows_service.dart` | `windowsUpdateCheckNow` / `windowsUpdateStatus` / `windowsUpdateApply` IPC |
| `services/vpn_controller.dart` | `startWindowsUpdateDownload` / `windowsUpdateStatus` / `applyWindowsUpdate` |
| `main_update_notification.dart` | Windows: Download → progress → Install-and-restart |
| `l10n/app_strings.dart` | New update strings |

Tooling (`tools/`): `build_installer.ps1`, `build_release_manifest.ps1`,
`release_exclude_globs.txt`, `README.md`.

## Notes / loose ends

- First run of an update-aware build has no `installed_manifest.json`; the
  service falls back to the installer-shipped `manifest.json`, so the first
  check just re-hashes files once.
- Logging is local only (`service.log`: `update.check.*`, `update.apply.*`,
  `update.rollback.*`). No remote telemetry.
- Not handled yet: polished messaging for disk-full or antivirus-quarantine
  failures during apply.
