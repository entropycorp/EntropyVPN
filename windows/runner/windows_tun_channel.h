#ifndef RUNNER_WINDOWS_TUN_CHANNEL_H_
#define RUNNER_WINDOWS_TUN_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateWindowsTunChannel(flutter::BinaryMessenger* messenger);

// Asks the EntropyVPN service to pre-create the wintun TUN adapter so xray
// can open an already-settled adapter at connect time. Runs on a detached
// background thread; safe to call before the service is fully ready (it'll
// fall back to the helper-process path or no-op silently). Idempotent.
void PrewarmTunAdapterAsync();

// Asks the service to close the pre-warmed adapter. Blocking, best-effort,
// short-timeout. Intended to run at app shutdown.
void ReleaseTunAdapterSync();

#endif
