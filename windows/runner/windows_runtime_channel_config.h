#ifndef RUNNER_WINDOWS_RUNTIME_CHANNEL_CONFIG_H_
#define RUNNER_WINDOWS_RUNTIME_CHANNEL_CONFIG_H_

#include <winsock2.h>
#include <windows.h>

#include <string>

namespace entropy_vpn::windows_runtime {

class NativeConfigBuilder {
 public:
  bool Build(const std::string& profile_json,
             const std::string& options_json,
             std::string* config_json,
             std::string* error);

 private:
  using BuildCoreConfigFn = char* (*)(const char* profile_json,
                                      const char* options_json,
                                      char** error_message);
  using FreeStringFn = void (*)(char* value);

  bool EnsureLoaded(std::string* error);

  HMODULE library_ = nullptr;
  BuildCoreConfigFn build_core_config_ = nullptr;
  FreeStringFn free_string_ = nullptr;
};

}  // namespace entropy_vpn::windows_runtime

#endif
