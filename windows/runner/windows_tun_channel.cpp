#include "windows_tun_channel.h"

#include <winsock2.h>
#include <ws2tcpip.h>

#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <windows.h>

#include <chrono>
#include <algorithm>
#include <cctype>
#include <cstdint>
#include <limits>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr char kWindowsTunChannelName[] = "entropy_vpn/windows_tun";
constexpr char kConfigureXrayTunIpv4Method[] = "configureXrayTunIpv4";
constexpr char kPrepareIpv4ServerRouteMethod[] = "prepareIpv4ServerRoute";
constexpr char kPrepareXrayTunIpv4RoutesMethod[] = "prepareXrayTunIpv4Routes";
constexpr char kRemoveIpv4RoutesMethod[] = "removeIpv4Routes";

using EncodableList = flutter::EncodableList;
using EncodableMap = flutter::EncodableMap;
using EncodableValue = flutter::EncodableValue;

std::string ErrorMessage(DWORD error) {
  if (error == NO_ERROR) {
    return "success";
  }

  LPWSTR message = nullptr;
  const DWORD length = FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, error, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      reinterpret_cast<LPWSTR>(&message), 0, nullptr);
  if (length == 0 || message == nullptr) {
    std::ostringstream stream;
    stream << "Windows error " << error;
    return stream.str();
  }

  const int required = WideCharToMultiByte(CP_UTF8, 0, message, length, nullptr,
                                           0, nullptr, nullptr);
  std::string result;
  if (required > 0) {
    result.resize(required);
    WideCharToMultiByte(CP_UTF8, 0, message, length, result.data(), required,
                        nullptr, nullptr);
  }
  LocalFree(message);

  while (!result.empty() &&
         (result.back() == '\r' || result.back() == '\n' ||
          result.back() == ' ' || result.back() == '\t')) {
    result.pop_back();
  }
  if (result.empty()) {
    std::ostringstream stream;
    stream << "Windows error " << error;
    return stream.str();
  }
  std::ostringstream stream;
  stream << result << " (Code 0x" << std::hex << error << ")";
  return stream.str();
}

std::wstring WideFromUtf8(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  const int required = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                           value.data(),
                                           static_cast<int>(value.size()),
                                           nullptr, 0);
  if (required <= 0) {
    return std::wstring();
  }
  std::wstring result;
  result.resize(required);
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), required);
  return result;
}

std::string Utf8FromWide(const wchar_t* value) {
  if (value == nullptr || value[0] == L'\0') {
    return std::string();
  }
  const int required = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0,
                                           nullptr, nullptr);
  if (required <= 1) {
    return std::string();
  }
  std::string result;
  result.resize(required - 1);
  WideCharToMultiByte(CP_UTF8, 0, value, -1, result.data(), required, nullptr,
                      nullptr);
  return result;
}

std::string ToLowerAscii(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char c) {
                   return static_cast<char>(std::tolower(c));
                 });
  return value;
}

bool ContainsToken(const std::string& value, const std::string& token) {
  return value.find(token) != std::string::npos;
}

bool LooksVirtualInterfaceAlias(const std::string& alias) {
  const std::string lower = ToLowerAscii(alias);
  return ContainsToken(lower, "vpn") || ContainsToken(lower, "tun") ||
         ContainsToken(lower, "tap") || ContainsToken(lower, "wintun") ||
         ContainsToken(lower, "wireguard") ||
         ContainsToken(lower, "loopback") || ContainsToken(lower, "virtual");
}

std::string Ipv4ToString(const IN_ADDR& address) {
  char buffer[INET_ADDRSTRLEN] = {};
  if (InetNtopA(AF_INET, const_cast<IN_ADDR*>(&address), buffer,
                INET_ADDRSTRLEN) == nullptr) {
    return std::string();
  }
  return std::string(buffer);
}

bool IsUsableIpv4Address(const IN_ADDR& address) {
  const auto host_order = ntohl(address.S_un.S_addr);
  const auto first_octet = (host_order >> 24) & 0xff;
  const auto second_octet = (host_order >> 16) & 0xff;
  if (host_order == 0 || first_octet == 127) {
    return false;
  }
  return !(first_octet == 169 && second_octet == 254);
}

const EncodableValue* FindValue(const EncodableMap& map, const char* key) {
  const auto iterator = map.find(EncodableValue(std::string(key)));
  if (iterator == map.end()) {
    return nullptr;
  }
  return &iterator->second;
}

