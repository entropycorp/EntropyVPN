#ifndef RUNNER_WINDOWS_APP_CATALOG_CHANNEL_H_
#define RUNNER_WINDOWS_APP_CATALOG_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateWindowsAppCatalogChannel(flutter::BinaryMessenger* messenger);

#endif
