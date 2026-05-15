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

