#include "windows_tun_channel.h"

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
#include <cstdint>
#include <cwctype>
#include <cstring>
#include <cstdlib>
#include <deque>
#include <limits>
#include <sstream>
#include <string>
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
constexpr wchar_t kEntropyVpnServicePipeName[] =
    L"\\\\.\\pipe\\EntropyVPNService";
constexpr wchar_t kEntropyVpnServiceExecutableName[] =
    L"entropy_vpn_service.exe";

using EncodableList = flutter::EncodableList;
using EncodableMap = flutter::EncodableMap;
using EncodableValue = flutter::EncodableValue;


#include "windows_tun_channel/windows_tun_channel_common.inc"
#include "windows_tun_channel/windows_tun_channel_routes.inc"
#include "windows_tun_channel/windows_tun_channel_proxy.inc"
#include "windows_tun_channel/windows_tun_channel_service.inc"
#include "windows_tun_channel/windows_tun_channel_methods.inc"
}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateWindowsTunChannel(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, kWindowsTunChannelName,
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        const auto* arguments = std::get_if<EncodableMap>(call.arguments());
        if (call.method_name() == kConfigureXrayTunIpv4Method) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(ConfigureXrayTunIpv4(*arguments));
          return;
        }

        if (call.method_name() == kPrepareIpv4ServerRouteMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(PrepareIpv4ServerRoute(*arguments));
          return;
        }

        if (call.method_name() == kPrepareTunServerRoutingMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(PrepareTunServerRouting(*arguments));
          return;
        }

        if (call.method_name() == kPrepareXrayTunRoutesMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(PrepareXrayTunRoutes(*arguments));
          return;
        }

        if (call.method_name() == kPrepareServerRoutesMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(PrepareServerRoutes(*arguments));
          return;
        }

        if (call.method_name() == kRemoveIpv4RoutesMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(RemoveIpv4Routes(*arguments));
          return;
        }

        if (call.method_name() == kRemoveRoutesMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(RemoveRoutes(*arguments));
          return;
        }

        if (call.method_name() == kCaptureSystemProxyMethod) {
          result->Success(CaptureSystemProxy());
          return;
        }

        if (call.method_name() == kSetSystemProxyMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(SetSystemProxy(*arguments));
          return;
        }

        if (call.method_name() == kRelaunchAsAdministratorMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(RelaunchAsAdministrator(*arguments));
          return;
        }

        if (call.method_name() == kStartWindowsServiceMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(StartWindowsService(*arguments));
          return;
        }

        if (call.method_name() == kRunWindowsServiceHelperMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(RunWindowsServiceHelper(*arguments));
          return;
        }

        if (call.method_name() == kStopStaleCoreProcessesMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(StopStaleCoreProcessesNative(*arguments));
          return;
        }

        if (call.method_name() == kTerminateProcessTreeMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(TerminateProcessTreeNative(*arguments));
          return;
        }

        if (call.method_name() == kExpandSplitTunnelProcessTreeMethod) {
          if (arguments == nullptr) {
            EncodableMap response;
            AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
            result->Success(EncodableValue(std::move(response)));
            return;
          }

          result->Success(ExpandSplitTunnelProcessTree(*arguments));
          return;
        }

        {
          result->NotImplemented();
          return;
        }
      });

  return channel;
}
