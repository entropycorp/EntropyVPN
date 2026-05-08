#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kSingleInstanceMutexName[] =
    L"Local\\EntropyVPN.SingleInstance";
constexpr wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kWindowTitle[] = L"EntropyVPN";
constexpr char kElevatedRelaunchArgument[] =
    "--entropyvpn-elevated-relaunch";

void ActivateExistingInstance() {
  HWND hwnd = FindWindowW(kWindowClassName, kWindowTitle);
  if (hwnd == nullptr) {
    return;
  }

  ShowWindow(hwnd, IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(hwnd);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {


  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
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
