#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "entropy_vpn_service_setup.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kSingleInstanceMutexName[] =
    L"Local\\EntropyVPN.SingleInstance";
constexpr wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kWindowTitle[] = L"EntropyVPN";
constexpr char kElevatedRelaunchArgument[] =
    "--entropyvpn-elevated-relaunch";
constexpr char kInstallServiceArgument[] = "--entropyvpn-install-service";
constexpr char kUninstallServiceArgument[] = "--entropyvpn-uninstall-service";

void ActivateExistingInstance() {
  HWND hwnd = FindWindowW(kWindowClassName, kWindowTitle);
  if (hwnd == nullptr) {
    return;
  }

  ShowWindow(hwnd, IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(hwnd);
}

// Path of the directory holding the running .exe. Used as both the service
// install location (we register the SCM service pointing at this folder's
// entropy_vpn_service.exe) and as the comparison target when checking
// whether an existing registration still points where the user thinks it
// does.
std::wstring ModuleDirectory() {
  wchar_t buffer[MAX_PATH] = {0};
  const DWORD length = GetModuleFileNameW(nullptr, buffer, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return std::wstring();
  }
  std::wstring path(buffer, length);
  const size_t slash = path.find_last_of(L'\\');
  if (slash == std::wstring::npos) {
    return std::wstring();
  }
  return path.substr(0, slash);
}

// Auto-install/repair the SCM service if it's missing or points at the
// wrong folder (which happens when the user moves their portable extract).
// Best-effort: if elevation is denied, we just continue without it — the
// per-op UAC fallback in the channels still works, just noisier. The
// installer-built setup has already registered the service identically, so
// for that route this returns immediately.
void EnsureServiceInstalledIfPossible() {
  const std::wstring install_dir = ModuleDirectory();
  if (install_dir.empty()) {
    return;
  }
  if (entropy_vpn::IsServiceInstalledCorrectly(install_dir)) {
    return;
  }
  // Bail if the bundled service binary isn't next to us — without it we
  // can't register a working service, and the elevation prompt would be a
  // dead end. (Edge case: someone deleted entropy_vpn_service.exe.)
  const std::wstring service_exe = install_dir + L"\\entropy_vpn_service.exe";
  if (GetFileAttributesW(service_exe.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return;
  }

  wchar_t self_path[MAX_PATH] = {0};
  if (GetModuleFileNameW(nullptr, self_path, MAX_PATH) == 0) {
    return;
  }
  entropy_vpn::SpawnElevatedInstall(self_path);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {


  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  std::vector<std::string> command_line_arguments = GetCommandLineArguments();

  // Service install/uninstall is the elevated-child entry point: when the
  // running .exe re-spawns itself with the `runas` verb, this branch fires
  // before anything else (single-instance mutex, COM init, Flutter window)
  // does any work. It just does the SCM op and returns.
  for (const auto& argument : command_line_arguments) {
    if (argument == kInstallServiceArgument) {
      const std::wstring install_dir = ModuleDirectory();
      if (install_dir.empty()) {
        return EXIT_FAILURE;
      }
      return entropy_vpn::InstallService(install_dir) == NO_ERROR
                 ? EXIT_SUCCESS
                 : EXIT_FAILURE;
    }
    if (argument == kUninstallServiceArgument) {
      return entropy_vpn::UninstallService() == NO_ERROR ? EXIT_SUCCESS
                                                          : EXIT_FAILURE;
    }
  }

  bool is_elevated_relaunch = false;
  for (auto argument = command_line_arguments.begin();
       argument != command_line_arguments.end();) {
    if (*argument == kElevatedRelaunchArgument) {
      is_elevated_relaunch = true;
      argument = command_line_arguments.erase(argument);
    } else {
      ++argument;
    }
  }

  HANDLE single_instance_mutex =
      CreateMutexW(nullptr, TRUE, kSingleInstanceMutexName);
  DWORD mutex_error = GetLastError();
  if (!is_elevated_relaunch && single_instance_mutex != nullptr &&
      mutex_error == ERROR_ALREADY_EXISTS) {
    ActivateExistingInstance();
    CloseHandle(single_instance_mutex);
    return EXIT_SUCCESS;
  }
  if (!is_elevated_relaunch && single_instance_mutex == nullptr &&
      mutex_error == ERROR_ACCESS_DENIED) {
    ActivateExistingInstance();
    return EXIT_SUCCESS;
  }

  // First-launch hook for the portable build: if the SCM service isn't
  // registered for this folder yet, re-spawn ourselves with the install arg
  // via `runas` so a one-time UAC click sets it up. After that, TUN starts
  // and auto-update applies go through the SYSTEM service silently — same
  // as the installer-built variant. Skipped on the elevated-relaunch path
  // since that one was already triggered by a privileged op needing UAC of
  // its own.
  if (!is_elevated_relaunch) {
    EnsureServiceInstalledIfPossible();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(kWindowTitle, origin, size)) {
    ::CoUninitialize();
    if (single_instance_mutex != nullptr) {
      CloseHandle(single_instance_mutex);
    }
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single_instance_mutex != nullptr) {
    CloseHandle(single_instance_mutex);
  }
  return EXIT_SUCCESS;
}
