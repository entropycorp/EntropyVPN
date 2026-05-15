#ifndef RUNNER_WINDOWS_RUNTIME_CHANNEL_H_
#define RUNNER_WINDOWS_RUNTIME_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>

#include <memory>

struct WindowsRuntimeChannels {
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> method;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events;
};

WindowsRuntimeChannels CreateWindowsRuntimeChannels(
    flutter::BinaryMessenger* messenger);

#endif
