// entropy_vpn_updater.exe — finishes a service self-update.
//
// The EntropyVPN service cannot replace its own running executable, so when an
// update changes entropy_vpn_service.exe the service:
//   1. stages the new binary as entropy_vpn_service.exe.new,
//   2. launches this helper,
//   3. stops itself.
//
// This helper waits for the service process to exit, swaps the new binary in,
// and restarts the service. It runs as SYSTEM (a detached child of the SYSTEM
// service), so it has the rights to write Program Files and to use the SCM.
//
//   entropy_vpn_updater.exe --install-dir <dir> --service-pid <pid>

#include <windows.h>

#include <cstdlib>
#include <string>
#include <vector>

#include "entropy_vpn_launch_user.h"

namespace {

std::wstring OptionValue(const std::vector<std::wstring>& args,
                         const std::wstring& name) {
  for (size_t i = 0; i + 1 < args.size(); ++i) {
    if (args[i] == name) {
      return args[i + 1];
    }
  }
  return std::wstring();
}

void WaitForProcessExit(DWORD pid, DWORD timeout_ms) {
  if (pid == 0) {
    return;
  }
  HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, pid);
  if (process == nullptr) {
    return;  // already gone
  }
  WaitForSingleObject(process, timeout_ms);
  CloseHandle(process);
}

bool ReplaceServiceBinary(const std::wstring& install_dir) {
  const std::wstring service_exe = install_dir + L"\\entropy_vpn_service.exe";
  const std::wstring new_exe = install_dir + L"\\entropy_vpn_service.exe.new";
  if (GetFileAttributesW(new_exe.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return false;
  }
  // The SCM may keep the old binary locked for a moment after the process
  // exits; retry briefly before giving up.
  for (int attempt = 0; attempt < 20; ++attempt) {
    if (MoveFileExW(new_exe.c_str(), service_exe.c_str(),
                    MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0) {
      return true;
    }
    Sleep(500);
  }
  return false;
}

void StartEntropyService() {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (manager == nullptr) {
    return;
  }
  SC_HANDLE service =
      OpenServiceW(manager, L"EntropyVPNService", SERVICE_START);
  if (service != nullptr) {
    StartServiceW(service, 0, nullptr);
    CloseServiceHandle(service);
  }
  CloseServiceHandle(manager);
}

}  // namespace

int wmain() {
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  std::vector<std::wstring> args;
  if (argv != nullptr) {
    for (int i = 0; i < argc; ++i) {
      args.emplace_back(argv[i]);
    }
    LocalFree(argv);
  }

  const std::wstring install_dir = OptionValue(args, L"--install-dir");
  const std::wstring pid_text = OptionValue(args, L"--service-pid");
  if (install_dir.empty()) {
    return 1;
  }
  const DWORD service_pid =
      pid_text.empty() ? 0 : static_cast<DWORD>(_wtoi(pid_text.c_str()));

  WaitForProcessExit(service_pid, 20000);
  Sleep(500);  // let the SCM release the old binary

  if (!ReplaceServiceBinary(install_dir)) {
    return 2;
  }
  StartEntropyService();

  // Relaunch the UI on the user's desktop. Best-effort — if it fails, the
  // user can just re-open the app manually.
  const std::wstring ui_exe = install_dir + L"\\entropy_vpn.exe";
  entropy_vpn::LaunchInActiveUserSession(ui_exe, install_dir);
  return 0;
}
