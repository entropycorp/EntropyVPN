#include "entropy_vpn_service_manifest.h"

#include <cstdlib>

#include "entropy_vpn_service_common.h"

namespace entropy_vpn_service {
namespace {

// --- JSON parser -----------------------------------------------------------

class JsonParser {
 public:
  JsonParser(const std::string& text) : text_(text) {}

  bool Parse(JsonValue* out, std::string* error) {
    SkipWhitespace();
    if (!ParseValue(out)) {
      *error = error_.empty() ? "Malformed JSON." : error_;
      return false;
    }
    SkipWhitespace();
    if (pos_ != text_.size()) {
      *error = "Trailing data after JSON document.";
      return false;
    }
    return true;
  }

 private:
  bool Fail(const std::string& message) {
    if (error_.empty()) {
      error_ = message;
    }
    return false;
  }

  void SkipWhitespace() {
    while (pos_ < text_.size()) {
      const char c = text_[pos_];
      if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
        ++pos_;
      } else {
        break;
      }
    }
  }

  bool ParseValue(JsonValue* out) {
    if (pos_ >= text_.size()) {
      return Fail("Unexpected end of JSON.");
    }
    const char c = text_[pos_];
    switch (c) {
      case '{':
        return ParseObject(out);
      case '[':
        return ParseArray(out);
      case '"':
        return ParseStringValue(out);
      case 't':
      case 'f':
        return ParseBool(out);
      case 'n':
        return ParseNull(out);
      default:
        if (c == '-' || (c >= '0' && c <= '9')) {
          return ParseNumber(out);
        }
        return Fail("Unexpected character in JSON.");
    }
  }

  bool ParseObject(JsonValue* out) {
    out->type = JsonValue::Type::Object;
    ++pos_;  // consume '{'
    SkipWhitespace();
    if (pos_ < text_.size() && text_[pos_] == '}') {
      ++pos_;
      return true;
    }
    while (true) {
      SkipWhitespace();
      if (pos_ >= text_.size() || text_[pos_] != '"') {
        return Fail("Expected a string key in JSON object.");
      }
      std::string key;
      if (!ParseString(&key)) {
        return false;
      }
      SkipWhitespace();
      if (pos_ >= text_.size() || text_[pos_] != ':') {
        return Fail("Expected ':' in JSON object.");
      }
      ++pos_;
      SkipWhitespace();
      JsonValue value;
      if (!ParseValue(&value)) {
        return false;
      }
      out->object_members.emplace_back(std::move(key), std::move(value));
      SkipWhitespace();
      if (pos_ >= text_.size()) {
        return Fail("Unterminated JSON object.");
      }
      if (text_[pos_] == ',') {
        ++pos_;
        continue;
      }
      if (text_[pos_] == '}') {
        ++pos_;
        return true;
      }
      return Fail("Expected ',' or '}' in JSON object.");
    }
  }

  bool ParseArray(JsonValue* out) {
    out->type = JsonValue::Type::Array;
    ++pos_;  // consume '['
    SkipWhitespace();
    if (pos_ < text_.size() && text_[pos_] == ']') {
      ++pos_;
      return true;
    }
    while (true) {
      SkipWhitespace();
      JsonValue value;
      if (!ParseValue(&value)) {
        return false;
      }
      out->array_items.push_back(std::move(value));
      SkipWhitespace();
      if (pos_ >= text_.size()) {
        return Fail("Unterminated JSON array.");
      }
      if (text_[pos_] == ',') {
        ++pos_;
        continue;
      }
      if (text_[pos_] == ']') {
        ++pos_;
        return true;
      }
      return Fail("Expected ',' or ']' in JSON array.");
    }
  }

  bool ParseStringValue(JsonValue* out) {
    out->type = JsonValue::Type::String;
    return ParseString(&out->string_value);
  }

