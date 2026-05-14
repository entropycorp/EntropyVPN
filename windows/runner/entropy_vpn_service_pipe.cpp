#include "entropy_vpn_service_pipe.h"

#include "entropy_vpn_service_commands.h"
#include "entropy_vpn_service_common.h"

#include <sddl.h>
#include <thread>
#include <vector>

namespace entropy_vpn_service {

PSECURITY_DESCRIPTOR BuildPipeSecurityDescriptor() {
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  ConvertStringSecurityDescriptorToSecurityDescriptorW(
      L"D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)(A;;GRGW;;;AU)",
      SDDL_REVISION_1, &descriptor, nullptr);
  return descriptor;
}

void HandlePipeClient(HANDLE pipe) {
  std::string request;
  std::vector<char> buffer(8192);
  while (true) {
    DWORD read = 0;
    const BOOL ok = ReadFile(pipe, buffer.data(),
                             static_cast<DWORD>(buffer.size()), &read,
                             nullptr);
    if (ok != 0 && read > 0) {
      request.append(buffer.data(), buffer.data() + read);
      break;
    }
    const DWORD error = GetLastError();
    if (error == ERROR_MORE_DATA) {
      request.append(buffer.data(), buffer.data() + read);
      continue;
    }
    break;
  }

  const std::string response = HandleRequest(request);
  DWORD written = 0;
  WriteFile(pipe, response.data(), static_cast<DWORD>(response.size()),
            &written, nullptr);
  FlushFileBuffers(pipe);
}

void PipeServerLoop(const std::atomic<bool>* stop_requested) {
  PSECURITY_DESCRIPTOR descriptor = BuildPipeSecurityDescriptor();
  SECURITY_ATTRIBUTES security_attributes{};
  security_attributes.nLength = sizeof(security_attributes);
  security_attributes.lpSecurityDescriptor = descriptor;
  security_attributes.bInheritHandle = FALSE;

  while (stop_requested != nullptr && !stop_requested->load()) {
    HANDLE pipe = CreateNamedPipeW(
        kPipeName, PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
        PIPE_UNLIMITED_INSTANCES, kPipeBufferSize, kPipeBufferSize, 0,
        descriptor == nullptr ? nullptr : &security_attributes);
    if (pipe == INVALID_HANDLE_VALUE) {
      Sleep(250);
      continue;
    }

    const BOOL connected =
        ConnectNamedPipe(pipe, nullptr) != 0 || GetLastError() == ERROR_PIPE_CONNECTED;
    if (connected) {
      // Dispatch to a thread so the server can accept new clients immediately.
      // Command handlers are already thread-safe: core state uses g_core_mutex,
      // and TUN/route commands use only stateless Win32 network APIs.
      std::thread([pipe]() {
        HandlePipeClient(pipe);
        DisconnectNamedPipe(pipe);
        CloseHandle(pipe);
      }).detach();
    } else {
      DisconnectNamedPipe(pipe);
      CloseHandle(pipe);
    }
  }

  if (descriptor != nullptr) {
    LocalFree(descriptor);
  }
}

void NudgePipeServer() {
  if (!WaitNamedPipeW(kPipeName, 100)) {
    return;
  }
  HANDLE pipe = CreateFileW(kPipeName, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (pipe != INVALID_HANDLE_VALUE) {
    CloseHandle(pipe);
  }
}
bool SendPipeRequest(const std::string& request, std::string* response,
                     std::string* error) {
  if (!WaitNamedPipeW(kPipeName, 3000)) {
    *error = "EntropyVPN service pipe is not available.";
    return false;
  }
  HANDLE pipe = CreateFileW(kPipeName, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (pipe == INVALID_HANDLE_VALUE) {
    *error = "Could not open EntropyVPN service pipe: " +
             ErrorMessage(GetLastError());
    return false;
  }

  DWORD mode = PIPE_READMODE_MESSAGE;
  SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr);

  DWORD written = 0;
  const BOOL write_ok =
      WriteFile(pipe, request.data(), static_cast<DWORD>(request.size()),
                &written, nullptr);
  if (write_ok == 0) {
    *error = "Could not write to EntropyVPN service pipe: " +
             ErrorMessage(GetLastError());
    CloseHandle(pipe);
    return false;
  }
  FlushFileBuffers(pipe);

  std::vector<char> buffer(8192);
  while (true) {
    DWORD read = 0;
    const BOOL read_ok = ReadFile(pipe, buffer.data(),
                                  static_cast<DWORD>(buffer.size()), &read,
                                  nullptr);
    if (read_ok != 0 && read > 0) {
      response->append(buffer.data(), buffer.data() + read);
      break;
    }
    const DWORD read_error = GetLastError();
    if (read_error == ERROR_MORE_DATA) {
      response->append(buffer.data(), buffer.data() + read);
      continue;
    }
    break;
  }
  CloseHandle(pipe);
  return true;
}

}  // namespace entropy_vpn_service