bool ReadInt64(const EncodableMap& map, const char* key, int64_t* value) {
  const EncodableValue* entry = FindValue(map, key);
  if (entry == nullptr) {
    return false;
  }
  if (const auto typed = std::get_if<int64_t>(entry)) {
    *value = *typed;
    return true;
  }
  if (const auto typed = std::get_if<int32_t>(entry)) {
    *value = *typed;
    return true;
  }
  return false;
}

bool ReadString(const EncodableMap& map, const char* key, std::string* value) {
  const EncodableValue* entry = FindValue(map, key);
  if (entry == nullptr) {
    return false;
  }
  if (const auto typed = std::get_if<std::string>(entry)) {
    *value = *typed;
    return true;
  }
  return false;
}

bool IsRetryableNetworkSetupError(DWORD error) {
  return error == ERROR_NOT_FOUND || error == ERROR_NOT_READY ||
         error == ERROR_NOT_CONNECTED;
}

std::string OperStatusString(IF_OPER_STATUS status) {
  switch (status) {
    case IfOperStatusUp:
      return "up";
    case IfOperStatusDown:
      return "disconnected";
    case IfOperStatusTesting:
      return "testing";
    case IfOperStatusUnknown:
      return "unknown";
    case IfOperStatusDormant:
      return "dormant";
    case IfOperStatusNotPresent:
      return "notPresent";
    case IfOperStatusLowerLayerDown:
      return "lowerLayerDown";
    default:
      return "unknown";
  }
}

void AddFailure(EncodableMap* response, const std::string& step, DWORD error) {
  response->insert_or_assign(EncodableValue("ok"), EncodableValue(false));
  response->insert_or_assign(EncodableValue("failedStep"), EncodableValue(step));
  response->insert_or_assign(EncodableValue("error"),
                             EncodableValue(ErrorMessage(error)));
  response->insert_or_assign(EncodableValue("errorCode"),
                             EncodableValue(static_cast<int64_t>(error)));
}

void AddSuccess(EncodableMap* response) {
  response->insert_or_assign(EncodableValue("ok"), EncodableValue(true));
}

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

bool IsDefaultIpv4Route(const MIB_IPFORWARD_ROW2& route) {
  return route.DestinationPrefix.Prefix.Ipv4.sin_family == AF_INET &&
         route.DestinationPrefix.PrefixLength == 0 &&
         route.NextHop.Ipv4.sin_family == AF_INET &&
         route.NextHop.Ipv4.sin_addr.S_un.S_addr != 0;
}

bool SameIpv4(const IN_ADDR& left, const IN_ADDR& right) {
  return left.S_un.S_addr == right.S_un.S_addr;
}

bool ParseIpv4Prefix(const std::string& destination_prefix,
                     IN_ADDR* destination,
                     UINT8* prefix_length) {
  const size_t slash = destination_prefix.find('/');
  if (slash == std::string::npos || slash == 0 ||
      slash + 1 >= destination_prefix.size()) {
    return false;
  }

  const std::string address = destination_prefix.substr(0, slash);
  const std::string prefix_text = destination_prefix.substr(slash + 1);
  int prefix = 0;
  for (const char c : prefix_text) {
    if (c < '0' || c > '9') {
      return false;
    }
    prefix = (prefix * 10) + (c - '0');
    if (prefix > 32) {
      return false;
    }
  }

  if (InetPtonA(AF_INET, address.c_str(), destination) != 1) {
    return false;
  }

  *prefix_length = static_cast<UINT8>(prefix);
  return true;
}

DWORD GetIpv4InterfaceInfo(NET_IFINDEX interface_index,
                           Ipv4InterfaceInfo* info) {
  MIB_IF_ROW2 row{};
  row.InterfaceIndex = interface_index;
  DWORD result = GetIfEntry2(&row);
  if (result != NO_ERROR) {
    return result;
  }

  info->alias = Utf8FromWide(row.Alias);
  info->hardware = row.InterfaceAndOperStatusFlags.HardwareInterface != 0;
  info->virtual_like = !info->hardware || LooksVirtualInterfaceAlias(info->alias);

  MIB_IPINTERFACE_ROW ip_row;
  InitializeIpInterfaceEntry(&ip_row);
  ip_row.Family = AF_INET;
  ip_row.InterfaceIndex = interface_index;
  result = GetIpInterfaceEntry(&ip_row);
  if (result == NO_ERROR) {
    info->interface_metric = ip_row.Metric;
  }
  return NO_ERROR;
}

