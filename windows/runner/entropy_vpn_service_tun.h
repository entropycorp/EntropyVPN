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

// Creates the "EntropyVPN TUN" wintun adapter and holds its handle for the
// whole app session so xray can open an already-settled adapter at connect
// time instead of paying the cold-adapter route-installation delay.
std::string PrewarmTunAdapterNative(
    const std::map<std::string, std::string>& fields);
std::string ReleaseTunAdapterNative(
    const std::map<std::string, std::string>& fields);
// Closes the pre-warmed adapter, if held. Safe to call when none exists.
void ReleasePrewarmedTunAdapter();

}  // namespace entropy_vpn_service
