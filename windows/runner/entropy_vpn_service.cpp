#include <windows.h>
#include <shellapi.h>

#include "entropy_vpn_service_commands.h"
#include "entropy_vpn_service_common.h"
#include "entropy_vpn_service_pipe.h"
#include "entropy_vpn_service_protocol.h"

#include <atomic>
#include <string>
#include <thread>
#include <vector>

namespace entropy_vpn_service {

SERVICE_STATUS_HANDLE g_status_handle = nullptr;
SERVICE_STATUS g_status{};
HANDLE g_stop_event = nullptr;
std::atomic<bool> g_stop_requested(false);

void SetServiceState(DWORD state, DWORD win32_exit_code = NO_ERROR,
                     DWORD wait_hint = 0) {
  g_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
  g_status.dwCurrentState = state;
  g_status.dwControlsAccepted =
      state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN : 0;
  g_status.dwWin32ExitCode = win32_exit_code;
  g_status.dwServiceSpecificExitCode = 0;
  g_status.dwCheckPoint = 0;
  g_status.dwWaitHint = wait_hint;
  if (g_status_handle != nullptr) {
    SetServiceStatus(g_status_handle, &g_status);
  }
}

DWORD WINAPI ServiceControlHandler(DWORD control, DWORD event_type,
                                   LPVOID event_data, LPVOID context) {
  UNREFERENCED_PARAMETER(event_type);
  UNREFERENCED_PARAMETER(event_data);
  UNREFERENCED_PARAMETER(context);
  if (control == SERVICE_CONTROL_STOP || control == SERVICE_CONTROL_SHUTDOWN) {
    SetServiceState(SERVICE_STOP_PENDING, NO_ERROR, 5000);
    g_stop_requested.store(true);
    if (g_stop_event != nullptr) {
      SetEvent(g_stop_event);
    }
    NudgePipeServer();
    return NO_ERROR;
  }
  return NO_ERROR;
}

void WINAPI ServiceMain(DWORD argc, LPWSTR* argv) {
  UNREFERENCED_PARAMETER(argc);
  UNREFERENCED_PARAMETER(argv);
  g_status_handle = RegisterServiceCtrlHandlerExW(
      kServiceName, ServiceControlHandler, nullptr);
  if (g_status_handle == nullptr) {
    return;
  }

  SetServiceState(SERVICE_START_PENDING, NO_ERROR, 3000);
  g_stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (g_stop_event == nullptr) {
    SetServiceState(SERVICE_STOPPED, GetLastError());
    return;
  }

  g_stop_requested.store(false);
  std::thread pipe_thread(PipeServerLoop, &g_stop_requested);
  SetServiceState(SERVICE_RUNNING);

  WaitForSingleObject(g_stop_event, INFINITE);
  g_stop_requested.store(true);
  NudgePipeServer();
  if (pipe_thread.joinable()) {
    pipe_thread.join();
  }

  StopActiveCore();

  CloseHandleIfValid(&g_stop_event);
  SetServiceState(SERVICE_STOPPED);
}

bool ResponseIsOk(const std::string& response) {
  const auto fields = ParseFields(response);
  const auto ok = fields.find("ok");
  return ok != fields.end() && ok->second == "1";
}

void WriteStdout(const std::string& text) {
  DWORD written = 0;
  HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
  if (output != INVALID_HANDLE_VALUE && output != nullptr) {
    WriteFile(output, text.data(), static_cast<DWORD>(text.size()), &written,
              nullptr);
  }
}

void WriteStderr(const std::string& text) {
  DWORD written = 0;
  HANDLE output = GetStdHandle(STD_ERROR_HANDLE);
  if (output != INVALID_HANDLE_VALUE && output != nullptr) {
    WriteFile(output, text.data(), static_cast<DWORD>(text.size()), &written,
              nullptr);
  }
}

std::vector<std::wstring> CommandLineArguments() {
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  std::vector<std::wstring> args;
  if (argv != nullptr) {
    for (int i = 0; i < argc; ++i) {
      args.emplace_back(argv[i]);
    }
    LocalFree(argv);
  }
  return args;
}

int ClientMain(const std::vector<std::wstring>& args) {
  if (args.size() < 2) {
    WriteStderr("Usage: entropy_vpn_service.exe service|ping|start-core|stop-core|status-core|run-process|prepare-ipv4-server-route|prepare-domain-server-route|prepare-xray-tun-ipv4-routes\n");
    return 64;
  }

  std::vector<std::string> request_args;
  request_args.reserve(args.size() - 1);
  for (size_t i = 1; i < args.size(); ++i) {
    request_args.push_back(Utf8FromWide(args[i]));
  }

  std::string request;
  std::string build_error;
  if (!BuildWindowsServiceRequest(request_args, &request, &build_error)) {
    WriteStderr(build_error + "\n");
    return 64;
  }

  std::string response;
  std::string error;
  if (!SendPipeRequest(request, &response, &error)) {
    WriteStderr(error + "\n");
    return 2;
  }
  WriteStdout(response);
  return ResponseIsOk(response) ? 0 : 1;
}

}  // namespace entropy_vpn_service

int wmain() {
  const std::vector<std::wstring> args =
      entropy_vpn_service::CommandLineArguments();
  if (args.size() >= 2 && args[1] == L"service") {
    SERVICE_TABLE_ENTRYW service_table[] = {
        {const_cast<LPWSTR>(entropy_vpn_service::kServiceName),
         entropy_vpn_service::ServiceMain},
        {nullptr, nullptr},
    };
    if (StartServiceCtrlDispatcherW(service_table) == 0) {
      return static_cast<int>(GetLastError());
    }
    return 0;
  }
  return entropy_vpn_service::ClientMain(args);
}


