#include "windows_tun_channel.h"

#include <winsock2.h>
#include <ws2tcpip.h>

#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <shellapi.h>
#include <tlhelp32.h>
#include <windows.h>
#include <windns.h>
#include <wininet.h>
#include <winsvc.h>

#include <algorithm>
#include <chrono>
#include <cctype>
#include <cstdint>
#include <cwctype>
#include <cstring>
#include <cstdlib>
#include <deque>
#include <limits>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <variant>
#include <vector>

namespace {

constexpr char kWindowsTunChannelName[] = "entropy_vpn/windows_tun";
constexpr char kConfigureXrayTunIpv4Method[] = "configureXrayTunIpv4";
constexpr char kPrepareIpv4ServerRouteMethod[] = "prepareIpv4ServerRoute";
constexpr char kPrepareTunServerRoutingMethod[] = "prepareTunServerRouting";
constexpr char kPrepareXrayTunRoutesMethod[] = "prepareXrayTunRoutes";
constexpr char kPrepareServerRoutesMethod[] = "prepareServerRoutes";
constexpr char kRemoveIpv4RoutesMethod[] = "removeIpv4Routes";
constexpr char kRemoveRoutesMethod[] = "removeRoutes";
constexpr char kCaptureSystemProxyMethod[] = "captureSystemProxy";
constexpr char kSetSystemProxyMethod[] = "setSystemProxy";
constexpr char kRelaunchAsAdministratorMethod[] = "relaunchAsAdministrator";
constexpr char kStartWindowsServiceMethod[] = "startWindowsService";
constexpr char kRunWindowsServiceHelperMethod[] = "runWindowsServiceHelper";
constexpr char kStopStaleCoreProcessesMethod[] = "stopStaleCoreProcesses";
constexpr char kTerminateProcessTreeMethod[] = "terminateProcessTree";
constexpr char kExpandSplitTunnelProcessTreeMethod[] =
    "expandSplitTunnelProcessTree";

constexpr wchar_t kInternetSettingsRegistryPath[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
constexpr wchar_t kEntropyVpnServicePipeName[] =
    L"\\\\.\\pipe\\EntropyVPNService";
constexpr wchar_t kEntropyVpnServiceExecutableName[] =
    L"entropy_vpn_service.exe";

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

bool ReadBool(const EncodableMap& map, const char* key, bool* value) {
  const EncodableValue* entry = FindValue(map, key);
  if (entry == nullptr) {
    return false;
  }
  if (const auto typed = std::get_if<bool>(entry)) {
    *value = *typed;
    return true;
  }
  return false;
}

std::vector<std::string> SplitCommaList(const std::string& value) {
  std::vector<std::string> items;
  size_t start = 0;
  while (start <= value.size()) {
    const size_t next = value.find(',', start);
    std::string item = value.substr(
        start, next == std::string::npos ? std::string::npos : next - start);
    while (!item.empty() &&
           std::isspace(static_cast<unsigned char>(item.front())) != 0) {
      item.erase(item.begin());
    }
    while (!item.empty() &&
           std::isspace(static_cast<unsigned char>(item.back())) != 0) {
      item.pop_back();
    }
    if (!item.empty()) {
      items.push_back(item);
    }
    if (next == std::string::npos) {
      break;
    }
    start = next + 1;
  }
  return items;
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

class ScopedServiceHandle {
 public:
  explicit ScopedServiceHandle(SC_HANDLE handle) : handle_(handle) {}
  ~ScopedServiceHandle() {
    if (handle_ != nullptr) {
      CloseServiceHandle(handle_);
    }
  }

  ScopedServiceHandle(const ScopedServiceHandle&) = delete;
  ScopedServiceHandle& operator=(const ScopedServiceHandle&) = delete;

  SC_HANDLE get() const { return handle_; }

 private:
  SC_HANDLE handle_ = nullptr;
};

std::string ServiceStateToString(DWORD state) {
  switch (state) {
    case SERVICE_STOPPED:
      return "stopped";
    case SERVICE_START_PENDING:
      return "startPending";
    case SERVICE_STOP_PENDING:
      return "stopPending";
    case SERVICE_RUNNING:
      return "running";
    case SERVICE_CONTINUE_PENDING:
      return "continuePending";
    case SERVICE_PAUSE_PENDING:
      return "pausePending";
    case SERVICE_PAUSED:
      return "paused";
    default:
      return "unknown";
  }
}

class ScopedHandle {
 public:
  explicit ScopedHandle(HANDLE handle) : handle_(handle) {}
  ~ScopedHandle() {
    if (handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE) {
      CloseHandle(handle_);
    }
  }

  ScopedHandle(const ScopedHandle&) = delete;
  ScopedHandle& operator=(const ScopedHandle&) = delete;

  HANDLE get() const { return handle_; }

  void reset(HANDLE handle = nullptr) {
    if (handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE) {
      CloseHandle(handle_);
    }
    handle_ = handle;
  }

  HANDLE release() {
    HANDLE handle = handle_;
    handle_ = nullptr;
    return handle;
  }

 private:
  HANDLE handle_ = nullptr;
};

void CloseHandleIfValid(HANDLE* handle) {
  if (handle != nullptr && *handle != nullptr &&
      *handle != INVALID_HANDLE_VALUE) {
    CloseHandle(*handle);
    *handle = nullptr;
  }
}

std::wstring LowerWide(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  return value;
}

std::wstring NormalizePathKey(std::wstring path) {
  if (path.empty()) {
    return std::wstring();
  }
  std::replace(path.begin(), path.end(), L'/', L'\\');

  DWORD required = GetFullPathNameW(path.c_str(), 0, nullptr, nullptr);
  if (required > 0) {
    std::wstring full_path;
    full_path.resize(required);
    const DWORD written =
        GetFullPathNameW(path.c_str(), required, full_path.data(), nullptr);
    if (written > 0 && written < required) {
      full_path.resize(written);
      path = std::move(full_path);
    }
  }

  while (!path.empty() &&
         (path.back() == L'\0' || path.back() == L' ' ||
          path.back() == L'\t' || path.back() == L'\r' ||
          path.back() == L'\n')) {
    path.pop_back();
  }
  return LowerWide(std::move(path));
}

std::string BasenameWithoutExtension(const std::string& path) {
  const size_t separator = path.find_last_of("\\/");
  const size_t start = separator == std::string::npos ? 0 : separator + 1;
  const size_t dot = path.find_last_of('.');
  const size_t end =
      dot == std::string::npos || dot < start ? path.size() : dot;
  return path.substr(start, end - start);
}

std::string LowerPathNameKey(const std::string& path) {
  return ToLowerAscii(BasenameWithoutExtension(path));
}

bool ReadStringList(const EncodableMap& map,
                    const char* key,
                    std::vector<std::string>* values) {
  const EncodableValue* entry = FindValue(map, key);
  if (entry == nullptr) {
    return false;
  }
  const auto* list = std::get_if<EncodableList>(entry);
  if (list == nullptr) {
    return false;
  }
  values->clear();
  values->reserve(list->size());
  for (const EncodableValue& item : *list) {
    const auto* text = std::get_if<std::string>(&item);
    if (text != nullptr && !text->empty()) {
      values->push_back(*text);
    }
  }
  return true;
}

bool ReadStringListAllowEmpty(const EncodableMap& map,
                              const char* key,
                              std::vector<std::string>* values) {
  const EncodableValue* entry = FindValue(map, key);
  if (entry == nullptr) {
    return false;
  }
  const auto* list = std::get_if<EncodableList>(entry);
  if (list == nullptr) {
    return false;
  }
  values->clear();
  values->reserve(list->size());
  for (const EncodableValue& item : *list) {
    const auto* text = std::get_if<std::string>(&item);
    if (text == nullptr) {
      return false;
    }
    values->push_back(*text);
  }
  return true;
}

struct ProcessSnapshotEntry {
  DWORD pid = 0;
  DWORD parent_pid = 0;
  std::string path;
  std::wstring path_key;
};

std::string QueryProcessImagePath(DWORD pid) {
  if (pid == 0) {
    return std::string();
  }

  ScopedHandle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                   pid));
  if (process.get() == nullptr) {
    return std::string();
  }

  std::vector<wchar_t> buffer(32768);
  DWORD length = static_cast<DWORD>(buffer.size());
  if (QueryFullProcessImageNameW(process.get(), 0, buffer.data(), &length) ==
          0 ||
      length == 0) {
    return std::string();
  }
  if (length < buffer.size()) {
    buffer[length] = L'\0';
  } else {
    buffer.back() = L'\0';
  }
  return Utf8FromWide(buffer.data());
}

DWORD SnapshotProcesses(std::vector<ProcessSnapshotEntry>* processes) {
  processes->clear();
  ScopedHandle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
  if (snapshot.get() == INVALID_HANDLE_VALUE) {
    return GetLastError();
  }

  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  if (Process32FirstW(snapshot.get(), &entry) == 0) {
    const DWORD error = GetLastError();
    return error == ERROR_NO_MORE_FILES ? NO_ERROR : error;
  }

  do {
    ProcessSnapshotEntry process;
    process.pid = entry.th32ProcessID;
    process.parent_pid = entry.th32ParentProcessID;
    process.path = QueryProcessImagePath(process.pid);
    if (!process.path.empty()) {
      process.path_key = NormalizePathKey(WideFromUtf8(process.path));
    }
    processes->push_back(std::move(process));
  } while (Process32NextW(snapshot.get(), &entry) != 0);

  const DWORD error = GetLastError();
  return error == ERROR_NO_MORE_FILES ? NO_ERROR : error;
}

std::unordered_map<DWORD, std::vector<size_t>> BuildChildrenByParent(
    const std::vector<ProcessSnapshotEntry>& processes) {
  std::unordered_map<DWORD, std::vector<size_t>> children_by_parent;
  children_by_parent.reserve(processes.size());
  for (size_t i = 0; i < processes.size(); ++i) {
    children_by_parent[processes[i].parent_pid].push_back(i);
  }
  return children_by_parent;
}

std::vector<DWORD> CollectProcessTreePids(
    DWORD root_pid,
    const std::vector<ProcessSnapshotEntry>& processes) {
  std::vector<DWORD> ordered;
  if (root_pid == 0) {
    return ordered;
  }

  const auto children_by_parent = BuildChildrenByParent(processes);
  std::unordered_set<DWORD> visited;
  std::deque<DWORD> queue;
  queue.push_back(root_pid);
  visited.insert(root_pid);

  while (!queue.empty()) {
    const DWORD current = queue.front();
    queue.pop_front();
    ordered.push_back(current);

    const auto children = children_by_parent.find(current);
    if (children == children_by_parent.end()) {
      continue;
    }
    for (size_t child_index : children->second) {
      const DWORD child_pid = processes[child_index].pid;
      if (child_pid != 0 && visited.insert(child_pid).second) {
        queue.push_back(child_pid);
      }
    }
  }

  std::reverse(ordered.begin(), ordered.end());
  return ordered;
}

struct ProcessTerminationResult {
  DWORD pid = 0;
  bool success = false;
  bool already_exited = false;
  bool terminate_requested = false;
  bool wait_timed_out = false;
  DWORD error = NO_ERROR;
};

ProcessTerminationResult TerminateSingleProcess(DWORD pid, DWORD wait_ms) {
  ProcessTerminationResult result;
  result.pid = pid;
  if (pid == 0 || pid == GetCurrentProcessId()) {
    result.error = ERROR_ACCESS_DENIED;
    return result;
  }

  ScopedHandle process(OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE,
                                   pid));
  if (process.get() == nullptr) {
    result.error = GetLastError();
    if (result.error == ERROR_INVALID_PARAMETER ||
        result.error == ERROR_NOT_FOUND) {
      result.success = true;
      result.already_exited = true;
      result.error = NO_ERROR;
    }
    return result;
  }

  if (TerminateProcess(process.get(), 1) == 0) {
    result.error = GetLastError();
    return result;
  }

  result.terminate_requested = true;
  if (wait_ms > 0) {
    const DWORD wait_result = WaitForSingleObject(process.get(), wait_ms);
    if (wait_result == WAIT_FAILED) {
      result.error = GetLastError();
      return result;
    }
    result.wait_timed_out = wait_result == WAIT_TIMEOUT;
  }
  result.success = true;
  return result;
}

