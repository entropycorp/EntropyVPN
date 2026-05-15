#ifndef RUNNER_WINDOWS_RUNTIME_CHANNEL_CONTROLLER_H_
#define RUNNER_WINDOWS_RUNTIME_CHANNEL_CONTROLLER_H_

#include "windows_runtime_channel_support.h"

#include <flutter/event_sink.h>

#include <memory>

namespace entropy_vpn::windows_runtime {

void SetWindowsRuntimeEventSink(
    std::unique_ptr<flutter::EventSink<EncodableValue>> event_sink);
void ClearWindowsRuntimeEventSink();

EncodableValue StartWindowsRuntime(const EncodableMap& arguments);
EncodableValue StopWindowsRuntime(bool wait_for_cleanup);
EncodableValue WindowsRuntimeStatus();

}  // namespace entropy_vpn::windows_runtime

#endif
