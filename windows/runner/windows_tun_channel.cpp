#include "windows_tun_channel.h"

#include "entropy_vpn_native_tun.h"
#include "entropy_vpn_service_common.h"
#include "entropy_vpn_service_protocol.h"

#include <winsock2.h>
#include <ws2tcpip.h>

#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <shellapi.h>
#include <tlhelp32.h>
#include <windows.h>
#include <windns.h>
#include <wininet.h>
#include <winsvc.h>

#include <algorithm>
#include <chrono>
#include <cctype>
#include <condition_variable>
#include <cstdint>
#include <cwctype>
#include <cstring>
#include <cstdlib>
#include <deque>
#include <functional>
#include <limits>
#include <memory>
#include <mutex>
#include <queue>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <variant>
#include <vector>

namespace {

constexpr char kWindowsTunChannelName[] = "entropy_vpn/windows_tun";
constexpr char kConfigureXrayTunIpv4Method[] = "configureXrayTunIpv4";
constexpr char kPrepareIpv4ServerRouteMethod[] = "prepareIpv4ServerRoute";
constexpr char kPrepareTunServerRoutingMethod[] = "prepareTunServerRouting";
constexpr char kPrepareXrayTunRoutesMethod[] = "prepareXrayTunRoutes";
constexpr char kPrepareServerRoutesMethod[] = "prepareServerRoutes";
constexpr char kRemoveIpv4RoutesMethod[] = "removeIpv4Routes";
constexpr char kRemoveRoutesMethod[] = "removeRoutes";
constexpr char kCaptureSystemProxyMethod[] = "captureSystemProxy";
constexpr char kSetSystemProxyMethod[] = "setSystemProxy";
constexpr char kRelaunchAsAdministratorMethod[] = "relaunchAsAdministrator";
constexpr char kStartWindowsServiceMethod[] = "startWindowsService";
constexpr char kRunWindowsServiceHelperMethod[] = "runWindowsServiceHelper";
constexpr char kStopStaleCoreProcessesMethod[] = "stopStaleCoreProcesses";
constexpr char kTerminateProcessTreeMethod[] = "terminateProcessTree";
constexpr char kExpandSplitTunnelProcessTreeMethod[] =
    "expandSplitTunnelProcessTree";

constexpr wchar_t kInternetSettingsRegistryPath[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
constexpr wchar_t kEntropyVpnServiceExecutableName[] =
    L"entropy_vpn_service.exe";

using EncodableList = flutter::EncodableList;
using EncodableMap = flutter::EncodableMap;
using EncodableValue = flutter::EncodableValue;

using namespace entropy_vpn_service;

#include "windows_tun_channel/windows_tun_channel_common.inc"
#define ENTROPY_VPN_NATIVE_TUN_FLUTTER_ONLY
#include "windows_tun_channel/windows_tun_channel_routes.inc"
#undef ENTROPY_VPN_NATIVE_TUN_FLUTTER_ONLY
#include "windows_tun_channel/windows_tun_channel_proxy.inc"
#include "windows_tun_channel/windows_tun_channel_service.inc"
#include "windows_tun_channel/windows_tun_channel_methods.inc"

class WindowsTunWorker {
 public:
  static WindowsTunWorker& Instance() {
    static WindowsTunWorker worker;
    return worker;
  }

  void Post(std::function<void()> task) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      tasks_.push(std::move(task));
    }
    condition_.notify_one();
  }

 private:
  WindowsTunWorker() { thread_ = std::thread([this]() { Run(); }); }

  ~WindowsTunWorker() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stopping_ = true;
    }
    condition_.notify_one();
    if (thread_.joinable()) {
      thread_.join();
    }
  }

  void Run() {
    while (true) {
      std::function<void()> task;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        condition_.wait(lock,
                        [this]() { return stopping_ || !tasks_.empty(); });
        if (stopping_ && tasks_.empty()) {
          return;
        }
        task = std::move(tasks_.front());
        tasks_.pop();
      }
      task();
    }
  }

  std::mutex mutex_;
  std::condition_variable condition_;
  std::queue<std::function<void()>> tasks_;
  bool stopping_ = false;
  std::thread thread_;
};

EncodableValue InvalidArgumentsResponse() {
  EncodableMap response;
  AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
  return EncodableValue(std::move(response));
}

bool IsWindowsTunMethodImplemented(const std::string& method_name) {
  return method_name == kConfigureXrayTunIpv4Method ||
         method_name == kPrepareIpv4ServerRouteMethod ||
         method_name == kPrepareTunServerRoutingMethod ||
         method_name == kPrepareXrayTunRoutesMethod ||
         method_name == kPrepareServerRoutesMethod ||
         method_name == kRemoveIpv4RoutesMethod ||
         method_name == kRemoveRoutesMethod ||
         method_name == kCaptureSystemProxyMethod ||
         method_name == kSetSystemProxyMethod ||
         method_name == kRelaunchAsAdministratorMethod ||
         method_name == kStartWindowsServiceMethod ||
         method_name == kRunWindowsServiceHelperMethod ||
         method_name == kStopStaleCoreProcessesMethod ||
         method_name == kTerminateProcessTreeMethod ||
         method_name == kExpandSplitTunnelProcessTreeMethod;
}

