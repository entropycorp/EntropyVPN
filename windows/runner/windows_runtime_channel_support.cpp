#include "windows_runtime_channel_support.h"

#include "entropy_vpn_service_common.h"

#include <utility>
#include <variant>

namespace entropy_vpn::windows_runtime {

WindowsRuntimeWorker& WindowsRuntimeWorker::Instance() {
  static WindowsRuntimeWorker worker;
  return worker;
}

void WindowsRuntimeWorker::Post(std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    tasks_.push(std::move(task));
  }
  condition_.notify_one();
}

WindowsRuntimeWorker::WindowsRuntimeWorker() {
  thread_ = std::thread([this]() { Run(); });
}

WindowsRuntimeWorker::~WindowsRuntimeWorker() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
  }
  condition_.notify_one();
  if (thread_.joinable()) {
    thread_.join();
  }
}

void WindowsRuntimeWorker::Run() {
  while (true) {
    std::function<void()> task;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      condition_.wait(lock, [this]() { return stopping_ || !tasks_.empty(); });
      if (stopping_ && tasks_.empty()) {
        return;
      }
      task = std::move(tasks_.front());
      tasks_.pop();
    }
    task();
  }
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

bool IsTruthy(const EncodableMap& map, const char* key) {
  const EncodableValue* value = FindValue(map, key);
  const auto* typed = value == nullptr ? nullptr : std::get_if<bool>(value);
  return typed != nullptr && *typed;
}

std::string MapString(const EncodableMap& map, const char* key) {
  const EncodableValue* value = FindValue(map, key);
  const auto* typed =
      value == nullptr ? nullptr : std::get_if<std::string>(value);
  return typed == nullptr ? std::string() : *typed;
}

int64_t MapInt64(const EncodableMap& map,
                 const char* key,
                 int64_t fallback) {
  int64_t value = fallback;
  ReadInt64(map, key, &value);
  return value;
}

std::wstring PathJoinWide(const std::wstring& left,
                          const std::wstring& right) {
  if (left.empty()) {
    return right;
  }
  if (left.back() == L'\\' || left.back() == L'/') {
    return left + right;
  }
  return left + L"\\" + right;
}

std::wstring RuntimeExecutableDirectory() {
  wchar_t module_path[MAX_PATH] = {};
  const DWORD length = GetModuleFileNameW(nullptr, module_path, MAX_PATH);
  if (length == 0 || length == MAX_PATH) {
    return std::wstring();
  }
  std::wstring path(module_path, length);
  const size_t separator = path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) {
    return std::wstring();
  }
  path.resize(separator);
  return path;
}

EncodableMap MakeFailure(const std::string& step,
                         const std::string& message,
                         DWORD code) {
  EncodableMap response;
  response.insert_or_assign(EncodableValue("ok"), EncodableValue(false));
  response.insert_or_assign(EncodableValue("failedStep"), EncodableValue(step));
  response.insert_or_assign(EncodableValue("error"), EncodableValue(message));
  response.insert_or_assign(EncodableValue("errorCode"),
                            EncodableValue(static_cast<int64_t>(code)));
  return response;
}

EncodableMap MakeFailureFromNativeMap(const EncodableMap& map,
                                      const std::string& fallback_step) {
  const std::string step = MapString(map, "failedStep").empty()
                               ? fallback_step
                               : MapString(map, "failedStep");
  const std::string message = MapString(map, "error").empty()
                                  ? "Native Windows runtime operation failed."
                                  : MapString(map, "error");
  return MakeFailure(step, message,
                     static_cast<DWORD>(MapInt64(map, "errorCode",
                                                 ERROR_GEN_FAILURE)));
}

}  // namespace entropy_vpn::windows_runtime
