#include "entropy_vpn_service_protocol.h"

#include "entropy_vpn_service_common.h"

#include <cstdlib>

namespace entropy_vpn_service {
namespace {

void AppendServiceField(std::string* request,
                        const std::string& key,
                        const std::string& value) {
  request->append(key);
  request->push_back('=');
  request->append(value);
  request->push_back('\n');
}

void AppendEncodedServiceField(std::string* request,
                               const std::string& key,
                               const std::string& value) {
  AppendServiceField(request, key, Base64Encode(value));
}

std::string WindowsServiceOptionValue(const std::vector<std::string>& args,
                                      const std::string& name,
                                      const std::string& fallback = "") {
  for (size_t i = 0; i + 1 < args.size(); ++i) {
    if (args[i] == name) {
      return args[i + 1];
    }
  }
  return fallback;
}

std::vector<std::string> WindowsServiceRepeatedOptionValues(
    const std::vector<std::string>& args,
    const std::string& name) {
  std::vector<std::string> values;
  for (size_t i = 0; i + 1 < args.size(); ++i) {
    if (args[i] == name) {
      values.push_back(args[i + 1]);
      ++i;
    }
  }
  return values;
}

void AppendServiceArguments(std::string* request,
                            const std::vector<std::string>& args) {
  AppendServiceField(request, "argCount", std::to_string(args.size()));
  for (size_t i = 0; i < args.size(); ++i) {
    AppendEncodedServiceField(request, "arg" + std::to_string(i), args[i]);
  }
}

}  // namespace

bool BuildWindowsServiceRequest(const std::vector<std::string>& args,
                                std::string* request,
                                std::string* error) {
  request->clear();
  if (args.empty()) {
    *error = "Missing EntropyVPN service command.";
    return false;
  }

  const std::string& command = args.front();
  if (command == "ping") {
    AppendServiceField(request, "command", "ping");
  } else if (command == "start-core") {
    AppendServiceField(request, "command", "start_core");
    AppendEncodedServiceField(
        request, "runId", WindowsServiceOptionValue(args, "--run-id"));
    AppendEncodedServiceField(
        request, "executable",
        WindowsServiceOptionValue(args, "--executable"));
    AppendEncodedServiceField(
        request, "workingDirectory",
        WindowsServiceOptionValue(args, "--working-directory"));
    AppendEncodedServiceField(
        request, "stdoutPath",
        WindowsServiceOptionValue(args, "--stdout-path"));
    AppendEncodedServiceField(
        request, "stderrPath",
        WindowsServiceOptionValue(args, "--stderr-path"));
    AppendServiceArguments(request,
                           WindowsServiceRepeatedOptionValues(args, "--arg"));
  } else if (command == "stop-core") {
    AppendServiceField(request, "command", "stop_core");
    AppendEncodedServiceField(
        request, "runId", WindowsServiceOptionValue(args, "--run-id"));
  } else if (command == "status-core") {
    AppendServiceField(request, "command", "status_core");
    AppendEncodedServiceField(
        request, "runId", WindowsServiceOptionValue(args, "--run-id"));
  } else if (command == "run-process") {
    AppendServiceField(request, "command", "run_process");
    AppendEncodedServiceField(
        request, "executable",
        WindowsServiceOptionValue(args, "--executable"));
    AppendEncodedServiceField(
        request, "workingDirectory",
        WindowsServiceOptionValue(args, "--working-directory"));
    AppendServiceField(
        request, "timeoutMs",
        WindowsServiceOptionValue(args, "--timeout-ms", "30000"));
    AppendServiceArguments(request,
                           WindowsServiceRepeatedOptionValues(args, "--arg"));
  } else if (command == "prepare-ipv4-server-route") {
    AppendServiceField(request, "command", "prepare_ipv4_server_route");
    AppendEncodedServiceField(
        request, "remoteAddress",
        WindowsServiceOptionValue(args, "--remote-address"));
  } else if (command == "prepare-domain-server-route") {
    AppendServiceField(request, "command", "prepare_domain_server_route");
    AppendEncodedServiceField(request, "host",
                              WindowsServiceOptionValue(args, "--host"));
    AppendServiceField(
        request, "tunIpMode",
        WindowsServiceOptionValue(args, "--tun-ip-mode", "ipv4"));
  } else if (command == "prepare-xray-tun-ipv4-routes") {
    AppendServiceField(request, "command", "prepare_xray_tun_ipv4_routes");
    AppendEncodedServiceField(
        request, "interfaceAlias",
        WindowsServiceOptionValue(args, "--interface-alias"));
    AppendEncodedServiceField(
        request, "address", WindowsServiceOptionValue(args, "--address"));
    AppendEncodedServiceField(
        request, "dnsServers",
        WindowsServiceOptionValue(args, "--dns-servers"));
    AppendServiceField(
        request, "timeoutMs",
        WindowsServiceOptionValue(args, "--timeout-ms", "2500"));
    AppendServiceField(
        request, "prefixLength",
        WindowsServiceOptionValue(args, "--prefix-length", "30"));
    AppendServiceField(request, "metric",
                       WindowsServiceOptionValue(args, "--metric", "1"));
  } else if (command == "prewarm-tun-adapter") {
    AppendServiceField(request, "command", "prewarm_tun_adapter");
    AppendEncodedServiceField(
        request, "interfaceAlias",
        WindowsServiceOptionValue(args, "--interface-alias"));
    AppendServiceField(request, "appPid",
                       WindowsServiceOptionValue(args, "--app-pid", "0"));
  } else if (command == "release-tun-adapter") {
    AppendServiceField(request, "command", "release_tun_adapter");
  } else {
    *error = "Unknown EntropyVPN service command: " + command;
    return false;
  }

  return true;
}

std::string ServiceFieldValue(const ServiceFields& fields,
                              const std::string& key) {
  const auto found = fields.find(key);
  return found == fields.end() ? std::string() : found->second;
}

std::string DecodeServiceField(const ServiceFields& fields,
                               const std::string& key) {
  std::string decoded;
  const std::string encoded = ServiceFieldValue(fields, key);
  if (encoded.empty() || !Base64Decode(encoded, &decoded)) {
    return std::string();
  }
  return decoded;
}

int64_t ParseServiceInt64(const ServiceFields& fields,
                          const std::string& key,
                          int64_t fallback) {
  const std::string value = ServiceFieldValue(fields, key);
  if (value.empty()) {
    return fallback;
  }
  char* end = nullptr;
  const long long parsed = std::strtoll(value.c_str(), &end, 10);
  return end != nullptr && *end == '\0' ? parsed : fallback;
}

ParsedServiceResponse ParseWindowsServiceResponse(
    const std::string& stdout_text,
    const std::string& stderr_text,
    DWORD exit_code) {
  ParsedServiceResponse parsed;
  parsed.fields = ParseFields(stdout_text);
  if (ServiceFieldValue(parsed.fields, "ok") == "1") {
    parsed.ok = true;
    return parsed;
  }

  const std::string decoded_error =
      TrimAscii(DecodeServiceField(parsed.fields, "errorB64"));
  if (!decoded_error.empty()) {
    parsed.error = decoded_error;
  } else if (!TrimAscii(stderr_text).empty()) {
    parsed.error = TrimAscii(stderr_text);
  } else if (!TrimAscii(stdout_text).empty()) {
    parsed.error = TrimAscii(stdout_text);
  } else {
    parsed.error =
        "EntropyVPN Service request failed with exit " +
        std::to_string(exit_code) + ".";
  }
  return parsed;
}

}  // namespace entropy_vpn_service