DWORD FindHardwareIpv4DefaultRoute(Ipv4DefaultRouteCandidate* selected) {
  PMIB_IPFORWARD_TABLE2 table = nullptr;
  DWORD result = GetIpForwardTable2(AF_INET, &table);
  if (result != NO_ERROR) {
    return result;
  }

  bool found = false;
  uint64_t best_metric = std::numeric_limits<uint64_t>::max();
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const MIB_IPFORWARD_ROW2& route = table->Table[i];
    if (!IsDefaultIpv4Route(route)) {
      continue;
    }

    Ipv4InterfaceInfo info;
    if (GetIpv4InterfaceInfo(route.InterfaceIndex, &info) != NO_ERROR ||
        !info.hardware || info.virtual_like || info.alias.empty()) {
      continue;
    }

    const uint64_t interface_metric =
        info.interface_metric == std::numeric_limits<ULONG>::max()
            ? 0
            : info.interface_metric;
    const uint64_t effective_metric =
        static_cast<uint64_t>(route.Metric) + interface_metric;
    if (!found || effective_metric < best_metric) {
      selected->route = route;
      selected->interface_info = info;
      selected->effective_metric = effective_metric;
      best_metric = effective_metric;
      found = true;
    }
  }

  FreeMibTable(table);
  return found ? NO_ERROR : ERROR_NOT_FOUND;
}

std::string FindSourceIpv4Address(NET_IFINDEX interface_index) {
  PMIB_UNICASTIPADDRESS_TABLE table = nullptr;
  const DWORD result = GetUnicastIpAddressTable(AF_INET, &table);
  if (result != NO_ERROR) {
    return std::string();
  }

  std::string address;
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const MIB_UNICASTIPADDRESS_ROW& row = table->Table[i];
    if (row.InterfaceIndex != interface_index ||
        row.Address.Ipv4.sin_family != AF_INET ||
        !IsUsableIpv4Address(row.Address.Ipv4.sin_addr)) {
      continue;
    }
    address = Ipv4ToString(row.Address.Ipv4.sin_addr);
    if (!address.empty()) {
      break;
    }
  }

  FreeMibTable(table);
  return address;
}

bool Ipv4RouteExists(const IN_ADDR& destination,
                     UINT8 prefix_length,
                     NET_IFINDEX interface_index,
                     const IN_ADDR& next_hop);

DWORD EnsureIpv4Route(const IN_ADDR& destination,
                      UINT8 prefix_length,
                      NET_IFINDEX interface_index,
                      const IN_ADDR& next_hop,
                      std::string* status);

bool Ipv4HostRouteExists(const IN_ADDR& destination,
                         NET_IFINDEX interface_index,
                         const IN_ADDR& next_hop) {
  return Ipv4RouteExists(destination, 32, interface_index, next_hop);
}

bool Ipv4RouteExists(const IN_ADDR& destination,
                     UINT8 prefix_length,
                     NET_IFINDEX interface_index,
                     const IN_ADDR& next_hop) {
  PMIB_IPFORWARD_TABLE2 table = nullptr;
  const DWORD result = GetIpForwardTable2(AF_INET, &table);
  if (result != NO_ERROR) {
    return false;
  }

  bool exists = false;
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const MIB_IPFORWARD_ROW2& route = table->Table[i];
    if (route.InterfaceIndex == interface_index &&
        route.DestinationPrefix.Prefix.Ipv4.sin_family == AF_INET &&
        route.DestinationPrefix.PrefixLength == prefix_length &&
        SameIpv4(route.DestinationPrefix.Prefix.Ipv4.sin_addr, destination) &&
        route.NextHop.Ipv4.sin_family == AF_INET &&
        SameIpv4(route.NextHop.Ipv4.sin_addr, next_hop)) {
      exists = true;
      break;
    }
  }

  FreeMibTable(table);
  return exists;
}

DWORD EnsureIpv4HostRoute(const IN_ADDR& destination,
                          NET_IFINDEX interface_index,
                          const IN_ADDR& next_hop,
                          std::string* status) {
  return EnsureIpv4Route(destination, 32, interface_index, next_hop, status);
}

DWORD EnsureIpv4Route(const IN_ADDR& destination,
                      UINT8 prefix_length,
                      NET_IFINDEX interface_index,
                      const IN_ADDR& next_hop,
                      std::string* status) {
  if (Ipv4RouteExists(destination, prefix_length, interface_index, next_hop)) {
    *status = "exists";
    return NO_ERROR;
  }

  MIB_IPFORWARD_ROW2 route;
  InitializeIpForwardEntry(&route);
  route.InterfaceIndex = interface_index;
  route.DestinationPrefix.Prefix.Ipv4.sin_family = AF_INET;
  route.DestinationPrefix.Prefix.Ipv4.sin_addr = destination;
  route.DestinationPrefix.PrefixLength = prefix_length;
  route.NextHop.Ipv4.sin_family = AF_INET;
  route.NextHop.Ipv4.sin_addr = next_hop;
  route.Metric = 1;
  route.Protocol = RouteProtocolNetMgmt;
  route.ValidLifetime = 0xffffffff;
  route.PreferredLifetime = 0xffffffff;

  const DWORD result = CreateIpForwardEntry2(&route);
  if (result == NO_ERROR) {
    *status = "created";
    return NO_ERROR;
  }
  if (result == ERROR_OBJECT_ALREADY_EXISTS) {
    *status = "exists";
    return NO_ERROR;
  }
  return result;
}

