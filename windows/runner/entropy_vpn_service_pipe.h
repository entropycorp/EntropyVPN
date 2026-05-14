#pragma once

#include <atomic>
#include <string>

namespace entropy_vpn_service {

void PipeServerLoop(const std::atomic<bool>* stop_requested);
void NudgePipeServer();
bool SendPipeRequest(const std::string& request,
                     std::string* response,
                     std::string* error);

}  // namespace entropy_vpn_service

