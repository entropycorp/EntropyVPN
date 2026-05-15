#include <winsock2.h>
#include <ws2tcpip.h>

#include "entropy_vpn_service_tun.h"

#include "entropy_vpn_service_common.h"

#include <iphlpapi.h>
#include <netioapi.h>
#include <windows.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <limits>
#include <map>
#include <sstream>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

namespace entropy_vpn_service {
namespace {

constexpr DWORD kXrayTunRetrySleepMs = 1;
#ifndef CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
constexpr DWORD CREATE_WAITABLE_TIMER_HIGH_RESOLUTION = 0x00000002;
#endif

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

std::string Utf8FromWideZ(const wchar_t* value) {
  if (value == nullptr || value[0] == L'\0') {
    return std::string();
  }
  return Utf8FromWide(std::wstring(value));
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

void AddField(std::vector<std::pair<std::string, std::string>>* fields,
              const std::string& key,
              const std::string& value) {
  fields->push_back({key, value});
}

void AddIntField(std::vector<std::pair<std::string, std::string>>* fields,
                 const std::string& key,
                 int64_t value) {
  AddField(fields, key, std::to_string(value));
}

void AddBoolField(std::vector<std::pair<std::string, std::string>>* fields,
                  const std::string& key,
                  bool value) {
  AddField(fields, key, value ? "1" : "0");
}

void AddResultFailure(
    std::vector<std::pair<std::string, std::string>>* fields,
    const std::string& step,
    DWORD error) {
  AddField(fields, "ok", "1");
  AddField(fields, "resultOk", "0");
  AddField(fields, "failedStep", step);
  AddIntField(fields, "errorCode", static_cast<int64_t>(error));
  AddTextField(fields, "errorB64", ErrorMessage(error));
}

void AddResultSuccess(
    std::vector<std::pair<std::string, std::string>>* fields) {
  AddField(fields, "ok", "1");
  AddField(fields, "resultOk", "1");
}

std::string BuildFailure(const std::string& step, DWORD error) {
  std::vector<std::pair<std::string, std::string>> fields;
  AddResultFailure(&fields, step, error);
  return BuildResponse(fields);
}

bool ReadDecodedField(const std::map<std::string, std::string>& fields,
                      const std::string& key,
                      std::string* value) {
  std::string decoded;
  if (!ReadDecodedString(fields, key, &decoded)) {
    return false;
  }
  *value = decoded;
  return true;
}

DWORD ReadNumberField(const std::map<std::string, std::string>& fields,
                      const std::string& key,
                      DWORD fallback) {
  return ReadDword(fields, key, fallback);
}

bool IsDefaultIpv4Route(const MIB_IPFORWARD_ROW2& route) {
  return route.DestinationPrefix.Prefix.Ipv4.sin_family == AF_INET &&
         route.DestinationPrefix.PrefixLength == 0 &&
         route.NextHop.Ipv4.sin_family == AF_INET &&
         route.NextHop.Ipv4.sin_addr.S_un.S_addr != 0;
}

bool SameIpv4(const IN_ADDR& left, const IN_ADDR& right) {
  return left.S_un.S_addr == right.S_un.S_addr;
}

DWORD GetIpv4InterfaceInfo(NET_IFINDEX interface_index,
                           Ipv4InterfaceInfo* info) {
  MIB_IF_ROW2 row{};
  row.InterfaceIndex = interface_index;
  DWORD result = GetIfEntry2(&row);
  if (result != NO_ERROR) {
    return result;
  }

  info->alias = Utf8FromWideZ(row.Alias);
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

std::vector<std::string> ResolveHostIpv4Addresses(const std::string& host,
                                                  DWORD* error) {
  std::vector<std::string> addresses;
  if (error != nullptr) {
    *error = NO_ERROR;
  }

  const std::wstring wide_host = WideFromUtf8(host);
  if (wide_host.empty()) {
    if (error != nullptr) {
      *error = ERROR_INVALID_PARAMETER;
    }
    return addresses;
  }

  WSADATA data{};
  const int startup = WSAStartup(MAKEWORD(2, 2), &data);
  if (startup != 0) {
    if (error != nullptr) {
      *error = static_cast<DWORD>(startup);
    }
    return addresses;
  }

  ADDRINFOW hints{};
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_protocol = IPPROTO_TCP;

  ADDRINFOW* results = nullptr;
  const int result = GetAddrInfoW(wide_host.c_str(), nullptr, &hints, &results);
  if (result != 0) {
    if (error != nullptr) {
      *error = static_cast<DWORD>(result);
    }
    WSACleanup();
    return addresses;
  }

  for (ADDRINFOW* entry = results; entry != nullptr; entry = entry->ai_next) {
    if (entry->ai_family != AF_INET || entry->ai_addr == nullptr ||
        entry->ai_addrlen < sizeof(sockaddr_in)) {
      continue;
    }
    const auto* address =
        reinterpret_cast<const sockaddr_in*>(entry->ai_addr);
    const std::string text = Ipv4ToString(address->sin_addr);
    if (!text.empty() &&
        std::find(addresses.begin(), addresses.end(), text) ==
            addresses.end()) {
      addresses.push_back(text);
    }
  }

  FreeAddrInfoW(results);
  WSACleanup();
  if (addresses.empty() && error != nullptr && *error == NO_ERROR) {
    *error = ERROR_NOT_FOUND;
  }
  return addresses;
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

DWORD RemoveConflictingIpv4Routes(const IN_ADDR& destination,
                                  UINT8 prefix_length,
                                  NET_IFINDEX interface_index,
                                  const IN_ADDR& next_hop,
                                  bool* removed) {
  PMIB_IPFORWARD_TABLE2 table = nullptr;
  const DWORD table_result = GetIpForwardTable2(AF_INET, &table);
  if (table_result != NO_ERROR) {
    return table_result;
  }

  std::vector<MIB_IPFORWARD_ROW2> routes_to_delete;
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const MIB_IPFORWARD_ROW2& route = table->Table[i];
    if (route.InterfaceIndex != interface_index &&
        route.DestinationPrefix.Prefix.Ipv4.sin_family == AF_INET &&
        route.DestinationPrefix.PrefixLength == prefix_length &&
        SameIpv4(route.DestinationPrefix.Prefix.Ipv4.sin_addr, destination) &&
        route.NextHop.Ipv4.sin_family == AF_INET &&
        SameIpv4(route.NextHop.Ipv4.sin_addr, next_hop)) {
      routes_to_delete.push_back(route);
    }
  }
  FreeMibTable(table);

  for (const auto& route : routes_to_delete) {
    const DWORD delete_result = DeleteIpForwardEntry2(
        const_cast<MIB_IPFORWARD_ROW2*>(&route));
    if (delete_result != NO_ERROR && delete_result != ERROR_NOT_FOUND) {
      return delete_result;
    }
    *removed = true;
  }
  return NO_ERROR;
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
    bool removed_conflict = false;
    const DWORD remove_result = RemoveConflictingIpv4Routes(
        destination, prefix_length, interface_index, next_hop,
        &removed_conflict);
    if (remove_result != NO_ERROR) {
      return remove_result;
    }
    if (removed_conflict) {
      const DWORD retry_result = CreateIpForwardEntry2(&route);
      if (retry_result == NO_ERROR ||
          retry_result == ERROR_OBJECT_ALREADY_EXISTS) {
        *status = retry_result == NO_ERROR ? "replaced" : "exists";
        return NO_ERROR;
      }
      return retry_result;
    }
    if (Ipv4RouteExists(destination, prefix_length, interface_index,
                        next_hop)) {
      *status = "exists";
      return NO_ERROR;
    }
  }
  return result;
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
          *resolved_alias = Utf8FromWideZ(row.Alias);
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
    Sleep(kXrayTunRetrySleepMs);
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

void AddRouteFields(std::vector<std::pair<std::string, std::string>>* fields,
                    int index,
                    const std::string& destination_prefix,
                    const std::string& next_hop,
                    const std::string& status) {
  const std::string prefix = "route." + std::to_string(index) + ".";
  AddField(fields, prefix + "destinationPrefix", destination_prefix);
  AddField(fields, prefix + "nextHop", next_hop);
  AddField(fields, prefix + "status", status);
}

HANDLE CreateHighResolutionTimer() {
  return CreateWaitableTimerExW(
      nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
      TIMER_MODIFY_STATE | SYNCHRONIZE);
}

HANDLE ThreadLocalHighResolutionTimer() {
  thread_local HANDLE timer = CreateHighResolutionTimer();
  return timer;
}

const char* RetryWait(DWORD milliseconds) {
  if (milliseconds == 0) {
    SwitchToThread();
    return "yield";
  }

  HANDLE timer = ThreadLocalHighResolutionTimer();
  if (timer == nullptr) {
    Sleep(milliseconds);
    return "sleep";
  }

  LARGE_INTEGER due_time{};
  due_time.QuadPart = -static_cast<LONGLONG>(milliseconds) * 10000;
  if (SetWaitableTimer(timer, &due_time, 0, nullptr, nullptr, FALSE) == 0) {
    Sleep(milliseconds);
    return "sleep";
  }
  WaitForSingleObject(timer, INFINITE);
  return "high_res";
}

class Ipv4InterfaceChangeWaiter {
 public:
  Ipv4InterfaceChangeWaiter() {
    event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (event_ == nullptr) {
      return;
    }
    const DWORD result = NotifyIpInterfaceChange(
        AF_INET, &Ipv4InterfaceChangeWaiter::OnChange, this, FALSE,
        &notification_);
    if (result != NO_ERROR) {
      CloseHandle(event_);
      event_ = nullptr;
      notification_ = nullptr;
    }
  }

  ~Ipv4InterfaceChangeWaiter() {
    if (notification_ != nullptr) {
      CancelMibChangeNotify2(notification_);
      notification_ = nullptr;
    }
    if (event_ != nullptr) {
      CloseHandle(event_);
      event_ = nullptr;
    }
  }

  Ipv4InterfaceChangeWaiter(const Ipv4InterfaceChangeWaiter&) = delete;
  Ipv4InterfaceChangeWaiter& operator=(const Ipv4InterfaceChangeWaiter&) =
      delete;

  HANDLE event() const { return event_; }

  void Reset() {
    if (event_ != nullptr) {
      ResetEvent(event_);
    }
  }

  void SetTarget(NET_IFINDEX interface_index) {
    target_interface_index_.store(interface_index, std::memory_order_release);
  }

 private:
  static void CALLBACK OnChange(PVOID context,
                                PMIB_IPINTERFACE_ROW row,
                                MIB_NOTIFICATION_TYPE notification_type) {
    (void)notification_type;
    auto* waiter = static_cast<Ipv4InterfaceChangeWaiter*>(context);
    if (waiter == nullptr || waiter->event_ == nullptr) {
      return;
    }
    const NET_IFINDEX target =
        waiter->target_interface_index_.load(std::memory_order_acquire);
    if (target == 0 || row == nullptr || row->InterfaceIndex == target) {
      SetEvent(waiter->event_);
    }
  }

  HANDLE event_ = nullptr;
  HANDLE notification_ = nullptr;
  std::atomic<NET_IFINDEX> target_interface_index_{0};
};

const char* RetryWaitForInterfaceChange(HANDLE event, DWORD milliseconds) {
  if (event == nullptr) {
    return RetryWait(milliseconds);
  }
  if (milliseconds == 0) {
    const DWORD wait = WaitForSingleObject(event, 0);
    if (wait == WAIT_OBJECT_0) {
      return "ip_change";
    }
    return RetryWait(0);
  }

  HANDLE timer = ThreadLocalHighResolutionTimer();
  if (timer == nullptr) {
    const DWORD wait = WaitForSingleObject(event, milliseconds);
    if (wait == WAIT_OBJECT_0) {
      return "ip_change";
    }
    return "sleep";
  }

  LARGE_INTEGER due_time{};
  due_time.QuadPart = -static_cast<LONGLONG>(milliseconds) * 10000;
  if (SetWaitableTimer(timer, &due_time, 0, nullptr, nullptr, FALSE) == 0) {
    const DWORD wait = WaitForSingleObject(event, milliseconds);
    if (wait == WAIT_OBJECT_0) {
      return "ip_change";
    }
    return "sleep";
  }

  HANDLE handles[] = {event, timer};
  const DWORD wait = WaitForMultipleObjects(2, handles, FALSE, INFINITE);
  if (wait == WAIT_OBJECT_0) {
    return "ip_change";
  }
  if (wait == WAIT_OBJECT_0 + 1) {
    return "high_res";
  }
  return RetryWait(milliseconds);
}

}  // namespace

std::string PrepareIpv4ServerRouteNative(
    const std::map<std::string, std::string>& fields) {
  std::string remote_address;
  if (!ReadDecodedField(fields, "remoteAddress", &remote_address) ||
      remote_address.empty()) {
    return BuildFailure("arguments", ERROR_INVALID_PARAMETER);
  }

  IN_ADDR destination{};
  if (InetPtonA(AF_INET, remote_address.c_str(), &destination) != 1) {
    return BuildFailure("remoteAddress", ERROR_INVALID_PARAMETER);
  }

  const auto start = std::chrono::steady_clock::now();
  Ipv4DefaultRouteCandidate candidate;
  DWORD result = FindHardwareIpv4DefaultRoute(&candidate);
  if (result != NO_ERROR) {
    return BuildFailure("default-route", result);
  }

  const IN_ADDR next_hop = candidate.route.NextHop.Ipv4.sin_addr;
  std::string route_status;
  result = EnsureIpv4Route(destination, 32, candidate.route.InterfaceIndex,
                           next_hop, &route_status);
  if (result != NO_ERROR) {
    return BuildFailure("host-route", result);
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - start);
  std::vector<std::pair<std::string, std::string>> response;
  AddResultSuccess(&response);
  AddIntField(&response, "elapsedMs", elapsed.count());
  AddTextField(&response, "interfaceAliasB64",
               candidate.interface_info.alias);
  AddIntField(&response, "interfaceIndex",
              static_cast<int64_t>(candidate.route.InterfaceIndex));
  AddField(&response, "sourceAddress",
           FindSourceIpv4Address(candidate.route.InterfaceIndex));
  AddField(&response, "nextHop", Ipv4ToString(next_hop));
  AddBoolField(&response, "hardwareInterface",
               candidate.interface_info.hardware);
  AddBoolField(&response, "virtual", candidate.interface_info.virtual_like);
  AddField(&response, "destinationPrefix", remote_address + "/32");
  AddField(&response, "routeStatus", route_status);
  return BuildResponse(response);
}

std::string PrepareDomainServerRouteNative(
    const std::map<std::string, std::string>& fields) {
  std::string host;
  if (!ReadDecodedField(fields, "host", &host) || host.empty()) {
    return BuildFailure("arguments", ERROR_INVALID_PARAMETER);
  }

  std::string tun_ip_mode = "ipv4";
  const auto mode_field = fields.find("tunIpMode");
  if (mode_field != fields.end()) {
    tun_ip_mode = ToLowerAscii(mode_field->second);
  }
  if (tun_ip_mode != "ipv4" && tun_ip_mode != "dualstack") {
    return BuildFailure("tun-ip-mode", ERROR_NOT_SUPPORTED);
  }

  const auto start = std::chrono::steady_clock::now();
  DWORD resolve_error = NO_ERROR;
  const std::vector<std::string> addresses =
      ResolveHostIpv4Addresses(host, &resolve_error);
  if (addresses.empty()) {
    return BuildFailure("resolve", resolve_error);
  }

  Ipv4DefaultRouteCandidate candidate;
  DWORD result = FindHardwareIpv4DefaultRoute(&candidate);
  if (result != NO_ERROR) {
    return BuildFailure("default-route", result);
  }

  const IN_ADDR next_hop = candidate.route.NextHop.Ipv4.sin_addr;
  const std::string next_hop_text = Ipv4ToString(next_hop);
  if (next_hop_text.empty()) {
    return BuildFailure("next-hop", ERROR_INVALID_PARAMETER);
  }

  std::vector<std::tuple<std::string, std::string, std::string>> routes;
  std::string selected_address;
  DWORD last_route_error = NO_ERROR;
  for (const std::string& address : addresses) {
    IN_ADDR destination{};
    const std::string destination_prefix = address + "/32";
    if (InetPtonA(AF_INET, address.c_str(), &destination) != 1) {
      routes.emplace_back(destination_prefix, next_hop_text, "failed");
      last_route_error = ERROR_INVALID_PARAMETER;
      continue;
    }

    std::string route_status;
    result = EnsureIpv4Route(destination, 32, candidate.route.InterfaceIndex,
                             next_hop, &route_status);
    if (result != NO_ERROR) {
      routes.emplace_back(destination_prefix, next_hop_text, "failed");
      last_route_error = result;
      continue;
    }

    routes.emplace_back(destination_prefix, next_hop_text, route_status);
    if (selected_address.empty()) {
      selected_address = address;
    }
  }

  if (selected_address.empty()) {
    return BuildFailure("host-route",
                        last_route_error == NO_ERROR ? ERROR_NOT_FOUND
                                                     : last_route_error);
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - start);
  std::vector<std::pair<std::string, std::string>> response;
  AddResultSuccess(&response);
  AddIntField(&response, "elapsedMs", elapsed.count());
  AddTextField(&response, "hostB64", host);
  AddIntField(&response, "resolvedAddressCount",
              static_cast<int64_t>(addresses.size()));
  for (size_t i = 0; i < addresses.size(); ++i) {
    AddField(&response, "resolvedAddress." + std::to_string(i),
             addresses[i]);
  }
  AddField(&response, "remoteAddress", selected_address);
  AddTextField(&response, "interfaceAliasB64",
               candidate.interface_info.alias);
  AddIntField(&response, "interfaceIndex",
              static_cast<int64_t>(candidate.route.InterfaceIndex));
  AddField(&response, "sourceAddress",
           FindSourceIpv4Address(candidate.route.InterfaceIndex));
  AddField(&response, "nextHop", next_hop_text);
  AddBoolField(&response, "hardwareInterface",
               candidate.interface_info.hardware);
  AddBoolField(&response, "virtual", candidate.interface_info.virtual_like);
  AddIntField(&response, "routeCount", static_cast<int64_t>(routes.size()));
  for (size_t i = 0; i < routes.size(); ++i) {
    AddRouteFields(&response, static_cast<int>(i), std::get<0>(routes[i]),
                   std::get<1>(routes[i]), std::get<2>(routes[i]));
  }
  return BuildResponse(response);
}

std::string PrepareXrayTunIpv4RoutesNative(
    const std::map<std::string, std::string>& fields) {
  std::string interface_alias;
  if (!ReadDecodedField(fields, "interfaceAlias", &interface_alias) ||
      interface_alias.empty()) {
    return BuildFailure("arguments", ERROR_INVALID_PARAMETER);
  }

  std::string ipv4_address = "172.19.0.1";
  std::string dns_servers;
  ReadDecodedField(fields, "address", &ipv4_address);
  ReadDecodedField(fields, "dnsServers", &dns_servers);

  const DWORD timeout_argument = ReadNumberField(fields, "timeoutMs", 2500);
  const DWORD prefix_length_argument =
      ReadNumberField(fields, "prefixLength", 30);
  const DWORD metric_argument = ReadNumberField(fields, "metric", 1);
  if (dns_servers.empty() || timeout_argument < 1 ||
      timeout_argument > 30000 || prefix_length_argument > 32 ||
      metric_argument > 9999) {
    return BuildFailure("arguments", ERROR_INVALID_PARAMETER);
  }

  const auto start = std::chrono::steady_clock::now();
  IN_ADDR next_hop{};
  IN_ADDR first_prefix{};
  IN_ADDR second_prefix{};
  if (InetPtonA(AF_INET, "0.0.0.0", &first_prefix) != 1 ||
      InetPtonA(AF_INET, "128.0.0.0", &second_prefix) != 1) {
    return BuildFailure("routes", ERROR_INVALID_PARAMETER);
  }
  const std::vector<std::pair<std::string, IN_ADDR>> route_specs = {
      {"0.0.0.0/1", first_prefix},
      {"128.0.0.0/1", second_prefix},
  };

  const auto setup_start = std::chrono::steady_clock::now();
  std::string address_status;
  bool metric_changed = false;
  bool dns_changed = false;
  std::vector<std::tuple<std::string, std::string, std::string>> routes;
  std::string failed_step;
  std::string failed_route_prefix;
  std::chrono::milliseconds configure_ms{0};
  std::chrono::milliseconds configure_total_ms{0};
  std::chrono::milliseconds route_ms{0};
  std::chrono::milliseconds route_total_ms{0};
  NET_IFINDEX interface_index = 0;
  std::string resolved_alias;
  std::string adapter_status;
  int64_t wait_ms = 0;
  int64_t attempts = 0;
  int64_t retry_sleep_ms = 0;
  int64_t interface_change_waits = 0;
  int64_t high_res_waits = 0;
  int64_t fallback_sleep_waits = 0;
  int64_t yield_waits = 0;
  DWORD last_retry_error = NO_ERROR;
  std::string last_retry_step;
  std::string last_retry_route_prefix;
  std::string last_retry_wait;
  DWORD result = NO_ERROR;
  Ipv4InterfaceChangeWaiter interface_change_waiter;

  while (true) {
    interface_change_waiter.Reset();
    ++attempts;
    failed_step.clear();
    failed_route_prefix.clear();
    address_status.clear();
    metric_changed = false;
    dns_changed = false;
    routes.clear();

    const auto elapsed_before_wait =
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - start);
    const int64_t remaining_ms =
        static_cast<int64_t>(timeout_argument) - elapsed_before_wait.count();
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
      } else {
        interface_change_waiter.SetTarget(interface_index);
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
        result = ConfigureMetric(interface_index, metric_argument,
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
      configure_total_ms += configure_ms;
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
        routes.emplace_back(spec.first, "0.0.0.0", route_status);
      }
      route_ms =
          std::chrono::duration_cast<std::chrono::milliseconds>(
              std::chrono::steady_clock::now() - routes_start);
      route_total_ms += route_ms;
    }

    if (result == NO_ERROR) {
      break;
    }

    const auto elapsed =
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - start);
    if (!IsRetryableNetworkSetupError(result) ||
        elapsed.count() >= static_cast<int64_t>(timeout_argument)) {
      std::vector<std::pair<std::string, std::string>> response;
      AddResultFailure(&response, failed_step.empty() ? "setup" : failed_step,
                       result);
      if (!failed_route_prefix.empty()) {
        AddField(&response, "routePrefix", failed_route_prefix);
      }
      AddIntField(&response, "waitMs", wait_ms);
      AddIntField(&response, "attempts", attempts);
      AddIntField(&response, "retrySleepMs", retry_sleep_ms);
      AddIntField(&response, "interfaceChangeWaits", interface_change_waits);
      AddIntField(&response, "highResWaits", high_res_waits);
      AddIntField(&response, "fallbackSleepWaits", fallback_sleep_waits);
      AddIntField(&response, "yieldWaits", yield_waits);
      AddIntField(&response, "configureTotalMs", configure_total_ms.count());
      AddIntField(&response, "routeTotalMs", route_total_ms.count());
      AddField(&response, "lastRetryStep", last_retry_step);
      AddField(&response, "lastRetryWait", last_retry_wait);
      AddIntField(&response, "lastRetryErrorCode",
                  static_cast<int64_t>(last_retry_error));
      AddTextField(&response, "lastRetryErrorB64",
                   last_retry_error == NO_ERROR ? std::string()
                                                : ErrorMessage(last_retry_error));
      if (!last_retry_route_prefix.empty()) {
        AddField(&response, "lastRetryRoutePrefix", last_retry_route_prefix);
      }
      AddIntField(&response, "elapsedMs", elapsed.count());
      AddIntField(
          &response, "setupMs",
          std::chrono::duration_cast<std::chrono::milliseconds>(
              std::chrono::steady_clock::now() - setup_start)
              .count());
      return BuildResponse(response);
    }