  static void AppendUtf8(std::string* out, uint32_t codepoint) {
    if (codepoint <= 0x7F) {
      out->push_back(static_cast<char>(codepoint));
    } else if (codepoint <= 0x7FF) {
      out->push_back(static_cast<char>(0xC0 | (codepoint >> 6)));
      out->push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
    } else if (codepoint <= 0xFFFF) {
      out->push_back(static_cast<char>(0xE0 | (codepoint >> 12)));
      out->push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F)));
      out->push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
    } else {
      out->push_back(static_cast<char>(0xF0 | (codepoint >> 18)));
      out->push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3F)));
      out->push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F)));
      out->push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
    }
  }

  bool ParseHex4(uint32_t* value) {
    if (pos_ + 4 > text_.size()) {
      return Fail("Truncated unicode escape in JSON string.");
    }
    uint32_t result = 0;
    for (int i = 0; i < 4; ++i) {
      const char c = text_[pos_++];
      result <<= 4;
      if (c >= '0' && c <= '9') {
        result |= static_cast<uint32_t>(c - '0');
      } else if (c >= 'a' && c <= 'f') {
        result |= static_cast<uint32_t>(c - 'a' + 10);
      } else if (c >= 'A' && c <= 'F') {
        result |= static_cast<uint32_t>(c - 'A' + 10);
      } else {
        return Fail("Invalid unicode escape in JSON string.");
      }
    }
    *value = result;
    return true;
  }

  bool ParseString(std::string* out) {
    out->clear();
    ++pos_;  // consume opening quote
    while (pos_ < text_.size()) {
      const unsigned char c = static_cast<unsigned char>(text_[pos_++]);
      if (c == '"') {
        return true;
      }
      if (c == '\\') {
        if (pos_ >= text_.size()) {
          return Fail("Unterminated escape in JSON string.");
        }
        const char esc = text_[pos_++];
        switch (esc) {
          case '"': out->push_back('"'); break;
          case '\\': out->push_back('\\'); break;
          case '/': out->push_back('/'); break;
          case 'b': out->push_back('\b'); break;
          case 'f': out->push_back('\f'); break;
          case 'n': out->push_back('\n'); break;
          case 'r': out->push_back('\r'); break;
          case 't': out->push_back('\t'); break;
          case 'u': {
            uint32_t unit = 0;
            if (!ParseHex4(&unit)) {
              return false;
            }
            if (unit >= 0xD800 && unit <= 0xDBFF) {
              // High surrogate — expect a following low surrogate.
              if (pos_ + 2 > text_.size() || text_[pos_] != '\\' ||
                  text_[pos_ + 1] != 'u') {
                return Fail("Lone high surrogate in JSON string.");
              }
              pos_ += 2;
              uint32_t low = 0;
              if (!ParseHex4(&low)) {
                return false;
              }
              if (low < 0xDC00 || low > 0xDFFF) {
                return Fail("Invalid low surrogate in JSON string.");
              }
              const uint32_t codepoint =
                  0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
              AppendUtf8(out, codepoint);
            } else {
              AppendUtf8(out, unit);
            }
            break;
          }
          default:
            return Fail("Unsupported escape in JSON string.");
        }
        continue;
      }
      out->push_back(static_cast<char>(c));
    }
    return Fail("Unterminated JSON string.");
  }

  bool ParseNumber(JsonValue* out) {
    const size_t start = pos_;
    bool is_double = false;
    if (pos_ < text_.size() && text_[pos_] == '-') {
      ++pos_;
    }
    while (pos_ < text_.size()) {
      const char c = text_[pos_];
      if (c >= '0' && c <= '9') {
        ++pos_;
      } else if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') {
        is_double = true;
        ++pos_;
      } else {
        break;
      }
    }
    if (pos_ == start) {
      return Fail("Invalid JSON number.");
    }
    const std::string token = text_.substr(start, pos_ - start);
    if (is_double) {
      out->type = JsonValue::Type::Double;
      out->double_value = std::strtod(token.c_str(), nullptr);
    } else {
      out->type = JsonValue::Type::Int;
      out->int_value = std::strtoll(token.c_str(), nullptr, 10);
    }
    return true;
  }

  bool ParseBool(JsonValue* out) {
    if (text_.compare(pos_, 4, "true") == 0) {
      pos_ += 4;
      out->type = JsonValue::Type::Bool;
      out->bool_value = true;
      return true;
    }
    if (text_.compare(pos_, 5, "false") == 0) {
      pos_ += 5;
      out->type = JsonValue::Type::Bool;
      out->bool_value = false;
      return true;
    }
    return Fail("Invalid JSON literal.");
  }

  bool ParseNull(JsonValue* out) {
    if (text_.compare(pos_, 4, "null") == 0) {
      pos_ += 4;
      out->type = JsonValue::Type::Null;
      return true;
    }
    return Fail("Invalid JSON literal.");
  }

  const std::string& text_;
  size_t pos_ = 0;
  std::string error_;
};

}  // namespace

const JsonValue* JsonValue::Find(const std::string& key) const {
  for (const auto& member : object_members) {
    if (member.first == key) {
      return &member.second;
    }
  }
  return nullptr;
}

