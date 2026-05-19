#include "entropy_vpn_service_sha256.h"

#include <windows.h>
#include <bcrypt.h>

namespace entropy_vpn_service {
namespace {

constexpr char kHexDigits[] = "0123456789abcdef";

// Thin RAII wrapper around a one-shot SHA-256 hash object.
class Sha256Hasher {
 public:
  Sha256Hasher() {
    if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(
            &algorithm_, BCRYPT_SHA256_ALGORITHM, nullptr, 0))) {
      algorithm_ = nullptr;
      return;
    }
    if (!BCRYPT_SUCCESS(
            BCryptCreateHash(algorithm_, &hash_, nullptr, 0, nullptr, 0, 0))) {
      hash_ = nullptr;
    }
  }

  ~Sha256Hasher() {
    if (hash_ != nullptr) {
      BCryptDestroyHash(hash_);
    }
    if (algorithm_ != nullptr) {
      BCryptCloseAlgorithmProvider(algorithm_, 0);
    }
  }

  Sha256Hasher(const Sha256Hasher&) = delete;
  Sha256Hasher& operator=(const Sha256Hasher&) = delete;

  bool valid() const { return hash_ != nullptr; }

  bool Update(const void* data, size_t length) {
    if (hash_ == nullptr || length == 0) {
      return hash_ != nullptr;
    }
    return BCRYPT_SUCCESS(BCryptHashData(
        hash_,
        reinterpret_cast<PUCHAR>(const_cast<void*>(data)),
        static_cast<ULONG>(length), 0));
  }

  std::vector<uint8_t> Finish() {
    std::vector<uint8_t> digest;
    if (hash_ == nullptr) {
      return digest;
    }
    digest.resize(32);
    if (!BCRYPT_SUCCESS(BCryptFinishHash(hash_, digest.data(), 32, 0))) {
      digest.clear();
    }
    return digest;
  }

 private:
  BCRYPT_ALG_HANDLE algorithm_ = nullptr;
  BCRYPT_HASH_HANDLE hash_ = nullptr;
};

}  // namespace

std::string HexEncode(const std::vector<uint8_t>& bytes) {
  std::string out;
  out.reserve(bytes.size() * 2);
  for (uint8_t byte : bytes) {
    out.push_back(kHexDigits[byte >> 4]);
    out.push_back(kHexDigits[byte & 0x0f]);
  }
  return out;
}

std::vector<uint8_t> Sha256Bytes(const void* data, size_t length) {
  Sha256Hasher hasher;
  if (!hasher.valid() || !hasher.Update(data, length)) {
    return std::vector<uint8_t>();
  }
  return hasher.Finish();
}

std::string Sha256HexOfBuffer(const std::string& data) {
  const std::vector<uint8_t> digest = Sha256Bytes(data.data(), data.size());
  return digest.empty() ? std::string() : HexEncode(digest);
}

std::string Sha256HexOfFile(const std::wstring& path) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return std::string();
  }

  Sha256Hasher hasher;
  if (!hasher.valid()) {
    CloseHandle(file);
    return std::string();
  }

  std::vector<uint8_t> buffer(64 * 1024);
  bool ok = true;
  while (true) {
    DWORD read = 0;
    if (ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &read,
                 nullptr) == 0) {
      ok = false;
      break;
    }
    if (read == 0) {
      break;
    }
    if (!hasher.Update(buffer.data(), read)) {
      ok = false;
      break;
    }
  }
  CloseHandle(file);
  if (!ok) {
    return std::string();
  }

  const std::vector<uint8_t> digest = hasher.Finish();
  return digest.empty() ? std::string() : HexEncode(digest);
}

}  // namespace entropy_vpn_service
