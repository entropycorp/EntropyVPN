#pragma once

#include <string>

namespace entropy_vpn_service {

// Appends a single timestamped line to <install_dir>\service.log.
//
// The log file is truncated once it passes ~1 MB. This logger is intentionally
// scoped to the updater modules only — do not wire it into the killswitch or
// TUN code paths.
void LogLine(const std::string& message);

}  // namespace entropy_vpn_service
