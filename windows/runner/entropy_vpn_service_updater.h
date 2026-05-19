#pragma once

#include <map>
#include <string>

namespace entropy_vpn_service {

// IPC entry points dispatched from entropy_vpn_service_commands.cpp.
//
// UpdateCheckNow / UpdateApply start background work and return immediately;
// the UI polls UpdateStatus for progress. All three are cheap and hold the
// updater mutex only briefly, so they never stall the VPN start path.
std::string UpdateCheckNow(const std::map<std::string, std::string>& fields);
std::string UpdateStatus(const std::map<std::string, std::string>& fields);
std::string UpdateApply(const std::map<std::string, std::string>& fields);

// Joins any in-flight updater thread. Called from ServiceMain on shutdown.
void ShutdownUpdater();

}  // namespace entropy_vpn_service
