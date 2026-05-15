#include "entropy_vpn_service_common.h"

#include <tlhelp32.h>

#include <algorithm>
#include <cwctype>
#include <cstdint>
#include <deque>
#include <sstream>
#include <unordered_set>

namespace entropy_vpn_service {

const wchar_t kServiceName[] = L"EntropyVPNService";
const wchar_t kPipeName[] = L"\\\\.\\pipe\\EntropyVPNService";
const DWORD kPipeBufferSize = 1024 * 1024;

std::string Utf8FromWide(const std::wstring& value) {
  if (value.empty()) {
    return std::string();
  }
  const int required = WideCharToMultiByte(CP_UTF8, 0, value.data(),
                                           static_cast<int>(value.size()),
                                           nullptr, 0, nullptr, nullptr);
  if (required <= 0) {
    return std::string();
  }
  std::string result(static_cast<size_t>(required), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(),
                      static_cast<int>(value.size()), result.data(), required,
                      nullptr, nullptr);
  return result;
}

std::string Utf8FromWide(const wchar_t* value) {
  if (value == nullptr || value[0] == L'\0') {
    return std::string();
  }
  return Utf8FromWide(std::wstring(value));
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
  std::wstring result(static_cast<size_t>(required), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), required);
  return result;
}

std::string ErrorMessage(DWORD error) {
  if (error == ERROR_SUCCESS) {
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
  std::wstring wide(message, length);
  LocalFree(message);
  while (!wide.empty() &&
         (wide.back() == L'\r' || wide.back() == L'\n' ||
          wide.back() == L' ' || wide.back() == L'\t')) {
    wide.pop_back();
  }
  std::ostringstream stream;
  stream << Utf8FromWide(wide) << " (Code " << error << ")";
  return stream.str();
}

std::string ToLowerAscii(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char c) {
                   return static_cast<char>(
                       (c >= 'A' && c <= 'Z') ? (c + 32) : c);
                 });
  return value;
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
  return start == 0 ? value : value.substr(start);
}

