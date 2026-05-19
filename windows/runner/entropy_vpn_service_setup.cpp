#include "entropy_vpn_service_setup.h"

#include <sddl.h>
#include <shellapi.h>
#include <winsvc.h>

#include <algorithm>
#include <cwctype>
#include <vector>

namespace entropy_vpn {
namespace {

constexpr wchar_t kServiceDisplay[] = L"EntropyVPN Service";
constexpr wchar_t kServiceDescription[] =
    L"Provides privileged Windows TUN mode support for EntropyVPN.";
// Matches the SDDL the installer applies via `sc sdset` so portable and
// installed builds end up with the exact same access controls: SYSTEM and
// Builtin Administrators get full control, Authenticated Users get start /
// stop / query — that last one is what lets the non-elevated UI talk to
// the service over the pipe without a UAC prompt.
constexpr wchar_t kServiceSddl[] =
    L"D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)"
    L"(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)"
    L"(A;;CCLCSWRPWPDTLOCRRC;;;AU)";
constexpr wchar_t kEntropyServiceExe[] = L"entropy_vpn_service.exe";

std::wstring LowerWide(std::wstring s) {
  for (wchar_t& c : s) {
    c = static_cast<wchar_t>(std::towlower(c));
  }
  return s;
}

std::wstring NormalizePath(std::wstring path) {
  std::replace(path.begin(), path.end(), L'/', L'\\');
  while (path.size() > 1 && path.back() == L'\\') {
    path.pop_back();
  }
  return LowerWide(std::move(path));
}

// CreateService binPath format mirrors the installer's:
//   "{app}\entropy_vpn_service.exe" service
// The trailing `service` is the arg entropy_vpn_service.cpp's main()
// dispatches on to enter service-control-handler mode.
std::wstring BuildBinPath(const std::wstring& install_dir) {
  return L"\"" + install_dir + L"\\" + std::wstring(kEntropyServiceExe) +
         L"\" service";
}

DWORD ApplyAccessControl(SC_HANDLE service) {
  PSECURITY_DESCRIPTOR sd = nullptr;
  if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
          kServiceSddl, SDDL_REVISION_1, &sd, nullptr) == 0) {
    return GetLastError();
  }
  DWORD err = NO_ERROR;
  if (SetServiceObjectSecurity(service, DACL_SECURITY_INFORMATION, sd) == 0) {
    err = GetLastError();
  }
  LocalFree(sd);
  return err;
}

DWORD StopServiceIfRunning(SC_HANDLE service) {
  SERVICE_STATUS status{};
  if (ControlService(service, SERVICE_CONTROL_STOP, &status) == 0) {
    const DWORD err = GetLastError();
    if (err == ERROR_SERVICE_NOT_ACTIVE) {
      return NO_ERROR;
    }
    return err;
  }
  // Wait briefly for the service to stop so DeleteService doesn't get a
  // "pending delete" status that survives until the next reboot.
  for (int i = 0; i < 20; ++i) {
    if (QueryServiceStatus(service, &status) == 0) {
      break;
    }
    if (status.dwCurrentState == SERVICE_STOPPED) {
      return NO_ERROR;
    }
    Sleep(250);
  }
  return NO_ERROR;
}

}  // namespace

bool IsServiceInstalledCorrectly(const std::wstring& install_dir) {
  SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (scm == nullptr) {
    return false;
  }
  SC_HANDLE service =
      OpenServiceW(scm, kEntropyServiceName, SERVICE_QUERY_CONFIG);
  if (service == nullptr) {
    CloseServiceHandle(scm);
    return false;
  }

  DWORD bytes_needed = 0;
  QueryServiceConfigW(service, nullptr, 0, &bytes_needed);
  if (bytes_needed == 0) {
    CloseServiceHandle(service);
    CloseServiceHandle(scm);
    return false;
  }
  std::vector<BYTE> buffer(bytes_needed);
  auto* config = reinterpret_cast<QUERY_SERVICE_CONFIGW*>(buffer.data());
  bool match = false;
  if (QueryServiceConfigW(service, config, bytes_needed, &bytes_needed) != 0 &&
      config->lpBinaryPathName != nullptr) {
    const std::wstring expected = BuildBinPath(install_dir);
    match = NormalizePath(config->lpBinaryPathName) == NormalizePath(expected);
  }

  CloseServiceHandle(service);
  CloseServiceHandle(scm);
  return match;
}

DWORD InstallService(const std::wstring& install_dir) {
  // Replace any existing registration first — handles the "user moved the
  // portable folder" case where the old binPath now points at nothing.
  UninstallService();

  SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr,
                                 SC_MANAGER_CONNECT | SC_MANAGER_CREATE_SERVICE);
  if (scm == nullptr) {
    return GetLastError();
  }

  const std::wstring bin_path = BuildBinPath(install_dir);
  SC_HANDLE service = CreateServiceW(
      scm, kEntropyServiceName, kServiceDisplay, SERVICE_ALL_ACCESS,
      SERVICE_WIN32_OWN_PROCESS, SERVICE_DEMAND_START, SERVICE_ERROR_NORMAL,
      bin_path.c_str(),
      /*load order group*/ nullptr,
      /*tag id*/ nullptr,
      /*dependencies*/ nullptr,
      /*service start name (LocalSystem)*/ nullptr,
      /*password*/ nullptr);
  if (service == nullptr) {
    const DWORD err = GetLastError();
    CloseServiceHandle(scm);
    return err;
  }

  SERVICE_DESCRIPTIONW desc{};
  desc.lpDescription = const_cast<LPWSTR>(kServiceDescription);
  ChangeServiceConfig2W(service, SERVICE_CONFIG_DESCRIPTION, &desc);

  ApplyAccessControl(service);

  CloseServiceHandle(service);
  CloseServiceHandle(scm);
  return NO_ERROR;
}

DWORD UninstallService() {
  SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (scm == nullptr) {
    return GetLastError();
  }
  SC_HANDLE service =
      OpenServiceW(scm, kEntropyServiceName, SERVICE_STOP | DELETE);
  if (service == nullptr) {
    const DWORD err = GetLastError();
    CloseServiceHandle(scm);
    return err == ERROR_SERVICE_DOES_NOT_EXIST ? NO_ERROR : err;
  }

  StopServiceIfRunning(service);
  if (DeleteService(service) == 0) {
    const DWORD err = GetLastError();
    CloseServiceHandle(service);
    CloseServiceHandle(scm);
    // Already-marked-for-deletion is fine.
    return err == ERROR_SERVICE_MARKED_FOR_DELETE ? NO_ERROR : err;
  }
  CloseServiceHandle(service);
  CloseServiceHandle(scm);
  return NO_ERROR;
}

DWORD SpawnElevatedInstall(const std::wstring& current_exe) {
  SHELLEXECUTEINFOW info{};
  info.cbSize = sizeof(info);
  info.fMask = SEE_MASK_NOCLOSEPROCESS;
  info.lpVerb = L"runas";
  info.lpFile = current_exe.c_str();
  info.lpParameters = kInstallServiceArg;
  info.nShow = SW_HIDE;
  if (ShellExecuteExW(&info) == 0) {
    return GetLastError();
  }
  if (info.hProcess == nullptr) {
    return NO_ERROR;
  }
  WaitForSingleObject(info.hProcess, INFINITE);
  DWORD exit_code = 0;
  GetExitCodeProcess(info.hProcess, &exit_code);
  CloseHandle(info.hProcess);
  return exit_code;
}

}  // namespace entropy_vpn
