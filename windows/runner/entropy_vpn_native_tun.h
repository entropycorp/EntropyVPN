#pragma once

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <iphlpapi.h>
#include <netioapi.h>

#include <cstdint>
#include <limits>
#include <string>
#include <utility>
#include <vector>

namespace entropy_vpn_service {

struct Ipv4InterfaceInfo {
  std::string alias;
  ULONG interface_metric = std::numeric_limits<ULONG>::max();
  bool hardware = false;
  bool virtual_like = true;
};

struct Ipv4DefaultRouteCandidate {
  MIB_IPFORWARD_ROW2 route{};
  Ipv4InterfaceInfo interface_info;
  uint64_t effective_metric = std::numeric_limits<uint64_t>::max();
};

struct InterfaceInfo {
  std::string alias;
  ULONG interface_metric = std::numeric_limits<ULONG>::max();
  bool hardware = false;
  bool virtual_like = true;
};

struct DefaultRouteCandidate {
  MIB_IPFORWARD_ROW2 route{};
  InterfaceInfo interface_info;
  ADDRESS_FAMILY family = AF_UNSPEC;
  uint64_t effective_metric = std::numeric_limits<uint64_t>::max();
};

std::string OperStatusString(IF_OPER_STATUS status);
std::string Ipv4ToString(const IN_ADDR& address);
std::string Ipv6ToString(const IN6_ADDR& address);
bool IsUsableIpv4Address(const IN_ADDR& address);
bool ParseIpv4Prefix(const std::string& destination_prefix,
                     IN_ADDR* destination,
                     UINT8* prefix_length);
bool ParseIpv6Prefix(const std::string& destination_prefix,
                     IN6_ADDR* destination,
                     UINT8* prefix_length);
bool SameIpv4(const IN_ADDR& left, const IN_ADDR& right);
bool SameIpv6(const IN6_ADDR& left, const IN6_ADDR& right);
bool IsDefaultIpv4Route(const MIB_IPFORWARD_ROW2& route);
bool IsDefaultRouteForFamily(const MIB_IPFORWARD_ROW2& route,
                             ADDRESS_FAMILY family);
DWORD GetIpv4InterfaceInfo(NET_IFINDEX interface_index,
                           Ipv4InterfaceInfo* info);
DWORD GetInterfaceInfo(NET_IFINDEX interface_index,
                       ADDRESS_FAMILY family,
                       InterfaceInfo* info);
DWORD FindHardwareIpv4DefaultRoute(Ipv4DefaultRouteCandidate* selected);
DWORD FindHardwareDefaultRouteForFamily(ADDRESS_FAMILY family,
                                        DefaultRouteCandidate* selected);
std::string FindSourceIpv4Address(NET_IFINDEX interface_index);
std::string FindSourceAddress(NET_IFINDEX interface_index,
                              ADDRESS_FAMILY family);
std::string RouteNextHopToString(const MIB_IPFORWARD_ROW2& route,
                                 ADDRESS_FAMILY family);
ADDRESS_FAMILY AddressFamilyForText(const std::string& address);
std::string HostPrefixForAddress(const std::string& address,
                                 ADDRESS_FAMILY family);
std::vector<std::string> ResolveHostIpv4Addresses(const std::string& host,
                                                  DWORD* error);
std::vector<std::string> ResolveServerRoutingAddresses(
    const std::string& server,
    const std::string& tun_ip_mode,
    DWORD* error);
bool Ipv4RouteExists(const IN_ADDR& destination,
                     UINT8 prefix_length,
                     NET_IFINDEX interface_index,
                     const IN_ADDR& next_hop);
DWORD RemoveConflictingIpv4Routes(const IN_ADDR& destination,
                                  UINT8 prefix_length,
                                  NET_IFINDEX interface_index,
                                  const IN_ADDR& next_hop,
                                  bool* removed);
DWORD EnsureIpv4HostRoute(const IN_ADDR& destination,
                          NET_IFINDEX interface_index,
                          const IN_ADDR& next_hop,
                          std::string* status);
DWORD EnsureIpv4Route(const IN_ADDR& destination,
                      UINT8 prefix_length,
                      NET_IFINDEX interface_index,
                      const IN_ADDR& next_hop,
                      std::string* status);
DWORD RemoveIpv4Route(const IN_ADDR& destination,
                      UINT8 prefix_length,
                      NET_IFINDEX interface_index,
                      const IN_ADDR& next_hop,
                      std::string* status);
DWORD EnsureIpv6Route(const IN6_ADDR& destination,
                      UINT8 prefix_length,
                      NET_IFINDEX interface_index,
                      const IN6_ADDR& next_hop,
                      std::string* status);
DWORD RemoveIpv6Route(const IN6_ADDR& destination,
                      UINT8 prefix_length,
                      NET_IFINDEX interface_index,
                      const IN6_ADDR& next_hop,
                      std::string* status);
DWORD EnsureRouteByPrefix(const std::string& destination_prefix,
                          const std::string& next_hop_text,
                          NET_IFINDEX interface_index,
                          std::string* status);
DWORD RemoveRouteByPrefix(const std::string& destination_prefix,
                          const std::string& next_hop_text,
                          NET_IFINDEX interface_index,
                          std::string* status);
bool UsesIpv4(const std::string& tun_ip_mode);
bool UsesIpv6(const std::string& tun_ip_mode);
std::vector<std::pair<std::string, std::string>> RouteSpecsForTunMode(
    const std::string& tun_ip_mode);
DWORD WaitForInterfaceAlias(const std::wstring& alias,
                            int64_t timeout_ms,
                            NET_IFINDEX* interface_index,
                            std::string* resolved_alias,
                            std::string* status,
                            int64_t* wait_ms);
DWORD ConfigureAddress(NET_IFINDEX interface_index,
                       const std::wstring& address,
                       UINT8 prefix_length,
                       std::string* status);
DWORD ConfigureIpv4AddressIfNeeded(NET_IFINDEX interface_index,
                                   const std::wstring& address,
                                   UINT8 prefix_length,
                                   bool* changed,
                                   std::string* status);
DWORD ConfigureIpv6Address(NET_IFINDEX interface_index,
                           const std::wstring& address,
                           UINT8 prefix_length,
                           bool* changed,
                           std::string* status);
DWORD ConfigureMetric(NET_IFINDEX interface_index, ULONG metric,
                      bool* changed);
DWORD ConfigureDns(NET_IFINDEX interface_index,
                   const std::wstring& servers,
                   bool* changed);
bool FlushDnsResolverCache(DWORD* error);

}  // namespace entropy_vpn_service