DWORD RemoveIpv4Route(const IN_ADDR& destination,
                      UINT8 prefix_length,
                      NET_IFINDEX interface_index,
                      const IN_ADDR& next_hop,
                      std::string* status) {
  PMIB_IPFORWARD_TABLE2 table = nullptr;
  const DWORD table_result = GetIpForwardTable2(AF_INET, &table);
  if (table_result != NO_ERROR) {
    return table_result;
  }

  MIB_IPFORWARD_ROW2 route_to_delete{};
  bool found = false;
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const MIB_IPFORWARD_ROW2& route = table->Table[i];
    if (route.InterfaceIndex == interface_index &&
        route.DestinationPrefix.Prefix.Ipv4.sin_family == AF_INET &&
        route.DestinationPrefix.PrefixLength == prefix_length &&
        SameIpv4(route.DestinationPrefix.Prefix.Ipv4.sin_addr, destination) &&
        route.NextHop.Ipv4.sin_family == AF_INET &&
        SameIpv4(route.NextHop.Ipv4.sin_addr, next_hop)) {
      route_to_delete = route;
      found = true;
      break;
    }
  }
  FreeMibTable(table);

  if (!found) {
    *status = "missing";
    return NO_ERROR;
  }

  const DWORD delete_result = DeleteIpForwardEntry2(&route_to_delete);
  if (delete_result == NO_ERROR) {
    *status = "removed";
    return NO_ERROR;
  }
  if (delete_result == ERROR_NOT_FOUND) {
    *status = "missing";
    return NO_ERROR;
  }
  return delete_result;
}

DWORD WaitForInterfaceAlias(const std::wstring& alias,
                            int64_t timeout_ms,
                            NET_IFINDEX* interface_index,
                            std::string* resolved_alias,
                            std::string* status,
                            int64_t* wait_ms) {
  const auto start = std::chrono::steady_clock::now();
  DWORD last_error = ERROR_NOT_FOUND;

  while (true) {
    NET_LUID luid{};
    last_error = ConvertInterfaceAliasToLuid(alias.c_str(), &luid);
    if (last_error == NO_ERROR) {
      NET_IFINDEX index = 0;
      last_error = ConvertInterfaceLuidToIndex(&luid, &index);
      if (last_error == NO_ERROR) {
        MIB_IF_ROW2 row{};
        row.InterfaceIndex = index;
        last_error = GetIfEntry2(&row);
        if (last_error == NO_ERROR) {
          *interface_index = index;
          *resolved_alias = Utf8FromWide(row.Alias);
          *status = OperStatusString(row.OperStatus);
          *wait_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                         std::chrono::steady_clock::now() - start)
                         .count();
          return NO_ERROR;
        }
      }
    }

    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start);
    if (elapsed.count() >= timeout_ms) {
      *wait_ms = elapsed.count();
      return last_error == NO_ERROR ? ERROR_TIMEOUT : last_error;
    }
    Sleep(10);
  }
}

DWORD ConfigureAddress(NET_IFINDEX interface_index,
                       const std::wstring& address,
                       UINT8 prefix_length,
                       std::string* status) {
  MIB_UNICASTIPADDRESS_ROW row;
  InitializeUnicastIpAddressEntry(&row);
  row.InterfaceIndex = interface_index;
  row.Address.Ipv4.sin_family = AF_INET;
  if (InetPtonW(AF_INET, address.c_str(), &row.Address.Ipv4.sin_addr) != 1) {
    return ERROR_INVALID_PARAMETER;
  }
  row.OnLinkPrefixLength = prefix_length;
  row.PrefixOrigin = IpPrefixOriginManual;
  row.SuffixOrigin = IpSuffixOriginManual;
  row.ValidLifetime = 0xffffffff;
  row.PreferredLifetime = 0xffffffff;
  row.DadState = IpDadStatePreferred;

  const DWORD create_result = CreateUnicastIpAddressEntry(&row);
  if (create_result == NO_ERROR) {
    *status = "created";
    return NO_ERROR;
  }
  if (create_result == ERROR_OBJECT_ALREADY_EXISTS) {
    MIB_UNICASTIPADDRESS_ROW existing = row;
    const DWORD get_result = GetUnicastIpAddressEntry(&existing);
    if (get_result == NO_ERROR && existing.OnLinkPrefixLength != prefix_length) {
      existing.OnLinkPrefixLength = prefix_length;
      existing.PrefixOrigin = IpPrefixOriginManual;
      existing.SuffixOrigin = IpSuffixOriginManual;
      existing.ValidLifetime = 0xffffffff;
      existing.PreferredLifetime = 0xffffffff;
      existing.DadState = IpDadStatePreferred;
      const DWORD set_result = SetUnicastIpAddressEntry(&existing);
      if (set_result != NO_ERROR) {
        return set_result;
      }
      *status = "updated";
      return NO_ERROR;
    }
    *status = "already-set";
    return NO_ERROR;
  }

  return create_result;
}

