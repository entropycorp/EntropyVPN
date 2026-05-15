#include "windows_runtime_channel_controller.h"

#include "entropy_vpn_native_tun.h"
#include "entropy_vpn_service_common.h"
#include "entropy_vpn_service_protocol.h"
#include "windows_runtime_channel_config.h"

#include <flutter/event_sink.h>

#include <shlobj.h>
#include <wininet.h>
#include <winsock2.h>
#include <ws2tcpip.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <limits>
#include <memory>
#include <mutex>
#include <queue>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_set>
#include <utility>
#include <vector>

namespace {

constexpr wchar_t kInternetSettingsRegistryPath[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
constexpr wchar_t kEntropyVpnServiceExecutableName[] =
    L"entropy_vpn_service.exe";
constexpr int64_t kXrayTunSetupTimeoutMs = 7000;
constexpr int64_t kXrayTunRouteOnlyTimeoutMs = 2500;
constexpr char kRuntimePhaseDisconnected[] = "disconnected";
constexpr char kRuntimePhaseStarting[] = "starting";
constexpr char kRuntimePhaseRunning[] = "running";
constexpr char kRuntimePhaseStopping[] = "stopping";
constexpr char kRuntimePhaseError[] = "error";

using EncodableList = flutter::EncodableList;
using EncodableMap = flutter::EncodableMap;
using EncodableValue = flutter::EncodableValue;
using entropy_vpn::windows_runtime::NativeConfigBuilder;
using namespace entropy_vpn_service;

#include "windows_tun_channel/windows_tun_channel_common.inc"
#define ENTROPY_VPN_NATIVE_TUN_FLUTTER_ONLY
#include "windows_tun_channel/windows_tun_channel_routes.inc"
#undef ENTROPY_VPN_NATIVE_TUN_FLUTTER_ONLY
#include "windows_tun_channel/windows_tun_channel_proxy.inc"
#include "windows_tun_channel/windows_tun_channel_service.inc"
#include "windows_tun_channel/windows_tun_channel_methods.inc"

struct RuntimeRoute {
  std::string destination_prefix;
  int64_t interface_index = 0;
  std::string next_hop;
  bool remove_when_unused = true;
};

struct ProxySnapshot {
  bool enabled = false;
  std::string server;
  std::string override_value;
  bool captured = false;
};

struct RuntimeState {
  std::atomic<bool> stop_requested{false};
  std::atomic<bool> cleaned{false};
  std::string phase = kRuntimePhaseDisconnected;
  std::string run_id;
  std::string core;
  std::string traffic_mode;
  std::string tun_ip_mode;
  std::string binary_path;
  std::string working_directory;
  std::string runtime_directory;
  std::string config_path;
  std::string stdout_path;
  std::string stderr_path;
  std::string service_run_id;
  bool use_service = false;
  bool started = false;
  DWORD pid = 0;
  HANDLE process = nullptr;
  HANDLE watcher_process = nullptr;
  ProxySnapshot proxy_snapshot;
  std::vector<RuntimeRoute> server_routes;
  std::vector<RuntimeRoute> tun_routes;
};

std::string JoinStrings(const std::vector<std::string>& values,
                        const char* separator) {
  std::ostringstream stream;
  for (size_t i = 0; i < values.size(); ++i) {
    if (i > 0) {
      stream << separator;
    }
    stream << values[i];
  }
  return stream.str();
}

std::string PathDirectory(const std::string& path) {
  const size_t separator = path.find_last_of("\\/");
  return separator == std::string::npos ? std::string() : path.substr(0, separator);
}

std::string PathBasename(const std::string& path) {
  const size_t separator = path.find_last_of("\\/");
  return separator == std::string::npos ? path : path.substr(separator + 1);
}

std::wstring PathJoinWide(const std::wstring& left, const std::wstring& right) {
  if (left.empty()) {
    return right;
  }
  if (left.back() == L'\\' || left.back() == L'/') {
    return left + right;
  }
  return left + L"\\" + right;
}

std::string JsonEscape(const std::string& value) {
  std::ostringstream stream;
  for (unsigned char ch : value) {
    switch (ch) {
      case '"':
        stream << "\\\"";
        break;
      case '\\':
        stream << "\\\\";
        break;
      case '\b':
        stream << "\\b";
        break;
      case '\f':
        stream << "\\f";
        break;
      case '\n':
        stream << "\\n";
        break;
      case '\r':
        stream << "\\r";
        break;
      case '\t':
        stream << "\\t";
        break;
      default:
        if (ch < 0x20) {
          char buffer[7] = {};
          std::snprintf(buffer, sizeof(buffer), "\\u%04x", ch);
          stream << buffer;
        } else {
          stream << static_cast<char>(ch);
        }
        break;
    }
  }
  return stream.str();
}

void AppendJsonStringField(std::string* json,
                           bool* first,
                           const char* key,
                           const std::string& value) {
  if (value.empty()) {
    return;
  }
  if (!*first) {
    json->append(",");
  }
  *first = false;
  json->append("\"");
  json->append(key);
  json->append("\":\"");
  json->append(JsonEscape(value));
  json->append("\"");
}

std::string InjectRuntimeConfigOptions(
    const std::string& options_json,
    const std::string& tun_interface_name,
    const std::string& outbound_bind_interface,
    const std::string& route_default_interface,
    const std::string& xray_server_address_override,
    std::string* error) {
  std::string trimmed = TrimAscii(options_json);
  if (trimmed.size() < 2 || trimmed.front() != '{' || trimmed.back() != '}') {
    *error = "Native runtime options JSON must be an object.";
    return std::string();
  }

  trimmed.pop_back();
  bool first = trimmed.size() <= 1;
  std::string injected = std::move(trimmed);
  AppendJsonStringField(&injected, &first, "tunInterfaceName",
                        tun_interface_name);
  AppendJsonStringField(&injected, &first, "outboundBindInterface",
                        outbound_bind_interface);
  AppendJsonStringField(&injected, &first, "routeDefaultInterface",
                        route_default_interface);
  AppendJsonStringField(&injected, &first, "xrayServerAddressOverride",
                        xray_server_address_override);
  injected.push_back('}');
  return injected;
}

bool IsTruthy(const EncodableMap& map, const char* key) {
  const EncodableValue* value = FindValue(map, key);
  const auto* typed = value == nullptr ? nullptr : std::get_if<bool>(value);
  return typed != nullptr && *typed;
}

std::string MapString(const EncodableMap& map, const char* key) {
  const EncodableValue* value = FindValue(map, key);
  const auto* typed = value == nullptr ? nullptr : std::get_if<std::string>(value);
  return typed == nullptr ? std::string() : *typed;
}

int64_t MapInt64(const EncodableMap& map, const char* key, int64_t fallback = 0) {
  int64_t value = fallback;
  ReadInt64(map, key, &value);
  return value;
}

EncodableMap MakeFailure(const std::string& step,
                         const std::string& message,
                         DWORD code = ERROR_GEN_FAILURE) {
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

bool FileExistsWide(const std::wstring& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

bool DirectoryExistsWide(const std::wstring& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

bool WriteUtf8File(const std::wstring& path,
                   const std::string& text,
                   std::string* error) {
  ScopedHandle file(CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                                CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
  if (file.get() == INVALID_HANDLE_VALUE || file.get() == nullptr) {
    *error = "Could not create " + Utf8FromWide(path) + ": " +
             ErrorMessage(GetLastError());
    return false;
  }

  const char* data = text.data();
  size_t remaining = text.size();
  while (remaining > 0) {
    const DWORD chunk =
        static_cast<DWORD>(std::min<size_t>(remaining, 1024 * 1024));
    DWORD written = 0;
    if (WriteFile(file.get(), data, chunk, &written, nullptr) == 0) {
      *error = "Could not write " + Utf8FromWide(path) + ": " +
               ErrorMessage(GetLastError());
      return false;
    }
    if (written == 0) {
      *error = "Could not write " + Utf8FromWide(path) + ": wrote 0 bytes.";
      return false;
    }
    data += written;
    remaining -= written;
  }
  return true;
}

std::string CreateRuntimeDirectory(std::string* error) {
  wchar_t temp_path[MAX_PATH + 1] = {};
  const DWORD temp_length = GetTempPathW(MAX_PATH, temp_path);
  if (temp_length == 0 || temp_length > MAX_PATH) {
    *error = "Could not resolve Windows temp directory: " +
             ErrorMessage(GetLastError());
    return std::string();
  }

  for (int attempt = 0; attempt < 100; ++attempt) {
    const uint64_t stamp = static_cast<uint64_t>(
        std::chrono::steady_clock::now().time_since_epoch().count());
    std::wstring directory =
        std::wstring(temp_path) + L"entropy_vpn_" +
        WideFromUtf8(std::to_string(GetCurrentProcessId())) + L"_" +
        WideFromUtf8(std::to_string(stamp + attempt));
    if (CreateDirectoryW(directory.c_str(), nullptr) != 0) {
      return Utf8FromWide(directory);
    }
    const DWORD create_error = GetLastError();
    if (create_error != ERROR_ALREADY_EXISTS) {
      *error = "Could not create runtime directory: " +
               ErrorMessage(create_error);
      return std::string();
    }
  }

  *error = "Could not create a unique runtime directory.";
  return std::string();
}

void DeleteRuntimeDirectory(const std::string& runtime_directory,
                            const std::vector<std::string>& files) {
  const std::wstring wide_directory = WideFromUtf8(runtime_directory);
  for (const std::string& file : files) {
    if (!file.empty()) {
      DeleteFileW(WideFromUtf8(file).c_str());
    }
  }
  if (!wide_directory.empty()) {
    RemoveDirectoryW(wide_directory.c_str());
  }
}

class WindowsRuntimeController {
 public:
  static WindowsRuntimeController& Instance() {
    static WindowsRuntimeController controller;
    return controller;
  }

  void SetEventSink(
      std::unique_ptr<flutter::EventSink<EncodableValue>> event_sink) {
    std::lock_guard<std::mutex> lock(event_mutex_);
    event_sink_ = std::move(event_sink);
    EmitStateLocked();
  }

  void ClearEventSink() {
    std::lock_guard<std::mutex> lock(event_mutex_);
    event_sink_.reset();
  }

  EncodableValue Start(const EncodableMap& arguments) {
    EncodableMap response;
    if (!StopInternal(false, nullptr)) {
      response = MakeFailure("stop-existing",
                             "Could not stop the existing Windows runtime.");
      return EncodableValue(std::move(response));
    }

    auto state = std::make_shared<RuntimeState>();
    state->phase = kRuntimePhaseStarting;
    state->run_id = std::to_string(
        std::chrono::steady_clock::now().time_since_epoch().count());

    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      state_ = state;
    }
    EmitState();

    response = StartInternal(arguments, state);
    if (!IsTruthy(response, "ok")) {
      state->phase = kRuntimePhaseError;
      EmitState();
      state->stop_requested.store(true);
      if (state->use_service && !state->service_run_id.empty()) {
        StopCoreViaService(state);
      } else if (state->process != nullptr) {
        TerminateProcess(state->process, 0);
        WaitForSingleObject(state->process, 5000);
        CloseHandle(state->process);
        state->process = nullptr;
      }
      CleanupState(state, false);
      {
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (state_ == state) {
          state_.reset();
        }
      }
      EmitState();
      return EncodableValue(std::move(response));
    }

    state->phase = kRuntimePhaseRunning;
    state->started = true;
    EmitState();
    return EncodableValue(std::move(response));
  }

  EncodableValue Stop(bool wait_for_cleanup) {
    EncodableMap response;
    const bool stopped = StopInternal(wait_for_cleanup, &response);
    if (!stopped && response.empty()) {
      response = MakeFailure("stop", "Could not stop Windows runtime.");
    }
    if (response.empty()) {
      response.insert_or_assign(EncodableValue("ok"), EncodableValue(true));
      response.insert_or_assign(EncodableValue("stopped"),
                                EncodableValue(false));
    }
    return EncodableValue(std::move(response));
  }

  EncodableValue Status() {
    EncodableMap response;
    std::shared_ptr<RuntimeState> state;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      state = state_;
    }
    response.insert_or_assign(EncodableValue("ok"), EncodableValue(true));
    response.insert_or_assign(EncodableValue("running"),
                              EncodableValue(state != nullptr &&
                                             state->started));
    response.insert_or_assign(
        EncodableValue("phase"),
        EncodableValue(state == nullptr ? std::string(kRuntimePhaseDisconnected)
                                        : state->phase));
    response.insert_or_assign(
        EncodableValue("pid"),
        EncodableValue(static_cast<int64_t>(state == nullptr ? 0 : state->pid)));
    response.insert_or_assign(
        EncodableValue("useService"),
        EncodableValue(state != nullptr && state->use_service));
    return EncodableValue(std::move(response));
  }

 private:
  WindowsRuntimeController() = default;

  void Emit(const EncodableMap& event) {
    std::lock_guard<std::mutex> lock(event_mutex_);
    if (event_sink_ != nullptr) {
      event_sink_->Success(EncodableValue(event));
    }
  }

  void EmitLog(const std::string& line) {
    EncodableMap event;
    event.emplace(EncodableValue("type"), EncodableValue("log"));
    event.emplace(EncodableValue("line"), EncodableValue(line));
    Emit(event);
  }

  void EmitState() {
    std::lock_guard<std::mutex> lock(event_mutex_);
    EmitStateLocked();
  }

  void EmitStateLocked() {
    if (event_sink_ == nullptr) {
      return;
    }
    std::shared_ptr<RuntimeState> state;
    {
      std::lock_guard<std::mutex> state_lock(state_mutex_);
      state = state_;
    }
    EncodableMap event;
    event.emplace(EncodableValue("type"), EncodableValue("state"));
    event.emplace(EncodableValue("running"),
                  EncodableValue(state != nullptr && state->started));
    event.emplace(
        EncodableValue("phase"),
        EncodableValue(state == nullptr ? std::string(kRuntimePhaseDisconnected)
                                        : state->phase));
    event.emplace(
        EncodableValue("pid"),
        EncodableValue(static_cast<int64_t>(state == nullptr ? 0 : state->pid)));
    event.emplace(EncodableValue("useService"),
                  EncodableValue(state != nullptr && state->use_service));
    event_sink_->Success(EncodableValue(std::move(event)));
  }

  void EmitExit(int64_t exit_code, const std::string& message) {
    EncodableMap event;
    event.emplace(EncodableValue("type"), EncodableValue("exit"));
    event.emplace(EncodableValue("exitCode"), EncodableValue(exit_code));
    event.emplace(EncodableValue("error"), EncodableValue(message));
    Emit(event);
  }

  EncodableMap StartInternal(const EncodableMap& arguments,
                             const std::shared_ptr<RuntimeState>& state) {
    std::string core;
    std::string binary_path;
    std::string traffic_mode;
    std::string tun_ip_mode;
    std::string profile_server;
    std::string profile_json;
    std::string options_json;
    std::string native_config_json;
    std::string working_directory;
    std::vector<std::string> dns_servers;
    bool profile_is_native_config = false;
    bool requires_tun_prerequisites = false;
    bool skip_validation = false;

    if (!ReadString(arguments, "core", &core) ||
        !ReadString(arguments, "binaryPath", &binary_path) ||
        !ReadString(arguments, "trafficMode", &traffic_mode) ||
        !ReadString(arguments, "tunIpMode", &tun_ip_mode)) {
      return MakeFailure("arguments", "Missing Windows runtime arguments.",
                         ERROR_INVALID_PARAMETER);
    }
    ReadString(arguments, "profileServer", &profile_server);
    ReadString(arguments, "profileJson", &profile_json);
    ReadString(arguments, "optionsJson", &options_json);
    ReadString(arguments, "nativeConfigJson", &native_config_json);
    ReadString(arguments, "workingDirectory", &working_directory);
    ReadStringList(arguments, "dnsServers", &dns_servers);
    ReadBool(arguments, "profileIsNativeConfig", &profile_is_native_config);
    ReadBool(arguments, "requiresTunPrerequisites", &requires_tun_prerequisites);
    ReadBool(arguments, "skipValidation", &skip_validation);

    state->core = core;
    state->binary_path = binary_path;
    state->traffic_mode = traffic_mode;
    state->tun_ip_mode = tun_ip_mode;

    EmitLog("[app] Starting native Windows runtime for " + core + " in " +
            traffic_mode + " mode.");

    const std::string binary_directory = PathDirectory(binary_path);
    const std::string wintun_path = binary_directory + "\\wintun.dll";
    bool use_service = false;
    if (requires_tun_prerequisites) {
      if (!FileExistsWide(WideFromUtf8(wintun_path))) {
        return MakeFailure("wintun",
                           "wintun.dll was not found next to " +
                               PathBasename(binary_path) + ".",
                           ERROR_FILE_NOT_FOUND);
      }
      const bool elevated = IsRunningAsAdministrator();
      if (!elevated) {
        if (tun_ip_mode == "ipv4" && EnsureWindowsServiceReady()) {
          use_service = true;
          EmitLog("[app] EntropyVPN Service helper is ready; privileged Windows TUN work is delegated.");
        } else {
          EncodableMap relaunch_args;
          relaunch_args.emplace(EncodableValue("executable"),
                                EncodableValue(Utf8FromWide(
                                    RuntimeExecutablePath())));
          relaunch_args.emplace(EncodableValue("workingDirectory"),
                                EncodableValue(Utf8FromWide(
                                    RuntimeExecutableDirectory())));
          relaunch_args.emplace(EncodableValue("arguments"),
                                EncodableValue(std::string(
                                    "--entropyvpn-elevated-relaunch")));
          EncodableValue relaunch = RelaunchAsAdministrator(relaunch_args);
          auto* relaunch_map = std::get_if<EncodableMap>(&relaunch);
          if (relaunch_map != nullptr && IsTruthy(*relaunch_map, "ok")) {
            EncodableMap response;
            response.insert_or_assign(EncodableValue("ok"),
                                      EncodableValue(false));
            response.insert_or_assign(EncodableValue("exitRequested"),
                                      EncodableValue(true));
            response.insert_or_assign(
                EncodableValue("failedStep"),
                EncodableValue(std::string("privilege-relaunch")));
            response.insert_or_assign(
                EncodableValue("error"),
                EncodableValue(std::string(
                    "Elevated EntropyVPN instance was launched.")));
            return response;
          }
          return MakeFailure("privilege",
                             "Administrator privileges are required for Windows TUN mode.");
        }
      }
    }
    state->use_service = use_service;

    if (requires_tun_prerequisites) {
      StopStaleCores(binary_path);
    }

    std::string tun_interface_name =
        requires_tun_prerequisites ? "EntropyVPN TUN" : std::string();
    std::string outbound_bind_interface;
    std::string route_default_interface;
    std::string xray_server_address_override;
    if (!profile_is_native_config && traffic_mode == "tun") {
      EncodableMap routing_args;
      routing_args.emplace(EncodableValue("server"),
                           EncodableValue(profile_server));
      routing_args.emplace(EncodableValue("tunIpMode"),
                           EncodableValue(tun_ip_mode));
      routing_args.emplace(EncodableValue("useService"),
                           EncodableValue(use_service));
      EncodableValue routing = PrepareTunServerRouting(routing_args);
      auto* routing_map = std::get_if<EncodableMap>(&routing);
      if (routing_map == nullptr || !IsTruthy(*routing_map, "ok")) {
        return routing_map == nullptr
                   ? MakeFailure("server-routing",
                                 "Native server routing returned no result.")
                   : MakeFailureFromNativeMap(*routing_map, "server-routing");
      }
      outbound_bind_interface = MapString(*routing_map, "interfaceAlias");
      const std::string selected_address =
          MapString(*routing_map, "remoteAddress");
      if (core == "xray" && !selected_address.empty() &&
          selected_address != profile_server &&
          AddressFamilyForText(profile_server) == AF_UNSPEC) {
        xray_server_address_override = selected_address;
      }
      DecodeRoutes(*routing_map, true, &state->server_routes);
      EmitLog("[app] Windows server route setup completed via " +
              (use_service ? std::string("service") : std::string("native")) +
              ".");
    }

    if (core == "singBox" && traffic_mode == "tun") {
      route_default_interface = outbound_bind_interface;
    } else {
      route_default_interface.clear();
    }

    std::string config_json;
    if (profile_is_native_config) {
      config_json = native_config_json;
      if (config_json.empty()) {
        return MakeFailure("config",
                           "Native Windows runtime received an empty native config.",
                           ERROR_INVALID_PARAMETER);
      }
    } else {
      if (core == "xray" || traffic_mode != "tun") {
        // Xray uses sockopt.interface; sing-box system proxy has no TUN route
        // default interface to inject.
      } else {
        outbound_bind_interface.clear();
      }
      std::string inject_error;
      const std::string injected_options = InjectRuntimeConfigOptions(
          options_json, tun_interface_name, outbound_bind_interface,
          route_default_interface, xray_server_address_override, &inject_error);
      if (injected_options.empty()) {
        return MakeFailure("config-options", inject_error,
                           ERROR_INVALID_PARAMETER);
      }
      std::string build_error;
      if (!config_builder_.Build(profile_json, injected_options, &config_json,
                                 &build_error)) {
        return MakeFailure("config-build", build_error);
      }
    }

    std::string runtime_error;
    state->runtime_directory = CreateRuntimeDirectory(&runtime_error);
    if (state->runtime_directory.empty()) {
      return MakeFailure("runtime-directory", runtime_error);
    }
    state->config_path = state->runtime_directory + "\\config.json";
    state->stdout_path = state->runtime_directory + "\\core.stdout.log";
    state->stderr_path = state->runtime_directory + "\\core.stderr.log";
    if (working_directory.empty()) {
      working_directory = state->runtime_directory;
    }
    state->working_directory = working_directory;
    EmitLog("[app] Native runtime directory: " + state->runtime_directory);

    std::string write_error;
    if (!WriteUtf8File(WideFromUtf8(state->config_path), config_json,
                       &write_error)) {
      return MakeFailure("write-config", write_error);
    }

    if (!skip_validation) {
      EncodableMap validation = ValidateConfig(core, binary_path,
                                               state->config_path,
                                               working_directory);
      if (!IsTruthy(validation, "ok")) {
        return validation;
      }
    } else {
      EmitLog("[app] Skipping runtime config validation because xray run -test initializes the Windows TUN driver.");
    }

    EncodableMap start_core =
        use_service ? StartCoreViaService(state)
                    : StartCoreDirect(state);
    if (!IsTruthy(start_core, "ok")) {
      return start_core;
    }

    if (core == "xray" && traffic_mode == "tun" &&
        requires_tun_prerequisites) {
      EncodableMap xray_routes = PrepareXrayTunAdapterRoutes(
          tun_interface_name, tun_ip_mode, JoinStrings(dns_servers, ","),
          use_service, false);
      if (!IsTruthy(xray_routes, "ok")) {
        return MakeFailureFromNativeMap(xray_routes, "xray-tun-routes");
      }
      DecodeRoutes(xray_routes, false, &state->tun_routes);
      EmitXrayTunSetupTiming(xray_routes);
      EmitLog("[app] Xray TUN adapter and routes are ready.");
    }

    if (traffic_mode == "systemProxy" && core == "xray" &&
        !profile_is_native_config) {
      EncodableMap proxy_result = CaptureProxy(&state->proxy_snapshot);
      if (!IsTruthy(proxy_result, "ok")) {
        return proxy_result;
      }
      EncodableMap set_proxy = SetProxy(true, "127.0.0.1:2081", "<local>");
      if (!IsTruthy(set_proxy, "ok")) {
        return set_proxy;
      }
      EmitLog("[app] Windows system proxy enabled on 127.0.0.1:2081.");
    }

    EncodableMap response;
    response.insert_or_assign(EncodableValue("ok"), EncodableValue(true));
    response.insert_or_assign(EncodableValue("pid"),
                              EncodableValue(static_cast<int64_t>(state->pid)));
    response.insert_or_assign(EncodableValue("useService"),
                              EncodableValue(use_service));
    response.insert_or_assign(EncodableValue("runtimeDirectory"),
                              EncodableValue(state->runtime_directory));
    return response;
  }

  bool StopInternal(bool wait_for_cleanup, EncodableMap* response) {
    std::shared_ptr<RuntimeState> state;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      state = state_;
      state_.reset();
    }

    if (state == nullptr) {
      EmitState();
      if (response != nullptr) {
        response->insert_or_assign(EncodableValue("ok"), EncodableValue(true));
        response->insert_or_assign(EncodableValue("stopped"),
                                   EncodableValue(false));
      }
      return true;
    }

    state->phase = kRuntimePhaseStopping;
    state->stop_requested.store(true);
    EmitState();
    EmitLog("[app] Stopping native Windows runtime...");

    if (state->use_service) {
      StopCoreViaService(state);
    } else if (state->process != nullptr) {
      TerminateProcess(state->process, 0);
      WaitForSingleObject(state->process, wait_for_cleanup ? 5000 : 500);
      CloseHandle(state->process);
      state->process = nullptr;
    }

    CleanupState(state, true);
    EmitState();
    if (response != nullptr) {
      response->insert_or_assign(EncodableValue("ok"), EncodableValue(true));
      response->insert_or_assign(EncodableValue("stopped"),
                                 EncodableValue(true));
    }
    return true;
  }

  bool IsRunningAsAdministrator() {
    BOOL is_member = FALSE;
    PSID admin_group = nullptr;
    SID_IDENTIFIER_AUTHORITY authority = SECURITY_NT_AUTHORITY;
    if (AllocateAndInitializeSid(&authority, 2, SECURITY_BUILTIN_DOMAIN_RID,
                                 DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0, 0,
                                 &admin_group) == 0) {
      return false;
    }
    CheckTokenMembership(nullptr, admin_group, &is_member);
    FreeSid(admin_group);
    return is_member != FALSE;
  }

  std::wstring RuntimeExecutablePath() {
    wchar_t module_path[MAX_PATH] = {};
    const DWORD length = GetModuleFileNameW(nullptr, module_path, MAX_PATH);
    return length == 0 || length == MAX_PATH ? std::wstring()
                                             : std::wstring(module_path, length);
  }

  bool EnsureWindowsServiceReady() {
    if (PingWindowsService()) {
      return true;
    }
    EncodableMap args;
    args.emplace(EncodableValue("serviceName"),
                 EncodableValue(std::string("EntropyVPNService")));
    args.emplace(EncodableValue("timeoutMs"), EncodableValue(int64_t(1500)));
    EncodableValue started = StartWindowsService(args);
    auto* map = std::get_if<EncodableMap>(&started);
    if (map == nullptr || !IsTruthy(*map, "ok")) {
      return false;
    }
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(4);
    while (std::chrono::steady_clock::now() < deadline) {
      if (PingWindowsService()) {
        return true;
      }
      Sleep(150);
    }
    return false;
  }

  bool PingWindowsService() {
    std::string request;
    std::string build_error;
    if (!BuildWindowsServiceRequest({"ping"}, &request, &build_error)) {
      return false;
    }
    const PipeRequestResult result = SendWindowsServicePipeRequest(request, 2000);
    if (!result.ok || result.response.empty()) {
      return false;
    }
    const ParsedServiceResponse parsed =
        ParseWindowsServiceResponse(result.response, std::string(), 0);
    return parsed.ok;
  }

  void StopStaleCores(const std::string& binary_path) {
    EncodableMap args;
    args.emplace(EncodableValue("binaryPath"), EncodableValue(binary_path));
    args.emplace(EncodableValue("currentPid"),
                 EncodableValue(static_cast<int64_t>(GetCurrentProcessId())));
    args.emplace(EncodableValue("waitMs"), EncodableValue(int64_t(500)));
    EncodableValue result = StopStaleCoreProcessesNative(args);
    auto* map = std::get_if<EncodableMap>(&result);
    if (map != nullptr && IsTruthy(*map, "ok")) {
      EmitLog("[app] Native stale core process sweep completed.");
    }
  }

  void DecodeRoutes(const EncodableMap& source,
                    bool remove_when_unused_from_status,
                    std::vector<RuntimeRoute>* output) {
    const EncodableValue* routes_value = FindValue(source, "routes");
    if (routes_value == nullptr) {
      routes_value = FindValue(source, "Routes");
    }
    const auto* routes = routes_value == nullptr
                             ? nullptr
                             : std::get_if<EncodableList>(routes_value);
    if (routes == nullptr) {
      return;
    }
    const int64_t fallback_index = MapInt64(source, "interfaceIndex");
    for (const EncodableValue& item_value : *routes) {
      const auto* item = std::get_if<EncodableMap>(&item_value);
      if (item == nullptr) {
        continue;
      }
      const std::string status = MapString(*item, "Status");
      if (status == "failed") {
        continue;
      }
      RuntimeRoute route;
      route.destination_prefix = MapString(*item, "DestinationPrefix");
      route.next_hop = MapString(*item, "NextHop");
      route.interface_index = MapInt64(*item, "InterfaceIndex", fallback_index);
      route.remove_when_unused =
          !remove_when_unused_from_status || status == "created";
      if (!route.destination_prefix.empty() && !route.next_hop.empty() &&
          route.interface_index > 0) {
        output->push_back(route);
      }
    }
  }

  EncodableMap ValidateConfig(const std::string& core,
                              const std::string& binary_path,
                              const std::string& config_path,
                              const std::string& working_directory) {
    std::vector<std::wstring> args;
    if (core == "xray") {
      args = {L"run", L"-test", L"-c", WideFromUtf8(config_path)};
    } else {
      args = {L"check", L"-c", WideFromUtf8(config_path)};
    }
    EmitLog("[app] Validating runtime config natively...");
    ProcessCaptureResult result = RunCapturedProcess(
        WideFromUtf8(binary_path), args, WideFromUtf8(working_directory),
        30000);
    if (!result.created) {
      return MakeFailure("config-validation", result.error_message,
                         result.error_code);
    }
    EmitProcessOutput("[check][stdout] ", result.stdout_text);
    EmitProcessOutput("[check][stderr] ", result.stderr_text);
    if (result.exit_code != 0) {
      const std::string message =
          TrimAscii(result.stderr_text).empty() ? TrimAscii(result.stdout_text)
                                                : TrimAscii(result.stderr_text);
      return MakeFailure("config-validation",
                         message.empty()
                             ? "Core configuration validation failed."
                             : message,
                         result.exit_code);
    }
    EncodableMap response;
    response.insert_or_assign(EncodableValue("ok"), EncodableValue(true));
    return response;
  }

  struct ProcessCaptureResult {
    bool created = false;
    DWORD error_code = NO_ERROR;
    DWORD exit_code = 1;
    std::string error_message;
    std::string stdout_text;
    std::string stderr_text;
  };

  ProcessCaptureResult RunCapturedProcess(const std::wstring& executable,
                                          const std::vector<std::wstring>& args,
                                          const std::wstring& working_directory,
                                          DWORD timeout_ms) {
    ProcessCaptureResult result;
    SECURITY_ATTRIBUTES security{};
    security.nLength = sizeof(security);
    security.bInheritHandle = TRUE;

    HANDLE stdout_read = nullptr;
    HANDLE stdout_write = nullptr;
    HANDLE stderr_read = nullptr;
    HANDLE stderr_write = nullptr;
    if (CreatePipe(&stdout_read, &stdout_write, &security, 0) == 0 ||
        CreatePipe(&stderr_read, &stderr_write, &security, 0) == 0) {
      result.error_code = GetLastError();
      result.error_message = "Could not create process output pipes: " +
                             ErrorMessage(result.error_code);
      CloseHandleIfValid(&stdout_read);
      CloseHandleIfValid(&stdout_write);
      CloseHandleIfValid(&stderr_read);
      CloseHandleIfValid(&stderr_write);
      return result;
    }
    SetHandleInformation(stdout_read, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(stderr_read, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdOutput = stdout_write;
    startup.hStdError = stderr_write;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

    PROCESS_INFORMATION info{};
    std::wstring command_line = BuildCommandLine(executable, args);
    const BOOL created = CreateProcessW(
        executable.c_str(), command_line.data(), nullptr, nullptr, TRUE,
        CREATE_NO_WINDOW, nullptr,
        working_directory.empty() ? nullptr : working_directory.c_str(),
        &startup, &info);
    result.error_code = GetLastError();
    CloseHandleIfValid(&stdout_write);
    CloseHandleIfValid(&stderr_write);
    if (created == 0) {
      result.error_message = "Could not start validation process: " +
                             ErrorMessage(result.error_code);
      CloseHandleIfValid(&stdout_read);
      CloseHandleIfValid(&stderr_read);
      return result;
    }

    result.created = true;
    std::thread stdout_thread(ReadPipeToString, stdout_read,
                              &result.stdout_text);
    std::thread stderr_thread(ReadPipeToString, stderr_read,
                              &result.stderr_text);
    const DWORD wait_result = WaitForSingleObject(info.hProcess, timeout_ms);
    if (wait_result == WAIT_TIMEOUT) {
      TerminateProcess(info.hProcess, WAIT_TIMEOUT);
      WaitForSingleObject(info.hProcess, 5000);
    }
    GetExitCodeProcess(info.hProcess, &result.exit_code);
    CloseHandle(info.hThread);
    CloseHandle(info.hProcess);
    stdout_thread.join();
    stderr_thread.join();
    CloseHandleIfValid(&stdout_read);
    CloseHandleIfValid(&stderr_read);
    return result;
  }

  void EmitProcessOutput(const std::string& prefix, const std::string& text) {
    std::string normalized = text;
    size_t start = 0;
    while (start < normalized.size()) {
      size_t end = normalized.find_first_of("\r\n", start);
      std::string line = end == std::string::npos
                             ? normalized.substr(start)
                             : normalized.substr(start, end - start);
      line = TrimAscii(line);
      if (!line.empty()) {
        EmitLog(prefix + line);
      }
      if (end == std::string::npos) {
        break;
      }
      start = end + 1;
    }
  }

  EncodableMap StartCoreDirect(const std::shared_ptr<RuntimeState>& state) {
    SECURITY_ATTRIBUTES security{};
    security.nLength = sizeof(security);
    security.bInheritHandle = TRUE;

    HANDLE stdout_read = nullptr;
    HANDLE stdout_write = nullptr;
    HANDLE stderr_read = nullptr;
    HANDLE stderr_write = nullptr;
    if (CreatePipe(&stdout_read, &stdout_write, &security, 0) == 0 ||
        CreatePipe(&stderr_read, &stderr_write, &security, 0) == 0) {
      DWORD error = GetLastError();
      CloseHandleIfValid(&stdout_read);
      CloseHandleIfValid(&stdout_write);
      CloseHandleIfValid(&stderr_read);
      CloseHandleIfValid(&stderr_write);
      return MakeFailure("core-pipes",
                         "Could not create core process pipes: " +
                             ErrorMessage(error),
                         error);
    }
    SetHandleInformation(stdout_read, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(stderr_read, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdOutput = stdout_write;
    startup.hStdError = stderr_write;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

    PROCESS_INFORMATION info{};
    const std::vector<std::wstring> args = {L"run", L"-c",
                                            WideFromUtf8(state->config_path)};
    std::wstring command_line =
        BuildCommandLine(WideFromUtf8(state->binary_path), args);
    const BOOL created = CreateProcessW(
        WideFromUtf8(state->binary_path).c_str(), command_line.data(), nullptr,
        nullptr, TRUE, CREATE_NO_WINDOW, nullptr,
        state->working_directory.empty()
            ? nullptr
            : WideFromUtf8(state->working_directory).c_str(),
        &startup, &info);
    const DWORD create_error = GetLastError();
    CloseHandleIfValid(&stdout_write);
    CloseHandleIfValid(&stderr_write);
    if (created == 0) {
      CloseHandleIfValid(&stdout_read);
      CloseHandleIfValid(&stderr_read);
      return MakeFailure("core-start",
                         "Could not start core process: " +
                             ErrorMessage(create_error),
                         create_error);
    }

    state->process = info.hProcess;
    state->pid = info.dwProcessId;
    CloseHandle(info.hThread);
    DuplicateHandle(GetCurrentProcess(), state->process, GetCurrentProcess(),
                    &state->watcher_process, SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                    FALSE, 0);
    EmitLog("[app] Core process started natively with PID " +
            std::to_string(state->pid) + ".");

    std::thread([this, stdout_read]() {
      StreamProcessPipe(stdout_read, false);
    }).detach();
    std::thread([this, stderr_read]() {
      StreamProcessPipe(stderr_read, true);
    }).detach();
    if (state->watcher_process != nullptr) {
      std::thread([this, state]() { WatchDirectProcess(state); }).detach();
    }

    EncodableMap response;
    response.insert_or_assign(EncodableValue("ok"), EncodableValue(true));
    response.insert_or_assign(EncodableValue("pid"),
                              EncodableValue(static_cast<int64_t>(state->pid)));
    return response;
  }

  EncodableMap StartCoreViaService(const std::shared_ptr<RuntimeState>& state) {
    state->service_run_id = state->run_id + "-" + state->core;
    const std::vector<std::string> service_args = {
        "start-core",
        "--run-id",
        state->service_run_id,
        "--executable",
        state->binary_path,
        "--working-directory",
        state->working_directory,
        "--stdout-path",
        state->stdout_path,
        "--stderr-path",
        state->stderr_path,
        "--arg",
        "run",
        "--arg",
        "-c",
        "--arg",
        state->config_path,
    };
    ParsedServiceResponse parsed;
    if (!RunServiceRequest(service_args, 10000, &parsed) || !parsed.ok) {
      return MakeFailure("service-core-start",
                         parsed.error.empty()
                             ? "EntropyVPN Service failed to start core."
                             : parsed.error);
    }
    state->pid =
        static_cast<DWORD>(ParseServiceInt64(parsed.fields, "pid", 0));
    EmitLog("[app] Core process started by EntropyVPN Service with PID " +
            std::to_string(state->pid) + ".");
    std::thread([this, state]() { PollServiceCore(state); }).detach();
    EncodableMap response;
    response.insert_or_assign(EncodableValue("ok"), EncodableValue(true));
    response.insert_or_assign(EncodableValue("pid"),
                              EncodableValue(static_cast<int64_t>(state->pid)));
    return response;
  }

  bool RunServiceRequest(const std::vector<std::string>& args,
                         DWORD timeout_ms,
                         ParsedServiceResponse* parsed) {
    std::string request;
    std::string build_error;
    if (!BuildWindowsServiceRequest(args, &request, &build_error)) {
      parsed->error = build_error;
      return false;
    }
    const PipeRequestResult pipe = SendWindowsServicePipeRequest(request,
                                                                 timeout_ms);
    std::string stdout_text;
    std::string stderr_text;
    DWORD exit_code = 0;
    if (!pipe.ok || pipe.response.empty()) {
      const HelperProcessResult helper =
          RunWindowsServiceHelperProcess(args, timeout_ms, pipe.error);
      if (!helper.ok) {
        parsed->error = helper.error;
        return false;
      }
      stdout_text = helper.stdout_text;
      stderr_text = helper.stderr_text;
      exit_code = helper.exit_code;
    } else {
      stdout_text = pipe.response;
    }
    *parsed = ParseWindowsServiceResponse(stdout_text, stderr_text, exit_code);
    return true;
  }

  void StopCoreViaService(const std::shared_ptr<RuntimeState>& state) {
    ParsedServiceResponse parsed;
    RunServiceRequest({"stop-core", "--run-id", state->service_run_id}, 8000,
                      &parsed);
    TailServiceLogs(state);
  }

  void PollServiceCore(const std::shared_ptr<RuntimeState>& state) {
    size_t stdout_offset = 0;
    size_t stderr_offset = 0;
    while (!state->stop_requested.load()) {
      TailServiceLog(state->stdout_path, &stdout_offset, false);
      TailServiceLog(state->stderr_path, &stderr_offset, true);
      ParsedServiceResponse parsed;
      if (RunServiceRequest({"status-core", "--run-id", state->service_run_id},
                            2000, &parsed) &&
          parsed.ok) {
        if (ServiceFieldValue(parsed.fields, "running") != "1") {
          const int64_t exit_code =
              ParseServiceInt64(parsed.fields, "exitCode", 0);
          HandleUnexpectedExit(state, exit_code);
          return;
        }
      }
      Sleep(500);
    }
  }

  void TailServiceLogs(const std::shared_ptr<RuntimeState>& state) {
    size_t offset = 0;
    TailServiceLog(state->stdout_path, &offset, false);
    offset = 0;
    TailServiceLog(state->stderr_path, &offset, true);
  }

  void TailServiceLog(const std::string& path, size_t* offset, bool is_error) {
    const std::wstring wide_path = WideFromUtf8(path);
    ScopedHandle file(CreateFileW(wide_path.c_str(), GENERIC_READ,
                                  FILE_SHARE_READ | FILE_SHARE_WRITE |
                                      FILE_SHARE_DELETE,
                                  nullptr, OPEN_EXISTING,
                                  FILE_ATTRIBUTE_NORMAL, nullptr));
    if (file.get() == INVALID_HANDLE_VALUE || file.get() == nullptr) {
      return;
    }
    LARGE_INTEGER size{};
    if (GetFileSizeEx(file.get(), &size) == 0 || size.QuadPart <= 0) {
      return;
    }
    if (*offset > static_cast<size_t>(size.QuadPart)) {
      *offset = 0;
    }
    if (*offset >= static_cast<size_t>(size.QuadPart)) {
      return;
    }
    LARGE_INTEGER position{};
    position.QuadPart = static_cast<LONGLONG>(*offset);
    SetFilePointerEx(file.get(), position, nullptr, FILE_BEGIN);
    const size_t remaining = static_cast<size_t>(size.QuadPart) - *offset;
    std::string text;
    text.resize(remaining);
    DWORD read = 0;
    if (ReadFile(file.get(), text.data(), static_cast<DWORD>(text.size()),
                 &read, nullptr) == 0) {
      return;
    }
    text.resize(read);
    *offset += read;
    EmitProcessOutput(is_error ? "ERR: " : "", text);
  }

  void StreamProcessPipe(HANDLE pipe, bool is_error) {
    std::string pending;
    std::vector<char> buffer(4096);
    while (true) {
      DWORD read = 0;
      const BOOL ok =
          ReadFile(pipe, buffer.data(), static_cast<DWORD>(buffer.size()),
                   &read, nullptr);
      if (ok == 0 || read == 0) {
        break;
      }
      pending.append(buffer.data(), buffer.data() + read);
      size_t line_start = 0;
      while (true) {
        size_t line_end = pending.find_first_of("\r\n", line_start);
        if (line_end == std::string::npos) {
          pending.erase(0, line_start);
          break;
        }
        std::string line = TrimAscii(pending.substr(line_start,
                                                    line_end - line_start));
        if (!line.empty()) {
          EmitLog(is_error ? "ERR: " + line : line);
        }
        line_start = line_end + 1;
      }
    }
    if (!TrimAscii(pending).empty()) {
      EmitLog(is_error ? "ERR: " + TrimAscii(pending) : TrimAscii(pending));
    }
    CloseHandleIfValid(&pipe);
  }

  void WatchDirectProcess(const std::shared_ptr<RuntimeState>& state) {
    HANDLE watch_handle = state->watcher_process;
    if (watch_handle == nullptr) {
      return;
    }
    const DWORD wait = WaitForSingleObject(watch_handle, INFINITE);
    if (wait != WAIT_OBJECT_0) {
      CloseHandle(watch_handle);
      state->watcher_process = nullptr;
      return;
    }
    DWORD exit_code = 0;
    GetExitCodeProcess(watch_handle, &exit_code);
    CloseHandle(watch_handle);
    state->watcher_process = nullptr;
    HandleUnexpectedExit(state, exit_code);
  }

  void HandleUnexpectedExit(const std::shared_ptr<RuntimeState>& state,
                            int64_t exit_code) {
    if (state->stop_requested.load()) {
      return;
    }
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      if (state_ != state) {
        return;
      }
      state_.reset();
    }
    EmitLog("[app] Core process exited with code " +
            std::to_string(exit_code) + ".");
    CleanupState(state, false);
    EmitState();
    EmitExit(exit_code, exit_code == 0
                            ? std::string()
                            : "Core process exited with code " +
                                  std::to_string(exit_code) + ".");
  }

  EncodableMap PrepareXrayTunAdapterRoutes(const std::string& interface_alias,
                                           const std::string& tun_ip_mode,
                                           const std::string& dns_servers,
                                           bool use_service,
                                           bool route_only_allowed) {
    EncodableMap args;
    args.emplace(EncodableValue("interfaceAlias"),
                 EncodableValue(interface_alias));
    args.emplace(EncodableValue("timeoutMs"),
                 EncodableValue(route_only_allowed
                                    ? kXrayTunRouteOnlyTimeoutMs
                                    : kXrayTunSetupTimeoutMs));
    args.emplace(EncodableValue("tunIpMode"), EncodableValue(tun_ip_mode));
    args.emplace(EncodableValue("address"),
                 EncodableValue(std::string("172.19.0.1")));
    args.emplace(EncodableValue("prefixLength"), EncodableValue(int64_t(30)));
    args.emplace(EncodableValue("metric"), EncodableValue(int64_t(1)));
    args.emplace(EncodableValue("dnsServers"), EncodableValue(dns_servers));
    args.emplace(EncodableValue("useService"), EncodableValue(use_service));
    args.emplace(EncodableValue("routeOnlyAllowed"),
                 EncodableValue(route_only_allowed));
    EncodableValue result = PrepareXrayTunRoutes(args);
    auto* map = std::get_if<EncodableMap>(&result);
    return map == nullptr ? MakeFailure("xray-tun-routes",
                                        "Xray TUN route setup returned no result.")
                          : *map;
  }

  void EmitXrayTunSetupTiming(const EncodableMap& xray_routes) {
    const std::string setup_kind = MapString(xray_routes, "setupKind");
    EmitLog("[app] Xray TUN adapter setup timing: prepare=" +
            std::to_string(MapInt64(xray_routes, "elapsedMs")) +
            "ms, wait_adapter=" +
            std::to_string(MapInt64(xray_routes, "waitMs")) +
            "ms, configure=" +
            std::to_string(MapInt64(xray_routes, "configureMs")) +
            "ms, routes=" +
            std::to_string(MapInt64(xray_routes, "routeMs")) + "ms" +
            (setup_kind.empty() ? "" : ", kind=" + setup_kind) + ".");
    EmitLog("[app] Xray TUN adapter setup retries: attempts=" +
            std::to_string(MapInt64(xray_routes, "attempts")) +
            ", retry_sleep=" +
            std::to_string(MapInt64(xray_routes, "retrySleepMs")) +
            "ms, configure_total=" +
            std::to_string(MapInt64(xray_routes, "configureTotalMs")) +
            "ms, route_total=" +
            std::to_string(MapInt64(xray_routes, "routeTotalMs")) +
            "ms, waits=ip_change:" +
            std::to_string(MapInt64(xray_routes, "interfaceChangeWaits")) +
            "|high_res:" +
            std::to_string(MapInt64(xray_routes, "highResWaits")) +
            "|sleep:" +
            std::to_string(MapInt64(xray_routes, "fallbackSleepWaits")) +
            "|yield:" +
            std::to_string(MapInt64(xray_routes, "yieldWaits")) +
            ", last_fail=step:" +
            (MapString(xray_routes, "lastRetryStep").empty()
                 ? std::string("-")
                 : MapString(xray_routes, "lastRetryStep")) +
            "|err:" +
            std::to_string(MapInt64(xray_routes, "lastRetryErrorCode")) +
            "|route:" +
            (MapString(xray_routes, "lastRetryRoutePrefix").empty()
                 ? std::string("-")
                 : MapString(xray_routes, "lastRetryRoutePrefix")) +
            ".");
  }

  EncodableMap CaptureProxy(ProxySnapshot* snapshot) {
    EncodableValue captured = CaptureSystemProxy();
    auto* map = std::get_if<EncodableMap>(&captured);
    if (map == nullptr) {
      return MakeFailure("proxy-capture",
                         "Native proxy capture returned no result.");
    }
    if (!IsTruthy(*map, "ok")) {
      return MakeFailureFromNativeMap(*map, "proxy-capture");
    }
    snapshot->enabled = IsTruthy(*map, "enabled");
    snapshot->server = MapString(*map, "server");
    snapshot->override_value = MapString(*map, "override");
    snapshot->captured = true;
    return *map;
  }

  EncodableMap SetProxy(bool enabled,
                        const std::string& server,
                        const std::string& override_value) {
    EncodableMap args;
    args.emplace(EncodableValue("enabled"), EncodableValue(enabled));
    if (!server.empty()) {
      args.emplace(EncodableValue("server"), EncodableValue(server));
    } else {
      args.emplace(EncodableValue("server"), EncodableValue());
    }
    if (!override_value.empty()) {
      args.emplace(EncodableValue("override"), EncodableValue(override_value));
    } else {
      args.emplace(EncodableValue("override"), EncodableValue());
    }
    EncodableValue result = SetSystemProxy(args);
    auto* map = std::get_if<EncodableMap>(&result);
    return map == nullptr ? MakeFailure("proxy-set",
                                        "Native proxy update returned no result.")
                          : *map;
  }

  void RestoreProxy(const ProxySnapshot& snapshot) {
    if (!snapshot.captured) {
      return;
    }
    SetProxy(snapshot.enabled, snapshot.server, snapshot.override_value);
    EmitLog("[app] Windows system proxy restored.");
  }

  void RemoveRuntimeRoutes(const std::vector<RuntimeRoute>& routes,
                           const char* label) {
    EncodableList route_list;
    for (const RuntimeRoute& route : routes) {
      if (!route.remove_when_unused) {
        continue;
      }
      EncodableMap route_map;
      route_map.emplace(EncodableValue("destinationPrefix"),
                        EncodableValue(route.destination_prefix));
      route_map.emplace(EncodableValue("interfaceIndex"),
                        EncodableValue(route.interface_index));
      route_map.emplace(EncodableValue("nextHop"),
                        EncodableValue(route.next_hop));
      route_list.emplace_back(EncodableValue(std::move(route_map)));
    }
    if (route_list.empty()) {
      return;
    }
    EncodableMap args;
    args.emplace(EncodableValue("routes"), EncodableValue(std::move(route_list)));
    EncodableValue result = RemoveRoutes(args);
    auto* map = std::get_if<EncodableMap>(&result);
    if (map != nullptr && IsTruthy(*map, "ok")) {
      EmitLog(std::string("[app] Native route cleanup completed for ") +
              label + ".");
    }
  }

  void CleanupState(const std::shared_ptr<RuntimeState>& state,
                    bool requested_stop) {
    bool expected = false;
    if (!state->cleaned.compare_exchange_strong(expected, true)) {
      return;
    }
    RemoveRuntimeRoutes(state->tun_routes, "xray_tun_routes");
    RemoveRuntimeRoutes(state->server_routes, "server_routes");
    RestoreProxy(state->proxy_snapshot);
    DeleteRuntimeDirectory(state->runtime_directory,
                           {state->config_path, state->stdout_path,
                            state->stderr_path});
    if (state->process != nullptr) {
      CloseHandle(state->process);
      state->process = nullptr;
    }
    if (requested_stop) {
      EmitLog("[app] Native Windows runtime stopped.");
    }
  }

  std::mutex state_mutex_;
  std::shared_ptr<RuntimeState> state_;
  std::mutex event_mutex_;
  std::unique_ptr<flutter::EventSink<EncodableValue>> event_sink_;
  NativeConfigBuilder config_builder_;
};

}  // namespace

namespace entropy_vpn::windows_runtime {

void SetWindowsRuntimeEventSink(
    std::unique_ptr<flutter::EventSink<EncodableValue>> event_sink) {
  WindowsRuntimeController::Instance().SetEventSink(std::move(event_sink));
}

void ClearWindowsRuntimeEventSink() {
  WindowsRuntimeController::Instance().ClearEventSink();
}

EncodableValue StartWindowsRuntime(const EncodableMap& arguments) {
  return WindowsRuntimeController::Instance().Start(arguments);
}

EncodableValue StopWindowsRuntime(bool wait_for_cleanup) {
  return WindowsRuntimeController::Instance().Stop(wait_for_cleanup);
}

EncodableValue WindowsRuntimeStatus() {
  return WindowsRuntimeController::Instance().Status();
}

}  // namespace entropy_vpn::windows_runtime
