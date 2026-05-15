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

class PipeIoDeadline {
 public:
  explicit PipeIoDeadline(DWORD timeout_ms)
      : timeout_ms_(timeout_ms == 0 ? 1 : timeout_ms),
        start_(std::chrono::steady_clock::now()) {}

  DWORD RemainingMs() const {
    const auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                                std::chrono::steady_clock::now() - start_)
                                .count();
    if (elapsed_ms <= 0) {
      return timeout_ms_;
    }
    const uint64_t elapsed = static_cast<uint64_t>(elapsed_ms);
    if (elapsed >= timeout_ms_) {
      return 0;
    }
    return static_cast<DWORD>(timeout_ms_ - elapsed);
  }

 private:
  DWORD timeout_ms_;
  std::chrono::steady_clock::time_point start_;
};

struct PipeIoCompletion {
  DWORD bytes = 0;
  DWORD error = ERROR_SUCCESS;
};

void SetPipeIoError(PipeRequestResult* result,
                    const char* operation,
                    DWORD error) {
  result->error_code = error;
  result->error = std::string("Could not ") + operation +
                  " EntropyVPN service pipe: " + ErrorMessage(error);
}

void SetPipeIoTimeout(PipeRequestResult* result, const char* operation) {
  result->error_code = ERROR_TIMEOUT;
  result->error = std::string("Timed out while trying to ") + operation +
                  " EntropyVPN service pipe.";
}

void CancelPendingPipeIo(HANDLE pipe, OVERLAPPED* overlapped) {
  CancelIoEx(pipe, overlapped);
  DWORD ignored = 0;
  GetOverlappedResult(pipe, overlapped, &ignored, TRUE);
}

bool CompletePipeIo(HANDLE pipe,
                    OVERLAPPED* overlapped,
                    DWORD immediate_error,
                    DWORD immediate_bytes,
                    PipeIoDeadline* deadline,
                    const char* operation,
                    PipeRequestResult* result,
                    PipeIoCompletion* completion) {
  if (immediate_error == ERROR_IO_PENDING) {
    const DWORD wait_ms = deadline->RemainingMs();
    if (wait_ms == 0) {
      CancelPendingPipeIo(pipe, overlapped);
      SetPipeIoTimeout(result, operation);
      return false;
    }

    const DWORD wait_result = WaitForSingleObject(overlapped->hEvent, wait_ms);
    if (wait_result == WAIT_TIMEOUT) {
      CancelPendingPipeIo(pipe, overlapped);
      SetPipeIoTimeout(result, operation);
      return false;
    }
    if (wait_result == WAIT_FAILED) {
      SetPipeIoError(result, operation, GetLastError());
      return false;
    }
    if (wait_result != WAIT_OBJECT_0) {
      SetPipeIoError(result, operation, wait_result);
      return false;
    }

    DWORD bytes = 0;
    if (GetOverlappedResult(pipe, overlapped, &bytes, FALSE) == 0) {
      const DWORD error = GetLastError();
      if (error != ERROR_MORE_DATA) {
        SetPipeIoError(result, operation, error);
        return false;
      }
      completion->error = ERROR_MORE_DATA;
    } else {
      completion->error = ERROR_SUCCESS;
    }
    completion->bytes = bytes;
    return true;
  }

  if (immediate_error == ERROR_SUCCESS || immediate_error == ERROR_MORE_DATA) {
    DWORD bytes = immediate_bytes;
    DWORD overlapped_bytes = 0;
    const BOOL result_ok =
        GetOverlappedResult(pipe, overlapped, &overlapped_bytes, FALSE);
    if (result_ok != 0 || GetLastError() == ERROR_MORE_DATA) {
      if (overlapped_bytes > 0 || bytes == 0) {
        bytes = overlapped_bytes;
      }
    }
    completion->bytes = bytes;
    completion->error = immediate_error;
    return true;
  }

  SetPipeIoError(result, operation, immediate_error);
  return false;
}

