#pragma once

#include <string>

namespace entropy_vpn_service {

std::string HandleRequest(const std::string& request_text);
void StopActiveCore();

// Signals the service to shut down. Defined in entropy_vpn_service.cpp; used by
// the updater after a service self-update has been staged.
void RequestServiceStop();

}  // namespace entropy_vpn_service

