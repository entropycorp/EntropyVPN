#include "entropy_vpn_service_common.h"

#include <algorithm>
#include <cwctype>
#include <cstdint>
#include <sstream>

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

void CloseHandleIfValid(HANDLE* handle) {
  if (handle != nullptr && *handle != nullptr && *handle != INVALID_HANDLE_VALUE) {
    CloseHandle(*handle);
    *handle = nullptr;
  }
}

}  // namespace entropy_vpn_service