bool WritePipeWithDeadline(HANDLE pipe,
                           const std::string& request,
                           PipeIoDeadline* deadline,
                           PipeRequestResult* result) {
  if (request.size() > std::numeric_limits<DWORD>::max()) {
    SetPipeIoError(result, "write to", ERROR_INVALID_PARAMETER);
    return false;
  }

  ScopedHandle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
  if (event.get() == nullptr) {
    SetPipeIoError(result, "create event for", GetLastError());
    return false;
  }

  OVERLAPPED overlapped{};
  overlapped.hEvent = event.get();
  DWORD written = 0;
  const BOOL write_ok =
      WriteFile(pipe, request.data(), static_cast<DWORD>(request.size()),
                &written, &overlapped);
  const DWORD immediate_error = write_ok != 0 ? ERROR_SUCCESS : GetLastError();

  PipeIoCompletion completion;
  if (!CompletePipeIo(pipe, &overlapped, immediate_error, written, deadline,
                      "write to", result, &completion)) {
    return false;
  }
  if (completion.error != ERROR_SUCCESS) {
    SetPipeIoError(result, "write to", completion.error);
    return false;
  }

  const size_t written_size = static_cast<size_t>(completion.bytes);
  if (written_size != request.size()) {
    result->error_code = ERROR_WRITE_FAULT;
    result->error =
        "Could not write complete EntropyVPN service request: wrote " +
        std::to_string(written_size) + " of " +
        std::to_string(request.size()) + " bytes.";
    return false;
  }
  return true;
}

bool ReadPipeMessageWithDeadline(HANDLE pipe,
                                 PipeIoDeadline* deadline,
                                 PipeRequestResult* result) {
  std::vector<char> buffer(8192);
  while (true) {
    ScopedHandle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    if (event.get() == nullptr) {
      SetPipeIoError(result, "create event for", GetLastError());
      return false;
    }

    OVERLAPPED overlapped{};
    overlapped.hEvent = event.get();
    DWORD read = 0;
    const BOOL read_ok =
        ReadFile(pipe, buffer.data(), static_cast<DWORD>(buffer.size()), &read,
                 &overlapped);
    const DWORD immediate_error = read_ok != 0 ? ERROR_SUCCESS : GetLastError();

    PipeIoCompletion completion;
    if (!CompletePipeIo(pipe, &overlapped, immediate_error, read, deadline,
                        "read from", result, &completion)) {
      return false;
    }
    if (completion.bytes > 0) {
      result->response.append(buffer.data(), buffer.data() + completion.bytes);
    }
    if (completion.error == ERROR_MORE_DATA) {
      if (completion.bytes == 0) {
        SetPipeIoError(result, "read from", ERROR_MORE_DATA);
        return false;
      }
      continue;
    }
    if (completion.error != ERROR_SUCCESS) {
      SetPipeIoError(result, "read from", completion.error);
      return false;
    }
    break;
  }

  result->ok = true;
  return true;
}