void AddPidList(EncodableMap* response,
                const std::string& key,
                const std::vector<DWORD>& pids) {
  EncodableList values;
  values.reserve(pids.size());
  for (DWORD pid : pids) {
    values.emplace_back(EncodableValue(static_cast<int64_t>(pid)));
  }
  response->insert_or_assign(EncodableValue(key),
                             EncodableValue(std::move(values)));
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

DWORD GetInterfaceInfo(NET_IFINDEX interface_index,
                       ADDRESS_FAMILY family,
                       InterfaceInfo* info) {
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
  ip_row.Family = family;
  ip_row.InterfaceIndex = interface_index;
  result = GetIpInterfaceEntry(&ip_row);
  if (result == NO_ERROR) {
    info->interface_metric = ip_row.Metric;
  }
  return NO_ERROR;
}

bool IsDefaultRouteForFamily(const MIB_IPFORWARD_ROW2& route,
                             ADDRESS_FAMILY family) {
  if (family == AF_INET) {
    return IsDefaultIpv4Route(route);
  }
  if (family == AF_INET6) {
    return route.DestinationPrefix.Prefix.Ipv6.sin6_family == AF_INET6 &&
           route.DestinationPrefix.PrefixLength == 0 &&
           route.NextHop.Ipv6.sin6_family == AF_INET6;
  }
  return false;
}

DWORD FindHardwareDefaultRouteForFamily(ADDRESS_FAMILY family,
                                        DefaultRouteCandidate* selected) {
  PMIB_IPFORWARD_TABLE2 table = nullptr;
  DWORD result = GetIpForwardTable2(family, &table);
  if (result != NO_ERROR) {
    return result;
  }

  bool found = false;
  uint64_t best_metric = std::numeric_limits<uint64_t>::max();
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const MIB_IPFORWARD_ROW2& route = table->Table[i];
    if (!IsDefaultRouteForFamily(route, family)) {
      continue;
    }

    InterfaceInfo info;
    if (GetInterfaceInfo(route.InterfaceIndex, family, &info) != NO_ERROR ||
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
      selected->family = family;
      selected->effective_metric = effective_metric;
      best_metric = effective_metric;
      found = true;
    }
  }

  FreeMibTable(table);
  return found ? NO_ERROR : ERROR_NOT_FOUND;
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

std::string Ipv6ToString(const IN6_ADDR& address) {
  char buffer[INET6_ADDRSTRLEN] = {};
  if (InetNtopA(AF_INET6, const_cast<IN6_ADDR*>(&address), buffer,
                INET6_ADDRSTRLEN) == nullptr) {
    return std::string();
  }
  return std::string(buffer);
}

std::string RouteNextHopToString(const MIB_IPFORWARD_ROW2& route,
                                 ADDRESS_FAMILY family) {
  if (family == AF_INET) {
    return Ipv4ToString(route.NextHop.Ipv4.sin_addr);
  }
  if (family == AF_INET6) {
    return Ipv6ToString(route.NextHop.Ipv6.sin6_addr);
  }
  return std::string();
}

bool IsUsableIpv6Address(const IN6_ADDR& address) {
  return !IN6_IS_ADDR_UNSPECIFIED(&address) &&
         !IN6_IS_ADDR_LOOPBACK(&address);
}

std::string FindSourceAddress(NET_IFINDEX interface_index,
                              ADDRESS_FAMILY family) {
  if (family == AF_INET) {
    return FindSourceIpv4Address(interface_index);
  }

  PMIB_UNICASTIPADDRESS_TABLE table = nullptr;
  const DWORD result = GetUnicastIpAddressTable(family, &table);
  if (result != NO_ERROR) {
    return std::string();
  }

  std::string fallback;
  std::string address;
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const MIB_UNICASTIPADDRESS_ROW& row = table->Table[i];
    if (row.InterfaceIndex != interface_index ||
        row.Address.si_family != family) {
      continue;
    }
    if (family == AF_INET6) {
      const std::string candidate = Ipv6ToString(row.Address.Ipv6.sin6_addr);
      if (fallback.empty()) {
        fallback = candidate;
      }
      if (IsUsableIpv6Address(row.Address.Ipv6.sin6_addr)) {
        address = candidate;
        break;
      }
    }
  }

  FreeMibTable(table);
  return address.empty() ? fallback : address;
}

ADDRESS_FAMILY AddressFamilyForText(const std::string& address) {
  IN_ADDR ipv4{};
  if (InetPtonA(AF_INET, address.c_str(), &ipv4) == 1) {
    return AF_INET;
  }
  IN6_ADDR ipv6{};
  if (InetPtonA(AF_INET6, address.c_str(), &ipv6) == 1) {
    return AF_INET6;
  }
  return AF_UNSPEC;
}

std::string HostPrefixForAddress(const std::string& address,
                                 ADDRESS_FAMILY family) {
  if (family == AF_INET) {
    return address + "/32";
  }
  if (family == AF_INET6) {
    return address + "/128";
  }
  return std::string();
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

DWORD ConfigureAddress(NET_IFINDEX interface_index,
                       const std::wstring& address,
                       UINT8 prefix_length,
                       std::string* status);

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

bool SameIpv6(const IN6_ADDR& left, const IN6_ADDR& right) {
  return std::memcmp(&left, &right, sizeof(IN6_ADDR)) == 0;
}

bool IsUsableIpv4OnInterface(NET_IFINDEX interface_index) {
  PMIB_UNICASTIPADDRESS_TABLE table = nullptr;
  const DWORD result = GetUnicastIpAddressTable(AF_INET, &table);
  if (result != NO_ERROR) {
    return false;
  }

  bool usable = false;
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const MIB_UNICASTIPADDRESS_ROW& row = table->Table[i];
    if (row.InterfaceIndex == interface_index &&
        row.Address.Ipv4.sin_family == AF_INET &&
        IsUsableIpv4Address(row.Address.Ipv4.sin_addr)) {
      usable = true;
      break;
    }
  }
  FreeMibTable(table);
  return usable;
}

bool Ipv4AddressExists(NET_IFINDEX interface_index, const IN_ADDR& address) {
  PMIB_UNICASTIPADDRESS_TABLE table = nullptr;
  const DWORD result = GetUnicastIpAddressTable(AF_INET, &table);
  if (result != NO_ERROR) {
    return false;
  }

  bool exists = false;
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const MIB_UNICASTIPADDRESS_ROW& row = table->Table[i];
    if (row.InterfaceIndex == interface_index &&
        row.Address.Ipv4.sin_family == AF_INET &&
        SameIpv4(row.Address.Ipv4.sin_addr, address)) {
      exists = true;
      break;
    }
  }
  FreeMibTable(table);
  return exists;
}

bool Ipv6AddressExists(NET_IFINDEX interface_index, const IN6_ADDR& address) {
  PMIB_UNICASTIPADDRESS_TABLE table = nullptr;
  const DWORD result = GetUnicastIpAddressTable(AF_INET6, &table);
  if (result != NO_ERROR) {
    return false;
  }

  bool exists = false;
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const MIB_UNICASTIPADDRESS_ROW& row = table->Table[i];
    if (row.InterfaceIndex == interface_index &&
        row.Address.Ipv6.sin6_family == AF_INET6 &&
        SameIpv6(row.Address.Ipv6.sin6_addr, address)) {
      exists = true;
      break;
    }
  }
  FreeMibTable(table);
  return exists;
}

DWORD ConfigureIpv4AddressIfNeeded(NET_IFINDEX interface_index,
                                   const std::wstring& address,
                                   UINT8 prefix_length,
                                   bool* changed,
                                   std::string* status) {
  IN_ADDR parsed{};
  if (InetPtonW(AF_INET, address.c_str(), &parsed) != 1) {
    return ERROR_INVALID_PARAMETER;
  }
  if (Ipv4AddressExists(interface_index, parsed)) {
    *status = "already-set";
    *changed = false;
    return NO_ERROR;
  }
  if (IsUsableIpv4OnInterface(interface_index)) {
    *status = "existing";
    *changed = false;
    return NO_ERROR;
  }

  DWORD result = ConfigureAddress(interface_index, address, prefix_length, status);
  if (result == NO_ERROR) {
    *changed = *status == "created" || *status == "updated";
  }
  return result;
}

DWORD ConfigureIpv6Address(NET_IFINDEX interface_index,
                           const std::wstring& address,
                           UINT8 prefix_length,
                           bool* changed,
                           std::string* status) {
  MIB_UNICASTIPADDRESS_ROW row;
  InitializeUnicastIpAddressEntry(&row);
  row.InterfaceIndex = interface_index;
  row.Address.Ipv6.sin6_family = AF_INET6;
  if (InetPtonW(AF_INET6, address.c_str(), &row.Address.Ipv6.sin6_addr) != 1) {
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
    *changed = true;
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
      *changed = true;
      return NO_ERROR;
    }
    *status = "already-set";
    *changed = false;
    return NO_ERROR;
  }

  return create_result;
}

bool ParseIpv6Prefix(const std::string& destination_prefix,
                     IN6_ADDR* destination,
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
    if (prefix > 128) {
      return false;
    }
  }

  if (InetPtonA(AF_INET6, address.c_str(), destination) != 1) {
    return false;
  }

  *prefix_length = static_cast<UINT8>(prefix);
  return true;
}

bool Ipv6RouteExists(const IN6_ADDR& destination,
                     UINT8 prefix_length,
                     NET_IFINDEX interface_index,
                     const IN6_ADDR& next_hop) {
  PMIB_IPFORWARD_TABLE2 table = nullptr;
  const DWORD result = GetIpForwardTable2(AF_INET6, &table);
  if (result != NO_ERROR) {
    return false;
  }

  bool exists = false;
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const MIB_IPFORWARD_ROW2& route = table->Table[i];
    if (route.InterfaceIndex == interface_index &&
        route.DestinationPrefix.Prefix.Ipv6.sin6_family == AF_INET6 &&
        route.DestinationPrefix.PrefixLength == prefix_length &&
        SameIpv6(route.DestinationPrefix.Prefix.Ipv6.sin6_addr, destination) &&
        route.NextHop.Ipv6.sin6_family == AF_INET6 &&
        SameIpv6(route.NextHop.Ipv6.sin6_addr, next_hop)) {
      exists = true;
      break;
    }
  }

  FreeMibTable(table);
  return exists;
}

