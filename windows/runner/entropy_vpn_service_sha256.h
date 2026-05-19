#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace entropy_vpn_service {

// Lowercase hex of arbitrary bytes.
std::string HexEncode(const std::vector<uint8_t>& bytes);

// Raw 32-byte SHA-256 of a buffer; empty vector on failure.
std::vector<uint8_t> Sha256Bytes(const void* data, size_t length);

// Lowercase-hex SHA-256 of a string buffer; empty string on failure.
std::string Sha256HexOfBuffer(const std::string& data);

// Streams a file through SHA-256. Returns lowercase hex, or an empty string if
// the file cannot be opened/read (e.g. it is missing).
std::string Sha256HexOfFile(const std::wstring& path);

}  // namespace entropy_vpn_service
