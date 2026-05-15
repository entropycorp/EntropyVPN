#ifndef ENTROPY_VPN_NATIVE_TUN_FLUTTER_ONLY
#ifndef ENTROPY_VPN_NATIVE_TUN_HEADER_TYPES
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
#endif  // ENTROPY_VPN_NATIVE_TUN_HEADER_TYPES

constexpr DWORD kTunInterfacePollSleepMs = 1;

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
    Sleep(kTunInterfacePollSleepMs);
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
#endif  // ENTROPY_VPN_NATIVE_TUN_FLUTTER_ONLY

#ifndef ENTROPY_VPN_NATIVE_TUN_ONLY
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
#endif  // ENTROPY_VPN_NATIVE_TUN_ONLY

#ifndef ENTROPY_VPN_NATIVE_TUN_FLUTTER_ONLY
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
#endif  // ENTROPY_VPN_NATIVE_TUN_FLUTTER_ONLY

#ifndef ENTROPY_VPN_NATIVE_TUN_ONLY
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
  DWORD result = WaitForInterfaceAlias(
      WideFromUtf8(interface_alias), timeout_ms, &interface_index,
      &resolved_alias, &adapter_status, &wait_ms);
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
      DWORD flush_error = NO_ERROR;
      if (FlushDnsResolverCache(&flush_error)) {
        changes.push_back("dns-cache=cleared");
      } else {
        warnings.push_back("DNS cache: " + ErrorMessage(flush_error));
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
#endif  // ENTROPY_VPN_NATIVE_TUN_ONLY

#ifndef ENTROPY_VPN_NATIVE_TUN_FLUTTER_ONLY
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
#endif  // ENTROPY_VPN_NATIVE_TUN_FLUTTER_ONLY