DWORD ConfigureMetric(NET_IFINDEX interface_index, ULONG metric,
                      bool* changed) {
  MIB_IPINTERFACE_ROW row;
  InitializeIpInterfaceEntry(&row);
  row.Family = AF_INET;
  row.InterfaceIndex = interface_index;
  DWORD result = GetIpInterfaceEntry(&row);
  if (result != NO_ERROR) {
    return result;
  }

  const bool already_configured =
      row.UseAutomaticMetric == FALSE && row.Metric == metric;
  row.UseAutomaticMetric = FALSE;
  row.Metric = metric;
  row.SitePrefixLength = 0;
  result = SetIpInterfaceEntry(&row);
  if (result == NO_ERROR) {
    *changed = !already_configured;
  }
  return result;
}

DWORD ConfigureDns(NET_IFINDEX interface_index, const std::wstring& servers,
                   bool* changed) {
  NET_LUID luid;
  DWORD result = ConvertInterfaceIndexToLuid(interface_index, &luid);
  if (result != NO_ERROR) {
    return result;
  }

  GUID guid;
  result = ConvertInterfaceLuidToGuid(&luid, &guid);
  if (result != NO_ERROR) {
    return result;
  }

  DNS_INTERFACE_SETTINGS settings{};
  settings.Version = DNS_INTERFACE_SETTINGS_VERSION1;
  settings.Flags = DNS_SETTING_NAMESERVER;
  settings.NameServer = const_cast<PWSTR>(servers.c_str());
  result = SetInterfaceDnsSettings(guid, &settings);
  if (result == NO_ERROR) {
    *changed = true;
  }
  return result;
}

EncodableValue ConfigureXrayTunIpv4(const EncodableMap& arguments) {
  EncodableMap response;
  int64_t index_argument = 0;
  if (!ReadInt64(arguments, "interfaceIndex", &index_argument) ||
      index_argument <= 0) {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }

  std::string ipv4_address = "172.19.0.1";
  std::string dns_servers;
  ReadString(arguments, "address", &ipv4_address);
  ReadString(arguments, "dnsServers", &dns_servers);

  int64_t prefix_length_argument = 30;
  ReadInt64(arguments, "prefixLength", &prefix_length_argument);
  int64_t metric_argument = 1;
  ReadInt64(arguments, "metric", &metric_argument);

  if (dns_servers.empty() || prefix_length_argument < 0 ||
      prefix_length_argument > 32 ||
      metric_argument < 0 || metric_argument > 9999) {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }

  const auto start = std::chrono::steady_clock::now();
  const auto interface_index = static_cast<NET_IFINDEX>(index_argument);
  std::string address_status;
  DWORD result = ConfigureAddress(interface_index, WideFromUtf8(ipv4_address),
                                  static_cast<UINT8>(prefix_length_argument),
                                  &address_status);
  if (result != NO_ERROR) {
    AddFailure(&response, "ipv4-address", result);
    return EncodableValue(std::move(response));
  }

  bool metric_changed = false;
  result = ConfigureMetric(interface_index, static_cast<ULONG>(metric_argument),
                           &metric_changed);
  if (result != NO_ERROR) {
    AddFailure(&response, "ipv4-metric", result);
    return EncodableValue(std::move(response));
  }

  bool dns_changed = false;
  result = ConfigureDns(interface_index, WideFromUtf8(dns_servers),
                        &dns_changed);
  if (result != NO_ERROR) {
    AddFailure(&response, "dns", result);
    return EncodableValue(std::move(response));
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - start);
  response.insert_or_assign(EncodableValue("elapsedMs"),
                            EncodableValue(static_cast<int64_t>(
                                elapsed.count())));
  response.insert_or_assign(
      EncodableValue("addressStatus"), EncodableValue(address_status));
  response.insert_or_assign(
      EncodableValue("metricStatus"),
      EncodableValue(metric_changed ? "set" : "already-1"));
  response.insert_or_assign(
      EncodableValue("dnsStatus"),
      EncodableValue(dns_changed ? "set" : "unchanged"));
  AddSuccess(&response);
  return EncodableValue(std::move(response));
}

