#include "entropy_vpn_service_commands.h"

#include "entropy_vpn_service_common.h"
#include "entropy_vpn_service_tun.h"

#include <mutex>
#include <thread>
#include <vector>

namespace entropy_vpn_service {

std::mutex g_core_mutex;
HANDLE g_core_process = nullptr;
DWORD g_core_pid = 0;
DWORD g_core_exit_code = 0;
bool g_core_has_exit_code = false;
std::wstring g_core_run_id;

void CloseCoreLocked() {
  if (g_core_process != nullptr) {
    CloseHandle(g_core_process);
    g_core_process = nullptr;
  }
  g_core_pid = 0;
  g_core_run_id.clear();
}

void RefreshCoreExitLocked() {
  if (g_core_process == nullptr) {
    return;
  }
  const DWORD wait = WaitForSingleObject(g_core_process, 0);
  if (wait != WAIT_OBJECT_0) {
    return;
  }
  DWORD exit_code = 0;
  if (GetExitCodeProcess(g_core_process, &exit_code) != 0) {
    g_core_exit_code = exit_code;
    g_core_has_exit_code = true;
  }
  CloseCoreLocked();
}

std::string StatusCore(const std::map<std::string, std::string>& fields) {
  const std::wstring run_id = ReadDecodedWide(fields, "runId");
  std::lock_guard<std::mutex> lock(g_core_mutex);
  RefreshCoreExitLocked();
  const bool matches =
      !run_id.empty() && !g_core_run_id.empty() && run_id == g_core_run_id;
  const bool running = g_core_process != nullptr && (run_id.empty() || matches);
  std::vector<std::pair<std::string, std::string>> response;
  response.push_back({"ok", "1"});
  response.push_back({"running", running ? "1" : "0"});
  response.push_back({"pid", std::to_string(running ? g_core_pid : 0)});
  if (!running && g_core_has_exit_code) {
    response.push_back({"exitCode", std::to_string(g_core_exit_code)});
  }
  return BuildResponse(response);
}

std::string StopCore(const std::map<std::string, std::string>& fields) {
  const std::wstring run_id = ReadDecodedWide(fields, "runId");
  HANDLE process = nullptr;
  DWORD pid = 0;
  {
    std::lock_guard<std::mutex> lock(g_core_mutex);
    RefreshCoreExitLocked();
    if (g_core_process == nullptr) {
      return BuildResponse({{"ok", "1"}, {"stopped", "0"}, {"exitCode", "0"}});
    }
    if (!run_id.empty() && !g_core_run_id.empty() && run_id != g_core_run_id) {
      return ErrorResponse("A different EntropyVPN core run is active.",
                           ERROR_BUSY);
    }
    process = g_core_process;
    pid = g_core_pid;
    g_core_process = nullptr;
    g_core_pid = 0;
    g_core_run_id.clear();
  }

  TerminateProcess(process, 0);
  WaitForSingleObject(process, 5000);
  DWORD exit_code = 0;
  GetExitCodeProcess(process, &exit_code);
  CloseHandle(process);

  std::lock_guard<std::mutex> lock(g_core_mutex);
  g_core_exit_code = exit_code;
  g_core_has_exit_code = true;
  return BuildResponse({{"ok", "1"},
                        {"stopped", "1"},
                        {"pid", std::to_string(pid)},
                        {"exitCode", std::to_string(exit_code)}});
}

std::string StartCore(const std::map<std::string, std::string>& fields) {
  const std::wstring run_id = ReadDecodedWide(fields, "runId");
  const std::wstring executable = ReadDecodedWide(fields, "executable");
  const std::wstring working_directory =
      ReadDecodedWide(fields, "workingDirectory");
  const std::wstring stdout_path = ReadDecodedWide(fields, "stdoutPath");
  const std::wstring stderr_path = ReadDecodedWide(fields, "stderrPath");
  const std::vector<std::wstring> args = ReadArguments(fields);
  if (run_id.empty() || executable.empty() || stdout_path.empty() ||
      stderr_path.empty()) {
    return ErrorResponse("Missing required start_core arguments.",
                         ERROR_INVALID_PARAMETER);
  }
  const std::wstring resolved_executable = ResolveAllowedCoreExecutable(executable);
  if (resolved_executable.empty()) {
    return ErrorResponse("Service helper rejected a core executable outside the installed cores directory.",
                         ERROR_ACCESS_DENIED);
  }

  HANDLE old_process = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_core_mutex);
    RefreshCoreExitLocked();
    old_process = g_core_process;
    g_core_process = nullptr;
    g_core_pid = 0;
    g_core_run_id.clear();
  }
  if (old_process != nullptr) {
    TerminateProcess(old_process, 0);
    WaitForSingleObject(old_process, 5000);
    CloseHandle(old_process);
  }

  SECURITY_ATTRIBUTES inherit_security{};
  inherit_security.nLength = sizeof(inherit_security);
  inherit_security.bInheritHandle = TRUE;

  HANDLE stdout_file = CreateFileW(
      stdout_path.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE |
                                          FILE_SHARE_DELETE,
      &inherit_security, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (stdout_file == INVALID_HANDLE_VALUE) {
    return ErrorResponse("Could not open core stdout log: " +
                             ErrorMessage(GetLastError()),
                         GetLastError());
  }

  HANDLE stderr_file = CreateFileW(
      stderr_path.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE |
                                          FILE_SHARE_DELETE,
      &inherit_security, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (stderr_file == INVALID_HANDLE_VALUE) {
    const DWORD error = GetLastError();
    CloseHandle(stdout_file);
    return ErrorResponse("Could not open core stderr log: " +
                             ErrorMessage(error),
                         error);
  }

  HANDLE nul_file = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ,
                                &inherit_security, OPEN_EXISTING,
                                FILE_ATTRIBUTE_NORMAL, nullptr);

  STARTUPINFOW startup_info{};
  startup_info.cb = sizeof(startup_info);
  startup_info.dwFlags = STARTF_USESTDHANDLES;
  startup_info.hStdInput = nul_file == INVALID_HANDLE_VALUE ? nullptr : nul_file;
  startup_info.hStdOutput = stdout_file;
  startup_info.hStdError = stderr_file;

  PROCESS_INFORMATION process_info{};
  std::wstring command_line = BuildCommandLine(resolved_executable, args);
  const BOOL created = CreateProcessW(
      resolved_executable.c_str(), command_line.data(), nullptr, nullptr, TRUE,
      CREATE_NO_WINDOW, nullptr,
      working_directory.empty() ? nullptr : working_directory.c_str(),
      &startup_info, &process_info);
  const DWORD create_error = GetLastError();

  CloseHandleIfValid(&nul_file);
  CloseHandleIfValid(&stdout_file);
  CloseHandleIfValid(&stderr_file);

  if (created == 0) {
    return ErrorResponse("Could not start core process: " +
                             ErrorMessage(create_error),
                         create_error);
  }
  CloseHandle(process_info.hThread);

  {
    std::lock_guard<std::mutex> lock(g_core_mutex);
    g_core_process = process_info.hProcess;
    g_core_pid = process_info.dwProcessId;
    g_core_run_id = run_id;
    g_core_has_exit_code = false;
    g_core_exit_code = 0;
  }

  std::vector<std::pair<std::string, std::string>> response;
  response.push_back({"ok", "1"});
  response.push_back({"pid", std::to_string(process_info.dwProcessId)});
  AddTextField(&response, "executableB64", Utf8FromWide(resolved_executable));
  return BuildResponse(response);
}