std::vector<std::string> SplitCommaList(const std::string& value) {
  std::vector<std::string> items;
  size_t start = 0;
  while (start <= value.size()) {
    const size_t next = value.find(',', start);
    std::string item = value.substr(
        start, next == std::string::npos ? std::string::npos : next - start);
    item = TrimAscii(std::move(item));
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

bool IsRetryableNetworkSetupError(DWORD error) {
  return error == ERROR_NOT_FOUND || error == ERROR_NOT_READY ||
         error == ERROR_NOT_CONNECTED;
}

std::wstring Basename(const std::wstring& path) {
  const size_t slash = path.find_last_of(L"\\/");
  if (slash == std::wstring::npos) {
    return path;
  }
  return path.substr(slash + 1);
}

bool HasPathSeparator(const std::wstring& value) {
  return value.find(L'\\') != std::wstring::npos ||
         value.find(L'/') != std::wstring::npos;
}

std::wstring LowerWide(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(), [](wchar_t c) {
    return static_cast<wchar_t>(std::towlower(c));
  });
  return value;
}

std::wstring FullPath(const std::wstring& path) {
  DWORD required = GetFullPathNameW(path.c_str(), 0, nullptr, nullptr);
  if (required == 0) {
    return path;
  }
  std::wstring result(required, L'\0');
  DWORD written =
      GetFullPathNameW(path.c_str(), required, result.data(), nullptr);
  if (written == 0 || written >= required) {
    return path;
  }
  result.resize(written);
  return result;
}

std::wstring ModuleDirectory() {
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
  const size_t slash = buffer.find_last_of(L"\\/");
  if (slash == std::wstring::npos) {
    return std::wstring();
  }
  return buffer.substr(0, slash);
}

bool SamePath(const std::wstring& left, const std::wstring& right) {
  return LowerWide(FullPath(left)) == LowerWide(FullPath(right));
}

bool FileExists(const std::wstring& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

bool IsAllowedCoreBasename(const std::wstring& basename) {
  const std::wstring lower = LowerWide(basename);
  return lower == L"xray.exe" || lower == L"sing-box.exe";
}

std::wstring TrustedCoreExecutablePath(const std::wstring& basename) {
  const std::wstring directory = ModuleDirectory();
  if (directory.empty()) {
    return std::wstring();
  }
  return directory + L"\\cores\\" + basename;
}

std::wstring ResolveAllowedCoreExecutable(const std::wstring& executable) {
  const std::wstring basename = Basename(executable);
  if (!IsAllowedCoreBasename(basename)) {
    return std::wstring();
  }

  const std::wstring trusted = TrustedCoreExecutablePath(basename);
  if (trusted.empty() || !FileExists(trusted)) {
    return std::wstring();
  }
  if (SamePath(executable, trusted)) {
    return executable;
  }

  return trusted;
}

bool IsAllowedCoreExecutable(const std::wstring& executable) {
  return !ResolveAllowedCoreExecutable(executable).empty();
}

bool IsAllowedToolInvocation(const std::wstring& executable,
                             const std::vector<std::wstring>& args) {
  if (HasPathSeparator(executable)) {
    return false;
  }
  const std::string lower = ToLowerAscii(Utf8FromWide(Basename(executable)));
  if (lower == "fltmc.exe") {
    return args.empty();
  }
  return false;
}

std::string Base64Encode(const std::string& input) {
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

int Base64Value(char c) {
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

bool Base64Decode(const std::string& input, std::string* output) {
  output->clear();
  int value = 0;
  int bits = -8;
  for (char c : input) {
    if (c == '=') {
      break;
    }
    const int decoded = Base64Value(c);
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

std::map<std::string, std::string> ParseFields(const std::string& text) {
  std::map<std::string, std::string> fields;
  size_t start = 0;
  while (start <= text.size()) {
    size_t end = text.find('\n', start);
    if (end == std::string::npos) {
      end = text.size();
    }
    std::string line = text.substr(start, end - start);
    if (!line.empty() && line.back() == '\r') {
      line.pop_back();
    }
    const size_t equals = line.find('=');
    if (equals != std::string::npos) {
      fields[line.substr(0, equals)] = line.substr(equals + 1);
    }
    if (end == text.size()) {
      break;
    }
    start = end + 1;
  }
  return fields;
}

std::string BuildResponse(
    const std::vector<std::pair<std::string, std::string>>& fields) {
  std::string response;
  for (const auto& field : fields) {
    response.append(field.first);
    response.push_back('=');
    response.append(field.second);
    response.push_back('\n');
  }
  return response;
}

void AddTextField(std::vector<std::pair<std::string, std::string>>* fields,
                  const std::string& name,
                  const std::string& value) {
  fields->push_back(std::make_pair(name, Base64Encode(value)));
}

std::string OkResponse() {
  return BuildResponse({{"ok", "1"}});
}

std::string ErrorResponse(const std::string& message, DWORD code) {
  std::vector<std::pair<std::string, std::string>> fields;
  fields.push_back({"ok", "0"});
  fields.push_back({"errorCode", std::to_string(code)});
  AddTextField(&fields, "errorB64", message);
  return BuildResponse(fields);
}

bool ReadDecodedString(const std::map<std::string, std::string>& fields,
                       const std::string& key,
                       std::string* value) {
  const auto found = fields.find(key);
  if (found == fields.end()) {
    return false;
  }
  return Base64Decode(found->second, value);
}

std::wstring ReadDecodedWide(
    const std::map<std::string, std::string>& fields,
    const std::string& key) {
  std::string decoded;
  if (!ReadDecodedString(fields, key, &decoded)) {
    return std::wstring();
  }
  return WideFromUtf8(decoded);
}

DWORD ReadDword(const std::map<std::string, std::string>& fields,
                const std::string& key,
                DWORD fallback) {
  const auto found = fields.find(key);
  if (found == fields.end()) {
    return fallback;
  }
  return static_cast<DWORD>(std::wcstoul(WideFromUtf8(found->second).c_str(),
                                         nullptr, 10));
}

std::vector<std::wstring> ReadArguments(
    const std::map<std::string, std::string>& fields) {
  std::vector<std::wstring> args;
  const DWORD count = ReadDword(fields, "argCount", 0);
  args.reserve(count);
  for (DWORD index = 0; index < count; ++index) {
    args.push_back(ReadDecodedWide(fields, "arg" + std::to_string(index)));
  }
  return args;
}

std::wstring QuoteArgument(const std::wstring& argument) {
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

  std::wstring result = L"\"";
  size_t backslashes = 0;
  for (wchar_t c : argument) {
    if (c == L'\\') {
      ++backslashes;
      continue;
    }
    if (c == L'"') {
      result.append(backslashes * 2 + 1, L'\\');
      result.push_back(c);
      backslashes = 0;
      continue;
    }
    result.append(backslashes, L'\\');
    backslashes = 0;
    result.push_back(c);
  }
  result.append(backslashes * 2, L'\\');
  result.push_back(L'"');
  return result;
}

std::wstring BuildCommandLine(const std::wstring& executable,
                              const std::vector<std::wstring>& args) {
  std::wstring command_line = QuoteArgument(executable);
  for (const auto& arg : args) {
    command_line.push_back(L' ');
    command_line.append(QuoteArgument(arg));
  }
  return command_line;
}

ScopedHandle::ScopedHandle(HANDLE handle) : handle_(handle) {}

ScopedHandle::~ScopedHandle() {
  reset();
}

HANDLE ScopedHandle::get() const {
  return handle_;
}

void ScopedHandle::reset(HANDLE handle) {
  if (handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE) {
    CloseHandle(handle_);
  }
  handle_ = handle;
}

HANDLE ScopedHandle::release() {
  HANDLE handle = handle_;
  handle_ = nullptr;
  return handle;
}

void CloseHandleIfValid(HANDLE* handle) {
  if (handle != nullptr && *handle != nullptr && *handle != INVALID_HANDLE_VALUE) {
    CloseHandle(*handle);
    *handle = nullptr;
  }
}

void ReadPipeToString(HANDLE pipe, std::string* output) {
  char buffer[4096];
  while (true) {
    DWORD read = 0;
    const BOOL ok = ReadFile(pipe, buffer, static_cast<DWORD>(sizeof(buffer)),
                             &read, nullptr);
    if (ok == 0 || read == 0) {
      break;
    }
    output->append(buffer, buffer + read);
  }
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

}  // namespace entropy_vpn_service

