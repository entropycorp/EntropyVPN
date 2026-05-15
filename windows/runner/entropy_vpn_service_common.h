#pragma once

#include <windows.h>

#include <cstddef>
#include <map>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace entropy_vpn_service {

extern const wchar_t kServiceName[];
extern const wchar_t kPipeName[];
extern const DWORD kPipeBufferSize;

std::string Utf8FromWide(const std::wstring& value);
std::string Utf8FromWide(const wchar_t* value);
std::wstring WideFromUtf8(const std::string& value);
std::string ErrorMessage(DWORD error);
std::string ToLowerAscii(std::string value);
std::string TrimAscii(std::string value);
std::vector<std::string> SplitCommaList(const std::string& value);
bool ContainsToken(const std::string& value, const std::string& token);
bool LooksVirtualInterfaceAlias(const std::string& alias);
bool IsRetryableNetworkSetupError(DWORD error);

std::wstring ModuleDirectory();
bool IsAllowedCoreExecutable(const std::wstring& executable);
std::wstring ResolveAllowedCoreExecutable(const std::wstring& executable);
bool IsAllowedToolInvocation(const std::wstring& executable,
                             const std::vector<std::wstring>& args);

std::string Base64Encode(const std::string& input);
bool Base64Decode(const std::string& input, std::string* output);

std::map<std::string, std::string> ParseFields(const std::string& text);
std::string BuildResponse(
    const std::vector<std::pair<std::string, std::string>>& fields);
void AddTextField(std::vector<std::pair<std::string, std::string>>* fields,
                  const std::string& key,
                  const std::string& value);
std::string OkResponse();
std::string ErrorResponse(const std::string& message, DWORD code);

bool ReadDecodedString(const std::map<std::string, std::string>& fields,
                       const std::string& key,
                       std::string* output);
std::wstring ReadDecodedWide(const std::map<std::string, std::string>& fields,
                             const std::string& key);
DWORD ReadDword(const std::map<std::string, std::string>& fields,
                const std::string& key,
                DWORD fallback);
std::vector<std::wstring> ReadArguments(
    const std::map<std::string, std::string>& fields);

std::wstring BuildCommandLine(const std::wstring& executable,
                              const std::vector<std::wstring>& args);
void CloseHandleIfValid(HANDLE* handle);
void ReadPipeToString(HANDLE pipe, std::string* output);

class ScopedHandle {
 public:
  explicit ScopedHandle(HANDLE handle = nullptr);
  ~ScopedHandle();

  ScopedHandle(const ScopedHandle&) = delete;
  ScopedHandle& operator=(const ScopedHandle&) = delete;

  HANDLE get() const;
  void reset(HANDLE handle = nullptr);
  HANDLE release();

 private:
  HANDLE handle_ = nullptr;
};

std::wstring LowerWide(std::wstring value);
std::wstring NormalizePathKey(std::wstring path);
std::string BasenameWithoutExtension(const std::string& path);
std::string LowerPathNameKey(const std::string& path);

struct ProcessSnapshotEntry {
  DWORD pid = 0;
  DWORD parent_pid = 0;
  std::string path;
  std::wstring path_key;
};

DWORD SnapshotProcesses(std::vector<ProcessSnapshotEntry>* processes);
std::unordered_map<DWORD, std::vector<size_t>> BuildChildrenByParent(
    const std::vector<ProcessSnapshotEntry>& processes);
std::vector<DWORD> CollectProcessTreePids(
    DWORD root_pid,
    const std::vector<ProcessSnapshotEntry>& processes);

struct ProcessTerminationResult {
  DWORD pid = 0;
  bool success = false;
  bool already_exited = false;
  bool terminate_requested = false;
  bool wait_timed_out = false;
  DWORD error = NO_ERROR;
};

ProcessTerminationResult TerminateSingleProcess(DWORD pid, DWORD wait_ms);

}  // namespace entropy_vpn_service

