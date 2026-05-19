#include "entropy_vpn_service_apply.h"

#include <windows.h>

#include <algorithm>
#include <string>
#include <utility>
#include <vector>

#include "entropy_vpn_launch_user.h"
#include "entropy_vpn_service_common.h"
#include "entropy_vpn_service_log.h"

namespace entropy_vpn_service {
namespace {

bool FileExists(const std::wstring& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

std::wstring LocalPathFor(const std::wstring& install_dir,
                          const std::string& posix_path) {
  std::wstring relative = WideFromUtf8(posix_path);
  std::replace(relative.begin(), relative.end(), L'/', L'\\');
  return install_dir + L"\\" + relative;
}

void CreateParentDirectories(const std::wstring& file_path) {
  const size_t slash = file_path.find_last_of(L'\\');
  if (slash == std::wstring::npos) {
    return;
  }
  const std::wstring directory = file_path.substr(0, slash);
  std::wstring built;
  size_t start = 0;
  while (start <= directory.size()) {
    const size_t next = directory.find(L'\\', start);
    const std::wstring segment = directory.substr(
        0, next == std::wstring::npos ? directory.size() : next);
    if (!segment.empty()) {
      CreateDirectoryW(segment.c_str(), nullptr);
    }
    if (next == std::wstring::npos) {
      break;
    }
    start = next + 1;
  }
}

void RemoveDirectoryRecursive(const std::wstring& directory) {
  WIN32_FIND_DATAW entry{};
  const std::wstring pattern = directory + L"\\*";
  HANDLE find = FindFirstFileW(pattern.c_str(), &entry);
  if (find != INVALID_HANDLE_VALUE) {
    do {
      const std::wstring name = entry.cFileName;
      if (name == L"." || name == L"..") {
        continue;
      }
      const std::wstring child = directory + L"\\" + name;
      if ((entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
        RemoveDirectoryRecursive(child);
      } else {
        SetFileAttributesW(child.c_str(), FILE_ATTRIBUTE_NORMAL);
        DeleteFileW(child.c_str());
      }
    } while (FindNextFileW(find, &entry) != 0);
    FindClose(find);
  }
  RemoveDirectoryW(directory.c_str());
}

bool ReadFileToString(const std::wstring& path, std::string* out) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  out->clear();
  char buffer[64 * 1024];
  bool ok = true;
  while (true) {
    DWORD read = 0;
    if (ReadFile(file, buffer, sizeof(buffer), &read, nullptr) == 0) {
      ok = false;
      break;
    }
    if (read == 0) {
      break;
    }
    out->append(buffer, read);
  }
  CloseHandle(file);
  return ok;
}

bool WriteStringToFile(const std::wstring& path, const std::string& data) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  bool ok = true;
  size_t total = 0;
  while (total < data.size()) {
    DWORD written = 0;
    const DWORD chunk = static_cast<DWORD>(
        std::min<size_t>(data.size() - total, 1u << 20));
    if (WriteFile(file, data.data() + total, chunk, &written, nullptr) == 0 ||
        written == 0) {
      ok = false;
      break;
    }
    total += written;
  }
  CloseHandle(file);
  return ok;
}

// Terminates any running EntropyVPN UI process inside the install directory so
// its executable, flutter_windows.dll and data/ files become writable.
void TerminateUiProcesses(const std::wstring& install_dir) {
  std::vector<ProcessSnapshotEntry> processes;
  if (SnapshotProcesses(&processes) != NO_ERROR) {
    return;
  }
  const std::wstring install_key = NormalizePathKey(install_dir) + L"\\";
  for (const ProcessSnapshotEntry& process : processes) {
    if (process.path.empty()) {
      continue;
    }
    if (LowerPathNameKey(process.path) != "entropy_vpn") {
      continue;
    }
    if (process.path_key.size() < install_key.size() ||
        process.path_key.compare(0, install_key.size(), install_key) != 0) {
      continue;
    }
    LogLine("update.apply.kill_ui pid=" + std::to_string(process.pid));
    TerminateSingleProcess(process.pid, 5000);
  }
}

void Rollback(const std::vector<std::pair<std::wstring, std::wstring>>& applied) {
  for (auto it = applied.rbegin(); it != applied.rend(); ++it) {
    if (it->second.empty()) {
      DeleteFileW(it->first.c_str());  // file was newly created
    } else {
      MoveFileExW(it->second.c_str(), it->first.c_str(),
                  MOVEFILE_REPLACE_EXISTING);
    }
  }
  LogLine("update.rollback.engaged files=" +
          std::to_string(applied.size()));
}

bool SpawnUpdaterHelper(const std::wstring& install_dir, std::string* error) {
  const std::wstring helper = install_dir + L"\\entropy_vpn_updater.exe";
  if (!FileExists(helper)) {
    *error = "The update helper (entropy_vpn_updater.exe) is missing.";
    return false;
  }

  std::vector<std::wstring> args = {
      L"--install-dir", install_dir, L"--service-pid",
      std::to_wstring(GetCurrentProcessId())};
  std::wstring command_line = BuildCommandLine(helper, args);

  STARTUPINFOW startup_info{};
  startup_info.cb = sizeof(startup_info);
  PROCESS_INFORMATION process_info{};
  if (CreateProcessW(helper.c_str(), command_line.data(), nullptr, nullptr,
                     FALSE, CREATE_NO_WINDOW | DETACHED_PROCESS, nullptr,
                     install_dir.c_str(), &startup_info, &process_info) == 0) {
    *error = "Could not launch the update helper: " +
             ErrorMessage(GetLastError());
    return false;
  }
  CloseHandle(process_info.hThread);
  CloseHandle(process_info.hProcess);
  return true;
}

}  // namespace

bool ApplyStagedUpdate(const ReleaseManifest& target,
                       const std::wstring& install_dir,
                       const std::wstring& staging_dir,
                       bool* service_restart_pending,
                       std::string* error) {
  *service_restart_pending = false;
  LogLine("update.apply.start version=" + target.version);

  const std::wstring rollback_dir = install_dir + L"\\.rollback";
  RemoveDirectoryRecursive(rollback_dir);
  CreateDirectoryW(rollback_dir.c_str(), nullptr);

  // A file needs applying iff a staged blob exists for its hash. The service
  // executable is handled separately because it cannot replace itself.
  struct PendingFile {
    std::string path;
    std::wstring staged;
    std::wstring destination;
  };
  std::vector<PendingFile> pending;
  std::wstring service_blob;
  for (const ManifestFile& file : target.files) {
    const std::wstring staged =
        staging_dir + L"\\" + WideFromUtf8(file.sha256) + L".bin";
    if (!FileExists(staged)) {
      continue;  // unchanged — nothing was downloaded for it
    }
    if (LowerPathNameKey(file.path) == "entropy_vpn_service") {
      service_blob = staged;
      continue;
    }
    pending.push_back({file.path, staged, LocalPathFor(install_dir, file.path)});
  }

  // Close the UI so its files unlock before the swap.
  TerminateUiProcesses(install_dir);

  std::vector<std::pair<std::wstring, std::wstring>> applied;
  int backup_index = 0;
  for (const PendingFile& file : pending) {
    CreateParentDirectories(file.destination);

    std::wstring backup;
    if (FileExists(file.destination)) {
      backup = rollback_dir + L"\\" + std::to_wstring(backup_index++) + L".bak";
      if (MoveFileExW(file.destination.c_str(), backup.c_str(),
                      MOVEFILE_REPLACE_EXISTING) == 0) {
        *error = "Could not back up " + file.path + ": " +
                 ErrorMessage(GetLastError());
        Rollback(applied);
        return false;
      }
    }

    if (MoveFileExW(file.staged.c_str(), file.destination.c_str(),
                    MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH |
                        MOVEFILE_COPY_ALLOWED) == 0) {
      *error = "Could not install " + file.path + ": " +
               ErrorMessage(GetLastError());
      if (!backup.empty()) {
        MoveFileExW(backup.c_str(), file.destination.c_str(),
                    MOVEFILE_REPLACE_EXISTING);
      }
      Rollback(applied);
      return false;
    }
    applied.emplace_back(file.destination, backup);
  }

  // Record the new installed state.
  std::string manifest_text;
  if (ReadFileToString(staging_dir + L"\\manifest.json", &manifest_text)) {
    WriteStringToFile(install_dir + L"\\installed_manifest.json", manifest_text);
    WriteStringToFile(install_dir + L"\\manifest.json", manifest_text);
  }

  if (!service_blob.empty()) {
    const std::wstring new_service =
        install_dir + L"\\entropy_vpn_service.exe.new";
    if (CopyFileW(service_blob.c_str(), new_service.c_str(), FALSE) == 0) {
      *error = "Could not stage the new service binary: " +
               ErrorMessage(GetLastError());
      Rollback(applied);
      return false;
    }
    if (!SpawnUpdaterHelper(install_dir, error)) {
      DeleteFileW(new_service.c_str());
      Rollback(applied);
      return false;
    }
    *service_restart_pending = true;
  }

  RemoveDirectoryRecursive(staging_dir);

  // The dialog asked us to "Install and restart" — bring the UI back up on
  // the user's desktop. When service_restart_pending is true we skip this:
  // entropy_vpn_updater.exe will do it after it finishes swapping the
  // service binary and restarting the service.
  if (!*service_restart_pending) {
    const std::wstring ui_exe = install_dir + L"\\entropy_vpn.exe";
    const DWORD launch_err =
        entropy_vpn::LaunchInActiveUserSession(ui_exe, install_dir);
    if (launch_err != NO_ERROR) {
      LogLine("update.apply.relaunch_failed code=" +
              std::to_string(launch_err));
    } else {
      LogLine("update.apply.relaunch_ok");
    }
  }

  LogLine("update.apply.complete version=" + target.version +
          " files=" + std::to_string(applied.size()));
  return true;
}

}  // namespace entropy_vpn_service