DWORD EnsureIpv6Route(const IN6_ADDR& destination,
                      UINT8 prefix_length,
                      NET_IFINDEX interface_index,
                      const IN6_ADDR& next_hop,
                      std::string* status) {
  if (Ipv6RouteExists(destination, prefix_length, interface_index, next_hop)) {
    *status = "exists";
    return NO_ERROR;
  }

  MIB_IPFORWARD_ROW2 route;
  InitializeIpForwardEntry(&route);
  route.InterfaceIndex = interface_index;
  route.DestinationPrefix.Prefix.Ipv6.sin6_family = AF_INET6;
  route.DestinationPrefix.Prefix.Ipv6.sin6_addr = destination;
  route.DestinationPrefix.PrefixLength = prefix_length;
  route.NextHop.Ipv6.sin6_family = AF_INET6;
  route.NextHop.Ipv6.sin6_addr = next_hop;
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

DWORD RemoveIpv6Route(const IN6_ADDR& destination,
                      UINT8 prefix_length,
                      NET_IFINDEX interface_index,
                      const IN6_ADDR& next_hop,
                      std::string* status) {
  PMIB_IPFORWARD_TABLE2 table = nullptr;
  const DWORD table_result = GetIpForwardTable2(AF_INET6, &table);
  if (table_result != NO_ERROR) {
    return table_result;
  }

  MIB_IPFORWARD_ROW2 route_to_delete{};
  bool found = false;
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const MIB_IPFORWARD_ROW2& route = table->Table[i];
    if (route.InterfaceIndex == interface_index &&
        route.DestinationPrefix.Prefix.Ipv6.sin6_family == AF_INET6 &&
        route.DestinationPrefix.PrefixLength == prefix_length &&
        SameIpv6(route.DestinationPrefix.Prefix.Ipv6.sin6_addr, destination) &&
        route.NextHop.Ipv6.sin6_family == AF_INET6 &&
        SameIpv6(route.NextHop.Ipv6.sin6_addr, next_hop)) {
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

void AddStringList(EncodableMap* map, const char* key,
                   const std::vector<std::string>& values) {
  EncodableList list;
  list.reserve(values.size());
  for (const auto& value : values) {
    list.emplace_back(EncodableValue(value));
  }
  map->insert_or_assign(EncodableValue(key), EncodableValue(std::move(list)));
}

void AddRouteResult(EncodableList* routes,
                    const std::string& destination_prefix,
                    const std::string& next_hop,
                    const std::string& status) {
  EncodableMap route;
  route.emplace(EncodableValue("DestinationPrefix"),
                EncodableValue(destination_prefix));
  route.emplace(EncodableValue("NextHop"), EncodableValue(next_hop));
  route.emplace(EncodableValue("Status"), EncodableValue(status));
  routes->emplace_back(EncodableValue(std::move(route)));
}

void AddRouteWarning(std::vector<std::string>* warnings,
                     const std::string& destination_prefix,
                     DWORD error) {
  warnings->push_back("Route " + destination_prefix + ": " +
                      ErrorMessage(error));
}

void AddAdapterInfo(EncodableMap* response,
                    const std::string& alias,
                    NET_IFINDEX interface_index,
                    const std::string& status) {
  EncodableMap adapter;
  adapter.emplace(EncodableValue("InterfaceAlias"), EncodableValue(alias));
  adapter.emplace(EncodableValue("InterfaceIndex"),
                  EncodableValue(static_cast<int64_t>(interface_index)));
  adapter.emplace(EncodableValue("Status"), EncodableValue(status));
  response->insert_or_assign(EncodableValue("Adapter"),
                             EncodableValue(std::move(adapter)));
}

void AddSetupFailure(EncodableMap* response, const std::string& step,
                     DWORD error, int64_t elapsed_ms) {
  AddFailure(response, step, error);
  response->insert_or_assign(EncodableValue("elapsedMs"),
                             EncodableValue(elapsed_ms));
}

std::vector<std::pair<std::string, std::string>> RouteSpecsForTunMode(
    const std::string& tun_ip_mode) {
  std::vector<std::pair<std::string, std::string>> specs;
  if (tun_ip_mode == "ipv4" || tun_ip_mode == "dualStack") {
    specs.emplace_back("0.0.0.0/1", "0.0.0.0");
    specs.emplace_back("128.0.0.0/1", "0.0.0.0");
  }
  if (tun_ip_mode == "ipv6" || tun_ip_mode == "dualStack") {
    specs.emplace_back("::/1", "::");
    specs.emplace_back("8000::/1", "::");
  }
  return specs;
}

DWORD EnsureRouteByPrefix(const std::string& destination_prefix,
                          const std::string& next_hop_text,
                          NET_IFINDEX interface_index,
                          std::string* status) {
  IN_ADDR ipv4_destination{};
  UINT8 ipv4_prefix_length = 0;
  if (ParseIpv4Prefix(destination_prefix, &ipv4_destination,
                      &ipv4_prefix_length)) {
    IN_ADDR ipv4_next_hop{};
    if (InetPtonA(AF_INET, next_hop_text.c_str(), &ipv4_next_hop) != 1) {
      return ERROR_INVALID_PARAMETER;
    }
    return EnsureIpv4Route(ipv4_destination, ipv4_prefix_length,
                           interface_index, ipv4_next_hop, status);
  }

  IN6_ADDR ipv6_destination{};
  UINT8 ipv6_prefix_length = 0;
  if (ParseIpv6Prefix(destination_prefix, &ipv6_destination,
                      &ipv6_prefix_length)) {
    IN6_ADDR ipv6_next_hop{};
    if (InetPtonA(AF_INET6, next_hop_text.c_str(), &ipv6_next_hop) != 1) {
      return ERROR_INVALID_PARAMETER;
    }
    return EnsureIpv6Route(ipv6_destination, ipv6_prefix_length,
                           interface_index, ipv6_next_hop, status);
  }

  return ERROR_INVALID_PARAMETER;
}

DWORD RemoveRouteByPrefix(const std::string& destination_prefix,
                          const std::string& next_hop_text,
                          NET_IFINDEX interface_index,
                          std::string* status) {
  IN_ADDR ipv4_destination{};
  UINT8 ipv4_prefix_length = 0;
  if (ParseIpv4Prefix(destination_prefix, &ipv4_destination,
                      &ipv4_prefix_length)) {
    IN_ADDR ipv4_next_hop{};
    if (InetPtonA(AF_INET, next_hop_text.c_str(), &ipv4_next_hop) != 1) {
      return ERROR_INVALID_PARAMETER;
    }
    return RemoveIpv4Route(ipv4_destination, ipv4_prefix_length,
                           interface_index, ipv4_next_hop, status);
  }

  IN6_ADDR ipv6_destination{};
  UINT8 ipv6_prefix_length = 0;
  if (ParseIpv6Prefix(destination_prefix, &ipv6_destination,
                      &ipv6_prefix_length)) {
    IN6_ADDR ipv6_next_hop{};
    if (InetPtonA(AF_INET6, next_hop_text.c_str(), &ipv6_next_hop) != 1) {
      return ERROR_INVALID_PARAMETER;
    }
    return RemoveIpv6Route(ipv6_destination, ipv6_prefix_length,
                           interface_index, ipv6_next_hop, status);
  }

  return ERROR_INVALID_PARAMETER;
}

bool UsesIpv4(const std::string& tun_ip_mode) {
  return tun_ip_mode == "ipv4" || tun_ip_mode == "dualStack";
}

bool UsesIpv6(const std::string& tun_ip_mode) {
  return tun_ip_mode == "ipv6" || tun_ip_mode == "dualStack";
}

EncodableValue PrepareXrayTunNativeSetup(const EncodableMap& arguments,
                                         bool configure_adapter) {
  EncodableMap response;
  const auto start = std::chrono::steady_clock::now();
  std::string interface_alias;
  if (!ReadString(arguments, "interfaceAlias", &interface_alias) ||
      interface_alias.empty()) {
    AddSetupFailure(&response, "arguments", ERROR_INVALID_PARAMETER, 0);
    return EncodableValue(std::move(response));
  }

  std::string tun_ip_mode = "ipv4";
  ReadString(arguments, "tunIpMode", &tun_ip_mode);
  if (tun_ip_mode != "ipv4" && tun_ip_mode != "ipv6" &&
      tun_ip_mode != "dualStack") {
    AddSetupFailure(&response, "arguments", ERROR_INVALID_PARAMETER, 0);
    return EncodableValue(std::move(response));
  }

  std::string dns_servers;
  ReadString(arguments, "dnsServers", &dns_servers);
  if (configure_adapter && SplitCommaList(dns_servers).empty()) {
    AddSetupFailure(&response, "arguments", ERROR_INVALID_PARAMETER, 0);
    return EncodableValue(std::move(response));
  }

  int64_t timeout_ms = configure_adapter ? 7000 : 2500;
  ReadInt64(arguments, "timeoutMs", &timeout_ms);
  if (timeout_ms < 1 || timeout_ms > 30000) {
    AddSetupFailure(&response, "arguments", ERROR_INVALID_PARAMETER, 0);
    return EncodableValue(std::move(response));
  }

  NET_IFINDEX interface_index = 0;
  std::string resolved_alias;
  std::string adapter_status;
  int64_t wait_ms = 0;
  DWORD result = WaitForInterfaceAlias(WideFromUtf8(interface_alias),
                                       timeout_ms, &interface_index,
                                       &resolved_alias, &adapter_status,
                                       &wait_ms);
  if (result != NO_ERROR) {
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start);
    AddSetupFailure(&response, "wait-adapter", result, elapsed.count());
    response.insert_or_assign(EncodableValue("waitMs"),
                              EncodableValue(wait_ms));
    return EncodableValue(std::move(response));
  }

  std::vector<std::string> changes;
  std::vector<std::string> warnings;
  bool network_changed = false;
  std::chrono::milliseconds configure_ms{0};
  if (configure_adapter) {
    const auto configure_start = std::chrono::steady_clock::now();
    if (UsesIpv4(tun_ip_mode)) {
      bool address_changed = false;
      std::string address_status;
      result = ConfigureIpv4AddressIfNeeded(interface_index, L"172.19.0.1",
                                            30, &address_changed,
                                            &address_status);
      if (result == NO_ERROR) {
        changes.push_back("ipv4-address=" +
                          (address_status == "created"
                               ? "172.19.0.1/30"
                               : address_status));
        network_changed = network_changed || address_changed;
      } else {
        warnings.push_back("IPv4 address: " + ErrorMessage(result));
      }

      bool metric_changed = false;
      result = ConfigureMetric(interface_index, 1, &metric_changed);
      if (result == NO_ERROR) {
        changes.push_back(metric_changed ? "ipv4-metric=1"
                                         : "ipv4-metric=already-1");
        network_changed = network_changed || metric_changed;
      } else {
        warnings.push_back("IPv4 metric: " + ErrorMessage(result));
      }
    }

    if (UsesIpv6(tun_ip_mode)) {
      bool ipv6_changed = false;
      std::string ipv6_status;
      result = ConfigureIpv6Address(interface_index, L"fd7a:115c:a1e0::1",
                                    64, &ipv6_changed, &ipv6_status);
      if (result == NO_ERROR) {
        changes.push_back("ipv6-address=" +
                          (ipv6_status == "created"
                               ? "fd7a:115c:a1e0::1/64"
                               : ipv6_status));
        network_changed = network_changed || ipv6_changed;
      } else {
        warnings.push_back("IPv6 address: " + ErrorMessage(result));
      }
    }

    bool dns_changed = false;
    result = ConfigureDns(interface_index, WideFromUtf8(dns_servers),
                          &dns_changed);
    if (result == NO_ERROR) {
      changes.push_back(dns_changed ? "dns=" + dns_servers : "dns=already-set");
      network_changed = network_changed || dns_changed;
    } else {
      warnings.push_back("DNS servers: " + ErrorMessage(result));
    }

    if (network_changed) {
      using DnsFlushResolverCacheFn = BOOL(WINAPI*)();
      HMODULE dnsapi = LoadLibraryW(L"dnsapi.dll");
      auto flush_resolver_cache =
          dnsapi == nullptr
              ? nullptr
              : reinterpret_cast<DnsFlushResolverCacheFn>(
                    GetProcAddress(dnsapi, "DnsFlushResolverCache"));
      if (flush_resolver_cache != nullptr && flush_resolver_cache()) {
        changes.push_back("dns-cache=cleared");
      } else {
        warnings.push_back("DNS cache: " + ErrorMessage(GetLastError()));
      }
      if (dnsapi != nullptr) {
        FreeLibrary(dnsapi);
      }
    }
    configure_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - configure_start);
  } else {
    changes.push_back("route-only");
  }

  const auto route_start = std::chrono::steady_clock::now();
  EncodableList route_results;
  const auto route_specs = RouteSpecsForTunMode(tun_ip_mode);
  for (const auto& spec : route_specs) {
    std::string route_status;
    const DWORD route_result = EnsureRouteByPrefix(
        spec.first, spec.second, interface_index, &route_status);
    if (route_result == NO_ERROR) {
      AddRouteResult(&route_results, spec.first, spec.second, route_status);
    } else {
      AddRouteWarning(&warnings, spec.first, route_result);
      AddRouteResult(&route_results, spec.first, spec.second, "failed");
    }
  }
  const auto route_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - route_start);
  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - start);

  response.insert_or_assign(EncodableValue("ok"), EncodableValue(true));
  response.insert_or_assign(EncodableValue("elapsedMs"),
                            EncodableValue(static_cast<int64_t>(
                                elapsed.count())));
  AddAdapterInfo(&response, resolved_alias, interface_index, adapter_status);
  AddStringList(&response, "Changes", changes);
  AddStringList(&response, "Warnings", warnings);
  response.insert_or_assign(EncodableValue("NetworkChanged"),
                            EncodableValue(network_changed));
  response.insert_or_assign(EncodableValue("Routes"),
                            EncodableValue(std::move(route_results)));

  std::vector<std::string> timings;
  timings.push_back("wait_adapter=" + std::to_string(wait_ms) + "ms");
  if (configure_adapter) {
    timings.push_back("configure_adapter=" +
                      std::to_string(configure_ms.count()) + "ms");
  }
  timings.push_back("install_routes=" + std::to_string(route_ms.count()) +
                    "ms");
  AddStringList(&response, "Timings", timings);
  return EncodableValue(std::move(response));
}

void AddServerRouteResult(EncodableList* routes,
                          const std::string& destination_prefix,
                          const std::string& next_hop,
                          const std::string& status,
                          const DefaultRouteCandidate& candidate,
                          DWORD error = NO_ERROR) {
  EncodableMap route;
  route.emplace(EncodableValue("DestinationPrefix"),
                EncodableValue(destination_prefix));
  route.emplace(EncodableValue("NextHop"), EncodableValue(next_hop));
  route.emplace(EncodableValue("Status"), EncodableValue(status));
  route.emplace(EncodableValue("InterfaceAlias"),
                EncodableValue(candidate.interface_info.alias));
  route.emplace(EncodableValue("InterfaceIndex"),
                EncodableValue(static_cast<int64_t>(
                    candidate.route.InterfaceIndex)));
  if (error != NO_ERROR) {
    route.emplace(EncodableValue("Error"), EncodableValue(ErrorMessage(error)));
    route.emplace(EncodableValue("ErrorCode"),
                  EncodableValue(static_cast<int64_t>(error)));
  }
  routes->emplace_back(EncodableValue(std::move(route)));
}

void AddSelectedServerRoute(EncodableMap* response,
                            const DefaultRouteCandidate& candidate,
                            const std::string& selected_address,
                            const std::string& next_hop) {
  response->insert_or_assign(EncodableValue("remoteAddress"),
                             EncodableValue(selected_address));
  response->insert_or_assign(EncodableValue("interfaceAlias"),
                             EncodableValue(candidate.interface_info.alias));
  response->insert_or_assign(
      EncodableValue("interfaceIndex"),
      EncodableValue(static_cast<int64_t>(candidate.route.InterfaceIndex)));
  response->insert_or_assign(
      EncodableValue("sourceAddress"),
      EncodableValue(FindSourceAddress(candidate.route.InterfaceIndex,
                                       candidate.family)));
  response->insert_or_assign(EncodableValue("nextHop"),
                             EncodableValue(next_hop));
  response->insert_or_assign(EncodableValue("hardwareInterface"),
                             EncodableValue(candidate.interface_info.hardware));
  response->insert_or_assign(
      EncodableValue("virtual"),
      EncodableValue(candidate.interface_info.virtual_like));
}

EncodableValue PrepareServerRoutesForAddresses(
    const std::vector<std::string>& addresses) {
  EncodableMap response;
  if (addresses.empty()) {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }

  const auto start = std::chrono::steady_clock::now();
  EncodableList route_results;
  route_results.reserve(addresses.size());

  bool selected = false;
  DefaultRouteCandidate selected_candidate;
  std::string selected_address;
  std::string selected_next_hop;
  DWORD last_error = ERROR_NOT_FOUND;
  std::string failed_step = "default-route";

  for (const std::string& remote_address : addresses) {
    const ADDRESS_FAMILY family = AddressFamilyForText(remote_address);
    const std::string destination_prefix =
        HostPrefixForAddress(remote_address, family);
    if (family == AF_UNSPEC || destination_prefix.empty()) {
      DefaultRouteCandidate empty_candidate;
      AddServerRouteResult(&route_results, remote_address, std::string(),
                           "failed", empty_candidate,
                           ERROR_INVALID_PARAMETER);
      last_error = ERROR_INVALID_PARAMETER;
      failed_step = "remoteAddress";
      continue;
    }

    DefaultRouteCandidate candidate;
    DWORD result = FindHardwareDefaultRouteForFamily(family, &candidate);
    if (result != NO_ERROR) {
      AddServerRouteResult(&route_results, destination_prefix, std::string(),
                           "failed", candidate, result);
      last_error = result;
      failed_step = "default-route";
      continue;
    }

    const std::string next_hop = RouteNextHopToString(candidate.route, family);
    if (next_hop.empty()) {
      AddServerRouteResult(&route_results, destination_prefix, std::string(),
                           "failed", candidate, ERROR_INVALID_PARAMETER);
      last_error = ERROR_INVALID_PARAMETER;
      failed_step = "next-hop";
      continue;
    }

    std::string route_status;
    result = EnsureRouteByPrefix(destination_prefix, next_hop,
                                 candidate.route.InterfaceIndex,
                                 &route_status);
    if (result == NO_ERROR) {
      AddServerRouteResult(&route_results, destination_prefix, next_hop,
                           route_status, candidate);
      if (!selected) {
        selected = true;
        selected_candidate = candidate;
        selected_address = remote_address;
        selected_next_hop = next_hop;
      }
    } else {
      AddServerRouteResult(&route_results, destination_prefix, next_hop,
                           "failed", candidate, result);
      last_error = result;
      failed_step = "host-route";
    }
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - start);
  response.insert_or_assign(EncodableValue("elapsedMs"),
                            EncodableValue(static_cast<int64_t>(
                                elapsed.count())));
  response.insert_or_assign(EncodableValue("routes"),
                            EncodableValue(std::move(route_results)));

  if (!selected) {
    AddFailure(&response, failed_step, last_error);
    return EncodableValue(std::move(response));
  }

  AddSelectedServerRoute(&response, selected_candidate, selected_address,
                         selected_next_hop);
  AddSuccess(&response);
  return EncodableValue(std::move(response));
}