EncodableValue PrepareIpv4ServerRoute(const EncodableMap& arguments) {
  EncodableMap response;
  std::string remote_address;
  if (!ReadString(arguments, "remoteAddress", &remote_address) ||
      remote_address.empty()) {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }

  IN_ADDR destination{};
  if (InetPtonA(AF_INET, remote_address.c_str(), &destination) != 1) {
    AddFailure(&response, "remoteAddress", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }

  const auto start = std::chrono::steady_clock::now();
  Ipv4DefaultRouteCandidate candidate;
  DWORD result = FindHardwareIpv4DefaultRoute(&candidate);
  if (result != NO_ERROR) {
    AddFailure(&response, "default-route", result);
    return EncodableValue(std::move(response));
  }

  const IN_ADDR next_hop = candidate.route.NextHop.Ipv4.sin_addr;
  std::string route_status;
  result = EnsureIpv4HostRoute(destination, candidate.route.InterfaceIndex,
                               next_hop, &route_status);
  if (result != NO_ERROR) {
    AddFailure(&response, "host-route", result);
    return EncodableValue(std::move(response));
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - start);
  response.insert_or_assign(EncodableValue("elapsedMs"),
                            EncodableValue(static_cast<int64_t>(
                                elapsed.count())));
  response.insert_or_assign(EncodableValue("interfaceAlias"),
                            EncodableValue(candidate.interface_info.alias));
  response.insert_or_assign(
      EncodableValue("interfaceIndex"),
      EncodableValue(static_cast<int64_t>(candidate.route.InterfaceIndex)));
  response.insert_or_assign(
      EncodableValue("sourceAddress"),
      EncodableValue(FindSourceIpv4Address(candidate.route.InterfaceIndex)));
  response.insert_or_assign(EncodableValue("nextHop"),
                            EncodableValue(Ipv4ToString(next_hop)));
  response.insert_or_assign(EncodableValue("hardwareInterface"),
                            EncodableValue(candidate.interface_info.hardware));
  response.insert_or_assign(
      EncodableValue("virtual"),
      EncodableValue(candidate.interface_info.virtual_like));
  response.insert_or_assign(EncodableValue("destinationPrefix"),
                            EncodableValue(remote_address + "/32"));
  response.insert_or_assign(EncodableValue("routeStatus"),
                            EncodableValue(route_status));
  AddSuccess(&response);
  return EncodableValue(std::move(response));
}

EncodableValue PrepareXrayTunIpv4Routes(const EncodableMap& arguments) {
  EncodableMap response;
  std::string interface_alias;
  if (!ReadString(arguments, "interfaceAlias", &interface_alias) ||
      interface_alias.empty()) {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }

  std::string ipv4_address = "172.19.0.1";
  std::string dns_servers;
  ReadString(arguments, "address", &ipv4_address);
  ReadString(arguments, "dnsServers", &dns_servers);

  int64_t timeout_ms = 2500;
  int64_t prefix_length_argument = 30;
  int64_t metric_argument = 1;
  ReadInt64(arguments, "timeoutMs", &timeout_ms);
  ReadInt64(arguments, "prefixLength", &prefix_length_argument);
  ReadInt64(arguments, "metric", &metric_argument);
  if (dns_servers.empty() || timeout_ms < 1 || timeout_ms > 30000 ||
      prefix_length_argument < 0 || prefix_length_argument > 32 ||
      metric_argument < 0 || metric_argument > 9999) {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }

  const auto start = std::chrono::steady_clock::now();
  IN_ADDR next_hop{};
  IN_ADDR first_prefix{};
  IN_ADDR second_prefix{};
  if (InetPtonA(AF_INET, "0.0.0.0", &first_prefix) != 1 ||
      InetPtonA(AF_INET, "128.0.0.0", &second_prefix) != 1) {
    AddFailure(&response, "routes", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }
  const std::vector<std::pair<std::string, IN_ADDR>> route_specs = {
      {"0.0.0.0/1", first_prefix},
      {"128.0.0.0/1", second_prefix},
  };

  const auto setup_start = std::chrono::steady_clock::now();
  std::string address_status;
  bool metric_changed = false;
  bool dns_changed = false;
  EncodableList routes;
  std::string failed_step;
  std::string failed_route_prefix;
  std::chrono::milliseconds configure_ms{0};
  std::chrono::milliseconds route_ms{0};
  NET_IFINDEX interface_index = 0;
  std::string resolved_alias;
  std::string adapter_status;
  int64_t wait_ms = 0;
  DWORD result = NO_ERROR;

  while (true) {
    failed_step.clear();
    failed_route_prefix.clear();
    address_status.clear();
    metric_changed = false;
    dns_changed = false;
    routes.clear();

    const auto elapsed_before_wait =
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - start);
    const int64_t remaining_ms = timeout_ms - elapsed_before_wait.count();
    if (remaining_ms <= 0) {
      result = ERROR_TIMEOUT;
      failed_step = "wait-adapter";
    } else {
      int64_t attempt_wait_ms = 0;
      result = WaitForInterfaceAlias(
          WideFromUtf8(interface_alias), remaining_ms, &interface_index,
          &resolved_alias, &adapter_status, &attempt_wait_ms);
      wait_ms += attempt_wait_ms;
      if (result != NO_ERROR) {
        failed_step = "wait-adapter";
      }
    }

    if (result == NO_ERROR) {
      const auto configure_start = std::chrono::steady_clock::now();
      result = ConfigureAddress(interface_index, WideFromUtf8(ipv4_address),
                                static_cast<UINT8>(prefix_length_argument),
                                &address_status);
      if (result != NO_ERROR) {
        failed_step = "ipv4-address";
      }

      if (result == NO_ERROR) {
        result = ConfigureMetric(interface_index,
                                 static_cast<ULONG>(metric_argument),
                                 &metric_changed);
        if (result != NO_ERROR) {
          failed_step = "ipv4-metric";
        }
      }

      if (result == NO_ERROR) {
        result = ConfigureDns(interface_index, WideFromUtf8(dns_servers),
                              &dns_changed);
        if (result != NO_ERROR) {
          failed_step = "dns";
        }
      }
      configure_ms =
          std::chrono::duration_cast<std::chrono::milliseconds>(
              std::chrono::steady_clock::now() - configure_start);
    }

    if (result == NO_ERROR) {
      const auto routes_start = std::chrono::steady_clock::now();
      for (const auto& spec : route_specs) {
        std::string route_status;
        result = EnsureIpv4Route(spec.second, 1, interface_index, next_hop,
                                 &route_status);
        if (result != NO_ERROR) {
          failed_step = "route";
          failed_route_prefix = spec.first;
          break;
        }

        EncodableMap route;
        route.emplace(EncodableValue("DestinationPrefix"),
                      EncodableValue(spec.first));
        route.emplace(EncodableValue("NextHop"), EncodableValue("0.0.0.0"));
        route.emplace(EncodableValue("Status"), EncodableValue(route_status));
        routes.emplace_back(EncodableValue(route));
      }
      route_ms =
          std::chrono::duration_cast<std::chrono::milliseconds>(
              std::chrono::steady_clock::now() - routes_start);
    }

    if (result == NO_ERROR) {
      break;
    }

    const auto elapsed =
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - start);
    if (!IsRetryableNetworkSetupError(result) || elapsed.count() >= timeout_ms) {
      AddFailure(&response, failed_step.empty() ? "setup" : failed_step,
                 result);
      if (!failed_route_prefix.empty()) {
        response.insert_or_assign(EncodableValue("routePrefix"),
                                  EncodableValue(failed_route_prefix));
      }
      response.insert_or_assign(EncodableValue("waitMs"),
                                EncodableValue(wait_ms));
      response.insert_or_assign(
          EncodableValue("elapsedMs"),
          EncodableValue(static_cast<int64_t>(elapsed.count())));
      response.insert_or_assign(
          EncodableValue("setupMs"),
          EncodableValue(static_cast<int64_t>(
              std::chrono::duration_cast<std::chrono::milliseconds>(
                  std::chrono::steady_clock::now() - setup_start)
                  .count())));
      return EncodableValue(std::move(response));
    }

    Sleep(10);
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - start);
  response.insert_or_assign(EncodableValue("elapsedMs"),
                            EncodableValue(static_cast<int64_t>(
                                elapsed.count())));
  response.insert_or_assign(EncodableValue("waitMs"), EncodableValue(wait_ms));
  response.insert_or_assign(
      EncodableValue("configureMs"),
      EncodableValue(static_cast<int64_t>(configure_ms.count())));
  response.insert_or_assign(
      EncodableValue("routeMs"),
      EncodableValue(static_cast<int64_t>(route_ms.count())));
  response.insert_or_assign(EncodableValue("interfaceAlias"),
                            EncodableValue(resolved_alias));
  response.insert_or_assign(EncodableValue("interfaceIndex"),
                            EncodableValue(static_cast<int64_t>(
                                interface_index)));
  response.insert_or_assign(EncodableValue("status"),
                            EncodableValue(adapter_status));
  response.insert_or_assign(
      EncodableValue("addressStatus"), EncodableValue(address_status));
  response.insert_or_assign(
      EncodableValue("metricStatus"),
      EncodableValue(metric_changed ? "set" : "already-1"));
  response.insert_or_assign(
      EncodableValue("dnsStatus"),
      EncodableValue(dns_changed ? "set" : "unchanged"));
  response.insert_or_assign(EncodableValue("routes"),
                            EncodableValue(routes));
  AddSuccess(&response);
  return EncodableValue(std::move(response));
}

