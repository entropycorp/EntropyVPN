#include "windows_runtime_channel_config.h"

#include "entropy_vpn_service_common.h"
#include "windows_runtime_channel_support.h"

namespace entropy_vpn::windows_runtime {
namespace {

constexpr wchar_t kNativeConfigDllName[] = L"entropy_vpn_native.dll";
constexpr char kEntropyBuildCoreConfigSymbol[] = "entropy_build_core_config";
constexpr char kEntropyFreeStringSymbol[] = "entropy_free_string";

}  // namespace

bool NativeConfigBuilder::Build(const std::string& profile_json,
                                const std::string& options_json,
                                std::string* config_json,
                                std::string* error) {
  if (!EnsureLoaded(error)) {
    return false;
  }

  char* error_message = nullptr;
  char* result =
      build_core_config_(profile_json.c_str(), options_json.c_str(),
                         &error_message);
  if (result == nullptr) {
    if (error_message != nullptr) {
      *error = error_message;
      free_string_(error_message);
    } else {
      *error = "Failed to build native runtime config.";
    }
    return false;
  }

  *config_json = result;
  free_string_(result);
  return true;
}

bool NativeConfigBuilder::EnsureLoaded(std::string* error) {
  if (build_core_config_ != nullptr && free_string_ != nullptr) {
    return true;
  }

  std::wstring dll_path = PathJoinWide(RuntimeExecutableDirectory(),
                                       kNativeConfigDllName);
  HMODULE library = LoadLibraryW(dll_path.c_str());
  if (library == nullptr) {
    library = LoadLibraryW(kNativeConfigDllName);
  }
  if (library == nullptr) {
    *error = "Could not load entropy_vpn_native.dll: " +
             entropy_vpn_service::ErrorMessage(GetLastError());
    return false;
  }

  auto build = reinterpret_cast<BuildCoreConfigFn>(
      GetProcAddress(library, kEntropyBuildCoreConfigSymbol));
  auto free_string = reinterpret_cast<FreeStringFn>(
      GetProcAddress(library, kEntropyFreeStringSymbol));
  if (build == nullptr || free_string == nullptr) {
    *error = "entropy_vpn_native.dll does not export the config builder.";
    FreeLibrary(library);
    return false;
  }

  library_ = library;
  build_core_config_ = build;
  free_string_ = free_string;
  return true;
}

}  // namespace entropy_vpn::windows_runtime