EncodableValue PrepareServerRoutes(const EncodableMap& arguments) {
  const EncodableValue* addresses_value = FindValue(arguments, "remoteAddresses");
  const auto* address_arguments =
      addresses_value == nullptr ? nullptr
                                 : std::get_if<EncodableList>(addresses_value);
  std::vector<std::string> addresses;
  if (address_arguments != nullptr) {
    addresses.reserve(address_arguments->size());
    for (const EncodableValue& address_value : *address_arguments) {
      const auto* typed_address = std::get_if<std::string>(&address_value);
      addresses.push_back(typed_address == nullptr ? std::string()
                                                   : *typed_address);
    }
  }
  return PrepareServerRoutesForAddresses(addresses);
}

std::vector<std::string> ResolveServerRoutingAddresses(
    const std::string& server,
    const std::string& tun_ip_mode,
    DWORD* error) {
  std::vector<std::string> addresses;
  if (error != nullptr) {
    *error = NO_ERROR;
  }

  const ADDRESS_FAMILY literal_family = AddressFamilyForText(server);
  if (literal_family == AF_INET || literal_family == AF_INET6) {
    if ((literal_family == AF_INET && UsesIpv4(tun_ip_mode)) ||
        (literal_family == AF_INET6 && UsesIpv6(tun_ip_mode))) {
      addresses.push_back(server);
    } else if (error != nullptr) {
      *error = ERROR_NOT_FOUND;
    }
    return addresses;
  }

  const std::wstring wide_server = WideFromUtf8(server);
  if (wide_server.empty()) {
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
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_protocol = IPPROTO_TCP;

  ADDRINFOW* results = nullptr;
  const int result =
      GetAddrInfoW(wide_server.c_str(), nullptr, &hints, &results);
  if (result != 0) {
    if (error != nullptr) {
      *error = static_cast<DWORD>(result);
    }
    WSACleanup();
    return addresses;
  }

  for (ADDRINFOW* entry = results; entry != nullptr; entry = entry->ai_next) {
    std::string text;
    if (entry->ai_family == AF_INET && UsesIpv4(tun_ip_mode) &&
        entry->ai_addr != nullptr && entry->ai_addrlen >= sizeof(sockaddr_in)) {
      const auto* address =
          reinterpret_cast<const sockaddr_in*>(entry->ai_addr);
      text = Ipv4ToString(address->sin_addr);
    } else if (entry->ai_family == AF_INET6 && UsesIpv6(tun_ip_mode) &&
               entry->ai_addr != nullptr &&
               entry->ai_addrlen >= sizeof(sockaddr_in6)) {
      const auto* address =
          reinterpret_cast<const sockaddr_in6*>(entry->ai_addr);
      text = Ipv6ToString(address->sin6_addr);
    }
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

DWORD ReadRegistryDword(HKEY key, const wchar_t* name, DWORD fallback) {
  DWORD value = fallback;
  DWORD type = 0;
  DWORD size = sizeof(value);
  const DWORD result =
      RegQueryValueExW(key, name, nullptr, &type,
                       reinterpret_cast<LPBYTE>(&value), &size);
  if (result != ERROR_SUCCESS || type != REG_DWORD) {
    return fallback;
  }
  return value;
}

std::wstring ReadRegistryString(HKEY key, const wchar_t* name) {
  DWORD type = 0;
  DWORD size = 0;
  DWORD result = RegQueryValueExW(key, name, nullptr, &type, nullptr, &size);
  if (result != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ) ||
      size == 0) {
    return std::wstring();
  }

  std::vector<wchar_t> buffer((size / sizeof(wchar_t)) + 1);
  result = RegQueryValueExW(key, name, nullptr, &type,
                            reinterpret_cast<LPBYTE>(buffer.data()), &size);
  if (result != ERROR_SUCCESS) {
    return std::wstring();
  }
  buffer.back() = L'\0';
  return std::wstring(buffer.data());
}

DWORD SetRegistryStringOrDelete(HKEY key,
                                const wchar_t* name,
                                const EncodableValue* value) {
  if (value == nullptr || std::holds_alternative<std::monostate>(*value)) {
    const DWORD result = RegDeleteValueW(key, name);
    return result == ERROR_FILE_NOT_FOUND ? ERROR_SUCCESS : result;
  }
  const auto* string_value = std::get_if<std::string>(value);
  if (string_value == nullptr) {
    return ERROR_INVALID_PARAMETER;
  }
  const std::wstring wide = WideFromUtf8(*string_value);
  return RegSetValueExW(
      key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(wide.c_str()),
      static_cast<DWORD>((wide.size() + 1) * sizeof(wchar_t)));
}

DWORD RefreshSystemProxySettings() {
  if (InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr,
                         0) == 0) {
    return GetLastError();
  }
  if (InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0) == 0) {
    return GetLastError();
  }
  return ERROR_SUCCESS;
}

EncodableValue CaptureSystemProxy() {
  EncodableMap response;
  HKEY key = nullptr;
  DWORD result = RegOpenKeyExW(HKEY_CURRENT_USER, kInternetSettingsRegistryPath,
                               0, KEY_QUERY_VALUE, &key);
  if (result != ERROR_SUCCESS) {
    AddFailure(&response, "registry-open", result);
    return EncodableValue(std::move(response));
  }

  const DWORD enabled = ReadRegistryDword(key, L"ProxyEnable", 0);
  const std::wstring server = ReadRegistryString(key, L"ProxyServer");
  const std::wstring override = ReadRegistryString(key, L"ProxyOverride");
  RegCloseKey(key);

  response.insert_or_assign(EncodableValue("enabled"),
                            EncodableValue(enabled == 1));
  response.insert_or_assign(EncodableValue("server"),
                            EncodableValue(Utf8FromWide(server.c_str())));
  response.insert_or_assign(EncodableValue("override"),
                            EncodableValue(Utf8FromWide(override.c_str())));
  AddSuccess(&response);
  return EncodableValue(std::move(response));
}

EncodableValue SetSystemProxy(const EncodableMap& arguments) {
  EncodableMap response;
  bool enabled = false;
  if (!ReadBool(arguments, "enabled", &enabled)) {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }

  HKEY key = nullptr;
  DWORD disposition = 0;
  DWORD result = RegCreateKeyExW(HKEY_CURRENT_USER,
                                 kInternetSettingsRegistryPath, 0, nullptr,
                                 REG_OPTION_NON_VOLATILE, KEY_SET_VALUE,
                                 nullptr, &key, &disposition);
  if (result != ERROR_SUCCESS) {
    AddFailure(&response, "registry-open", result);
    return EncodableValue(std::move(response));
  }

  DWORD enabled_value = enabled ? 1 : 0;
  result = RegSetValueExW(key, L"ProxyEnable", 0, REG_DWORD,
                          reinterpret_cast<const BYTE*>(&enabled_value),
                          sizeof(enabled_value));
  if (result == ERROR_SUCCESS) {
    result =
        SetRegistryStringOrDelete(key, L"ProxyServer",
                                  FindValue(arguments, "server"));
  }
  if (result == ERROR_SUCCESS) {
    result =
        SetRegistryStringOrDelete(key, L"ProxyOverride",
                                  FindValue(arguments, "override"));
  }
  RegCloseKey(key);

  if (result != ERROR_SUCCESS) {
    AddFailure(&response, "registry-set", result);
    return EncodableValue(std::move(response));
  }

  result = RefreshSystemProxySettings();
  if (result != ERROR_SUCCESS) {
    AddFailure(&response, "proxy-refresh", result);
    return EncodableValue(std::move(response));
  }

  AddSuccess(&response);
  return EncodableValue(std::move(response));
}

EncodableValue RelaunchAsAdministrator(const EncodableMap& arguments) {
  EncodableMap response;
  std::string executable;
  std::string working_directory;
  std::string relaunch_arguments;
  if (!ReadString(arguments, "executable", &executable) ||
      executable.empty()) {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }
  ReadString(arguments, "workingDirectory", &working_directory);
  ReadString(arguments, "arguments", &relaunch_arguments);

  const std::wstring executable_wide = WideFromUtf8(executable);
  const std::wstring working_directory_wide = WideFromUtf8(working_directory);
  const std::wstring arguments_wide = WideFromUtf8(relaunch_arguments);
  HINSTANCE launch_result = ShellExecuteW(
      nullptr, L"runas", executable_wide.c_str(),
      arguments_wide.empty() ? nullptr : arguments_wide.c_str(),
      working_directory_wide.empty() ? nullptr : working_directory_wide.c_str(),
      SW_SHOWNORMAL);
  const INT_PTR code = reinterpret_cast<INT_PTR>(launch_result);
  if (code <= 32) {
    AddFailure(&response, "shell-execute",
               code > 0 ? static_cast<DWORD>(code) : GetLastError());
    return EncodableValue(std::move(response));
  }

  AddSuccess(&response);
  return EncodableValue(std::move(response));
}

void AddFailureMessage(EncodableMap* response,
                       const std::string& step,
                       const std::string& message,
                       DWORD error_code = ERROR_GEN_FAILURE) {
  response->insert_or_assign(EncodableValue("ok"), EncodableValue(false));
  response->insert_or_assign(EncodableValue("failedStep"), EncodableValue(step));
  response->insert_or_assign(EncodableValue("error"), EncodableValue(message));
  response->insert_or_assign(EncodableValue("errorCode"),
                             EncodableValue(static_cast<int64_t>(error_code)));
}

std::string TrimAscii(std::string value) {
  while (!value.empty() &&
         (value.back() == '\r' || value.back() == '\n' ||
          value.back() == ' ' || value.back() == '\t')) {
    value.pop_back();
  }
  size_t start = 0;
  while (start < value.size() &&
         (value[start] == '\r' || value[start] == '\n' ||
          value[start] == ' ' || value[start] == '\t')) {
    ++start;
  }
  if (start == 0) {
    return value;
  }
  return value.substr(start);
}

std::string ServiceBase64Encode(const std::string& input) {
  static constexpr char kAlphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string output;
  output.reserve(((input.size() + 2) / 3) * 4);
  for (size_t i = 0; i < input.size(); i += 3) {
    const uint32_t b0 = static_cast<unsigned char>(input[i]);
    const uint32_t b1 =
        i + 1 < input.size() ? static_cast<unsigned char>(input[i + 1]) : 0;
    const uint32_t b2 =
        i + 2 < input.size() ? static_cast<unsigned char>(input[i + 2]) : 0;
    output.push_back(kAlphabet[(b0 >> 2) & 0x3f]);
    output.push_back(kAlphabet[((b0 << 4) | (b1 >> 4)) & 0x3f]);
    output.push_back(i + 1 < input.size()
                         ? kAlphabet[((b1 << 2) | (b2 >> 6)) & 0x3f]
                         : '=');
    output.push_back(i + 2 < input.size() ? kAlphabet[b2 & 0x3f] : '=');
  }
  return output;
}

int ServiceBase64Value(char c) {
  if (c >= 'A' && c <= 'Z') {
    return c - 'A';
  }
  if (c >= 'a' && c <= 'z') {
    return c - 'a' + 26;
  }
  if (c >= '0' && c <= '9') {
    return c - '0' + 52;
  }
  if (c == '+') {
    return 62;
  }
  if (c == '/') {
    return 63;
  }
  return -1;
}

bool ServiceBase64Decode(const std::string& input, std::string* output) {
  output->clear();
  int value = 0;
  int bits = -8;
  for (char c : input) {
    if (c == '=') {
      break;
    }
    const int decoded = ServiceBase64Value(c);
    if (decoded < 0) {
      if (c == '\r' || c == '\n' || c == ' ' || c == '\t') {
        continue;
      }
      return false;
    }
    value = (value << 6) + decoded;
    bits += 6;
    if (bits >= 0) {
      output->push_back(static_cast<char>((value >> bits) & 0xff));
      bits -= 8;
    }
  }
  return true;
}

void AppendServiceField(std::string* request,
                        const std::string& key,
                        const std::string& value) {
  request->append(key);
  request->push_back('=');
  request->append(value);
  request->push_back('\n');
}

void AppendEncodedServiceField(std::string* request,
                               const std::string& key,
                               const std::string& value) {
  AppendServiceField(request, key, ServiceBase64Encode(value));
}

std::string WindowsServiceOptionValue(const std::vector<std::string>& args,
                                      const std::string& name,
                                      const std::string& fallback = "") {
  for (size_t i = 0; i + 1 < args.size(); ++i) {
    if (args[i] == name) {
      return args[i + 1];
    }
  }
  return fallback;
}

std::vector<std::string> WindowsServiceRepeatedOptionValues(
    const std::vector<std::string>& args,
    const std::string& name) {
  std::vector<std::string> values;
  for (size_t i = 0; i + 1 < args.size(); ++i) {
    if (args[i] == name) {
      values.push_back(args[i + 1]);
      ++i;
    }
  }
  return values;
}

void AppendServiceArguments(std::string* request,
                            const std::vector<std::string>& args) {
  AppendServiceField(request, "argCount", std::to_string(args.size()));
  for (size_t i = 0; i < args.size(); ++i) {
    AppendEncodedServiceField(request, "arg" + std::to_string(i), args[i]);
  }
}

