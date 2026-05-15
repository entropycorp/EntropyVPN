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
  response.insert_or_assign(EncodableValue("remoteAddress"),
                            EncodableValue(remote_address));
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