    last_retry_error = result;
    last_retry_step = failed_step;
    last_retry_route_prefix = failed_route_prefix;
    const auto sleep_start = std::chrono::steady_clock::now();
    const char* retry_wait = RetryWaitForInterfaceChange(
        interface_change_waiter.event(), kXrayTunRetrySleepMs);
    last_retry_wait = retry_wait;
    if (last_retry_wait == "ip_change") {
      ++interface_change_waits;
    } else if (last_retry_wait == "high_res") {
      ++high_res_waits;
    } else if (last_retry_wait == "sleep") {
      ++fallback_sleep_waits;
    } else if (last_retry_wait == "yield") {
      ++yield_waits;
    }
    retry_sleep_ms += std::chrono::duration_cast<std::chrono::milliseconds>(
                          std::chrono::steady_clock::now() - sleep_start)
                          .count();
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - start);
  std::vector<std::pair<std::string, std::string>> response;
  AddResultSuccess(&response);
  AddIntField(&response, "elapsedMs", elapsed.count());
  AddIntField(&response, "waitMs", wait_ms);
  AddIntField(&response, "configureMs", configure_ms.count());
  AddIntField(&response, "routeMs", route_ms.count());
  AddIntField(&response, "attempts", attempts);
  AddIntField(&response, "retrySleepMs", retry_sleep_ms);
  AddIntField(&response, "interfaceChangeWaits", interface_change_waits);
  AddIntField(&response, "highResWaits", high_res_waits);
  AddIntField(&response, "fallbackSleepWaits", fallback_sleep_waits);
  AddIntField(&response, "yieldWaits", yield_waits);
  AddIntField(&response, "configureTotalMs", configure_total_ms.count());
  AddIntField(&response, "routeTotalMs", route_total_ms.count());
  AddField(&response, "lastRetryStep", last_retry_step);
  AddField(&response, "lastRetryWait", last_retry_wait);
  AddIntField(&response, "lastRetryErrorCode",
              static_cast<int64_t>(last_retry_error));
  AddTextField(&response, "lastRetryErrorB64",
               last_retry_error == NO_ERROR ? std::string()
                                            : ErrorMessage(last_retry_error));
  if (!last_retry_route_prefix.empty()) {
    AddField(&response, "lastRetryRoutePrefix", last_retry_route_prefix);
  }
  AddTextField(&response, "interfaceAliasB64", resolved_alias);
  AddIntField(&response, "interfaceIndex",
              static_cast<int64_t>(interface_index));
  AddField(&response, "status", adapter_status);
  AddField(&response, "addressStatus", address_status);
  AddField(&response, "metricStatus", metric_changed ? "set" : "already-1");
  AddField(&response, "dnsStatus", dns_changed ? "set" : "unchanged");
  AddIntField(&response, "routeCount", static_cast<int64_t>(routes.size()));
  for (size_t i = 0; i < routes.size(); ++i) {
    AddRouteFields(&response, static_cast<int>(i), std::get<0>(routes[i]),
                   std::get<1>(routes[i]), std::get<2>(routes[i]));
  }
  return BuildResponse(response);
}

}  // namespace entropy_vpn_service