bool ParseJson(const std::string& text, JsonValue* out, std::string* error) {
  JsonParser parser(text);
  return parser.Parse(out, error);
}

bool ParseReleaseManifest(const std::string& json_text,
                          ReleaseManifest* out,
                          std::string* error) {
  JsonValue root;
  if (!ParseJson(json_text, &root, error)) {
    return false;
  }
  if (!root.is_object()) {
    *error = "Manifest root is not a JSON object.";
    return false;
  }

  const JsonValue* schema = root.Find("schema");
  if (schema == nullptr || schema->type != JsonValue::Type::Int) {
    *error = "Manifest is missing a numeric \"schema\".";
    return false;
  }
  out->schema = static_cast<int>(schema->int_value);
  if (out->schema != 2) {
    *error = "Unsupported manifest schema " + std::to_string(out->schema) + ".";
    return false;
  }

  const JsonValue* version = root.Find("version");
  const JsonValue* generated_at = root.Find("generated_at");
  const JsonValue* files = root.Find("files");
  if (version == nullptr || !version->is_string() ||
      generated_at == nullptr || !generated_at->is_string() ||
      files == nullptr || !files->is_array()) {
    *error = "Manifest is missing required fields.";
    return false;
  }
  out->version = version->string_value;
  out->generated_at = generated_at->string_value;

  out->files.clear();
  for (const JsonValue& entry : files->array_items) {
    if (!entry.is_object()) {
      *error = "Manifest \"files\" entry is not an object.";
      return false;
    }
    const JsonValue* path = entry.Find("path");
    const JsonValue* size = entry.Find("size");
    const JsonValue* sha256 = entry.Find("sha256");
    const JsonValue* pack_offset = entry.Find("pack_offset");
    if (path == nullptr || !path->is_string() ||
        sha256 == nullptr || !sha256->is_string() ||
        size == nullptr || size->type != JsonValue::Type::Int ||
        size->int_value < 0 ||
        pack_offset == nullptr ||
        pack_offset->type != JsonValue::Type::Int ||
        pack_offset->int_value < 0) {
      *error = "Manifest \"files\" entry is malformed.";
      return false;
    }
    ManifestFile file;
    file.path = path->string_value;
    file.size = static_cast<uint64_t>(size->int_value);
    file.sha256 = ToLowerAscii(sha256->string_value);
    file.pack_offset = static_cast<uint64_t>(pack_offset->int_value);
    out->files.push_back(std::move(file));
  }
  return true;
}

int CompareVersions(const std::string& left, const std::string& right) {
  size_t left_pos = 0;
  size_t right_pos = 0;
  while (true) {
    long long left_segment = 0;
    while (left_pos < left.size() && left[left_pos] >= '0' &&
           left[left_pos] <= '9') {
      left_segment = left_segment * 10 + (left[left_pos] - '0');
      ++left_pos;
    }
    long long right_segment = 0;
    while (right_pos < right.size() && right[right_pos] >= '0' &&
           right[right_pos] <= '9') {
      right_segment = right_segment * 10 + (right[right_pos] - '0');
      ++right_pos;
    }
    if (left_segment != right_segment) {
      return left_segment < right_segment ? -1 : 1;
    }

    const bool left_dot = left_pos < left.size() && left[left_pos] == '.';
    const bool right_dot = right_pos < right.size() && right[right_pos] == '.';
    if (left_dot) {
      ++left_pos;
    }
    if (right_dot) {
      ++right_pos;
    }
    if (left_dot || right_dot) {
      // At least one side has another numeric segment; keep comparing.
      continue;
    }

    // No more numeric segments on either side. What's left (if anything) is a
    // SemVer-style pre-release suffix like "-beta". Per SemVer §11, a version
    // *with* a pre-release sorts BELOW the same version without one
    // ("1.8.0-beta" < "1.8.0"). If both sides have suffixes, fall back to a
    // lexicographic compare of the rest — also guarantees the loop terminates
    // even on garbage input.
    const bool left_has = left_pos < left.size();
    const bool right_has = right_pos < right.size();
    if (!left_has && !right_has) {
      return 0;
    }
    if (!left_has) {
      return 1;
    }
    if (!right_has) {
      return -1;
    }
    const int tail_cmp = left.compare(left_pos, left.size() - left_pos,
                                      right, right_pos,
                                      right.size() - right_pos);
    if (tail_cmp == 0) {
      return 0;
    }
    return tail_cmp < 0 ? -1 : 1;
  }
}

}  // namespace entropy_vpn_service
