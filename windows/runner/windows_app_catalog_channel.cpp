#include "windows_app_catalog_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <tlhelp32.h>
#include <windows.h>

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace {

constexpr char kWindowsAppCatalogChannelName[] =
    "entropy_vpn/windows_app_catalog";
constexpr char kListApplicationsMethod[] = "listApplications";
constexpr DWORD kProcessQueryLimitedInformation = 0x1000;
constexpr size_t kMaxPathBufferChars = 32768;

using EncodableList = flutter::EncodableList;
using EncodableMap = flutter::EncodableMap;
using EncodableValue = flutter::EncodableValue;

struct AppCatalogItem {
  std::string name;
  std::string path;
};

struct ComDeleter {
  template <typename T>
  void operator()(T* value) const {
    if (value != nullptr) {
      value->Release();
    }
  }
};

struct CoTaskMemDeleter {
  void operator()(wchar_t* value) const {
    if (value != nullptr) {
      CoTaskMemFree(value);
    }
  }
};

std::string Utf8FromWide(const std::wstring& value) {
  if (value.empty()) {
    return std::string();
  }
  const int required = WideCharToMultiByte(
      CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0,
      nullptr, nullptr);
  if (required <= 0) {
    return std::string();
  }
  std::string result;
  result.resize(required);
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      result.data(), required, nullptr, nullptr);
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
  std::wstring result;
  result.resize(required);
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), required);
  return result;
}

std::string ToLowerAscii(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char ch) {
                   return static_cast<char>(std::tolower(ch));
                 });
  return value;
}

std::string Trim(std::string value) {
  const auto first = std::find_if_not(value.begin(), value.end(),
                                      [](unsigned char ch) {
                                        return std::isspace(ch) != 0;
                                      });
  const auto last = std::find_if_not(value.rbegin(), value.rend(),
                                     [](unsigned char ch) {
                                       return std::isspace(ch) != 0;
                                     })
                        .base();
  if (first >= last) {
    return std::string();
  }
  return std::string(first, last);
}

bool EndsWithExe(const std::string& path) {
  const std::string lower = ToLowerAscii(path);
  return lower.size() >= 4 && lower.compare(lower.size() - 4, 4, ".exe") == 0;
}

