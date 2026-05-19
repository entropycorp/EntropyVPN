#pragma once

#include <cstdint>
#include <functional>
#include <string>

namespace entropy_vpn_service {

struct HttpResult {
  bool ok = false;
  unsigned int status = 0;  // HTTP status code
  std::string body;         // populated by HttpGetString only
  std::string error;        // human-readable, populated when !ok
};

// In-memory HTTPS GET, for the GitHub releases API and the manifest itself.
// Fails if the body would exceed `max_bytes`. `accept_header` may be empty.
HttpResult HttpGetString(const std::wstring& url,
                         size_t max_bytes,
                         const std::string& accept_header);

// Streams a `range_length`-byte slice starting at `range_offset` to
// `dest_path` (overwriting it). Used to pull individual files out of the
// release's blobs.pack asset without downloading the whole pack.
//
// Refuses any response other than 206 Partial Content so a server that
// silently ignores the Range header can't trick us into writing the entire
// asset into one staging blob. `progress` is invoked periodically with
// (received_bytes, range_length).
HttpResult HttpDownloadRangeToFile(
    const std::wstring& url,
    const std::wstring& dest_path,
    uint64_t range_offset,
    uint64_t range_length,
    const std::function<void(uint64_t, uint64_t)>& progress);

}  // namespace entropy_vpn_service
