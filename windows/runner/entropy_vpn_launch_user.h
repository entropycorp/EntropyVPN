#pragma once

// Helper used by the in-app updater to bring the UI back up after applying
// an update. The service runs as SYSTEM and so cannot launch a Flutter window
// directly — a process spawned by the service would also run as SYSTEM, with
// no access to the logged-in user's desktop/profile. We instead grab a token
// for whoever's at the console session and use CreateProcessAsUserW so the
// new entropy_vpn.exe comes up as that user, with their environment and on
// their visible desktop.
//
// Header-only because both entropy_vpn_service.exe (via apply.cpp) and the
// standalone entropy_vpn_updater.exe need it, and the latter intentionally
// doesn't link the shared static lib.

#include <windows.h>
#include <userenv.h>
#include <wtsapi32.h>

#include <string>

namespace entropy_vpn {

inline DWORD LaunchInActiveUserSession(
    const std::wstring& executable,
    const std::wstring& working_directory) {
  const DWORD session = WTSGetActiveConsoleSessionId();
  if (session == 0xFFFFFFFF) {
    return ERROR_NOT_LOGGED_ON;
  }

  HANDLE user_token = nullptr;
  if (WTSQueryUserToken(session, &user_token) == 0) {
    return GetLastError();
  }

  // Best-effort: if CreateEnvironmentBlock fails we still try to launch with
  // a default environment, which is usually enough for a desktop GUI app.
  LPVOID env_block = nullptr;
  const BOOL has_env =
      CreateEnvironmentBlock(&env_block, user_token, FALSE);

  STARTUPINFOW startup_info{};
  startup_info.cb = sizeof(startup_info);
  // Without an explicit desktop string the new process can't open windows.
  wchar_t desktop[] = L"winsta0\\default";
  startup_info.lpDesktop = desktop;

  // CreateProcessAsUserW wants a mutable buffer for the command line.
  std::wstring command_line = L"\"" + executable + L"\"";

  PROCESS_INFORMATION process_info{};
  const BOOL ok = CreateProcessAsUserW(
      user_token,
      executable.c_str(),
      command_line.data(),
      nullptr,
      nullptr,
      FALSE,
      CREATE_UNICODE_ENVIRONMENT | NORMAL_PRIORITY_CLASS,
      has_env ? env_block : nullptr,
      working_directory.empty() ? nullptr : working_directory.c_str(),
      &startup_info,
      &process_info);
  const DWORD error = ok ? NO_ERROR : GetLastError();

  if (has_env && env_block != nullptr) {
    DestroyEnvironmentBlock(env_block);
  }
  CloseHandle(user_token);
  if (ok) {
    CloseHandle(process_info.hThread);
    CloseHandle(process_info.hProcess);
  }
  return error;
}

}  // namespace entropy_vpn