bool FileExists(const std::string& path) {
  const std::wstring wide_path = WideFromUtf8(path);
  if (wide_path.empty()) {
    return false;
  }
  const DWORD attributes = GetFileAttributesW(wide_path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

std::string BasenameWithoutExtension(const std::string& path) {
  const std::filesystem::path fs_path(WideFromUtf8(path));
  return Utf8FromWide(fs_path.stem().wstring());
}

void AddAppItem(std::map<std::string, AppCatalogItem>* items,
                const std::string& raw_name,
                const std::string& raw_path) {
  if (items == nullptr) {
    return;
  }
  const std::string path = Trim(raw_path);
  if (path.empty() || !EndsWithExe(path) || !FileExists(path)) {
    return;
  }
  std::string name = Trim(raw_name);
  if (name.empty()) {
    name = BasenameWithoutExtension(path);
  }
  if (name.empty()) {
    return;
  }
  const std::string key = ToLowerAscii(path);
  items->try_emplace(key, AppCatalogItem{name, path});
}

std::wstring KnownFolderPath(REFKNOWNFOLDERID folder_id) {
  PWSTR raw_path = nullptr;
  if (SHGetKnownFolderPath(folder_id, 0, nullptr, &raw_path) != S_OK ||
      raw_path == nullptr) {
    return std::wstring();
  }
  std::unique_ptr<wchar_t, CoTaskMemDeleter> path(raw_path);
  return std::wstring(path.get());
}

std::string ResolveShortcutTarget(const std::filesystem::path& shortcut_path) {
  IShellLinkW* raw_link = nullptr;
  HRESULT result = CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                                   IID_PPV_ARGS(&raw_link));
  if (FAILED(result) || raw_link == nullptr) {
    return std::string();
  }
  std::unique_ptr<IShellLinkW, ComDeleter> link(raw_link);

  IPersistFile* raw_file = nullptr;
  result = link->QueryInterface(IID_PPV_ARGS(&raw_file));
  if (FAILED(result) || raw_file == nullptr) {
    return std::string();
  }
  std::unique_ptr<IPersistFile, ComDeleter> file(raw_file);

  result = file->Load(shortcut_path.c_str(), STGM_READ);
  if (FAILED(result)) {
    return std::string();
  }

  std::vector<wchar_t> target(kMaxPathBufferChars);
  result = link->GetPath(target.data(), static_cast<int>(target.size()),
                         nullptr, 0);
  if (FAILED(result) || target[0] == L'\0') {
    return std::string();
  }
  return Utf8FromWide(target.data());
}

void AddShortcutApplications(const std::wstring& root,
                             std::map<std::string, AppCatalogItem>* items) {
  if (root.empty() || items == nullptr) {
    return;
  }
  std::error_code error;
  if (!std::filesystem::exists(root, error)) {
    return;
  }

  std::filesystem::recursive_directory_iterator iterator(
      root, std::filesystem::directory_options::skip_permission_denied, error);
  const std::filesystem::recursive_directory_iterator end;
  while (!error && iterator != end) {
    const auto entry = *iterator;
    iterator.increment(error);
    if (!entry.is_regular_file(error)) {
      continue;
    }
    const auto path = entry.path();
    if (ToLowerAscii(Utf8FromWide(path.extension().wstring())) != ".lnk") {
      continue;
    }
    AddAppItem(items, Utf8FromWide(path.stem().wstring()),
               ResolveShortcutTarget(path));
  }
}

std::string QueryProcessImagePath(DWORD process_id) {
  if (process_id == 0) {
    return std::string();
  }
  HANDLE process =
      OpenProcess(kProcessQueryLimitedInformation, FALSE, process_id);
  if (process == nullptr) {
    return std::string();
  }

  std::vector<wchar_t> buffer(kMaxPathBufferChars);
  DWORD length = static_cast<DWORD>(buffer.size());
  const BOOL ok = QueryFullProcessImageNameW(process, 0, buffer.data(), &length);
  CloseHandle(process);
  if (!ok || length == 0) {
    return std::string();
  }
  return Utf8FromWide(std::wstring(buffer.data(), length));
}

void AddRunningApplications(std::map<std::string, AppCatalogItem>* items) {
  if (items == nullptr) {
    return;
  }
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) {
    return;
  }

  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  if (Process32FirstW(snapshot, &entry) == FALSE) {
    CloseHandle(snapshot);
    return;
  }

  do {
    const std::string path = QueryProcessImagePath(entry.th32ProcessID);
    AddAppItem(items, BasenameWithoutExtension(path), path);
  } while (Process32NextW(snapshot, &entry) != FALSE);

  CloseHandle(snapshot);
}

EncodableList ListApplications() {
  std::map<std::string, AppCatalogItem> by_path;
  AddShortcutApplications(KnownFolderPath(FOLDERID_StartMenu), &by_path);
  AddShortcutApplications(KnownFolderPath(FOLDERID_CommonStartMenu), &by_path);
  AddShortcutApplications(KnownFolderPath(FOLDERID_Desktop), &by_path);
  AddShortcutApplications(KnownFolderPath(FOLDERID_PublicDesktop), &by_path);
  AddRunningApplications(&by_path);

  std::vector<AppCatalogItem> apps;
  apps.reserve(by_path.size());
  for (const auto& entry : by_path) {
    apps.push_back(entry.second);
  }
  std::sort(apps.begin(), apps.end(), [](const AppCatalogItem& left,
                                         const AppCatalogItem& right) {
    const std::string left_name = ToLowerAscii(left.name);
    const std::string right_name = ToLowerAscii(right.name);
    if (left_name != right_name) {
      return left_name < right_name;
    }
    return ToLowerAscii(left.path) < ToLowerAscii(right.path);
  });

  EncodableList result;
  result.reserve(apps.size());
  for (const auto& app : apps) {
    EncodableMap item;
    item.emplace(EncodableValue("name"), EncodableValue(app.name));
    item.emplace(EncodableValue("path"), EncodableValue(app.path));
    result.emplace_back(EncodableValue(std::move(item)));
  }
  return result;
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateWindowsAppCatalogChannel(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, kWindowsAppCatalogChannelName,
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() == kListApplicationsMethod) {
          result->Success(EncodableValue(ListApplications()));
          return;
        }
        result->NotImplemented();
      });

  return channel;
}
