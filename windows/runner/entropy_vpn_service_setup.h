#pragma once

// Self-installs the EntropyVPN SCM service from the running .exe's folder.
// The installer route (Inno Setup) registers the service for you at install
// time; this module is what lets the *portable* zip do the same thing on
// first launch, with a single UAC click instead of one UAC per TUN-mode
// start. After the service is registered, the rest of the privileged-ops
// flow (TUN, auto-update apply) goes through the SYSTEM service exactly as
// it does for the installed build — fully silent.

#include <windows.h>

#include <string>

namespace entropy_vpn {

// CLI arg that re-spawning entropy_vpn.exe with `runas` listens for. When
// main.cpp sees it on the command line, it does the SCM ops and exits;
// nothing Flutter ever starts. Keep this arg name stable — it's part of
// the spawn-self contract.
inline constexpr wchar_t kInstallServiceArg[] =
    L"--entropyvpn-install-service";
inline constexpr wchar_t kUninstallServiceArg[] =
    L"--entropyvpn-uninstall-service";

inline constexpr wchar_t kEntropyServiceName[] = L"EntropyVPNService";

// Returns true iff the service is registered with the SCM AND its binary
// path points at <install_dir>\entropy_vpn_service.exe. Returns false in
// every other case (not installed, points elsewhere — e.g. user moved the
// portable folder).
bool IsServiceInstalledCorrectly(const std::wstring& install_dir);

// Creates/replaces the SCM registration. Mirrors what
// installer/entropy_vpn.iss [Run] does today: CreateService → description
// → SDDL granting Authenticated Users SERVICE_START. Caller MUST be running
// elevated; otherwise CreateServiceW fails with ACCESS_DENIED.
DWORD InstallService(const std::wstring& install_dir);

// Stops and deletes the service. Returns NO_ERROR if there was nothing to
// remove. Caller MUST be elevated.
DWORD UninstallService();

// Re-launches the current .exe with kInstallServiceArg via the `runas`
// verb (triggers UAC), waits for it to exit, and returns its exit code.
// On UAC cancel, returns ERROR_CANCELLED — the caller should keep going
// without a service (the per-op elevation fallback still works).
DWORD SpawnElevatedInstall(const std::wstring& current_exe);

}  // namespace entropy_vpn
