#include "entropy_vpn_service_updater.h"

#include <windows.h>

#include <algorithm>
#include <ctime>
#include <mutex>
#include <thread>
#include <vector>

#include "entropy_vpn_service_apply.h"
#include "entropy_vpn_service_commands.h"
#include "entropy_vpn_service_common.h"
#include "entropy_vpn_service_http.h"
#include "entropy_vpn_service_log.h"
#include "entropy_vpn_service_manifest.h"
#include "entropy_vpn_service_sha256.h"

namespace entropy_vpn_service {
namespace {

constexpr wchar_t kGithubLatestReleaseUrl[] =
    L"https://api.github.com/repos/entropycorp/EntropyVPN/releases/latest";
constexpr char kGithubAcceptHeader[] = "application/vnd.github+json";
constexpr int64_t kRateLimitSeconds = 3600;
constexpr size_t kMaxApiBytes = 4 * 1024 * 1024;
constexpr size_t kMaxManifestBytes = 8 * 1024 * 1024;

enum class UpdateState {
  Idle,
  Checking,
  Downloading,
  Ready,
  Applying,
  Error,
};

const char* StateName(UpdateState state) {
  switch (state) {
    case UpdateState::Idle: return "idle";
    case UpdateState::Checking: return "checking";
    case UpdateState::Downloading: return "downloading";
    case UpdateState::Ready: return "ready";
    case UpdateState::Applying: return "applying";
    case UpdateState::Error: return "error";
  }
  return "idle";
}

std::mutex g_update_mutex;
UpdateState g_state = UpdateState::Idle;
std::string g_available_version;
uint64_t g_progress_bytes = 0;
uint64_t g_total_bytes = 0;
std::string g_error;
int64_t g_last_check_unix = 0;
bool g_worker_active = false;
std::thread g_worker;
ReleaseManifest g_staged_manifest;

// --- small helpers ---------------------------------------------------------

std::wstring InstallDirectory() { return ModuleDirectory(); }

std::wstring StagingDirectory() {
  return InstallDirectory() + L"\\.update_staging";
}

std::wstring LocalPathFor(const std::wstring& install_dir,
                          const std::string& posix_path) {
  std::wstring relative = WideFromUtf8(posix_path);
  std::replace(relative.begin(), relative.end(), L'/', L'\\');
  return install_dir + L"\\" + relative;
}

bool WriteStringToFile(const std::wstring& path, const std::string& data) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  bool ok = true;
  size_t written_total = 0;
  while (written_total < data.size()) {
    DWORD written = 0;
    const DWORD chunk =
        static_cast<DWORD>(std::min<size_t>(data.size() - written_total,
                                            1u << 20));
    if (WriteFile(file, data.data() + written_total, chunk, &written,
                  nullptr) == 0 ||
        written == 0) {
      ok = false;
      break;
    }
    written_total += written;
  }
  CloseHandle(file);
  return ok;
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

// The version EntropyVPN currently believes is installed. installed_manifest
// is written by a completed update; manifest.json is shipped by the installer.
std::string ReadInstalledVersion() {
  const std::wstring dir = InstallDirectory();
  for (const wchar_t* name : {L"\\installed_manifest.json", L"\\manifest.json"}) {
    std::string text;
    if (!ReadFileToString(dir + name, &text)) {
      continue;
    }
    ReleaseManifest manifest;
    std::string error;
    if (ParseReleaseManifest(text, &manifest, &error)) {
      return manifest.version;
    }
  }
  return "0.0.0";
}

void SetState(UpdateState state) {
  std::lock_guard<std::mutex> lock(g_update_mutex);
  g_state = state;
}

void FinishWithError(const std::string& message) {
  std::lock_guard<std::mutex> lock(g_update_mutex);
  g_state = UpdateState::Error;
  g_error = message;
  g_worker_active = false;
  LogLine("update.error " + message);
}

void FinishIdle(const std::string& note) {
  std::lock_guard<std::mutex> lock(g_update_mutex);
  g_state = UpdateState::Idle;
  g_error.clear();
  g_worker_active = false;
  LogLine("update.check.result " + note);
}

void FinishReady(const ReleaseManifest& manifest) {
  std::lock_guard<std::mutex> lock(g_update_mutex);
  g_state = UpdateState::Ready;
  g_error.clear();
  g_staged_manifest = manifest;
  g_worker_active = false;
  LogLine("update.ready version=" + manifest.version);
}

// --- check / download worker ----------------------------------------------

void RunCheckWorker() {
  LogLine("update.check.start");

  HttpResult api = HttpGetString(kGithubLatestReleaseUrl, kMaxApiBytes,
                                 kGithubAcceptHeader);
  if (!api.ok) {
    FinishWithError("Could not reach the update server: " + api.error);
    return;
  }

  JsonValue release;
  std::string json_error;
  if (!ParseJson(api.body, &release, &json_error) || !release.is_object()) {
    FinishWithError("Update server returned an unreadable response.");
    return;
  }

  const JsonValue* assets = release.Find("assets");
  if (assets == nullptr || !assets->is_array()) {
    const JsonValue* message = release.Find("message");
    FinishWithError(message != nullptr && message->is_string()
                        ? "Update server: " + message->string_value
                        : "Update server returned no release assets.");
    return;
  }

  std::wstring manifest_url;
  std::wstring pack_url;
  for (const JsonValue& asset : assets->array_items) {
    if (!asset.is_object()) {
      continue;
    }
    const JsonValue* name = asset.Find("name");
    const JsonValue* url = asset.Find("browser_download_url");
    if (name == nullptr || !name->is_string() || url == nullptr ||
        !url->is_string()) {
      continue;
    }
    if (name->string_value == "manifest.json") {
      manifest_url = WideFromUtf8(url->string_value);
    } else if (name->string_value == "blobs.pack") {
      pack_url = WideFromUtf8(url->string_value);
    }
  }
  if (manifest_url.empty()) {
    FinishWithError("The latest release has no update manifest.");
    return;
  }
  if (pack_url.empty()) {
    FinishWithError("The latest release is missing blobs.pack.");
    return;
  }

  HttpResult manifest_response =
      HttpGetString(manifest_url, kMaxManifestBytes, std::string());
  if (!manifest_response.ok) {
    FinishWithError("Could not download the update manifest: " +
                    manifest_response.error);
    return;
  }

  ReleaseManifest manifest;
  std::string manifest_error;
  if (!ParseReleaseManifest(manifest_response.body, &manifest,
                            &manifest_error)) {
    FinishWithError("Update manifest is invalid: " + manifest_error);
    return;
  }

  const std::string installed = ReadInstalledVersion();
  if (CompareVersions(manifest.version, installed) <= 0) {
    FinishIdle("up-to-date installed=" + installed +
               " latest=" + manifest.version);
    return;
  }

  {
    std::lock_guard<std::mutex> lock(g_update_mutex);
    g_state = UpdateState::Downloading;
    g_available_version = manifest.version;
    g_progress_bytes = 0;
    g_total_bytes = 0;
  }

  // Stage the manifest text now so the apply step can install it verbatim as
  // installed_manifest.json once the swap succeeds.
  const std::wstring install_dir = InstallDirectory();
  const std::wstring staging = StagingDirectory();
  CreateDirectoryW(staging.c_str(), nullptr);
  if (!WriteStringToFile(staging + L"\\manifest.json", manifest_response.body)) {
    FinishWithError("Could not write the staging manifest.");
    return;
  }

  // Diff: hash each installed file, collect mismatches/missing.
  std::vector<ManifestFile> to_download;
  uint64_t total = 0;
  for (const ManifestFile& file : manifest.files) {
    const std::wstring local = LocalPathFor(install_dir, file.path);
    if (Sha256HexOfFile(local) == file.sha256) {
      continue;
    }
    to_download.push_back(file);
    total += file.size;
  }
  {
    std::lock_guard<std::mutex> lock(g_update_mutex);
    g_total_bytes = total;
  }
  LogLine("update.check.result update available version=" + manifest.version +
          " files=" + std::to_string(to_download.size()) +
          " bytes=" + std::to_string(total));

  if (to_download.empty()) {
    // Every file already matches — nothing to fetch, ready immediately.
    FinishReady(manifest);
    return;
  }

  uint64_t completed_bytes = 0;
  for (const ManifestFile& file : to_download) {
    const std::wstring blob_name = WideFromUtf8(file.sha256) + L".bin";
    const std::wstring staged_path = staging + L"\\" + blob_name;

    // Resume: a leftover blob with the right hash survives a service crash.
    if (Sha256HexOfFile(staged_path) == file.sha256) {
      completed_bytes += file.size;
      std::lock_guard<std::mutex> lock(g_update_mutex);
      g_progress_bytes = completed_bytes;
      continue;
    }

    const uint64_t base = completed_bytes;
    HttpResult download = HttpDownloadRangeToFile(
        pack_url, staged_path, file.pack_offset, file.size,
        [base](uint64_t received, uint64_t /*range_length*/) {
          std::lock_guard<std::mutex> lock(g_update_mutex);
          g_progress_bytes = base + received;
        });
    if (!download.ok) {
      FinishWithError("Download failed for " + file.path + ": " +
                      download.error);
      return;
    }

    // A hash/size mismatch means a server/manifest inconsistency, not a
    // transient error — fail the whole update, don't retry.
    if (Sha256HexOfFile(staged_path) != file.sha256) {
      DeleteFileW(staged_path.c_str());
      FinishWithError("Downloaded file failed its hash check (" + file.path +
                      ").");
      return;
    }

    completed_bytes += file.size;
    std::lock_guard<std::mutex> lock(g_update_mutex);
    g_progress_bytes = completed_bytes;
  }

  FinishReady(manifest);
}

void RunApplyWorker() {
  ReleaseManifest manifest;
  {
    std::lock_guard<std::mutex> lock(g_update_mutex);
    manifest = g_staged_manifest;
  }

  std::string error;
  bool restart_pending = false;
  const bool ok = ApplyStagedUpdate(manifest, InstallDirectory(),
                                    StagingDirectory(), &restart_pending,
                                    &error);
  if (!ok) {
    FinishWithError(error);
    return;
  }

  if (restart_pending) {
    // The service binary itself was updated; entropy_vpn_updater.exe is now
    // waiting for us to exit so it can swap it in and restart the service.
    {
      std::lock_guard<std::mutex> lock(g_update_mutex);
      g_worker_active = false;
    }
    LogLine("update.apply.success service restart pending");
    RequestServiceStop();
    return;
  }

  std::lock_guard<std::mutex> lock(g_update_mutex);
  g_state = UpdateState::Idle;
  g_available_version.clear();
  g_worker_active = false;
}

// Joins a finished worker so its std::thread can be reused. Caller must hold
// g_update_mutex and have observed g_worker_active == false.
void JoinFinishedWorkerLocked() {
  if (g_worker.joinable()) {
    g_worker.join();
  }
}

}  // namespace

std::string UpdateCheckNow(const std::map<std::string, std::string>& fields) {
  const bool force = ReadDword(fields, "force", 0) != 0;
  const int64_t now = static_cast<int64_t>(std::time(nullptr));

  std::lock_guard<std::mutex> lock(g_update_mutex);
  if (g_worker_active) {
    // A check or download is already running; let the caller poll status.
    return BuildResponse({{"ok", "1"}, {"started", "0"}});
  }
  if (!force && g_last_check_unix != 0 &&
      now - g_last_check_unix < kRateLimitSeconds) {
    return BuildResponse({{"ok", "1"}, {"started", "0"}});
  }

  JoinFinishedWorkerLocked();
  g_state = UpdateState::Checking;
  g_error.clear();
  g_progress_bytes = 0;
  g_total_bytes = 0;
  g_last_check_unix = now;
  g_worker_active = true;
  g_worker = std::thread(RunCheckWorker);
  return BuildResponse({{"ok", "1"}, {"started", "1"}});
}

std::string UpdateApply(const std::map<std::string, std::string>& fields) {
  (void)fields;
  std::lock_guard<std::mutex> lock(g_update_mutex);
  if (g_worker_active) {
    return ErrorResponse("An update operation is already in progress.",
                         ERROR_BUSY);
  }
  if (g_state != UpdateState::Ready) {
    return ErrorResponse("No staged update is ready to apply.",
                         ERROR_INVALID_STATE);
  }
  JoinFinishedWorkerLocked();
  g_state = UpdateState::Applying;
  g_error.clear();
  g_worker_active = true;
  g_worker = std::thread(RunApplyWorker);
  return BuildResponse({{"ok", "1"}, {"started", "1"}});
}

std::string UpdateStatus(const std::map<std::string, std::string>& fields) {
  (void)fields;
  // Read installed version OUTSIDE the lock — ReadInstalledVersion does file
  // I/O and we don't want to block apply/check workers on disk reads.
  const std::string installed = ReadInstalledVersion();
  std::lock_guard<std::mutex> lock(g_update_mutex);
  std::vector<std::pair<std::string, std::string>> response;
  response.push_back({"ok", "1"});
  response.push_back({"state", StateName(g_state)});
  response.push_back({"progressBytes", std::to_string(g_progress_bytes)});
  response.push_back({"totalBytes", std::to_string(g_total_bytes)});
  response.push_back({"lastCheckUnix", std::to_string(g_last_check_unix)});
  AddTextField(&response, "availableVersionB64", g_available_version);
  AddTextField(&response, "installedVersionB64", installed);
  AddTextField(&response, "errorB64", g_error);
  return BuildResponse(response);
}

void ShutdownUpdater() {
  std::thread worker;
  {
    std::lock_guard<std::mutex> lock(g_update_mutex);
    worker = std::move(g_worker);
  }
  if (worker.joinable()) {
    worker.join();
  }
}

}  // namespace entropy_vpn_service
