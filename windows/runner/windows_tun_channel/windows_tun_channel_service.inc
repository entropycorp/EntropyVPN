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