PipeRequestResult SendWindowsServicePipeRequest(const std::string& request,
                                                DWORD timeout_ms) {
  PipeRequestResult result;
  PipeIoDeadline deadline(timeout_ms);
  const DWORD remaining_ms = deadline.RemainingMs();
  const DWORD wait_ms = remaining_ms > 3000 ? 3000 : remaining_ms;
  if (wait_ms == 0) {
    SetPipeIoTimeout(&result, "wait for");
    return result;
  }
  if (WaitNamedPipeW(kPipeName, wait_ms) == 0) {
    result.error_code = GetLastError();
    result.error = "EntropyVPN service pipe is not available: " +
                   ErrorMessage(result.error_code);
    return result;
  }

  ScopedHandle pipe(CreateFileW(kPipeName,
                                GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                                OPEN_EXISTING,
                                FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED,
                                nullptr));
  if (pipe.get() == INVALID_HANDLE_VALUE) {
    result.error_code = GetLastError();
    result.error = "Could not open EntropyVPN service pipe: " +
                   ErrorMessage(result.error_code);
    return result;
  }

  DWORD mode = PIPE_READMODE_MESSAGE;
  SetNamedPipeHandleState(pipe.get(), &mode, nullptr, nullptr);

  if (!WritePipeWithDeadline(pipe.get(), request, &deadline, &result)) {
    return result;
  }
  ReadPipeMessageWithDeadline(pipe.get(), &deadline, &result);
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
  std::vector<std::wstring> wide_args;
  wide_args.reserve(args.size());
  for (const auto& arg : args) {
    wide_args.push_back(WideFromUtf8(arg));
  }
  std::wstring command_line = BuildCommandLine(helper_path, wide_args);
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

EncodableMap ServiceFieldsToEncodable(const ServiceFields& fields) {
  EncodableMap encoded;
  for (const auto& field : fields) {
    encoded.emplace(EncodableValue(field.first), EncodableValue(field.second));
  }
  return encoded;
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

void AddServiceRouteResult(
    EncodableList* routes,
    const ServiceFields& fields,
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
    const ServiceFields& fields,
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
    const ServiceFields& fields,
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

// Fire-and-result helper for prewarm/release-tun-adapter. Returns true if the
// service responded with resultOk=1. Populates `status_out` with the status
// field ("created", "already-warm") and `elapsed_ms_out` with elapsedMs (0 if
// absent). All outputs may be null.
bool TryPrewarmTunAdapterViaService(const std::string& interface_alias,
                                    DWORD timeout_ms,
                                    std::string* status_out,
                                    int64_t* elapsed_ms_out,
                                    int64_t* interface_index_out,
                                    std::string* error_out) {
  const std::vector<std::string> service_args = {
      "prewarm-tun-adapter",
      "--interface-alias",
      interface_alias,
  };
  std::string request;
  std::string build_error;
  if (!BuildWindowsServiceRequest(service_args, &request, &build_error)) {
    if (error_out) *error_out = build_error;
    return false;
  }

  std::string stdout_text;
  std::string stderr_text;
  DWORD exit_code = 0;
  const PipeRequestResult direct_result =
      SendWindowsServicePipeRequest(request, timeout_ms);
  if (!direct_result.ok || direct_result.response.empty()) {
    const HelperProcessResult helper_result = RunWindowsServiceHelperProcess(
        service_args, timeout_ms, direct_result.error);
    if (!helper_result.ok) {
      if (error_out) *error_out = helper_result.error;
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
  if (!parsed.ok ||
      ServiceFieldValue(parsed.fields, "resultOk") != "1") {
    if (error_out) {
      *error_out = ServiceFieldValue(parsed.fields, "failedStep");
      if (error_out->empty()) *error_out = "service-error";
    }
    return false;
  }
  if (status_out) *status_out = ServiceFieldValue(parsed.fields, "status");
  if (elapsed_ms_out) {
    *elapsed_ms_out = ParseServiceInt64(parsed.fields, "elapsedMs");
  }
  if (interface_index_out) {
    *interface_index_out =
        ParseServiceInt64(parsed.fields, "interfaceIndex");
  }
  return true;
}

bool TryReleaseTunAdapterViaService(DWORD timeout_ms,
                                    bool* released_out,
                                    std::string* error_out) {
  const std::vector<std::string> service_args = {"release-tun-adapter"};
  std::string request;
  std::string build_error;
  if (!BuildWindowsServiceRequest(service_args, &request, &build_error)) {
    if (error_out) *error_out = build_error;
    return false;
  }

  std::string stdout_text;
  std::string stderr_text;
  DWORD exit_code = 0;
  const PipeRequestResult direct_result =
      SendWindowsServicePipeRequest(request, timeout_ms);
  if (!direct_result.ok || direct_result.response.empty()) {
    const HelperProcessResult helper_result = RunWindowsServiceHelperProcess(
        service_args, timeout_ms, direct_result.error);
    if (!helper_result.ok) {
      if (error_out) *error_out = helper_result.error;
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
  if (!parsed.ok ||
      ServiceFieldValue(parsed.fields, "resultOk") != "1") {
    if (error_out) {
      *error_out = ServiceFieldValue(parsed.fields, "failedStep");
      if (error_out->empty()) *error_out = "service-error";
    }
    return false;
  }
  if (released_out) {
    *released_out = ServiceFieldValue(parsed.fields, "released") == "1";
  }
  return true;
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