void ReadPipeToString(HANDLE pipe, std::string* output) {
  char buffer[4096];
  while (true) {
    DWORD read = 0;
    const BOOL ok = ReadFile(pipe, buffer, static_cast<DWORD>(sizeof(buffer)),
                             &read, nullptr);
    if (ok == 0 || read == 0) {
      break;
    }
    output->append(buffer, buffer + read);
  }
}

std::string RunAllowedProcess(
    const std::map<std::string, std::string>& fields) {
  const std::wstring executable = ReadDecodedWide(fields, "executable");
  const std::wstring working_directory =
      ReadDecodedWide(fields, "workingDirectory");
  const std::vector<std::wstring> args = ReadArguments(fields);
  const DWORD timeout_ms = ReadDword(fields, "timeoutMs", 30000);
  if (executable.empty() || !IsAllowedToolInvocation(executable, args)) {
    return ErrorResponse("Service helper rejected a non-allowlisted tool.",
                         ERROR_ACCESS_DENIED);
  }

  SECURITY_ATTRIBUTES pipe_security{};
  pipe_security.nLength = sizeof(pipe_security);
  pipe_security.bInheritHandle = TRUE;

  HANDLE stdout_read = nullptr;
  HANDLE stdout_write = nullptr;
  HANDLE stderr_read = nullptr;
  HANDLE stderr_write = nullptr;
  if (CreatePipe(&stdout_read, &stdout_write, &pipe_security, 0) == 0 ||
      CreatePipe(&stderr_read, &stderr_write, &pipe_security, 0) == 0) {
    const DWORD error = GetLastError();
    CloseHandleIfValid(&stdout_read);
    CloseHandleIfValid(&stdout_write);
    CloseHandleIfValid(&stderr_read);
    CloseHandleIfValid(&stderr_write);
    return ErrorResponse("Could not create capture pipes: " +
                             ErrorMessage(error),
                         error);
  }
  SetHandleInformation(stdout_read, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(stderr_read, HANDLE_FLAG_INHERIT, 0);

  STARTUPINFOW startup_info{};
  startup_info.cb = sizeof(startup_info);
  startup_info.dwFlags = STARTF_USESTDHANDLES;
  startup_info.hStdOutput = stdout_write;
  startup_info.hStdError = stderr_write;
  startup_info.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

  PROCESS_INFORMATION process_info{};
  std::wstring command_line = BuildCommandLine(executable, args);
  const BOOL created = CreateProcessW(
      nullptr, command_line.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW,
      nullptr, working_directory.empty() ? nullptr : working_directory.c_str(),
      &startup_info, &process_info);
  const DWORD create_error = GetLastError();
  CloseHandleIfValid(&stdout_write);
  CloseHandleIfValid(&stderr_write);
  if (created == 0) {
    CloseHandleIfValid(&stdout_read);
    CloseHandleIfValid(&stderr_read);
    return ErrorResponse("Could not run allowlisted tool: " +
                             ErrorMessage(create_error),
                         create_error);
  }

  std::string stdout_text;
  std::string stderr_text;
  std::thread stdout_thread(ReadPipeToString, stdout_read, &stdout_text);
  std::thread stderr_thread(ReadPipeToString, stderr_read, &stderr_text);

  bool timed_out = false;
  DWORD wait_result = WaitForSingleObject(process_info.hProcess, timeout_ms);
  if (wait_result == WAIT_TIMEOUT) {
    timed_out = true;
    TerminateProcess(process_info.hProcess, WAIT_TIMEOUT);
    WaitForSingleObject(process_info.hProcess, 5000);
  }

  DWORD exit_code = 1;
  GetExitCodeProcess(process_info.hProcess, &exit_code);
  CloseHandle(process_info.hThread);
  CloseHandle(process_info.hProcess);
  stdout_thread.join();
  stderr_thread.join();
  CloseHandleIfValid(&stdout_read);
  CloseHandleIfValid(&stderr_read);

  std::vector<std::pair<std::string, std::string>> response;
  response.push_back({"ok", "1"});
  response.push_back({"pid", std::to_string(process_info.dwProcessId)});
  response.push_back({"exitCode", std::to_string(exit_code)});
  response.push_back({"timedOut", timed_out ? "1" : "0"});
  AddTextField(&response, "stdoutB64", stdout_text);
  AddTextField(&response, "stderrB64", stderr_text);
  return BuildResponse(response);
}

std::string HandleRequest(const std::string& request_text) {
  const auto fields = ParseFields(request_text);
  const auto command = fields.find("command");
  if (command == fields.end()) {
    return ErrorResponse("Missing service command.", ERROR_INVALID_PARAMETER);
  }
  if (command->second == "ping") {
    return OkResponse();
  }
  if (command->second == "start_core") {
    return StartCore(fields);
  }
  if (command->second == "stop_core") {
    return StopCore(fields);
  }
  if (command->second == "status_core") {
    return StatusCore(fields);
  }
  if (command->second == "run_process") {
    return RunAllowedProcess(fields);
  }
  if (command->second == "prepare_ipv4_server_route") {
    return PrepareIpv4ServerRouteNative(fields);
  }
  if (command->second == "prepare_domain_server_route") {
    return PrepareDomainServerRouteNative(fields);
  }
  if (command->second == "prepare_xray_tun_ipv4_routes") {
    return PrepareXrayTunIpv4RoutesNative(fields);
  }
  return ErrorResponse("Unknown service command.", ERROR_INVALID_PARAMETER);
}

void StopActiveCore() {
  std::lock_guard<std::mutex> lock(g_core_mutex);
  if (g_core_process != nullptr) {
    TerminateProcess(g_core_process, 0);
    WaitForSingleObject(g_core_process, 5000);
    CloseCoreLocked();
  }
}
}  // namespace entropy_vpn_service

