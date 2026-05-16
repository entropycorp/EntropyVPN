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

// App-session TUN adapter pre-warm command handlers.
//
// PrewarmTunAdapterNative creates the "EntropyVPN TUN" wintun adapter and
// holds it so xray opens an already-settled adapter at connect time. The
// adapter is released automatically when the requesting app process (appPid)
// exits. ReleaseTunAdapterNative releases it explicitly.
std::string PrewarmTunAdapterNative(
    const std::map<std::string, std::string>& fields);
std::string ReleaseTunAdapterNative(
    const std::map<std::string, std::string>& fields);
// Releases the pre-warmed adapter, if held. Safe to call when none exists.
void ReleasePrewarmTunAdapter();

}  // namespace entropy_vpn_service
