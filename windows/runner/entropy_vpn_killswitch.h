#pragma once

#include <windows.h>

#include <string>
#include <vector>

namespace entropy_vpn_service {

// Installs WFP filters that block all outbound IPv4/IPv6 traffic except:
//   - loopback,
//   - DHCP (so a new physical network can come up while engaged),
//   - the executables in `permit_exe_paths` (the VPN core, so a reconnect
//     attempt can still reach the VPN server).
//
// All filters live in a dedicated EntropyVPN sublayer so they can be wiped
// cleanly by DisengageKillswitch. Idempotent: calling Engage while the
// sublayer already exists rebuilds it from scratch.
//
// Returns NO_ERROR on success; otherwise a Win32 error code and *error_step
// is populated with a short identifier of the step that failed.
DWORD EngageKillswitch(const std::vector<std::wstring>& permit_exe_paths,
                       std::string* error_step);

// Removes the EntropyVPN WFP sublayer and all of its filters. Safe to call
// when not engaged. Sets *changed=true if filters were actually removed.
DWORD DisengageKillswitch(bool* changed);

}  // namespace entropy_vpn_service
