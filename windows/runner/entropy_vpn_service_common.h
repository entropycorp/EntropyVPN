#pragma once

#include <windows.h>

#include <map>
#include <string>
#include <utility>
#include <vector>

namespace entropy_vpn_service {

extern const wchar_t kServiceName[];
extern const wchar_t kPipeName[];
extern const DWORD kPipeBufferSize;

std::string Utf8FromWide(const std::wstring& value);
std::wstring WideFromUtf8(const std::string& value);
std::string ErrorMessage(DWORD error);
std::string ToLowerAscii(std::string value);

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

}  // namespace entropy_vpn_service