bool BuildWindowsServiceRequest(const std::vector<std::string>& args,
                                std::string* request,
                                std::string* error) {
  request->clear();
  if (args.empty()) {
    *error = "Missing EntropyVPN service command.";
    return false;
  }

  const std::string& command = args.front();
  if (command == "ping") {
    AppendServiceField(request, "command", "ping");
  } else if (command == "start-core") {
    AppendServiceField(request, "command", "start_core");
    AppendEncodedServiceField(
        request, "runId", WindowsServiceOptionValue(args, "--run-id"));
    AppendEncodedServiceField(
        request, "executable",
        WindowsServiceOptionValue(args, "--executable"));
    AppendEncodedServiceField(
        request, "workingDirectory",
        WindowsServiceOptionValue(args, "--working-directory"));
    AppendEncodedServiceField(
        request, "stdoutPath",
        WindowsServiceOptionValue(args, "--stdout-path"));
    AppendEncodedServiceField(
        request, "stderrPath",
        WindowsServiceOptionValue(args, "--stderr-path"));
    AppendServiceArguments(request,
                           WindowsServiceRepeatedOptionValues(args, "--arg"));
  } else if (command == "stop-core") {
    AppendServiceField(request, "command", "stop_core");
    AppendEncodedServiceField(
        request, "runId", WindowsServiceOptionValue(args, "--run-id"));
  } else if (command == "status-core") {
    AppendServiceField(request, "command", "status_core");
    AppendEncodedServiceField(
        request, "runId", WindowsServiceOptionValue(args, "--run-id"));
  } else if (command == "run-process") {
    AppendServiceField(request, "command", "run_process");
    AppendEncodedServiceField(
        request, "executable",
        WindowsServiceOptionValue(args, "--executable"));
    AppendEncodedServiceField(
        request, "workingDirectory",
        WindowsServiceOptionValue(args, "--working-directory"));
    AppendServiceField(
        request, "timeoutMs",
        WindowsServiceOptionValue(args, "--timeout-ms", "30000"));
    AppendServiceArguments(request,
                           WindowsServiceRepeatedOptionValues(args, "--arg"));
  } else if (command == "prepare-ipv4-server-route") {
    AppendServiceField(request, "command", "prepare_ipv4_server_route");
    AppendEncodedServiceField(
        request, "remoteAddress",
        WindowsServiceOptionValue(args, "--remote-address"));
  } else if (command == "prepare-domain-server-route") {
    AppendServiceField(request, "command", "prepare_domain_server_route");
    AppendEncodedServiceField(request, "host",
                              WindowsServiceOptionValue(args, "--host"));
    AppendServiceField(
        request, "tunIpMode",
        WindowsServiceOptionValue(args, "--tun-ip-mode", "ipv4"));
  } else if (command == "prepare-xray-tun-ipv4-routes") {
    AppendServiceField(request, "command", "prepare_xray_tun_ipv4_routes");
    AppendEncodedServiceField(
        request, "interfaceAlias",
        WindowsServiceOptionValue(args, "--interface-alias"));
    AppendEncodedServiceField(
        request, "address", WindowsServiceOptionValue(args, "--address"));
    AppendEncodedServiceField(
        request, "dnsServers",
        WindowsServiceOptionValue(args, "--dns-servers"));
    AppendServiceField(
        request, "timeoutMs",
        WindowsServiceOptionValue(args, "--timeout-ms", "2500"));
    AppendServiceField(
        request, "prefixLength",
        WindowsServiceOptionValue(args, "--prefix-length", "30"));
    AppendServiceField(request, "metric",
                       WindowsServiceOptionValue(args, "--metric", "1"));
  } else {
    *error = "Unknown EntropyVPN service command: " + command;
    return false;
  }

  return true;
}

std::unordered_map<std::string, std::string> ParseServiceFields(
    const std::string& output) {
  std::unordered_map<std::string, std::string> fields;
  size_t start = 0;
  while (start <= output.size()) {
    size_t end = output.find('\n', start);
    if (end == std::string::npos) {
      end = output.size();
    }
    std::string line = output.substr(start, end - start);
    if (!line.empty() && line.back() == '\r') {
      line.pop_back();
    }
    const size_t separator = line.find('=');
    if (separator != std::string::npos && separator > 0) {
      fields[line.substr(0, separator)] = line.substr(separator + 1);
    }
    if (end == output.size()) {
      break;
    }
    start = end + 1;
  }
  return fields;
}

std::string ServiceFieldValue(
    const std::unordered_map<std::string, std::string>& fields,
    const std::string& key) {
  const auto found = fields.find(key);
  return found == fields.end() ? std::string() : found->second;
}

std::string DecodeServiceField(
    const std::unordered_map<std::string, std::string>& fields,
    const std::string& key) {
  std::string decoded;
  const std::string encoded = ServiceFieldValue(fields, key);
  if (encoded.empty() || !ServiceBase64Decode(encoded, &decoded)) {
    return std::string();
  }
  return decoded;
}

struct ParsedServiceResponse {
  bool ok = false;
  std::unordered_map<std::string, std::string> fields;
  std::string error;
};

ParsedServiceResponse ParseWindowsServiceResponse(const std::string& stdout_text,
                                                  const std::string& stderr_text,
                                                  DWORD exit_code) {
  ParsedServiceResponse parsed;
  parsed.fields = ParseServiceFields(stdout_text);
  if (ServiceFieldValue(parsed.fields, "ok") == "1") {
    parsed.ok = true;
    return parsed;
  }

  const std::string decoded_error =
      TrimAscii(DecodeServiceField(parsed.fields, "errorB64"));
  if (!decoded_error.empty()) {
    parsed.error = decoded_error;
  } else if (!TrimAscii(stderr_text).empty()) {
    parsed.error = TrimAscii(stderr_text);
  } else if (!TrimAscii(stdout_text).empty()) {
    parsed.error = TrimAscii(stdout_text);
  } else {
    parsed.error =
        "EntropyVPN Service request failed with exit " +
        std::to_string(exit_code) + ".";
  }
  return parsed;
}

EncodableMap ServiceFieldsToEncodable(
    const std::unordered_map<std::string, std::string>& fields) {
  EncodableMap encoded;
  for (const auto& field : fields) {
    encoded.emplace(EncodableValue(field.first), EncodableValue(field.second));
  }
  return encoded;
}

DWORD ClampTimeoutMs(int64_t timeout_ms, DWORD fallback) {
  if (timeout_ms <= 0) {
    return fallback;
  }
  if (static_cast<uint64_t>(timeout_ms) >
      static_cast<uint64_t>(std::numeric_limits<DWORD>::max())) {
    return std::numeric_limits<DWORD>::max();
  }
  return static_cast<DWORD>(timeout_ms);
}

struct PipeRequestResult {
  bool ok = false;
  std::string response;
  std::string error;
  DWORD error_code = ERROR_SUCCESS;
};

PipeRequestResult SendWindowsServicePipeRequest(const std::string& request,
                                                DWORD timeout_ms) {
  PipeRequestResult result;
  const DWORD wait_ms =
      timeout_ms == 0 ? 1 : (timeout_ms > 3000 ? 3000 : timeout_ms);
  if (WaitNamedPipeW(kEntropyVpnServicePipeName, wait_ms) == 0) {
    result.error_code = GetLastError();
    result.error = "EntropyVPN service pipe is not available: " +
                   ErrorMessage(result.error_code);
    return result;
  }

  ScopedHandle pipe(CreateFileW(kEntropyVpnServicePipeName,
                                GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                                OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                                nullptr));
  if (pipe.get() == INVALID_HANDLE_VALUE) {
    result.error_code = GetLastError();
    result.error = "Could not open EntropyVPN service pipe: " +
                   ErrorMessage(result.error_code);
    return result;
  }

  DWORD mode = PIPE_READMODE_MESSAGE;
  SetNamedPipeHandleState(pipe.get(), &mode, nullptr, nullptr);

  DWORD written = 0;
  const BOOL write_ok = WriteFile(
      pipe.get(), request.data(), static_cast<DWORD>(request.size()),
      &written, nullptr);
  if (write_ok == 0) {
    result.error_code = GetLastError();
    result.error = "Could not write to EntropyVPN service pipe: " +
                   ErrorMessage(result.error_code);
    return result;
  }
  const size_t written_size = static_cast<size_t>(written);
  if (written_size != request.size()) {
    result.error_code = ERROR_WRITE_FAULT;
    result.error = "Could not write complete EntropyVPN service request: wrote " +
                   std::to_string(written_size) + " of " +
                   std::to_string(request.size()) + " bytes.";
    return result;
  }
  FlushFileBuffers(pipe.get());

  std::vector<char> buffer(8192);
  while (true) {
    DWORD read = 0;
    const BOOL read_ok =
        ReadFile(pipe.get(), buffer.data(), static_cast<DWORD>(buffer.size()),
                 &read, nullptr);
    if (read_ok != 0 && read > 0) {
      result.response.append(buffer.data(), buffer.data() + read);
      break;
    }
    const DWORD read_error = GetLastError();
    if (read_error == ERROR_MORE_DATA) {
      if (read > 0) {
        result.response.append(buffer.data(), buffer.data() + read);
      }
      continue;
    }
    break;
  }

  result.ok = true;
  return result;
}

std::wstring ParentDirectory(const std::wstring& path) {
  const size_t slash = path.find_last_of(L"\\/");
  if (slash == std::wstring::npos) {
    return path;
  }
  if (slash == 0) {
    return path.substr(0, 1);
  }
  return path.substr(0, slash);
}

std::wstring RunnerModuleDirectory() {
  std::wstring buffer(MAX_PATH, L'\0');
  DWORD length = GetModuleFileNameW(nullptr, buffer.data(),
                                    static_cast<DWORD>(buffer.size()));
  while (length == buffer.size()) {
    buffer.resize(buffer.size() * 2);
    length = GetModuleFileNameW(nullptr, buffer.data(),
                                static_cast<DWORD>(buffer.size()));
  }
  if (length == 0) {
    return std::wstring();
  }
  buffer.resize(length);
  return ParentDirectory(buffer);
}

