#ifndef RUNNER_WINDOWS_RUNTIME_CHANNEL_SUPPORT_H_
#define RUNNER_WINDOWS_RUNTIME_CHANNEL_SUPPORT_H_

#include <flutter/encodable_value.h>

#include <winsock2.h>
#include <windows.h>

#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <vector>

namespace entropy_vpn::windows_runtime {

inline constexpr char kWindowsRuntimeMethodChannelName[] =
    "entropy_vpn/windows_runtime";
inline constexpr char kWindowsRuntimeEventChannelName[] =
    "entropy_vpn/windows_runtime_events";

using EncodableList = flutter::EncodableList;
using EncodableMap = flutter::EncodableMap;
using EncodableValue = flutter::EncodableValue;

class WindowsRuntimeWorker {
 public:
  static WindowsRuntimeWorker& Instance();

  void Post(std::function<void()> task);

 private:
  WindowsRuntimeWorker();
  ~WindowsRuntimeWorker();

  WindowsRuntimeWorker(const WindowsRuntimeWorker&) = delete;
  WindowsRuntimeWorker& operator=(const WindowsRuntimeWorker&) = delete;

  void Run();

  std::mutex mutex_;
  std::condition_variable condition_;
  std::queue<std::function<void()>> tasks_;
  bool stopping_ = false;
  std::thread thread_;
};

const EncodableValue* FindValue(const EncodableMap& map, const char* key);
bool ReadInt64(const EncodableMap& map, const char* key, int64_t* value);
bool ReadString(const EncodableMap& map, const char* key, std::string* value);
bool ReadBool(const EncodableMap& map, const char* key, bool* value);
bool ReadStringList(const EncodableMap& map,
                    const char* key,
                    std::vector<std::string>* values);

bool IsTruthy(const EncodableMap& map, const char* key);
std::string MapString(const EncodableMap& map, const char* key);
int64_t MapInt64(const EncodableMap& map,
                 const char* key,
                 int64_t fallback = 0);

std::wstring PathJoinWide(const std::wstring& left,
                          const std::wstring& right);
std::wstring RuntimeExecutableDirectory();

EncodableMap MakeFailure(const std::string& step,
                         const std::string& message,
                         DWORD code = ERROR_GEN_FAILURE);
EncodableMap MakeFailureFromNativeMap(const EncodableMap& map,
                                      const std::string& fallback_step);

}  // namespace entropy_vpn::windows_runtime

#endif
