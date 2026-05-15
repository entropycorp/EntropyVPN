#include "entropy_vpn_native_tun.h"

#include "entropy_vpn_service_common.h"

#include <windns.h>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <tuple>

namespace entropy_vpn_service {

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

#define ENTROPY_VPN_NATIVE_TUN_ONLY
#define ENTROPY_VPN_NATIVE_TUN_HEADER_TYPES
#include "windows_tun_channel/windows_tun_channel_routes.inc"
#undef ENTROPY_VPN_NATIVE_TUN_HEADER_TYPES
#undef ENTROPY_VPN_NATIVE_TUN_ONLY

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

bool FlushDnsResolverCache(DWORD* error) {
  using DnsFlushResolverCacheFn = BOOL(WINAPI*)();
  HMODULE dnsapi = LoadLibraryW(L"dnsapi.dll");
  auto flush_resolver_cache =
      dnsapi == nullptr
          ? nullptr
          : reinterpret_cast<DnsFlushResolverCacheFn>(
                GetProcAddress(dnsapi, "DnsFlushResolverCache"));
  const BOOL flushed =
      flush_resolver_cache == nullptr ? FALSE : flush_resolver_cache();
  const DWORD last_error = flushed ? NO_ERROR : GetLastError();
  if (dnsapi != nullptr) {
    FreeLibrary(dnsapi);
  }
  if (error != nullptr) {
    *error = last_error;
  }
  return flushed != FALSE;
}

}  // namespace entropy_vpn_service