bool FileExistsAtPath(const std::wstring& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

void AddCandidateRoot(std::vector<std::wstring>* roots,
                      std::unordered_set<std::wstring>* seen,
                      std::wstring start) {
  if (start.empty()) {
    return;
  }
  std::replace(start.begin(), start.end(), L'/', L'\\');
  std::wstring current = start;
  while (!current.empty()) {
    const std::wstring key = NormalizePathKey(current);
    if (key.empty() || !seen->insert(key).second) {
      break;
    }
    roots->push_back(current);
    const std::wstring parent = ParentDirectory(current);
    if (parent == current) {
      break;
    }
    current = parent;
  }
}

std::wstring ResolveWindowsServiceHelperPath() {
  std::vector<std::wstring> roots;
  std::unordered_set<std::wstring> seen;

  DWORD current_required = GetCurrentDirectoryW(0, nullptr);
  if (current_required > 0) {
    std::wstring current_directory(current_required, L'\0');
    const DWORD written = GetCurrentDirectoryW(
        current_required, current_directory.data());
    if (written > 0 && written < current_required) {
      current_directory.resize(written);
      AddCandidateRoot(&roots, &seen, current_directory);
    }
  }
  AddCandidateRoot(&roots, &seen, RunnerModuleDirectory());

  for (const std::wstring& root : roots) {
    std::wstring candidate = root;
    if (!candidate.empty() && candidate.back() != L'\\' &&
        candidate.back() != L'/') {
      candidate.push_back(L'\\');
    }
    candidate.append(kEntropyVpnServiceExecutableName);
    if (FileExistsAtPath(candidate)) {
      return candidate;
    }
  }
  return std::wstring();
}

std::wstring QuoteWindowsCommandArgument(const std::wstring& argument) {
  if (argument.empty()) {
    return L"\"\"";
  }
  bool needs_quotes = false;
  for (wchar_t c : argument) {
    if (c == L' ' || c == L'\t' || c == L'"') {
      needs_quotes = true;
      break;
    }
  }
  if (!needs_quotes) {
    return argument;
  }

  std::wstring quoted = L"\"";
  size_t backslashes = 0;
  for (wchar_t c : argument) {
    if (c == L'\\') {
      ++backslashes;
      continue;
    }
    if (c == L'"') {
      quoted.append(backslashes * 2 + 1, L'\\');
      quoted.push_back(c);
      backslashes = 0;
      continue;
    }
    quoted.append(backslashes, L'\\');
    backslashes = 0;
    quoted.push_back(c);
  }
  quoted.append(backslashes * 2, L'\\');
  quoted.push_back(L'"');
  return quoted;
}

std::wstring BuildHelperProcessCommandLine(
    const std::wstring& helper_path,
    const std::vector<std::string>& args) {
  std::wstring command_line = QuoteWindowsCommandArgument(helper_path);
  for (const std::string& arg : args) {
    command_line.push_back(L' ');
    command_line.append(QuoteWindowsCommandArgument(WideFromUtf8(arg)));
  }
  return command_line;
}

void ReadPipeToString(HANDLE pipe, std::string* output) {
  char buffer[4096];
  while (true) {
    DWORD read = 0;
    const BOOL ok =
        ReadFile(pipe, buffer, static_cast<DWORD>(sizeof(buffer)), &read,
                 nullptr);
    if (ok == 0 || read == 0) {
      break;
    }
    output->append(buffer, buffer + read);
  }
}

struct HelperProcessResult {
  bool ok = false;
  std::string stdout_text;
  std::string stderr_text;
  DWORD exit_code = 1;
  std::string error;
};

HelperProcessResult RunWindowsServiceHelperProcess(
    const std::vector<std::string>& args,
    DWORD timeout_ms,
    const std::string& direct_error) {
  HelperProcessResult result;
  const std::wstring helper_path = ResolveWindowsServiceHelperPath();
  if (helper_path.empty()) {
    result.error =
        "EntropyVPN service pipe request failed and entropy_vpn_service.exe "
        "was not found for fallback: " +
        direct_error;
    return result;
  }

  SECURITY_ATTRIBUTES pipe_security{};
  pipe_security.nLength = sizeof(pipe_security);
  pipe_security.bInheritHandle = TRUE;

  HANDLE stdout_read_raw = nullptr;
  HANDLE stdout_write_raw = nullptr;
  HANDLE stderr_read_raw = nullptr;
  HANDLE stderr_write_raw = nullptr;
  if (CreatePipe(&stdout_read_raw, &stdout_write_raw, &pipe_security, 0) == 0 ||
      CreatePipe(&stderr_read_raw, &stderr_write_raw, &pipe_security, 0) == 0) {
    const DWORD error = GetLastError();
    CloseHandleIfValid(&stdout_read_raw);
    CloseHandleIfValid(&stdout_write_raw);
    CloseHandleIfValid(&stderr_read_raw);
    CloseHandleIfValid(&stderr_write_raw);
    result.error = "Could not create service helper capture pipes: " +
                   ErrorMessage(error);
    return result;
  }

  ScopedHandle stdout_read(stdout_read_raw);
  ScopedHandle stdout_write(stdout_write_raw);
  ScopedHandle stderr_read(stderr_read_raw);
  ScopedHandle stderr_write(stderr_write_raw);
  SetHandleInformation(stdout_read.get(), HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(stderr_read.get(), HANDLE_FLAG_INHERIT, 0);

  STARTUPINFOW startup_info{};
  startup_info.cb = sizeof(startup_info);
  startup_info.dwFlags = STARTF_USESTDHANDLES;
  startup_info.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
  startup_info.hStdOutput = stdout_write.get();
  startup_info.hStdError = stderr_write.get();

  PROCESS_INFORMATION process_info{};
  std::wstring command_line = BuildHelperProcessCommandLine(helper_path, args);
  const BOOL created = CreateProcessW(
      helper_path.c_str(), command_line.data(), nullptr, nullptr, TRUE,
      CREATE_NO_WINDOW, nullptr, nullptr, &startup_info, &process_info);
  if (created == 0) {
    const DWORD error = GetLastError();
    result.error = "Could not start EntropyVPN service helper process: " +
                   ErrorMessage(error);
    return result;
  }

  ScopedHandle process(process_info.hProcess);
  ScopedHandle thread(process_info.hThread);
  stdout_write.reset();
  stderr_write.reset();

  const DWORD wait_result = WaitForSingleObject(process.get(), timeout_ms);
  if (wait_result == WAIT_TIMEOUT) {
    TerminateProcess(process.get(), WAIT_TIMEOUT);
    WaitForSingleObject(process.get(), 5000);
  }

  DWORD exit_code = 1;
  GetExitCodeProcess(process.get(), &exit_code);
  result.exit_code = exit_code;
  ReadPipeToString(stdout_read.get(), &result.stdout_text);
  ReadPipeToString(stderr_read.get(), &result.stderr_text);

  if (wait_result == WAIT_TIMEOUT) {
    result.error = "EntropyVPN service helper process timed out.";
    return result;
  }
  if (wait_result == WAIT_FAILED) {
    const DWORD error = GetLastError();
    result.error = "EntropyVPN service helper wait failed: " +
                   ErrorMessage(error);
    return result;
  }

  result.ok = true;
  return result;
}

EncodableValue RunWindowsServiceHelper(const EncodableMap& arguments) {
  const auto start = std::chrono::steady_clock::now();
  EncodableMap response;
  std::vector<std::string> args;
  if (!ReadStringListAllowEmpty(arguments, "args", &args)) {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }

  int64_t timeout_argument = 5000;
  ReadInt64(arguments, "timeoutMs", &timeout_argument);
  const DWORD timeout_ms = ClampTimeoutMs(timeout_argument, 5000);

  std::string request;
  std::string build_error;
  if (!BuildWindowsServiceRequest(args, &request, &build_error)) {
    AddFailureMessage(&response, "build-request", build_error,
                      ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }

  std::string transport = "direct_pipe";
  std::string stdout_text;
  std::string stderr_text;
  DWORD exit_code = 0;
  std::string direct_error;

  const PipeRequestResult direct_result =
      SendWindowsServicePipeRequest(request, timeout_ms);
  if (!direct_result.ok || direct_result.response.empty()) {
    direct_error = direct_result.ok
                       ? "EntropyVPN service pipe returned no response."
                       : direct_result.error;
    transport = "helper_process";
    const HelperProcessResult helper_result =
        RunWindowsServiceHelperProcess(args, timeout_ms, direct_error);
    if (!helper_result.ok) {
      AddFailureMessage(&response, "helper-process", helper_result.error);
      response.insert_or_assign(EncodableValue("transport"),
                                EncodableValue(transport));
      response.insert_or_assign(EncodableValue("directError"),
                                EncodableValue(direct_error));
      const auto elapsed =
          std::chrono::duration_cast<std::chrono::milliseconds>(
              std::chrono::steady_clock::now() - start);
      response.insert_or_assign(EncodableValue("elapsedMs"),
                                EncodableValue(static_cast<int64_t>(
                                    elapsed.count())));
      return EncodableValue(std::move(response));
    }
    stdout_text = helper_result.stdout_text;
    stderr_text = helper_result.stderr_text;
    exit_code = helper_result.exit_code;
  } else {
    stdout_text = direct_result.response;
  }

  ParsedServiceResponse parsed =
      ParseWindowsServiceResponse(stdout_text, stderr_text, exit_code);
  if (!parsed.ok) {
    AddFailureMessage(&response, "service-response", parsed.error,
                      exit_code == 0 ? ERROR_GEN_FAILURE : exit_code);
    response.insert_or_assign(EncodableValue("transport"),
                              EncodableValue(transport));
    if (!direct_error.empty()) {
      response.insert_or_assign(EncodableValue("directError"),
                                EncodableValue(direct_error));
    }
    response.insert_or_assign(EncodableValue("fields"),
                              EncodableValue(ServiceFieldsToEncodable(
                                  parsed.fields)));
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start);
    response.insert_or_assign(EncodableValue("elapsedMs"),
                              EncodableValue(static_cast<int64_t>(
                                  elapsed.count())));
    return EncodableValue(std::move(response));
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - start);
  response.insert_or_assign(EncodableValue("fields"),
                            EncodableValue(ServiceFieldsToEncodable(
                                parsed.fields)));
  response.insert_or_assign(EncodableValue("transport"),
                            EncodableValue(transport));
  if (!direct_error.empty()) {
    response.insert_or_assign(EncodableValue("directError"),
                              EncodableValue(direct_error));
  }
  response.insert_or_assign(EncodableValue("elapsedMs"),
                            EncodableValue(static_cast<int64_t>(
                                elapsed.count())));
  AddSuccess(&response);
  return EncodableValue(std::move(response));
}

int64_t ParseServiceInt64(
    const std::unordered_map<std::string, std::string>& fields,
    const std::string& key,
    int64_t fallback = 0) {
  const std::string value = ServiceFieldValue(fields, key);
  if (value.empty()) {
    return fallback;
  }
  char* end = nullptr;
  const long long parsed = std::strtoll(value.c_str(), &end, 10);
  return end != nullptr && *end == '\0' ? parsed : fallback;
}

void AddServiceRouteResult(
    EncodableList* routes,
    const std::unordered_map<std::string, std::string>& fields,
    const std::string& prefix,
    const std::string& interface_alias,
    int64_t interface_index) {
  const std::string destination_prefix =
      ServiceFieldValue(fields, prefix + "destinationPrefix");
  const std::string next_hop = ServiceFieldValue(fields, prefix + "nextHop");
  if (destination_prefix.empty() || next_hop.empty()) {
    return;
  }

  EncodableMap route;
  route.emplace(EncodableValue("DestinationPrefix"),
                EncodableValue(destination_prefix));
  route.emplace(EncodableValue("NextHop"), EncodableValue(next_hop));
  route.emplace(EncodableValue("Status"),
                EncodableValue(ServiceFieldValue(fields, prefix + "status")));
  route.emplace(EncodableValue("InterfaceAlias"),
                EncodableValue(interface_alias));
  route.emplace(EncodableValue("InterfaceIndex"),
                EncodableValue(interface_index));
  routes->emplace_back(EncodableValue(std::move(route)));
}

bool ServiceRoutingFieldsToResponse(
    const std::unordered_map<std::string, std::string>& fields,
    EncodableMap* response) {
  if (ServiceFieldValue(fields, "resultOk") != "1") {
    return false;
  }

  const std::string interface_alias =
      DecodeServiceField(fields, "interfaceAliasB64");
  const int64_t interface_index = ParseServiceInt64(fields, "interfaceIndex");
  const std::string remote_address = ServiceFieldValue(fields, "remoteAddress");
  const std::string next_hop = ServiceFieldValue(fields, "nextHop");
  if (interface_alias.empty() || interface_index <= 0 ||
      remote_address.empty() || next_hop.empty()) {
    return false;
  }

  response->insert_or_assign(
      EncodableValue("elapsedMs"),
      EncodableValue(ParseServiceInt64(fields, "elapsedMs")));
  response->insert_or_assign(EncodableValue("remoteAddress"),
                             EncodableValue(remote_address));
  response->insert_or_assign(EncodableValue("interfaceAlias"),
                             EncodableValue(interface_alias));
  response->insert_or_assign(EncodableValue("interfaceIndex"),
                             EncodableValue(interface_index));
  response->insert_or_assign(
      EncodableValue("sourceAddress"),
      EncodableValue(ServiceFieldValue(fields, "sourceAddress")));
  response->insert_or_assign(EncodableValue("nextHop"),
                             EncodableValue(next_hop));
  response->insert_or_assign(
      EncodableValue("hardwareInterface"),
      EncodableValue(ServiceFieldValue(fields, "hardwareInterface") == "1"));
  response->insert_or_assign(
      EncodableValue("virtual"),
      EncodableValue(ServiceFieldValue(fields, "virtual") == "1"));

  EncodableList routes;
  const int64_t route_count = ParseServiceInt64(fields, "routeCount");
  if (route_count > 0) {
    routes.reserve(static_cast<size_t>(route_count));
    for (int64_t i = 0; i < route_count; ++i) {
      AddServiceRouteResult(&routes, fields,
                            "route." + std::to_string(i) + ".",
                            interface_alias, interface_index);
    }
  } else {
    EncodableMap route;
    route.emplace(
        EncodableValue("DestinationPrefix"),
        EncodableValue(ServiceFieldValue(fields, "destinationPrefix")));
    route.emplace(EncodableValue("NextHop"), EncodableValue(next_hop));
    route.emplace(EncodableValue("Status"),
                  EncodableValue(ServiceFieldValue(fields, "routeStatus")));
    route.emplace(EncodableValue("InterfaceAlias"),
                  EncodableValue(interface_alias));
    route.emplace(EncodableValue("InterfaceIndex"),
                  EncodableValue(interface_index));
    routes.emplace_back(EncodableValue(std::move(route)));
  }
  response->insert_or_assign(EncodableValue("routes"),
                             EncodableValue(std::move(routes)));
  AddSuccess(response);
  return true;
}

void AddSetupKind(EncodableValue* value, const std::string& setup_kind) {
  auto* response = std::get_if<EncodableMap>(value);
  if (response == nullptr) {
    return;
  }
  response->insert_or_assign(EncodableValue("setupKind"),
                             EncodableValue(setup_kind));
}

bool EncodableResponseOk(const EncodableValue& value) {
  const auto* response = std::get_if<EncodableMap>(&value);
  if (response == nullptr) {
    return false;
  }
  const auto found = response->find(EncodableValue("ok"));
  if (found == response->end()) {
    return false;
  }
  const auto* ok = std::get_if<bool>(&found->second);
  return ok != nullptr && *ok;
}

bool ServiceXrayTunIpv4FieldsToResponse(
    const std::unordered_map<std::string, std::string>& fields,
    EncodableMap* response) {
  if (ServiceFieldValue(fields, "resultOk") != "1") {
    return false;
  }

  const std::string interface_alias =
      DecodeServiceField(fields, "interfaceAliasB64");
  const int64_t interface_index = ParseServiceInt64(fields, "interfaceIndex");
  if (interface_alias.empty() || interface_index <= 0) {
    return false;
  }

  response->insert_or_assign(
      EncodableValue("elapsedMs"),
      EncodableValue(ParseServiceInt64(fields, "elapsedMs")));
  response->insert_or_assign(
      EncodableValue("waitMs"),
      EncodableValue(ParseServiceInt64(fields, "waitMs")));
  response->insert_or_assign(
      EncodableValue("configureMs"),
      EncodableValue(ParseServiceInt64(fields, "configureMs")));
  response->insert_or_assign(
      EncodableValue("routeMs"),
      EncodableValue(ParseServiceInt64(fields, "routeMs")));
  response->insert_or_assign(EncodableValue("interfaceAlias"),
                             EncodableValue(interface_alias));
  response->insert_or_assign(EncodableValue("interfaceIndex"),
                             EncodableValue(interface_index));
  response->insert_or_assign(EncodableValue("status"),
                             EncodableValue(ServiceFieldValue(fields,
                                                              "status")));
  response->insert_or_assign(
      EncodableValue("addressStatus"),
      EncodableValue(ServiceFieldValue(fields, "addressStatus")));
  response->insert_or_assign(
      EncodableValue("metricStatus"),
      EncodableValue(ServiceFieldValue(fields, "metricStatus")));
  response->insert_or_assign(
      EncodableValue("dnsStatus"),
      EncodableValue(ServiceFieldValue(fields, "dnsStatus")));
  response->insert_or_assign(
      EncodableValue("attempts"),
      EncodableValue(ParseServiceInt64(fields, "attempts")));
  response->insert_or_assign(
      EncodableValue("retrySleepMs"),
      EncodableValue(ParseServiceInt64(fields, "retrySleepMs")));
  response->insert_or_assign(
      EncodableValue("interfaceChangeWaits"),
      EncodableValue(ParseServiceInt64(fields, "interfaceChangeWaits")));
  response->insert_or_assign(
      EncodableValue("highResWaits"),
      EncodableValue(ParseServiceInt64(fields, "highResWaits")));
  response->insert_or_assign(
      EncodableValue("fallbackSleepWaits"),
      EncodableValue(ParseServiceInt64(fields, "fallbackSleepWaits")));
  response->insert_or_assign(
      EncodableValue("yieldWaits"),
      EncodableValue(ParseServiceInt64(fields, "yieldWaits")));
  response->insert_or_assign(
      EncodableValue("configureTotalMs"),
      EncodableValue(ParseServiceInt64(fields, "configureTotalMs")));
  response->insert_or_assign(
      EncodableValue("routeTotalMs"),
      EncodableValue(ParseServiceInt64(fields, "routeTotalMs")));
  response->insert_or_assign(
      EncodableValue("lastRetryStep"),
      EncodableValue(ServiceFieldValue(fields, "lastRetryStep")));
  response->insert_or_assign(
      EncodableValue("lastRetryWait"),
      EncodableValue(ServiceFieldValue(fields, "lastRetryWait")));
  response->insert_or_assign(
      EncodableValue("lastRetryErrorCode"),
      EncodableValue(ParseServiceInt64(fields, "lastRetryErrorCode")));
  response->insert_or_assign(
      EncodableValue("lastRetryRoutePrefix"),
      EncodableValue(ServiceFieldValue(fields, "lastRetryRoutePrefix")));

  EncodableList routes;
  const int64_t route_count = ParseServiceInt64(fields, "routeCount");
  if (route_count > 0) {
    routes.reserve(static_cast<size_t>(route_count));
    for (int64_t i = 0; i < route_count; ++i) {
      AddServiceRouteResult(&routes, fields,
                            "route." + std::to_string(i) + ".",
                            interface_alias, interface_index);
    }
  }
  response->insert_or_assign(EncodableValue("routes"),
                             EncodableValue(std::move(routes)));
  response->insert_or_assign(EncodableValue("setupKind"),
                             EncodableValue("serviceIpv4"));
  response->insert_or_assign(EncodableValue("path"),
                             EncodableValue("service"));
  AddSuccess(response);
  return true;
}

bool TryPrepareXrayTunIpv4ViaService(
    const std::string& interface_alias,
    const std::string& address,
    const std::string& dns_servers,
    int64_t timeout_ms,
    int64_t prefix_length,
    int64_t metric,
    EncodableMap* response) {
  const std::vector<std::string> service_args = {
      "prepare-xray-tun-ipv4-routes",
      "--interface-alias",
      interface_alias,
      "--timeout-ms",
      std::to_string(timeout_ms),
      "--address",
      address,
      "--prefix-length",
      std::to_string(prefix_length),
      "--metric",
      std::to_string(metric),
      "--dns-servers",
      dns_servers,
  };

  std::string request;
  std::string build_error;
  if (!BuildWindowsServiceRequest(service_args, &request, &build_error)) {
    return false;
  }

  std::string stdout_text;
  std::string stderr_text;
  DWORD exit_code = 0;
  const DWORD service_timeout_ms = ClampTimeoutMs(timeout_ms + 5500, 8000);
  const PipeRequestResult direct_result =
      SendWindowsServicePipeRequest(request, service_timeout_ms);
  if (!direct_result.ok || direct_result.response.empty()) {
    const HelperProcessResult helper_result = RunWindowsServiceHelperProcess(
        service_args, service_timeout_ms, direct_result.error);
    if (!helper_result.ok) {
      return false;
    }
    stdout_text = helper_result.stdout_text;
    stderr_text = helper_result.stderr_text;
    exit_code = helper_result.exit_code;
  } else {
    stdout_text = direct_result.response;
  }

  const ParsedServiceResponse parsed =
      ParseWindowsServiceResponse(stdout_text, stderr_text, exit_code);
  return parsed.ok &&
         ServiceXrayTunIpv4FieldsToResponse(parsed.fields, response);
}

bool TryPrepareServerRoutingViaService(const std::vector<std::string>& args,
                                       DWORD timeout_ms,
                                       EncodableMap* response) {
  std::string request;
  std::string build_error;
  if (!BuildWindowsServiceRequest(args, &request, &build_error)) {
    return false;
  }

  std::string stdout_text;
  std::string stderr_text;
  DWORD exit_code = 0;
  const PipeRequestResult direct_result =
      SendWindowsServicePipeRequest(request, timeout_ms);
  if (!direct_result.ok || direct_result.response.empty()) {
    const HelperProcessResult helper_result =
        RunWindowsServiceHelperProcess(args, timeout_ms, direct_result.error);
    if (!helper_result.ok) {
      return false;
    }
    stdout_text = helper_result.stdout_text;
    stderr_text = helper_result.stderr_text;
    exit_code = helper_result.exit_code;
  } else {
    stdout_text = direct_result.response;
  }

  const ParsedServiceResponse parsed =
      ParseWindowsServiceResponse(stdout_text, stderr_text, exit_code);
  return parsed.ok && ServiceRoutingFieldsToResponse(parsed.fields, response);
}

EncodableValue PrepareTunServerRouting(const EncodableMap& arguments) {
  EncodableMap response;
  std::string server;
  if (!ReadString(arguments, "server", &server) || TrimAscii(server).empty()) {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }
  server = TrimAscii(server);

  std::string tun_ip_mode = "ipv4";
  ReadString(arguments, "tunIpMode", &tun_ip_mode);
  if (tun_ip_mode != "ipv4" && tun_ip_mode != "ipv6" &&
      tun_ip_mode != "dualStack") {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }

  bool use_service = false;
  ReadBool(arguments, "useService", &use_service);
  const ADDRESS_FAMILY literal_family = AddressFamilyForText(server);
  const bool domain = literal_family == AF_UNSPEC;
  if (use_service &&
      (tun_ip_mode == "ipv4" || tun_ip_mode == "dualStack") &&
      (domain || literal_family == AF_INET)) {
    std::vector<std::string> service_args;
    if (domain) {
      service_args = {"prepare-domain-server-route", "--host", server,
                      "--tun-ip-mode", tun_ip_mode};
    } else {
      service_args = {"prepare-ipv4-server-route", "--remote-address", server};
    }
    if (TryPrepareServerRoutingViaService(service_args, 5000, &response)) {
      response.insert_or_assign(EncodableValue("path"),
                                EncodableValue("service"));
      return EncodableValue(std::move(response));
    }
    response.clear();
  }

  DWORD resolve_error = NO_ERROR;
  const std::vector<std::string> addresses =
      ResolveServerRoutingAddresses(server, tun_ip_mode, &resolve_error);
  if (addresses.empty()) {
    AddFailure(&response, domain ? "resolve" : "remoteAddress",
               resolve_error == NO_ERROR ? ERROR_NOT_FOUND : resolve_error);
    return EncodableValue(std::move(response));
  }

  EncodableValue prepared = PrepareServerRoutesForAddresses(addresses);
  if (auto* prepared_map = std::get_if<EncodableMap>(&prepared)) {
    prepared_map->insert_or_assign(EncodableValue("path"),
                                   EncodableValue("native"));
    if (domain) {
      EncodableList resolved;
      resolved.reserve(addresses.size());
      for (const auto& address : addresses) {
        resolved.emplace_back(EncodableValue(address));
      }
      prepared_map->insert_or_assign(EncodableValue("resolvedAddresses"),
                                     EncodableValue(std::move(resolved)));
    }
  }
  return prepared;
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

EncodableValue PrepareXrayTunRoutes(const EncodableMap& arguments) {
  EncodableMap response;
  std::string interface_alias;
  if (!ReadString(arguments, "interfaceAlias", &interface_alias) ||
      interface_alias.empty()) {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }

  std::string tun_ip_mode = "ipv4";
  ReadString(arguments, "tunIpMode", &tun_ip_mode);
  if (tun_ip_mode != "ipv4" && tun_ip_mode != "ipv6" &&
      tun_ip_mode != "dualStack") {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }

  std::string ipv4_address = "172.19.0.1";
  std::string dns_servers;
  int64_t timeout_ms = 2500;
  int64_t prefix_length = 30;
  int64_t metric = 1;
  bool use_service = false;
  bool route_only_allowed = false;
  ReadString(arguments, "address", &ipv4_address);
  ReadString(arguments, "dnsServers", &dns_servers);
  ReadInt64(arguments, "timeoutMs", &timeout_ms);
  ReadInt64(arguments, "prefixLength", &prefix_length);
  ReadInt64(arguments, "metric", &metric);
  ReadBool(arguments, "useService", &use_service);
  ReadBool(arguments, "routeOnlyAllowed", &route_only_allowed);

  if (dns_servers.empty() || timeout_ms < 1 || timeout_ms > 30000 ||
      prefix_length < 0 || prefix_length > 32 || metric < 0 ||
      metric > 9999) {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }

  if (tun_ip_mode == "ipv4") {
    if (use_service &&
        TryPrepareXrayTunIpv4ViaService(interface_alias, ipv4_address,
                                        dns_servers, timeout_ms,
                                        prefix_length, metric, &response)) {
      return EncodableValue(std::move(response));
    }

    if (!use_service) {
      EncodableValue fast_setup = PrepareXrayTunIpv4Routes(arguments);
      if (EncodableResponseOk(fast_setup)) {
        AddSetupKind(&fast_setup, "fastNativeApi");
        return fast_setup;
      }
    }
  }

  if (route_only_allowed) {
    EncodableValue route_only_setup =
        PrepareXrayTunNativeSetup(arguments, false);
    if (EncodableResponseOk(route_only_setup)) {
      AddSetupKind(&route_only_setup, "routeOnly");
      return route_only_setup;
    }
  }

  EncodableValue full_setup = PrepareXrayTunNativeSetup(arguments, true);
  if (EncodableResponseOk(full_setup)) {
    AddSetupKind(&full_setup, "full");
  }
  return full_setup;
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

EncodableValue RemoveRoutes(const EncodableMap& arguments) {
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

    if (route == nullptr || interface_index_argument <= 0 ||
        destination_prefix.empty() || next_hop_text.empty()) {
      route_result.emplace(EncodableValue("Status"),
                           EncodableValue("failed"));
      route_result.emplace(EncodableValue("Error"),
                           EncodableValue("invalid route arguments"));
      route_results.emplace_back(EncodableValue(std::move(route_result)));
      continue;
    }

    std::string status;
    const DWORD result = RemoveRouteByPrefix(
        destination_prefix, next_hop_text,
        static_cast<NET_IFINDEX>(interface_index_argument), &status);
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

EncodableValue StartWindowsService(const EncodableMap& arguments) {
  EncodableMap response;
  std::string service_name;
  int64_t timeout_ms_argument = 1500;
  ReadInt64(arguments, "timeoutMs", &timeout_ms_argument);
  if (!ReadString(arguments, "serviceName", &service_name) ||
      service_name.empty() || timeout_ms_argument < 0) {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }
  if (timeout_ms_argument > 10000) {
    timeout_ms_argument = 10000;
  }

  const auto start = std::chrono::steady_clock::now();
  auto elapsed_ms = [&]() -> int64_t {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now() - start)
        .count();
  };
  auto fail = [&](const std::string& step, DWORD error) {
    AddFailure(&response, step, error);
    response.insert_or_assign(EncodableValue("elapsedMs"),
                              EncodableValue(elapsed_ms()));
    return EncodableValue(std::move(response));
  };

  const std::wstring wide_service_name = WideFromUtf8(service_name);
  if (wide_service_name.empty()) {
    return fail("arguments", ERROR_INVALID_PARAMETER);
  }

  ScopedServiceHandle scm(
      OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT));
  if (scm.get() == nullptr) {
    return fail("open-scm", GetLastError());
  }

  ScopedServiceHandle service(
      OpenServiceW(scm.get(), wide_service_name.c_str(),
                   SERVICE_QUERY_STATUS | SERVICE_START));
  if (service.get() == nullptr) {
    return fail("open-service", GetLastError());
  }

  auto query_status = [&](SERVICE_STATUS_PROCESS* status) -> DWORD {
    DWORD bytes_needed = 0;
    if (QueryServiceStatusEx(service.get(), SC_STATUS_PROCESS_INFO,
                             reinterpret_cast<LPBYTE>(status),
                             sizeof(SERVICE_STATUS_PROCESS),
                             &bytes_needed) == 0) {
      return GetLastError();
    }
    return NO_ERROR;
  };

  SERVICE_STATUS_PROCESS status{};
  DWORD query_result = query_status(&status);
  if (query_result != NO_ERROR) {
    return fail("query-status", query_result);
  }

  const bool already_running = status.dwCurrentState == SERVICE_RUNNING;
  bool start_requested = false;
  DWORD start_error = NO_ERROR;
  if (!already_running && status.dwCurrentState != SERVICE_START_PENDING) {
    if (StartServiceW(service.get(), 0, nullptr) == 0) {
      start_error = GetLastError();
      if (start_error != ERROR_SERVICE_ALREADY_RUNNING) {
        return fail("start-service", start_error);
      }
    } else {
      start_requested = true;
    }
  }

  const auto deadline = start + std::chrono::milliseconds(timeout_ms_argument);
  bool timed_out = false;
  while (status.dwCurrentState != SERVICE_RUNNING) {
    query_result = query_status(&status);
    if (query_result != NO_ERROR) {
      return fail("query-status", query_result);
    }
    if (status.dwCurrentState == SERVICE_RUNNING) {
      break;
    }
    if (std::chrono::steady_clock::now() >= deadline) {
      timed_out = true;
      break;
    }
    DWORD sleep_ms = status.dwWaitHint / 10;
    if (sleep_ms < 50) {
      sleep_ms = 50;
    } else if (sleep_ms > 250) {
      sleep_ms = 250;
    }
    Sleep(sleep_ms);
  }

  response.insert_or_assign(EncodableValue("serviceName"),
                            EncodableValue(service_name));
  response.insert_or_assign(EncodableValue("state"),
                            EncodableValue(ServiceStateToString(
                                status.dwCurrentState)));
  response.insert_or_assign(EncodableValue("stateCode"),
                            EncodableValue(static_cast<int64_t>(
                                status.dwCurrentState)));
  response.insert_or_assign(EncodableValue("running"),
                            EncodableValue(status.dwCurrentState ==
                                           SERVICE_RUNNING));
  response.insert_or_assign(EncodableValue("alreadyRunning"),
                            EncodableValue(already_running));
  response.insert_or_assign(EncodableValue("startRequested"),
                            EncodableValue(start_requested));
  response.insert_or_assign(EncodableValue("timedOut"),
                            EncodableValue(timed_out));
  response.insert_or_assign(EncodableValue("processId"),
                            EncodableValue(static_cast<int64_t>(
                                status.dwProcessId)));
  response.insert_or_assign(EncodableValue("checkpoint"),
                            EncodableValue(static_cast<int64_t>(
                                status.dwCheckPoint)));
  response.insert_or_assign(EncodableValue("waitHintMs"),
                            EncodableValue(static_cast<int64_t>(
                                status.dwWaitHint)));
  if (start_error != NO_ERROR) {
    response.insert_or_assign(EncodableValue("startError"),
                              EncodableValue(ErrorMessage(start_error)));
    response.insert_or_assign(EncodableValue("startErrorCode"),
                              EncodableValue(static_cast<int64_t>(
                                  start_error)));
  }
  response.insert_or_assign(EncodableValue("elapsedMs"),
                            EncodableValue(elapsed_ms()));
  AddSuccess(&response);
  return EncodableValue(std::move(response));
}

EncodableValue TerminateProcessTreeNative(const EncodableMap& arguments) {
  const auto start = std::chrono::steady_clock::now();
  EncodableMap response;
  int64_t pid_argument = 0;
  if (!ReadInt64(arguments, "pid", &pid_argument) || pid_argument <= 0 ||
      pid_argument > std::numeric_limits<DWORD>::max()) {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }

  int64_t wait_ms_argument = 500;
  ReadInt64(arguments, "waitMs", &wait_ms_argument);
  const DWORD wait_ms = ClampTimeoutMs(wait_ms_argument, 500);
  const DWORD root_pid = static_cast<DWORD>(pid_argument);

  std::vector<ProcessSnapshotEntry> processes;
  const DWORD snapshot_result = SnapshotProcesses(&processes);
  std::vector<DWORD> pids = snapshot_result == NO_ERROR
                                ? CollectProcessTreePids(root_pid, processes)
                                : std::vector<DWORD>{root_pid};
  if (pids.empty()) {
    pids.push_back(root_pid);
  }

  std::unordered_set<DWORD> seen;
  std::vector<DWORD> unique_pids;
  unique_pids.reserve(pids.size());
  for (DWORD pid : pids) {
    if (pid != 0 && seen.insert(pid).second) {
      unique_pids.push_back(pid);
    }
  }

  std::vector<DWORD> terminated_pids;
  std::vector<DWORD> exited_pids;
  std::vector<DWORD> failed_pids;
  DWORD first_error = NO_ERROR;
  for (DWORD process_id : unique_pids) {
    const ProcessTerminationResult termination =
        TerminateSingleProcess(process_id, wait_ms);
    if (termination.success) {
      if (termination.already_exited) {
        exited_pids.push_back(process_id);
      } else {
        terminated_pids.push_back(process_id);
      }
    } else {
      failed_pids.push_back(process_id);
      if (first_error == NO_ERROR) {
        first_error = termination.error;
      }
    }
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - start);
  response.insert_or_assign(EncodableValue("success"),
                            EncodableValue(failed_pids.empty()));
  response.insert_or_assign(EncodableValue("elapsedMs"),
                            EncodableValue(static_cast<int64_t>(
                                elapsed.count())));
  response.insert_or_assign(EncodableValue("processCount"),
                            EncodableValue(static_cast<int64_t>(
                                processes.size())));
  response.insert_or_assign(EncodableValue("terminatedCount"),
                            EncodableValue(static_cast<int64_t>(
                                terminated_pids.size())));
  response.insert_or_assign(EncodableValue("failedCount"),
                            EncodableValue(static_cast<int64_t>(
                                failed_pids.size())));
  if (snapshot_result != NO_ERROR) {
    response.insert_or_assign(EncodableValue("snapshotError"),
                              EncodableValue(ErrorMessage(snapshot_result)));
    response.insert_or_assign(
        EncodableValue("snapshotErrorCode"),
        EncodableValue(static_cast<int64_t>(snapshot_result)));
  }
  if (first_error != NO_ERROR) {
    response.insert_or_assign(EncodableValue("error"),
                              EncodableValue(ErrorMessage(first_error)));
    response.insert_or_assign(EncodableValue("errorCode"),
                              EncodableValue(static_cast<int64_t>(
                                  first_error)));
  }
  AddPidList(&response, "pids", unique_pids);
  AddPidList(&response, "terminatedPids", terminated_pids);
  AddPidList(&response, "exitedPids", exited_pids);
  AddPidList(&response, "failedPids", failed_pids);
  AddSuccess(&response);
  return EncodableValue(std::move(response));
}

EncodableValue StopStaleCoreProcessesNative(const EncodableMap& arguments) {
  const auto start = std::chrono::steady_clock::now();
  EncodableMap response;
  std::string binary_path;
  if (!ReadString(arguments, "binaryPath", &binary_path) ||
      binary_path.empty()) {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }

  int64_t current_pid_argument = GetCurrentProcessId();
  ReadInt64(arguments, "currentPid", &current_pid_argument);
  int64_t wait_ms_argument = 500;
  ReadInt64(arguments, "waitMs", &wait_ms_argument);
  const DWORD wait_ms = ClampTimeoutMs(wait_ms_argument, 500);

  std::vector<ProcessSnapshotEntry> processes;
  const DWORD snapshot_result = SnapshotProcesses(&processes);
  if (snapshot_result != NO_ERROR) {
    AddFailure(&response, "snapshot-processes", snapshot_result);
    return EncodableValue(std::move(response));
  }

  const std::wstring target_key = NormalizePathKey(WideFromUtf8(binary_path));
  const DWORD current_pid =
      current_pid_argument > 0 &&
              current_pid_argument <= std::numeric_limits<DWORD>::max()
          ? static_cast<DWORD>(current_pid_argument)
          : GetCurrentProcessId();

  std::vector<DWORD> matched_pids;
  std::vector<DWORD> terminate_order;
  std::unordered_set<DWORD> scheduled_pids;
  for (const ProcessSnapshotEntry& process : processes) {
    if (process.pid == 0 || process.pid == current_pid ||
        process.path_key.empty() || process.path_key != target_key) {
      continue;
    }
    matched_pids.push_back(process.pid);
    const std::vector<DWORD> tree_pids =
        CollectProcessTreePids(process.pid, processes);
    for (DWORD tree_pid : tree_pids) {
      if (tree_pid != 0 && tree_pid != current_pid &&
          scheduled_pids.insert(tree_pid).second) {
        terminate_order.push_back(tree_pid);
      }
    }
  }

  std::vector<DWORD> terminated_pids;
  std::vector<DWORD> exited_pids;
  std::vector<DWORD> failed_pids;
  DWORD first_error = NO_ERROR;
  for (DWORD process_id : terminate_order) {
    const ProcessTerminationResult termination =
        TerminateSingleProcess(process_id, wait_ms);
    if (termination.success) {
      if (termination.already_exited) {
        exited_pids.push_back(process_id);
      } else {
        terminated_pids.push_back(process_id);
      }
    } else {
      failed_pids.push_back(process_id);
      if (first_error == NO_ERROR) {
        first_error = termination.error;
      }
    }
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - start);
  response.insert_or_assign(EncodableValue("success"),
                            EncodableValue(failed_pids.empty()));
  response.insert_or_assign(EncodableValue("elapsedMs"),
                            EncodableValue(static_cast<int64_t>(
                                elapsed.count())));
  response.insert_or_assign(EncodableValue("processCount"),
                            EncodableValue(static_cast<int64_t>(
                                processes.size())));
  response.insert_or_assign(EncodableValue("matchedCount"),
                            EncodableValue(static_cast<int64_t>(
                                matched_pids.size())));
  response.insert_or_assign(EncodableValue("terminatedCount"),
                            EncodableValue(static_cast<int64_t>(
                                terminated_pids.size())));
  response.insert_or_assign(EncodableValue("failedCount"),
                            EncodableValue(static_cast<int64_t>(
                                failed_pids.size())));
  if (first_error != NO_ERROR) {
    response.insert_or_assign(EncodableValue("error"),
                              EncodableValue(ErrorMessage(first_error)));
    response.insert_or_assign(EncodableValue("errorCode"),
                              EncodableValue(static_cast<int64_t>(
                                  first_error)));
  }
  AddPidList(&response, "matchedPids", matched_pids);
  AddPidList(&response, "terminatedPids", terminated_pids);
  AddPidList(&response, "exitedPids", exited_pids);
  AddPidList(&response, "failedPids", failed_pids);
  AddSuccess(&response);
  return EncodableValue(std::move(response));
}

EncodableValue ExpandSplitTunnelProcessTree(const EncodableMap& arguments) {
  EncodableMap response;
  std::vector<std::string> selected_paths;
  if (!ReadStringList(arguments, "selectedPaths", &selected_paths)) {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }

  const auto start = std::chrono::steady_clock::now();
  std::unordered_set<std::wstring> selected_path_keys;
  selected_path_keys.reserve(selected_paths.size());
  for (const std::string& path : selected_paths) {
    const std::wstring key = NormalizePathKey(WideFromUtf8(path));
    if (!key.empty()) {
      selected_path_keys.insert(key);
    }
  }

  if (selected_path_keys.empty()) {
    response.insert_or_assign(EncodableValue("paths"),
                              EncodableValue(EncodableList()));
    response.insert_or_assign(EncodableValue("processCount"),
                              EncodableValue(static_cast<int64_t>(0)));
    response.insert_or_assign(EncodableValue("rootCount"),
                              EncodableValue(static_cast<int64_t>(0)));
    response.insert_or_assign(EncodableValue("elapsedMs"),
                              EncodableValue(static_cast<int64_t>(0)));
    AddSuccess(&response);
    return EncodableValue(std::move(response));
  }

  std::vector<ProcessSnapshotEntry> processes;
  DWORD result = SnapshotProcesses(&processes);
  if (result != NO_ERROR) {
    AddFailure(&response, "snapshot-processes", result);
    return EncodableValue(std::move(response));
  }

  std::unordered_map<DWORD, std::vector<size_t>> children_by_parent;
  children_by_parent.reserve(processes.size());
  std::deque<DWORD> queue;
  std::unordered_set<DWORD> queued_roots;
  for (size_t index = 0; index < processes.size(); ++index) {
    const ProcessSnapshotEntry& process = processes[index];
    children_by_parent[process.parent_pid].push_back(index);
    if (!process.path_key.empty() &&
        selected_path_keys.find(process.path_key) != selected_path_keys.end() &&
        queued_roots.insert(process.pid).second) {
      queue.push_back(process.pid);
    }
  }

  std::unordered_set<DWORD> visited_pids;
  visited_pids.reserve(processes.size());
  std::unordered_map<std::wstring, std::string> descendants_by_path;
  while (!queue.empty()) {
    const DWORD parent_pid = queue.front();
    queue.pop_front();
    if (!visited_pids.insert(parent_pid).second) {
      continue;
    }

    const auto children = children_by_parent.find(parent_pid);
    if (children == children_by_parent.end()) {
      continue;
    }
    for (const size_t child_index : children->second) {
      const ProcessSnapshotEntry& child = processes[child_index];
      if (!child.path_key.empty() && !child.path.empty() &&
          selected_path_keys.find(child.path_key) == selected_path_keys.end() &&
          descendants_by_path.find(child.path_key) ==
              descendants_by_path.end()) {
        descendants_by_path.emplace(child.path_key, child.path);
      }
      queue.push_back(child.pid);
    }
  }

  std::vector<std::string> descendant_paths;
  descendant_paths.reserve(descendants_by_path.size());
  for (const auto& entry : descendants_by_path) {
    descendant_paths.push_back(entry.second);
  }
  std::sort(descendant_paths.begin(), descendant_paths.end(),
            [](const std::string& left, const std::string& right) {
              const std::string left_key = LowerPathNameKey(left);
              const std::string right_key = LowerPathNameKey(right);
              if (left_key != right_key) {
                return left_key < right_key;
              }
              return ToLowerAscii(left) < ToLowerAscii(right);
            });

  EncodableList paths;
  paths.reserve(descendant_paths.size());
  for (const std::string& path : descendant_paths) {
    paths.emplace_back(EncodableValue(path));
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - start);
  response.insert_or_assign(EncodableValue("paths"),
                            EncodableValue(std::move(paths)));
  response.insert_or_assign(EncodableValue("processCount"),
                            EncodableValue(static_cast<int64_t>(
                                processes.size())));
  response.insert_or_assign(EncodableValue("rootCount"),
                            EncodableValue(static_cast<int64_t>(
                                queued_roots.size())));
  response.insert_or_assign(EncodableValue("elapsedMs"),
                            EncodableValue(static_cast<int64_t>(
                                elapsed.count())));
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

        if (call.method_name() == kPrepareTunServerRoutingMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(PrepareTunServerRouting(*arguments));
          return;
        }

        if (call.method_name() == kPrepareXrayTunRoutesMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(PrepareXrayTunRoutes(*arguments));
          return;
        }

        if (call.method_name() == kPrepareServerRoutesMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(PrepareServerRoutes(*arguments));
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

        if (call.method_name() == kRemoveRoutesMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(RemoveRoutes(*arguments));
          return;
        }

        if (call.method_name() == kCaptureSystemProxyMethod) {
          result->Success(CaptureSystemProxy());
          return;
        }

        if (call.method_name() == kSetSystemProxyMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(SetSystemProxy(*arguments));
          return;
        }

        if (call.method_name() == kRelaunchAsAdministratorMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(RelaunchAsAdministrator(*arguments));
          return;
        }

        if (call.method_name() == kStartWindowsServiceMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(StartWindowsService(*arguments));
          return;
        }

        if (call.method_name() == kRunWindowsServiceHelperMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(RunWindowsServiceHelper(*arguments));
          return;
        }

        if (call.method_name() == kStopStaleCoreProcessesMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(StopStaleCoreProcessesNative(*arguments));
          return;
        }

        if (call.method_name() == kTerminateProcessTreeMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(TerminateProcessTreeNative(*arguments));
          return;
        }

        if (call.method_name() == kExpandSplitTunnelProcessTreeMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(ExpandSplitTunnelProcessTree(*arguments));
          return;
        }

        {
          result->NotImplemented();
          return;
        }
      });

  return channel;
}
