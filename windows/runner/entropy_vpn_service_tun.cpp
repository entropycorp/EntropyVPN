#include <winsock2.h>
#include <ws2tcpip.h>

#include "entropy_vpn_service_tun.h"

#include "entropy_vpn_native_tun.h"
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
  AddField(&response, "remoteAddress", remote_address);
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
