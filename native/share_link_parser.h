#pragma once

#if defined(_WIN32)
#define ENTROPY_EXPORT __declspec(dllexport)
#else
#define ENTROPY_EXPORT __attribute__((visibility("default")))
#endif

extern "C" {

ENTROPY_EXPORT char* entropy_parse_share_link(const char* raw_input, char** error_message);
ENTROPY_EXPORT char* entropy_parse_share_links(const char* raw_input, char** error_message);
ENTROPY_EXPORT char* entropy_try_decode_subscription_base64(const char* raw_input, char** error_message);
ENTROPY_EXPORT char* entropy_parse_core_config(const char* raw_input, const char* options_json, char** error_message);
ENTROPY_EXPORT char* entropy_build_core_config(const char* profile_json, const char* options_json, char** error_message);
ENTROPY_EXPORT char* entropy_measure_tcp_pings(const char* targets_json, int timeout_ms, int max_concurrent, char** error_message);
ENTROPY_EXPORT void entropy_free_string(char* value);

}