EncodableValue RemoveIpv4Routes(const EncodableMap& arguments) {
  EncodableMap response;
  const EncodableValue* routes_value = FindValue(arguments, "routes");
  const auto* route_arguments = routes_value == nullptr
                                    ? nullptr
                                    : std::get_if<EncodableList>(routes_value);
  if (route_arguments == nullptr) {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }

  const auto start = std::chrono::steady_clock::now();
  EncodableList route_results;
  route_results.reserve(route_arguments->size());

  for (const EncodableValue& route_value : *route_arguments) {
    EncodableMap route_result;
    const auto* route = std::get_if<EncodableMap>(&route_value);
    std::string destination_prefix;
    std::string next_hop_text;
    int64_t interface_index_argument = 0;

    if (route != nullptr) {
      ReadString(*route, "destinationPrefix", &destination_prefix);
      ReadString(*route, "nextHop", &next_hop_text);
      ReadInt64(*route, "interfaceIndex", &interface_index_argument);
    }

    route_result.emplace(EncodableValue("DestinationPrefix"),
                         EncodableValue(destination_prefix));
    route_result.emplace(EncodableValue("NextHop"),
                         EncodableValue(next_hop_text));
    route_result.emplace(EncodableValue("InterfaceIndex"),
                         EncodableValue(interface_index_argument));

    IN_ADDR destination{};
    UINT8 prefix_length = 0;
    IN_ADDR next_hop{};
    if (route == nullptr || interface_index_argument <= 0 ||
        !ParseIpv4Prefix(destination_prefix, &destination, &prefix_length) ||
        InetPtonA(AF_INET, next_hop_text.c_str(), &next_hop) != 1) {
      route_result.emplace(EncodableValue("Status"),
                           EncodableValue("failed"));
      route_result.emplace(EncodableValue("Error"),
                           EncodableValue("invalid route arguments"));
      route_results.emplace_back(EncodableValue(std::move(route_result)));
      continue;
    }

    std::string status;
    const DWORD result =
        RemoveIpv4Route(destination, prefix_length,
                        static_cast<NET_IFINDEX>(interface_index_argument),
                        next_hop, &status);
    if (result == NO_ERROR) {
      route_result.emplace(EncodableValue("Status"), EncodableValue(status));
    } else {
      route_result.emplace(EncodableValue("Status"),
                           EncodableValue("failed"));
      route_result.emplace(EncodableValue("Error"),
                           EncodableValue(ErrorMessage(result)));
      route_result.emplace(EncodableValue("ErrorCode"),
                           EncodableValue(static_cast<int64_t>(result)));
    }
    route_results.emplace_back(EncodableValue(std::move(route_result)));
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - start);
  response.insert_or_assign(EncodableValue("elapsedMs"),
                            EncodableValue(static_cast<int64_t>(
                                elapsed.count())));
  response.insert_or_assign(EncodableValue("routes"),
                            EncodableValue(std::move(route_results)));
  AddSuccess(&response);
  return EncodableValue(std::move(response));
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateWindowsTunChannel(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, kWindowsTunChannelName,
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        const auto* arguments = std::get_if<EncodableMap>(call.arguments());
        if (call.method_name() == kConfigureXrayTunIpv4Method) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(ConfigureXrayTunIpv4(*arguments));
          return;
        }

        if (call.method_name() == kPrepareIpv4ServerRouteMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(PrepareIpv4ServerRoute(*arguments));
          return;
        }

        if (call.method_name() == kPrepareXrayTunIpv4RoutesMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(PrepareXrayTunIpv4Routes(*arguments));
          return;
        }

        if (call.method_name() == kRemoveIpv4RoutesMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(RemoveIpv4Routes(*arguments));
          return;
        }

        {
          result->NotImplemented();
          return;
        }
      });

  return channel;
}
