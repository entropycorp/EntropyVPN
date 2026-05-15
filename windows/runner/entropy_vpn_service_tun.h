#pragma once

#include <map>
#include <string>

namespace entropy_vpn_service {

std::string PrepareIpv4ServerRouteNative(
    const std::map<std::string, std::string>& fields);
std::string PrepareDomainServerRouteNative(
    const std::map<std::string, std::string>& fields);
std::string PrepareXrayTunIpv4RoutesNative(
    const std::map<std::string, std::string>& fields);

}  // namespace entropy_vpn_service
