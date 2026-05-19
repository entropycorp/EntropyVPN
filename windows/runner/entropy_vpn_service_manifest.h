#pragma once

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace entropy_vpn_service {

// --- Minimal JSON ----------------------------------------------------------
//
// A small recursive-descent JSON parser used both for the release manifest and
// for the GitHub releases API response.

struct JsonValue {
  enum class Type { Null, Bool, Int, Double, String, Array, Object };

  Type type = Type::Null;
  bool bool_value = false;
  int64_t int_value = 0;
  double double_value = 0.0;
  std::string string_value;
  std::vector<JsonValue> array_items;
  std::vector<std::pair<std::string, JsonValue>> object_members;

  bool is_object() const { return type == Type::Object; }
  bool is_array() const { return type == Type::Array; }
  bool is_string() const { return type == Type::String; }

  // Returns the member with `key`, or nullptr. First match wins.
  const JsonValue* Find(const std::string& key) const;
};

bool ParseJson(const std::string& text, JsonValue* out, std::string* error);

// --- Release manifest ------------------------------------------------------

struct ManifestFile {
  std::string path;    // POSIX-style, relative to the install directory
  uint64_t size = 0;
  std::string sha256;  // lowercase hex
  // Byte offset of this file's content inside the release's blobs.pack asset.
  // Multiple entries with the same sha256 share an offset (dedup'd at pack
  // build time). The byte range to fetch is [pack_offset, pack_offset + size).
  uint64_t pack_offset = 0;
};

struct ReleaseManifest {
  int schema = 0;
  std::string version;
  std::string generated_at;
  std::vector<ManifestFile> files;
};

// Parses and structurally validates a manifest.
bool ParseReleaseManifest(const std::string& json_text,
                          ReleaseManifest* out,
                          std::string* error);

// Compares dotted-numeric version strings ("1.8.0"). Returns <0, 0, or >0.
int CompareVersions(const std::string& left, const std::string& right);

}  // namespace entropy_vpn_service