EncodableValue HandleWindowsTunMethodCall(const std::string& method_name,
                                          const EncodableMap* arguments) {
  if (method_name == kCaptureSystemProxyMethod) {
    return CaptureSystemProxy();
  }

  if (arguments == nullptr) {
    return InvalidArgumentsResponse();
  }

  if (method_name == kConfigureXrayTunIpv4Method) {
    return ConfigureXrayTunIpv4(*arguments);
  }
  if (method_name == kPrepareIpv4ServerRouteMethod) {
    return PrepareIpv4ServerRoute(*arguments);
  }
  if (method_name == kPrepareTunServerRoutingMethod) {
    return PrepareTunServerRouting(*arguments);
  }
  if (method_name == kPrepareXrayTunRoutesMethod) {
    return PrepareXrayTunRoutes(*arguments);
  }
  if (method_name == kPrepareServerRoutesMethod) {
    return PrepareServerRoutes(*arguments);
  }
  if (method_name == kRemoveIpv4RoutesMethod) {
    return RemoveIpv4Routes(*arguments);
  }
  if (method_name == kRemoveRoutesMethod) {
    return RemoveRoutes(*arguments);
  }
  if (method_name == kSetSystemProxyMethod) {
    return SetSystemProxy(*arguments);
  }
  if (method_name == kRelaunchAsAdministratorMethod) {
    return RelaunchAsAdministrator(*arguments);
  }
  if (method_name == kStartWindowsServiceMethod) {
    return StartWindowsService(*arguments);
  }
  if (method_name == kRunWindowsServiceHelperMethod) {
    return RunWindowsServiceHelper(*arguments);
  }
  if (method_name == kStopStaleCoreProcessesMethod) {
    return StopStaleCoreProcessesNative(*arguments);
  }
  if (method_name == kTerminateProcessTreeMethod) {
    return TerminateProcessTreeNative(*arguments);
  }
  if (method_name == kExpandSplitTunnelProcessTreeMethod) {
    return ExpandSplitTunnelProcessTree(*arguments);
  }

  EncodableMap response;
  AddFailure(&response, "method", ERROR_NOT_SUPPORTED);
  return EncodableValue(std::move(response));
}

void RunWindowsTunMethodAsync(
    std::string method_name,
    const EncodableMap* arguments,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  EncodableMap arguments_copy;
  const bool has_arguments = arguments != nullptr;
  if (has_arguments) {
    arguments_copy = *arguments;
  }

  std::shared_ptr<flutter::MethodResult<EncodableValue>> result_ptr(
      std::move(result));
  WindowsTunWorker::Instance().Post(
      [method_name = std::move(method_name),
       arguments = std::move(arguments_copy), has_arguments,
       result = std::move(result_ptr)]() mutable {
        const EncodableMap* worker_arguments =
            has_arguments ? &arguments : nullptr;
        EncodableValue response =
            HandleWindowsTunMethodCall(method_name, worker_arguments);
        result->Success(response);
      });
}
}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateWindowsTunChannel(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, kWindowsTunChannelName,
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        std::string method_name = call.method_name();
        if (!IsWindowsTunMethodImplemented(method_name)) {
          result->NotImplemented();
          return;
        }

        const auto* arguments = std::get_if<EncodableMap>(call.arguments());
        RunWindowsTunMethodAsync(std::move(method_name), arguments,
                                 std::move(result));
      });

  return channel;
}

void PrewarmTunAdapterAsync() {
  std::thread([] {
    std::string status;
    int64_t elapsed_ms = 0;
    int64_t interface_index = 0;
    std::string error;
    // Generous timeout: the helper-process fallback can be slow to spin up
    // on a cold service, and we tolerate the call failing silently.
    constexpr DWORD kTimeoutMs = 8000;
    TryPrewarmTunAdapterViaService(/*interface_alias=*/"EntropyVPN TUN",
                                   kTimeoutMs, &status, &elapsed_ms,
                                   &interface_index, &error);
    // Intentionally no error surfacing — connect-time path will still work
    // (it falls back to creating the adapter on demand, just slower).
  }).detach();
}

void ReleaseTunAdapterSync() {
  bool released = false;
  std::string error;
  constexpr DWORD kTimeoutMs = 2000;
  TryReleaseTunAdapterViaService(kTimeoutMs, &released, &error);
}
