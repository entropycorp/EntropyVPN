#include "windows_runtime_channel.h"

#include "windows_runtime_channel_controller.h"
#include "windows_runtime_channel_support.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <utility>
#include <variant>

namespace {

using entropy_vpn::windows_runtime::EncodableMap;
using entropy_vpn::windows_runtime::EncodableValue;
using entropy_vpn::windows_runtime::MakeFailure;
using entropy_vpn::windows_runtime::ReadBool;
using entropy_vpn::windows_runtime::WindowsRuntimeWorker;

EncodableValue InvalidArgumentsResponse() {
  return EncodableValue(
      MakeFailure("arguments", "Invalid Windows runtime arguments.",
                  ERROR_INVALID_PARAMETER));
}

void RunRuntimeMethodAsync(
    const std::string& method,
    const EncodableMap* arguments,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const bool has_arguments = arguments != nullptr;
  EncodableMap arguments_copy;
  if (has_arguments) {
    arguments_copy = *arguments;
  }

  std::shared_ptr<flutter::MethodResult<EncodableValue>> result_ptr(
      std::move(result));
  WindowsRuntimeWorker::Instance().Post(
      [method, has_arguments, arguments = std::move(arguments_copy),
       result = std::move(result_ptr)]() mutable {
        if (method == "start") {
          if (!has_arguments) {
            result->Success(InvalidArgumentsResponse());
            return;
          }
          result->Success(
              entropy_vpn::windows_runtime::StartWindowsRuntime(arguments));
          return;
        }
        if (method == "stop") {
          bool wait_for_cleanup = false;
          if (has_arguments) {
            ReadBool(arguments, "waitForCleanup", &wait_for_cleanup);
          }
          result->Success(entropy_vpn::windows_runtime::StopWindowsRuntime(
              wait_for_cleanup));
          return;
        }
        if (method == "status") {
          result->Success(
              entropy_vpn::windows_runtime::WindowsRuntimeStatus());
          return;
        }
        if (method == "prewarmTunAdapter") {
          result->Success(
              entropy_vpn::windows_runtime::PrewarmWindowsTunAdapter());
          return;
        }
        result->NotImplemented();
      });
}

}  // namespace

WindowsRuntimeChannels CreateWindowsRuntimeChannels(
    flutter::BinaryMessenger* messenger) {
  WindowsRuntimeChannels channels;
  channels.method =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger,
          entropy_vpn::windows_runtime::kWindowsRuntimeMethodChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  channels.events =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger,
          entropy_vpn::windows_runtime::kWindowsRuntimeEventChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  channels.method->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        const auto* arguments = std::get_if<EncodableMap>(call.arguments());
        RunRuntimeMethodAsync(call.method_name(), arguments, std::move(result));
      });

  auto stream_handler =
      std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
          [](const EncodableValue*,
             std::unique_ptr<flutter::EventSink<EncodableValue>>&& events)
              -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
            entropy_vpn::windows_runtime::SetWindowsRuntimeEventSink(
                std::move(events));
            return nullptr;
          },
          [](const EncodableValue*)
              -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
            entropy_vpn::windows_runtime::ClearWindowsRuntimeEventSink();
            return nullptr;
          });
  channels.events->SetStreamHandler(std::move(stream_handler));
  return channels;
}
