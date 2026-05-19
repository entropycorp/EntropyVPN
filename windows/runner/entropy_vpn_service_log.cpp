#include "entropy_vpn_service_log.h"

#include <windows.h>

#include <cstdio>
#include <mutex>

#include "entropy_vpn_service_common.h"

namespace entropy_vpn_service {
namespace {

std::mutex g_log_mutex;
constexpr long long kMaxLogBytes = 1024 * 1024;

std::wstring LogFilePath() {
  const std::wstring directory = ModuleDirectory();
  if (directory.empty()) {
    return std::wstring();
  }
  return directory + L"\\service.log";
}

std::string Timestamp() {
  SYSTEMTIME now{};
  GetSystemTime(&now);
  char buffer[32];
  std::snprintf(buffer, sizeof(buffer), "%04u-%02u-%02uT%02u:%02u:%02uZ",
                now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute,
                now.wSecond);
  return std::string(buffer);
}

}  // namespace

void LogLine(const std::string& message) {
  std::lock_guard<std::mutex> lock(g_log_mutex);
  const std::wstring path = LogFilePath();
  if (path.empty()) {
    return;
  }

  HANDLE file = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ,
                            nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }

  LARGE_INTEGER size{};
  if (GetFileSizeEx(file, &size) != 0 && size.QuadPart > kMaxLogBytes) {
    CloseHandle(file);
    file = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                       CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
      return;
    }
  }

  const std::string line = Timestamp() + " " + message + "\r\n";
  DWORD written = 0;
  WriteFile(file, line.data(), static_cast<DWORD>(line.size()), &written,
            nullptr);
  CloseHandle(file);
}

}  // namespace entropy_vpn_service
