#pragma once

#include <string>

namespace entropy_vpn_service {

std::string HandleRequest(const std::string& request_text);
void StopActiveCore();

}  // namespace entropy_vpn_service

