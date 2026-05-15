#pragma once

#include <windows.h>

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace entropy_vpn_service {

using ServiceFields = std::map<std::string, std::string>;

struct ParsedServiceResponse {
  bool ok = false;
  ServiceFields fields;
  std::string error;
};

bool BuildWindowsServiceRequest(const std::vector<std::string>& args,
                                std::string* request,
                                std::string* error);
std::string ServiceFieldValue(const ServiceFields& fields,
                              const std::string& key);
std::string DecodeServiceField(const ServiceFields& fields,
                               const std::string& key);
int64_t ParseServiceInt64(const ServiceFields& fields,
                          const std::string& key,
                          int64_t fallback = 0);
ParsedServiceResponse ParseWindowsServiceResponse(
    const std::string& stdout_text,
    const std::string& stderr_text,
    DWORD exit_code);

}  // namespace entropy_vpn_service
