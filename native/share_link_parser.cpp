#include "share_link_parser.h"

#include <algorithm>
#include <cctype>
#include <charconv>
#include <cstring>
#include <atomic>
#include <chrono>
#include <map>
#include <memory>
#include <sstream>
#include <set>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <variant>
#include <vector>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#endif

namespace {

struct Profile {
  std::string protocol;
  std::string server;
  int port = 0;
  std::string transport = "raw";
  std::string tls_mode = "none";
  std::string remark;
  std::string user_id;
  std::string password;
  std::string method;
  std::string security;
  int alter_id = 0;
  std::string flow;
  std::string sni;
  std::vector<std::string> alpn;
  std::string host;
  std::string path;
  std::string service_name;
  std::string authority;
  std::string fingerprint;
  std::string public_key;
  std::string short_id;
  std::string spider_x;
  bool allow_insecure = false;
  std::string plugin;
  std::string plugin_opts;
  std::vector<std::string> server_ports;
  int upload_mbps = 0;
  int download_mbps = 0;
  std::string hysteria_network;
  std::string obfs;
  std::string obfs_password;
  std::string sing_box_config_json;
  std::string xray_config_json;
};

struct ConfigOptions {
  std::string core;
  std::string traffic_mode = "systemProxy";
  std::string tun_ip_mode = "ipv4";
  bool is_android = false;
  bool is_windows = false;
  std::string dns_mode = "classic";
  std::vector<std::string> dns_servers;
  std::string split_tunnel_mode = "off";
  std::vector<std::string> split_tunnel_app_names;
  std::vector<std::string> split_tunnel_app_paths;
  std::string domain_split_tunnel_mode = "off";
  std::vector<std::string> domain_split_tunnel_domains;
  std::string tun_interface_name;
  std::string outbound_bind_interface;
  std::string route_default_interface;
  std::string xray_server_address_override;
};

struct Json {
  using Object = std::map<std::string, Json>;
  using Array = std::vector<Json>;

  std::variant<std::nullptr_t, bool, double, std::string, Array, Object> value;

  Json() : value(nullptr) {}
  explicit Json(bool v) : value(v) {}
  explicit Json(double v) : value(v) {}
  explicit Json(std::string v) : value(std::move(v)) {}
  explicit Json(Array v) : value(std::move(v)) {}
  explicit Json(Object v) : value(std::move(v)) {}

  bool is_object() const { return std::holds_alternative<Object>(value); }
  bool is_array() const { return std::holds_alternative<Array>(value); }
  bool is_string() const { return std::holds_alternative<std::string>(value); }
  bool is_bool() const { return std::holds_alternative<bool>(value); }
  bool is_number() const { return std::holds_alternative<double>(value); }

  const Object& object() const {
    static const Object empty;
    return is_object() ? std::get<Object>(value) : empty;
  }
  const Array& array() const {
    static const Array empty;
    return is_array() ? std::get<Array>(value) : empty;
  }
  std::string string_value() const {
    if (is_string()) return std::get<std::string>(value);
    if (is_number()) {
      const auto number = std::get<double>(value);
      if (number == static_cast<long long>(number)) return std::to_string(static_cast<long long>(number));
      std::ostringstream out;
      out << number;
      return out.str();
    }
    if (is_bool()) return std::get<bool>(value) ? "true" : "false";
    return "";
  }
  bool bool_value() const { return is_bool() && std::get<bool>(value); }
  int int_value() const {
    if (is_number()) return static_cast<int>(std::get<double>(value));
    const auto text = string_value();
    if (text.empty()) return 0;
    return std::atoi(text.c_str());
  }
  const Json& at(const std::string& key) const {
    static const Json empty;
    const auto& obj = object();
    const auto it = obj.find(key);
    return it == obj.end() ? empty : it->second;
  }
  bool contains(const std::string& key) const {
    return object().find(key) != object().end();
  }
  bool is_null() const { return std::holds_alternative<std::nullptr_t>(value); }
  Object& object_mut() {
    if (!is_object()) value = Object{};
    return std::get<Object>(value);
  }
  Array& array_mut() {
    if (!is_array()) value = Array{};
    return std::get<Array>(value);
  }
  Json& member(const std::string& key) { return object_mut()[key]; }
  void erase(const std::string& key) {
    if (is_object()) std::get<Object>(value).erase(key);
  }
};

long read_hex4(std::string_view text, size_t pos) {
  if (pos + 4 > text.size()) return -1;
  long value = 0;
  for (size_t i = 0; i < 4; ++i) {
    const char ch = text[pos + i];
    value <<= 4;
    if (ch >= '0' && ch <= '9') value |= (ch - '0');
    else if (ch >= 'a' && ch <= 'f') value |= (ch - 'a' + 10);
    else if (ch >= 'A' && ch <= 'F') value |= (ch - 'A' + 10);
    else return -1;
  }
  return value;
}

void append_utf8(std::string& out, unsigned long cp) {
  if (cp == 0) return;
  if (cp < 0x80) {
    out.push_back(static_cast<char>(cp));
  } else if (cp < 0x800) {
    out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else if (cp < 0x10000) {
    out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else {
    out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  }
}

class JsonParser {
 public:
  explicit JsonParser(std::string_view text) : text_(text) {}

  Json parse() {
    skip_ws();
    auto value = parse_value();
    skip_ws();
    return value;
  }

 private:
  std::string_view text_;
  size_t pos_ = 0;

  void skip_ws() {
    while (pos_ < text_.size() && std::isspace(static_cast<unsigned char>(text_[pos_]))) ++pos_;
  }

  char peek() const { return pos_ < text_.size() ? text_[pos_] : '\0'; }
  char take() { return pos_ < text_.size() ? text_[pos_++] : '\0'; }

  void expect(char expected) {
    if (take() != expected) throw std::runtime_error("Invalid JSON.");
  }

  Json parse_value() {
    skip_ws();
    switch (peek()) {
      case '{': return parse_object();
      case '[': return parse_array();
      case '"': return Json(parse_string());
      case 't': pos_ += 4; return Json(true);
      case 'f': pos_ += 5; return Json(false);
      case 'n': pos_ += 4; return Json();
      default: return parse_number();
    }
  }

  Json parse_object() {
    expect('{');
    Json::Object object;
    skip_ws();
    if (peek() == '}') {
      take();
      return Json(std::move(object));
    }
    while (true) {
      skip_ws();
      const auto key = parse_string();
      skip_ws();
      expect(':');
      object[key] = parse_value();
      skip_ws();
      const auto ch = take();
      if (ch == '}') break;
      if (ch != ',') throw std::runtime_error("Invalid JSON object.");
    }
    return Json(std::move(object));
  }

  Json parse_array() {
    expect('[');
    Json::Array array;
    skip_ws();
    if (peek() == ']') {
      take();
      return Json(std::move(array));
    }
    while (true) {
      array.push_back(parse_value());
      skip_ws();
      const auto ch = take();
      if (ch == ']') break;
      if (ch != ',') throw std::runtime_error("Invalid JSON array.");
    }
    return Json(std::move(array));
  }

  std::string parse_string() {
    expect('"');
    std::string out;
    while (pos_ < text_.size()) {
      const char ch = take();
      if (ch == '"') break;
      if (ch == '\\') {
        const char escaped = take();
        switch (escaped) {
          case '"': out.push_back('"'); break;
          case '\\': out.push_back('\\'); break;
          case '/': out.push_back('/'); break;
          case 'b': out.push_back('\b'); break;
          case 'f': out.push_back('\f'); break;
          case 'n': out.push_back('\n'); break;
          case 'r': out.push_back('\r'); break;
          case 't': out.push_back('\t'); break;
          case 'u': {
            long code = read_hex4(text_, pos_);
            if (code < 0) break;
            pos_ += 4;
            if (code >= 0xD800 && code <= 0xDBFF && pos_ + 6 <= text_.size() &&
                text_[pos_] == '\\' && text_[pos_ + 1] == 'u') {
              const long low = read_hex4(text_, pos_ + 2);
              if (low >= 0xDC00 && low <= 0xDFFF) {
                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                pos_ += 6;
              }
            }
            append_utf8(out, static_cast<unsigned long>(code));
            break;
          }
          default: out.push_back(escaped); break;
        }
      } else {
        out.push_back(ch);
      }
    }
    return out;
  }

  Json parse_number() {
    const size_t start = pos_;
    while (pos_ < text_.size()) {
      const char ch = text_[pos_];
      if (!(std::isdigit(static_cast<unsigned char>(ch)) || ch == '-' || ch == '+' || ch == '.' || ch == 'e' || ch == 'E')) break;
      ++pos_;
    }
    return Json(std::strtod(std::string(text_.substr(start, pos_ - start)).c_str(), nullptr));
  }
};

struct ParsedUri {
  std::string scheme;
  std::string user_info;
  std::string host;
  int port = 0;
  std::vector<std::string> server_ports;
  std::string path;
  std::map<std::string, std::string> query;
  std::string fragment;
};

std::string trim(std::string_view value) {
  size_t start = 0;
  while (start < value.size() && std::isspace(static_cast<unsigned char>(value[start]))) {
    ++start;
  }
  size_t end = value.size();
  while (end > start && std::isspace(static_cast<unsigned char>(value[end - 1]))) {
    --end;
  }
  return std::string(value.substr(start, end - start));
}

std::string without_utf8_bom_markers(std::string value) {
  const std::string marker = "\xEF\xBB\xBF";
  size_t pos = 0;
  while ((pos = value.find(marker, pos)) != std::string::npos) {
    value.erase(pos, marker.size());
  }
  return value;
}

std::string first_non_empty_line(const char* raw_input) {
  if (raw_input == nullptr) {
    return "";
  }
  std::string raw(raw_input);
  size_t start = 0;
  while (start <= raw.size()) {
    const size_t end = raw.find_first_of("\r\n", start);
    const auto line = trim(std::string_view(raw).substr(start, end == std::string::npos ? std::string::npos : end - start));
    if (!line.empty()) {
      return line;
    }
    if (end == std::string::npos) {
      break;
    }
    start = end + 1;
  }
  return "";
}

std::string lower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
    return static_cast<char>(std::tolower(ch));
  });
  return value;
}

int parse_int(const std::string& value, int fallback = 0) {
  int parsed = fallback;
  const auto* begin = value.data();
  const auto* end = value.data() + value.size();
  auto result = std::from_chars(begin, end, parsed);
  if (result.ec != std::errc() || result.ptr != end) {
    return fallback;
  }
  return parsed;
}

std::vector<std::string> split_port_items(const std::string& raw) {
  std::vector<std::string> values;
  size_t start = 0;
  while (start <= raw.size()) {
    const size_t next = raw.find(',', start);
    const auto value = trim(std::string_view(raw).substr(start, next == std::string::npos ? std::string::npos : next - start));
    if (!value.empty()) {
      values.push_back(value);
    }
    if (next == std::string::npos) {
      break;
    }
    start = next + 1;
  }
  return values;
}

int first_server_port(const std::vector<std::string>& ports) {
  for (const auto& item : ports) {
    const auto first = trim(std::string_view(item).substr(0, item.find('-')));
    const auto parsed = parse_int(first);
    if (parsed > 0) {
      return parsed;
    }
  }
  return 0;
}

std::string url_decode(std::string_view value) {
  std::string out;
  out.reserve(value.size());
  for (size_t i = 0; i < value.size(); ++i) {
    const char ch = value[i];
    if (ch == '%' && i + 2 < value.size()) {
      const auto hex = std::string(value.substr(i + 1, 2));
      char* end = nullptr;
      const long decoded = std::strtol(hex.c_str(), &end, 16);
      if (end != nullptr && *end == '\0') {
        out.push_back(static_cast<char>(decoded));
        i += 2;
        continue;
      }
    }
    out.push_back(ch == '+' ? ' ' : ch);
  }
  return out;
}

std::map<std::string, std::string> parse_query(std::string_view raw) {
  std::map<std::string, std::string> query;
  size_t start = 0;
  while (start <= raw.size()) {
    const size_t amp = raw.find('&', start);
    const auto part = raw.substr(start, amp == std::string::npos ? std::string::npos : amp - start);
    if (!part.empty()) {
      const size_t eq = part.find('=');
      const auto key = url_decode(part.substr(0, eq));
      const auto value = eq == std::string::npos ? std::string() : url_decode(part.substr(eq + 1));
      query[key] = value;
    }
    if (amp == std::string::npos) {
      break;
    }
    start = amp + 1;
  }
  return query;
}

std::string query_value(const std::map<std::string, std::string>& query, const std::string& key) {
  const auto it = query.find(key);
  if (it == query.end()) {
    return "";
  }
  return trim(it->second);
}

std::string first_query_value(const std::map<std::string, std::string>& query, std::initializer_list<const char*> keys) {
  for (const auto* key : keys) {
    const auto value = query_value(query, key);
    if (!value.empty()) {
      return value;
    }
  }
  return "";
}

ParsedUri parse_uri(const std::string& link) {
  const size_t scheme_sep = link.find("://");
  if (scheme_sep == std::string::npos || scheme_sep == 0) {
    throw std::runtime_error("Unsupported link format.");
  }
  ParsedUri uri;
  uri.scheme = lower(link.substr(0, scheme_sep));
  std::string rest = link.substr(scheme_sep + 3);

  const size_t hash = rest.find('#');
  if (hash != std::string::npos) {
    uri.fragment = url_decode(std::string_view(rest).substr(hash + 1));
    rest = rest.substr(0, hash);
  }

  const size_t question = rest.find('?');
  if (question != std::string::npos) {
    uri.query = parse_query(std::string_view(rest).substr(question + 1));
    rest = rest.substr(0, question);
  }

  const size_t slash = rest.find('/');
  if (slash != std::string::npos) {
    uri.path = url_decode(std::string_view(rest).substr(slash));
    rest = rest.substr(0, slash);
  }

  const size_t at = rest.rfind('@');
  if (at != std::string::npos) {
    uri.user_info = url_decode(std::string_view(rest).substr(0, at));
    rest = rest.substr(at + 1);
  }

  if (!rest.empty() && rest.front() == '[') {
    const size_t close = rest.find(']');
    if (close == std::string::npos || close <= 1) {
      throw std::runtime_error("IPv6 endpoint is invalid.");
    }
    uri.host = url_decode(std::string_view(rest).substr(1, close - 1));
    if (close + 1 < rest.size() && rest[close + 1] == ':') {
      const auto port_text = rest.substr(close + 2);
      uri.server_ports = (port_text.find(',') != std::string::npos || port_text.find('-') != std::string::npos)
          ? split_port_items(port_text)
          : std::vector<std::string>();
      uri.port = uri.server_ports.empty() ? parse_int(port_text) : first_server_port(uri.server_ports);
    }
  } else {
    const size_t colon = rest.rfind(':');
    if (colon != std::string::npos) {
      uri.host = url_decode(std::string_view(rest).substr(0, colon));
      const auto port_text = rest.substr(colon + 1);
      uri.server_ports = (port_text.find(',') != std::string::npos || port_text.find('-') != std::string::npos)
          ? split_port_items(port_text)
          : std::vector<std::string>();
      uri.port = uri.server_ports.empty() ? parse_int(port_text) : first_server_port(uri.server_ports);
    } else {
      uri.host = url_decode(rest);
    }
  }
  return uri;
}

std::string normalize_path(const std::string& raw) {
  const auto value = trim(raw);
  if (value.empty()) {
    return "";
  }
  return value.front() == '/' ? value : "/" + value;
}

std::vector<std::string> split_list(const std::string& raw, char separator = ',') {
  std::vector<std::string> values;
  size_t start = 0;
  while (start <= raw.size()) {
    const size_t next = raw.find(separator, start);
    const auto value = trim(std::string_view(raw).substr(start, next == std::string::npos ? std::string::npos : next - start));
    if (!value.empty()) {
      values.push_back(value);
    }
    if (next == std::string::npos) {
      break;
    }
    start = next + 1;
  }
  return values;
}

bool to_bool(const std::string& raw) {
  const auto value = lower(trim(raw));
  return value == "1" || value == "true" || value == "yes" || value == "on";
}

std::string parse_transport(const std::string& raw) {
  const auto value = lower(trim(raw));
  if (value.empty() || value == "tcp" || value == "raw") return "raw";
  if (value == "ws") return "ws";
  if (value == "grpc") return "grpc";
  if (value == "h2" || value == "http") return "http";
  if (value == "httpupgrade" || value == "http-upgrade") return "httpUpgrade";
  if (value == "quic") return "quic";
  if (value == "xhttp" || value == "splithttp" || value == "split-http") return "xhttp";
  throw std::runtime_error("Unsupported transport: " + value);
}

std::string parse_tls_mode(const std::string& raw) {
  const auto value = lower(trim(raw));
  if (value == "tls" || value == "xtls") return "tls";
  if (value == "reality") return "reality";
  return "none";
}

std::string grpc_service_name(const std::string& raw) {
  return trim(raw);
}

std::string resolve_service_name(const std::string& transport, const std::map<std::string, std::string>& query) {
  if (transport != "grpc") {
    return "";
  }
  return grpc_service_name(first_query_value(query, {"servicename", "serviceName", "path"}));
}

std::string base64_decode(std::string value) {
  value.erase(std::remove_if(value.begin(), value.end(), [](unsigned char ch) {
    return ch == '\r' || ch == '\n' || std::isspace(ch);
  }), value.end());
  while (value.size() % 4 != 0) {
    value.push_back('=');
  }
  std::string out;
  int val = 0;
  int valb = -8;
  for (unsigned char ch : value) {
    if (ch == '=') break;
    int decoded = -1;
    if (ch >= 'A' && ch <= 'Z') decoded = ch - 'A';
    if (ch >= 'a' && ch <= 'z') decoded = ch - 'a' + 26;
    if (ch >= '0' && ch <= '9') decoded = ch - '0' + 52;
    if (ch == '+' || ch == '-') decoded = 62;
    if (ch == '/' || ch == '_') decoded = 63;
    if (decoded < 0) {
      throw std::runtime_error("Base64 payload is invalid.");
    }
    val = (val << 6) + decoded;
    valb += 6;
    if (valb >= 0) {
      out.push_back(static_cast<char>((val >> valb) & 0xFF));
      valb -= 8;
    }
  }
  return out;
}

std::string try_decode_subscription_base64_text(const char* raw_input) {
  if (raw_input == nullptr) {
    return "";
  }
  auto normalized = without_utf8_bom_markers(std::string(raw_input));
  normalized.erase(std::remove_if(normalized.begin(), normalized.end(), [](unsigned char ch) {
    return std::isspace(ch) != 0;
  }), normalized.end());
  if (normalized.empty() || normalized.find("://") != std::string::npos) {
    return "";
  }
  return trim(base64_decode(normalized));
}

std::string json_string_value(const std::string& json, const std::string& key) {
  const std::string needle = "\"" + key + "\"";
  size_t pos = json.find(needle);
  if (pos == std::string::npos) return "";
  pos = json.find(':', pos + needle.size());
  if (pos == std::string::npos) return "";
  ++pos;
  while (pos < json.size() && std::isspace(static_cast<unsigned char>(json[pos]))) ++pos;
  if (pos >= json.size()) return "";
  if (json[pos] != '"') {
    const size_t end = json.find_first_of(",}", pos);
    const auto value = trim(std::string_view(json).substr(pos, end == std::string::npos ? std::string::npos : end - pos));
    return value == "null" ? "" : value;
  }
  ++pos;
  std::string out;
  while (pos < json.size()) {
    const char ch = json[pos++];
    if (ch == '"') break;
    if (ch == '\\' && pos < json.size()) {
      const char escaped = json[pos++];
      switch (escaped) {
        case '"': out.push_back('"'); break;
        case '\\': out.push_back('\\'); break;
        case '/': out.push_back('/'); break;
        case 'b': out.push_back('\b'); break;
        case 'f': out.push_back('\f'); break;
        case 'n': out.push_back('\n'); break;
        case 'r': out.push_back('\r'); break;
        case 't': out.push_back('\t'); break;
        default: out.push_back(escaped); break;
      }
    } else {
      out.push_back(ch);
    }
  }
  return out;
}

bool json_bool_value(const std::string& json, const std::string& key) {
  const std::string needle = "\"" + key + "\"";
  size_t pos = json.find(needle);
  if (pos == std::string::npos) return false;
  pos = json.find(':', pos + needle.size());
  if (pos == std::string::npos) return false;
  ++pos;
  while (pos < json.size() && std::isspace(static_cast<unsigned char>(json[pos]))) ++pos;
  return json.compare(pos, 4, "true") == 0;
}

std::vector<std::string> json_string_array_value(const std::string& json, const std::string& key) {
  std::vector<std::string> values;
  const std::string needle = "\"" + key + "\"";
  size_t pos = json.find(needle);
  if (pos == std::string::npos) return values;
  pos = json.find('[', pos + needle.size());
  if (pos == std::string::npos) return values;
  ++pos;
  while (pos < json.size()) {
    while (pos < json.size() && std::isspace(static_cast<unsigned char>(json[pos]))) ++pos;
    if (pos >= json.size() || json[pos] == ']') break;
    if (json[pos] != '"') {
      pos = json.find_first_of(",]", pos);
      if (pos == std::string::npos || json[pos] == ']') break;
      ++pos;
      continue;
    }
    ++pos;
    std::string out;
    while (pos < json.size()) {
      const char ch = json[pos++];
      if (ch == '"') break;
      if (ch == '\\' && pos < json.size()) {
        const char escaped = json[pos++];
        switch (escaped) {
          case '"': out.push_back('"'); break;
          case '\\': out.push_back('\\'); break;
          case '/': out.push_back('/'); break;
          case 'b': out.push_back('\b'); break;
          case 'f': out.push_back('\f'); break;
          case 'n': out.push_back('\n'); break;
          case 'r': out.push_back('\r'); break;
          case 't': out.push_back('\t'); break;
          default: out.push_back(escaped); break;
        }
      } else {
        out.push_back(ch);
      }
    }
    values.push_back(out);
    pos = json.find_first_of(",]", pos);
    if (pos == std::string::npos || json[pos] == ']') break;
    ++pos;
  }
  return values;
}

Profile parse_vless_or_trojan(const std::string& link, bool trojan) {
  const auto uri = parse_uri(link);
  if (uri.host.empty() || uri.port == 0 || uri.user_info.empty()) {
    throw std::runtime_error(trojan ? "Trojan link is incomplete." : "VLESS link is incomplete.");
  }
  Profile profile;
  profile.protocol = trojan ? "trojan" : "vless";
  profile.server = uri.host;
  profile.port = uri.port;
  profile.transport = parse_transport(first_query_value(uri.query, {"type", "net"}));
  profile.tls_mode = parse_tls_mode(first_query_value(uri.query, {"security"}).empty() && trojan ? "tls" : first_query_value(uri.query, {"security"}));
  profile.remark = uri.fragment;
  if (trojan) {
    profile.password = uri.user_info;
  } else {
    profile.user_id = uri.user_info;
    profile.security = first_query_value(uri.query, {"encryption"});
    if (profile.security.empty()) profile.security = "none";
    profile.flow = query_value(uri.query, "flow");
  }
  profile.sni = first_query_value(uri.query, {"sni", "servername"});
  profile.alpn = split_list(query_value(uri.query, "alpn"));
  profile.host = query_value(uri.query, "host");
  profile.path = normalize_path(query_value(uri.query, "path"));
  profile.service_name = resolve_service_name(profile.transport, uri.query);
  profile.authority = first_query_value(uri.query, {"authority", "host"});
  profile.fingerprint = query_value(uri.query, "fp");
  profile.public_key = query_value(uri.query, "pbk");
  profile.short_id = query_value(uri.query, "sid");
  profile.spider_x = query_value(uri.query, "spx");
  profile.allow_insecure = to_bool(first_query_value(uri.query, {"allowinsecure", "insecure"}));
  return profile;
}

Profile parse_vmess(const std::string& link) {
  const auto payload = trim(std::string_view(link).substr(std::string("vmess://").size()));
  const auto decoded = base64_decode(payload);
  const auto server = json_string_value(decoded, "add");
  const auto port_text = json_string_value(decoded, "port");
  const auto user_id = json_string_value(decoded, "id");
  if (server.empty()) throw std::runtime_error("Missing field: add");
  if (port_text.empty()) throw std::runtime_error("Field port must be an integer.");
  if (user_id.empty()) throw std::runtime_error("Missing field: id");

  Profile profile;
  profile.protocol = "vmess";
  profile.server = server;
  profile.port = parse_int(port_text);
  profile.user_id = user_id;
  profile.transport = parse_transport(!json_string_value(decoded, "net").empty() ? json_string_value(decoded, "net") : json_string_value(decoded, "type"));
  const auto tls = lower(!json_string_value(decoded, "tls").empty() ? json_string_value(decoded, "tls") : json_string_value(decoded, "security"));
  profile.tls_mode = tls == "tls" ? "tls" : (tls == "reality" ? "reality" : "none");
  profile.remark = json_string_value(decoded, "ps");
  profile.security = !json_string_value(decoded, "scy").empty() ? json_string_value(decoded, "scy") : json_string_value(decoded, "security");
  if (profile.security.empty()) profile.security = "auto";
  profile.alter_id = parse_int(json_string_value(decoded, "aid"));
  profile.sni = json_string_value(decoded, "sni");
  profile.alpn = split_list(json_string_value(decoded, "alpn"));
  profile.host = json_string_value(decoded, "host");
  profile.path = normalize_path(json_string_value(decoded, "path"));
  profile.service_name = profile.transport == "grpc" ? grpc_service_name(!json_string_value(decoded, "serviceName").empty() ? json_string_value(decoded, "serviceName") : json_string_value(decoded, "path")) : "";
  profile.authority = !json_string_value(decoded, "authority").empty() ? json_string_value(decoded, "authority") : profile.host;
  profile.fingerprint = json_string_value(decoded, "fp");
  profile.allow_insecure = to_bool(!json_string_value(decoded, "allowInsecure").empty() ? json_string_value(decoded, "allowInsecure") : json_string_value(decoded, "insecure"));
  return profile;
}

Profile parse_shadowsocks(const std::string& link) {
  std::string rest = link.substr(std::string("ss://").size());
  std::string remark;
  const size_t hash = rest.find('#');
  if (hash != std::string::npos) {
    remark = url_decode(std::string_view(rest).substr(hash + 1));
    rest = rest.substr(0, hash);
  }
  const size_t question = rest.find('?');
  const std::string main_part = question == std::string::npos ? rest : rest.substr(0, question);
  const auto query = question == std::string::npos ? std::map<std::string, std::string>() : parse_query(std::string_view(rest).substr(question + 1));

  std::string credentials;
  std::string server_part;
  if (main_part.find('@') != std::string::npos) {
    const size_t at = main_part.rfind('@');
    credentials = main_part.substr(0, at);
    server_part = main_part.substr(at + 1);
    if (credentials.find(':') == std::string::npos) {
      credentials = base64_decode(credentials);
    }
  } else {
    const auto decoded = base64_decode(main_part);
    const size_t at = decoded.rfind('@');
    if (at == std::string::npos) {
      throw std::runtime_error("Shadowsocks link is incomplete.");
    }
    credentials = decoded.substr(0, at);
    server_part = decoded.substr(at + 1);
  }

  const size_t cred_sep = credentials.find(':');
  if (cred_sep == std::string::npos || cred_sep == 0) {
    throw std::runtime_error("Shadowsocks credentials are invalid.");
  }
  const auto endpoint = parse_uri("ss://placeholder@" + server_part);
  if (endpoint.host.empty() || endpoint.port == 0) {
    throw std::runtime_error("Shadowsocks link is incomplete.");
  }

  Profile profile;
  profile.protocol = "shadowsocks";
  profile.server = endpoint.host;
  profile.port = endpoint.port;
  profile.method = credentials.substr(0, cred_sep);
  profile.password = credentials.substr(cred_sep + 1);
  profile.remark = remark;
  const auto plugin_raw = query_value(query, "plugin");
  if (!plugin_raw.empty()) {
    const auto parts = split_list(plugin_raw, ';');
    if (!parts.empty()) profile.plugin = parts.front();
    if (parts.size() > 1) {
      std::ostringstream joined;
      for (size_t i = 1; i < parts.size(); ++i) {
        if (i > 1) joined << ';';
        joined << parts[i];
      }
      profile.plugin_opts = joined.str();
    }
  }
  return profile;
}

Profile parse_hysteria(const std::string& link, bool version2) {
  auto uri = parse_uri(link);
  if (version2 && uri.port == 0) {
    uri.port = 443;
  }
  if (uri.host.empty() || uri.port <= 0) {
    throw std::runtime_error(version2 ? "Hysteria2 link is incomplete." : "Hysteria link is incomplete.");
  }
  Profile profile;
  profile.protocol = version2 ? "hysteria2" : "hysteria";
  profile.server = uri.host;
  profile.port = uri.port;
  profile.server_ports = uri.server_ports;
  profile.transport = "quic";
  profile.tls_mode = "tls";
  profile.remark = uri.fragment;
  profile.sni = first_query_value(uri.query, version2 ? std::initializer_list<const char*>{"sni"} : std::initializer_list<const char*>{"peer", "sni"});
  profile.alpn = split_list(query_value(uri.query, "alpn"));
  profile.allow_insecure = to_bool(query_value(uri.query, "insecure"));
  profile.upload_mbps = parse_int(query_value(uri.query, "upmbps"));
  profile.download_mbps = parse_int(query_value(uri.query, "downmbps"));
  profile.hysteria_network = first_query_value(uri.query, {version2 ? "network" : "protocol"});
  if (profile.hysteria_network != "tcp" && profile.hysteria_network != "udp") {
    profile.hysteria_network.clear();
  }
  profile.obfs = query_value(uri.query, "obfs");
  profile.obfs_password = first_query_value(uri.query, {"obfs-password", "obfsPassword", "obfs-param", "obfsParam"});
  if (version2) {
    profile.password = uri.user_info;
  } else {
    profile.password = query_value(uri.query, "auth");
    if (profile.upload_mbps <= 0 || profile.download_mbps <= 0) {
      throw std::runtime_error("Field upmbps must be a positive integer.");
    }
  }
  return profile;
}

Profile parse_profile(const char* raw_input) {
  const auto raw = first_non_empty_line(raw_input);
  if (raw.empty()) {
    throw std::runtime_error("Connection link is empty.");
  }
  const size_t scheme_sep = raw.find("://");
  if (scheme_sep == std::string::npos || scheme_sep == 0) {
    throw std::runtime_error("Unsupported link format.");
  }
  const auto scheme = lower(raw.substr(0, scheme_sep));
  if (scheme == "vless") return parse_vless_or_trojan(raw, false);
  if (scheme == "trojan") return parse_vless_or_trojan(raw, true);
  if (scheme == "vmess") return parse_vmess(raw);
  if (scheme == "ss") return parse_shadowsocks(raw);
  if (scheme == "hysteria") return parse_hysteria(raw, false);
  if (scheme == "hysteria2" || scheme == "hy2") return parse_hysteria(raw, true);
  throw std::runtime_error("Unsupported protocol: " + scheme);
}

std::string to_json(const Profile& profile);

bool is_share_link_scheme(const std::string& scheme) {
  return scheme == "hysteria2" || scheme == "hysteria" || scheme == "vless" ||
      scheme == "vmess" || scheme == "trojan" || scheme == "hy2" || scheme == "ss";
}

bool is_likely_share_link_boundary(const std::string& text, size_t start) {
  if (start == 0) {
    return true;
  }
  const unsigned char previous = static_cast<unsigned char>(text[start - 1]);
  if (previous <= 32) {
    return true;
  }
  return previous == 0x22 || previous == 0x27 || previous == 0x28 ||
      previous == 0x2c || previous == 0x3b || previous == 0x3c ||
      previous == 0x3e || previous == 0x5b || previous == 0x60 ||
      previous == 0x7b || previous == 0x7c;
}

bool is_scheme_char(unsigned char ch) {
  return std::isalnum(ch) != 0;
}

bool is_trailing_share_link_separator(unsigned char ch) {
  return ch == 0x22 || ch == 0x27 || ch == 0x29 || ch == 0x2c ||
      ch == 0x2e || ch == 0x3b || ch == 0x3e || ch == 0x5d ||
      ch == 0x60 || ch == 0x7c || ch == 0x7d;
}

std::string trim_share_link(std::string value) {
  value = trim(value);
  const size_t line_break = value.find_first_of("\r\n");
  if (line_break != std::string::npos) {
    value = trim(std::string_view(value).substr(0, line_break));
  }
  while (!value.empty() &&
         is_trailing_share_link_separator(static_cast<unsigned char>(value.back()))) {
    value.pop_back();
    value = trim(value);
  }
  return value;
}

std::vector<std::string> extract_share_links(const char* raw_input) {
  if (raw_input == nullptr) {
    return {};
  }
  const auto normalized = without_utf8_bom_markers(std::string(raw_input));
  const auto lowered = lower(normalized);
  std::vector<size_t> starts;
  size_t search = 0;
  while (true) {
    const size_t separator = lowered.find("://", search);
    if (separator == std::string::npos) {
      break;
    }
    size_t scheme_start = separator;
    while (scheme_start > 0 &&
           is_scheme_char(static_cast<unsigned char>(lowered[scheme_start - 1]))) {
      --scheme_start;
    }
    const auto scheme = lowered.substr(scheme_start, separator - scheme_start);
    if (is_share_link_scheme(scheme) &&
        is_likely_share_link_boundary(normalized, scheme_start)) {
      starts.push_back(scheme_start);
    }
    search = separator + 3;
  }
  std::vector<std::string> links;
  for (size_t i = 0; i < starts.size(); ++i) {
    const size_t start = starts[i];
    const size_t end = i + 1 < starts.size() ? starts[i + 1] : normalized.size();
    const auto candidate = trim_share_link(normalized.substr(start, end - start));
    if (!candidate.empty()) {
      links.push_back(candidate);
    }
  }
  return links;
}

std::string parse_share_links_json(const char* raw_input) {
  const auto links = extract_share_links(raw_input);
  std::set<std::string> seen;
  std::ostringstream json;
  json << '[';
  bool first = true;
  for (const auto& link : links) {
    if (!seen.insert(link).second) {
      continue;
    }
    try {
      const auto profile_json = to_json(parse_profile(link.c_str()));
      if (!first) {
        json << ',';
      }
      first = false;
      json << profile_json;
    } catch (...) {
    }
  }
  json << ']';
  return json.str();
}

std::string json_escape(const std::string& value) {
  std::string out;
  out.reserve(value.size() + 2);
  for (const char ch : value) {
    switch (ch) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (static_cast<unsigned char>(ch) < 0x20) {
          out += "\\u00";
          const char* hex = "0123456789abcdef";
          out.push_back(hex[(ch >> 4) & 0xF]);
          out.push_back(hex[ch & 0xF]);
        } else {
          out.push_back(ch);
        }
        break;
    }
  }
  return out;
}

void add_string(std::ostringstream& json, bool& first, const char* key, const std::string& value) {
  if (value.empty()) return;
  if (!first) json << ',';
  first = false;
  json << '"' << key << "\":\"" << json_escape(value) << '"';
}

void add_int(std::ostringstream& json, bool& first, const char* key, int value, bool omit_zero = true) {
  if (omit_zero && value == 0) return;
  if (!first) json << ',';
  first = false;
  json << '"' << key << "\":" << value;
}

void add_bool(std::ostringstream& json, bool& first, const char* key, bool value) {
  if (!value) return;
  if (!first) json << ',';
  first = false;
  json << '"' << key << "\":true";
}

void add_string_array(std::ostringstream& json, bool& first, const char* key, const std::vector<std::string>& values) {
  if (values.empty()) return;
  if (!first) json << ',';
  first = false;
  json << '"' << key << "\":[";
  for (size_t i = 0; i < values.size(); ++i) {
    if (i > 0) json << ',';
    json << '"' << json_escape(values[i]) << '"';
  }
  json << ']';
}

struct TcpPingTargetNative {
  int profile_index = 0;
  std::string profile_key;
  std::string host;
  int port = 0;
};

struct TcpPingResultNative {
  bool ok = false;
  int profile_index = 0;
  std::string profile_key;
  int latency_ms = 0;
};

std::vector<TcpPingTargetNative> tcp_ping_targets_from_json(const char* targets_json) {
  const auto root = JsonParser(targets_json == nullptr ? "[]" : targets_json).parse();
  std::vector<TcpPingTargetNative> targets;
  if (!root.is_array()) {
    throw std::runtime_error("TCP ping targets must be a JSON array.");
  }
  for (const auto& item : root.array()) {
    if (!item.is_object()) {
      continue;
    }
    TcpPingTargetNative target;
    target.profile_index = item.at("profileIndex").int_value();
    target.profile_key = item.at("profileKey").string_value();
    target.host = trim(item.at("host").string_value());
    target.port = item.at("port").int_value();
    if (!target.host.empty() && target.port > 0 && target.port <= 65535) {
      targets.push_back(std::move(target));
    }
  }
  return targets;
}

#if defined(_WIN32)
class WinsockSession {
 public:
  WinsockSession() {
    WSADATA data{};
    const int result = WSAStartup(MAKEWORD(2, 2), &data);
    if (result != 0) {
      throw std::runtime_error("WSAStartup failed.");
    }
    initialized_ = true;
  }

  ~WinsockSession() {
    if (initialized_) {
      WSACleanup();
    }
  }

  WinsockSession(const WinsockSession&) = delete;
  WinsockSession& operator=(const WinsockSession&) = delete;

 private:
  bool initialized_ = false;
};

class SocketHandle {
 public:
  explicit SocketHandle(SOCKET socket) : socket_(socket) {}
  ~SocketHandle() {
    if (socket_ != INVALID_SOCKET) {
      closesocket(socket_);
    }
  }

  SocketHandle(const SocketHandle&) = delete;
  SocketHandle& operator=(const SocketHandle&) = delete;

  SOCKET get() const { return socket_; }

 private:
  SOCKET socket_ = INVALID_SOCKET;
};

int tcp_connect_latency_ms(const std::string& host, int port, int timeout_ms) {
  const auto started = std::chrono::steady_clock::now();
  const auto deadline = started + std::chrono::milliseconds(timeout_ms);
  addrinfo hints{};
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_protocol = IPPROTO_TCP;

  addrinfo* raw_addresses = nullptr;
  const std::string port_text = std::to_string(port);
  const int resolve_result =
      getaddrinfo(host.c_str(), port_text.c_str(), &hints, &raw_addresses);
  if (resolve_result != 0 || raw_addresses == nullptr) {
    throw std::runtime_error("Could not resolve TCP ping target.");
  }
  std::unique_ptr<addrinfo, decltype(&freeaddrinfo)> addresses(raw_addresses,
                                                               freeaddrinfo);

  int last_error = 0;
  for (addrinfo* address = addresses.get(); address != nullptr;
       address = address->ai_next) {
    const auto now = std::chrono::steady_clock::now();
    if (now >= deadline) {
      last_error = WSAETIMEDOUT;
      break;
    }
    const auto remaining_ms =
        std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now)
            .count();
    SocketHandle socket(socket(address->ai_family, address->ai_socktype,
                               address->ai_protocol));
    if (socket.get() == INVALID_SOCKET) {
      last_error = WSAGetLastError();
      continue;
    }

    u_long non_blocking = 1;
    if (ioctlsocket(socket.get(), FIONBIO, &non_blocking) != 0) {
      last_error = WSAGetLastError();
      continue;
    }

    const int connect_result =
        connect(socket.get(), address->ai_addr,
                static_cast<int>(address->ai_addrlen));
    if (connect_result == 0) {
      const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now() - started);
      return elapsed.count() <= 0 ? 1 : static_cast<int>(elapsed.count());
    }

    const int connect_error = WSAGetLastError();
    if (connect_error != WSAEWOULDBLOCK &&
        connect_error != WSAEINPROGRESS &&
        connect_error != WSAEINVAL) {
      last_error = connect_error;
      continue;
    }

    fd_set write_set;
    fd_set error_set;
    FD_ZERO(&write_set);
    FD_ZERO(&error_set);
    FD_SET(socket.get(), &write_set);
    FD_SET(socket.get(), &error_set);
    timeval timeout{};
    timeout.tv_sec = static_cast<long>(remaining_ms / 1000);
    timeout.tv_usec = static_cast<long>((remaining_ms % 1000) * 1000);
    const int selected =
        select(0, nullptr, &write_set, &error_set, &timeout);
    if (selected <= 0) {
      last_error = selected == 0 ? WSAETIMEDOUT : WSAGetLastError();
      continue;
    }

    int socket_error = 0;
    int socket_error_size = sizeof(socket_error);
    if (getsockopt(socket.get(), SOL_SOCKET, SO_ERROR,
                   reinterpret_cast<char*>(&socket_error),
                   &socket_error_size) != 0) {
      last_error = WSAGetLastError();
      continue;
    }
    if (socket_error == 0 && FD_ISSET(socket.get(), &write_set)) {
      const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now() - started);
      return elapsed.count() <= 0 ? 1 : static_cast<int>(elapsed.count());
    }
    last_error = socket_error == 0 ? WSAECONNREFUSED : socket_error;
  }

  throw std::runtime_error("TCP ping failed with Windows socket error " +
                           std::to_string(last_error) + ".");
}
#else
int tcp_connect_latency_ms(const std::string& host, int port, int timeout_ms) {
  (void)host;
  (void)port;
  (void)timeout_ms;
  throw std::runtime_error("Native TCP ping is only available on Windows.");
}
#endif

std::string measure_tcp_pings_json(const char* targets_json,
                                   int timeout_ms,
                                   int max_concurrent) {
  const auto targets = tcp_ping_targets_from_json(targets_json);
  if (targets.empty()) {
    return "[]";
  }
  if (timeout_ms <= 0) {
    timeout_ms = 1;
  }
  if (max_concurrent <= 0) {
    max_concurrent = 1;
  }
  if (max_concurrent > 64) {
    max_concurrent = 64;
  }

#if defined(_WIN32)
  WinsockSession winsock;
#endif

  std::vector<TcpPingResultNative> results(targets.size());
  std::atomic<size_t> next_index{0};
  const size_t worker_count = (std::min)(
      targets.size(), static_cast<size_t>(max_concurrent));
  std::vector<std::thread> workers;
  workers.reserve(worker_count);
  for (size_t worker = 0; worker < worker_count; ++worker) {
    workers.emplace_back([&]() {
      while (true) {
        const size_t index = next_index.fetch_add(1);
        if (index >= targets.size()) {
          return;
        }
        const auto& target = targets[index];
        TcpPingResultNative result;
        result.profile_index = target.profile_index;
        result.profile_key = target.profile_key;
        try {
          result.latency_ms =
              tcp_connect_latency_ms(target.host, target.port, timeout_ms);
          result.ok = true;
        } catch (...) {
          result.ok = false;
        }
        results[index] = std::move(result);
      }
    });
  }
  for (auto& worker : workers) {
    worker.join();
  }

  std::ostringstream json;
  json << '[';
  bool first = true;
  for (const auto& result : results) {
    if (!result.ok) {
      continue;
    }
    if (!first) {
      json << ',';
    }
    first = false;
    json << '{';
    bool first_field = true;
    add_int(json, first_field, "profileIndex", result.profile_index, false);
    add_string(json, first_field, "profileKey", result.profile_key);
    add_int(json, first_field, "latencyMs", result.latency_ms, false);
    json << '}';
  }
  json << ']';
  return json.str();
}

std::string to_json(const Profile& profile) {
  std::ostringstream json;
  bool first = true;
  json << '{';
  add_string(json, first, "protocol", profile.protocol);
  add_string(json, first, "server", profile.server);
  add_int(json, first, "port", profile.port, false);
  add_string(json, first, "transport", profile.transport);
  add_string(json, first, "tlsMode", profile.tls_mode);
  add_string(json, first, "remark", profile.remark);
  add_string(json, first, "userId", profile.user_id);
  add_string(json, first, "password", profile.password);
  add_string(json, first, "method", profile.method);
  add_string(json, first, "security", profile.security);
  add_int(json, first, "alterId", profile.alter_id);
  add_string(json, first, "flow", profile.flow);
  add_string(json, first, "sni", profile.sni);
  add_string_array(json, first, "alpn", profile.alpn);
  add_string(json, first, "host", profile.host);
  add_string(json, first, "path", profile.path);
  add_string(json, first, "serviceName", profile.service_name);
  add_string(json, first, "authority", profile.authority);
  add_string(json, first, "fingerprint", profile.fingerprint);
  add_string(json, first, "publicKey", profile.public_key);
  add_string(json, first, "shortId", profile.short_id);
  add_string(json, first, "spiderX", profile.spider_x);
  add_bool(json, first, "allowInsecure", profile.allow_insecure);
  add_string(json, first, "plugin", profile.plugin);
  add_string(json, first, "pluginOpts", profile.plugin_opts);
  add_string_array(json, first, "serverPorts", profile.server_ports);
  add_int(json, first, "uploadMbps", profile.upload_mbps);
  add_int(json, first, "downloadMbps", profile.download_mbps);
  add_string(json, first, "hysteriaNetwork", profile.hysteria_network);
  add_string(json, first, "obfs", profile.obfs);
  add_string(json, first, "obfsPassword", profile.obfs_password);
  json << '}';
  return json.str();
}

Profile profile_from_json(const std::string& json) {
  Profile profile;
  profile.protocol = json_string_value(json, "protocol");
  profile.server = json_string_value(json, "server");
  profile.port = parse_int(json_string_value(json, "port"));
  profile.transport = json_string_value(json, "transport");
  if (profile.transport.empty()) profile.transport = "raw";
  profile.tls_mode = json_string_value(json, "tlsMode");
  if (profile.tls_mode.empty()) profile.tls_mode = "none";
  profile.remark = json_string_value(json, "remark");
  profile.user_id = json_string_value(json, "userId");
  profile.password = json_string_value(json, "password");
  profile.method = json_string_value(json, "method");
  profile.security = json_string_value(json, "security");
  profile.alter_id = parse_int(json_string_value(json, "alterId"));
  profile.flow = json_string_value(json, "flow");
  profile.sni = json_string_value(json, "sni");
  profile.alpn = json_string_array_value(json, "alpn");
  profile.host = json_string_value(json, "host");
  profile.path = json_string_value(json, "path");
  profile.service_name = json_string_value(json, "serviceName");
  profile.authority = json_string_value(json, "authority");
  profile.fingerprint = json_string_value(json, "fingerprint");
  profile.public_key = json_string_value(json, "publicKey");
  profile.short_id = json_string_value(json, "shortId");
  profile.spider_x = json_string_value(json, "spiderX");
  profile.allow_insecure = json_bool_value(json, "allowInsecure");
  profile.plugin = json_string_value(json, "plugin");
  profile.plugin_opts = json_string_value(json, "pluginOpts");
  profile.server_ports = json_string_array_value(json, "serverPorts");
  profile.upload_mbps = parse_int(json_string_value(json, "uploadMbps"));
  profile.download_mbps = parse_int(json_string_value(json, "downloadMbps"));
  profile.hysteria_network = json_string_value(json, "hysteriaNetwork");
  profile.obfs = json_string_value(json, "obfs");
  profile.obfs_password = json_string_value(json, "obfsPassword");
  profile.sing_box_config_json = json_string_value(json, "singBoxConfigJson");
  profile.xray_config_json = json_string_value(json, "xrayConfigJson");
  return profile;
}

ConfigOptions options_from_json(const std::string& json) {
  ConfigOptions options;
  options.core = json_string_value(json, "core");
  options.traffic_mode = json_string_value(json, "trafficMode");
  if (options.traffic_mode.empty()) options.traffic_mode = "systemProxy";
  options.tun_ip_mode = json_string_value(json, "tunIpMode");
  if (options.tun_ip_mode.empty()) options.tun_ip_mode = "ipv4";
  options.is_android = json_bool_value(json, "isAndroid");
  options.is_windows = json_bool_value(json, "isWindows");
  options.dns_mode = json_string_value(json, "dnsMode");
  if (options.dns_mode.empty()) options.dns_mode = "classic";
  options.dns_servers = json_string_array_value(json, "dnsServers");
  options.split_tunnel_mode = json_string_value(json, "splitTunnelMode");
  if (options.split_tunnel_mode.empty()) options.split_tunnel_mode = "off";
  options.split_tunnel_app_names = json_string_array_value(json, "splitTunnelAppNames");
  options.split_tunnel_app_paths = json_string_array_value(json, "splitTunnelAppPaths");
  options.domain_split_tunnel_mode = json_string_value(json, "domainSplitTunnelMode");
  if (options.domain_split_tunnel_mode.empty()) options.domain_split_tunnel_mode = "off";
  options.domain_split_tunnel_domains = json_string_array_value(json, "domainSplitTunnelDomains");
  options.tun_interface_name = json_string_value(json, "tunInterfaceName");
  options.outbound_bind_interface = json_string_value(json, "outboundBindInterface");
  options.route_default_interface = json_string_value(json, "routeDefaultInterface");
  options.xray_server_address_override = json_string_value(json, "xrayServerAddressOverride");
  return options;
}

void write_string(std::ostringstream& json, const std::string& value) {
  json << '"' << json_escape(value) << '"';
}

void write_string_array(std::ostringstream& json, const std::vector<std::string>& values) {
  json << '[';
  for (size_t i = 0; i < values.size(); ++i) {
    if (i > 0) json << ',';
    write_string(json, values[i]);
  }
  json << ']';
}

std::string require_value(const std::string& value, const std::string& name) {
  if (trim(value).empty()) {
    throw std::runtime_error(name + " is missing in the provided link.");
  }
  return value;
}

int require_positive_int(int value, const std::string& name) {
  if (value <= 0) {
    throw std::runtime_error(name + " is missing in the provided link.");
  }
  return value;
}

bool is_tun(const ConfigOptions& options) {
  return options.traffic_mode == "tun";
}

std::string dns_strategy(const std::string& mode) {
  if (mode == "dualStack") return "prefer_ipv4";
  if (mode == "ipv6") return "ipv6_only";
  return "ipv4_only";
}

std::string xray_dns_strategy(const std::string& mode) {
  if (mode == "dualStack") return "UseIP";
  if (mode == "ipv6") return "UseIPv6";
  return "UseIPv4";
}

std::vector<std::string> tun_addresses(const std::string& mode) {
  if (mode == "dualStack") return {"172.19.0.1/30", "fdfe:dcba:9876::1/126"};
  if (mode == "ipv6") return {"fdfe:dcba:9876::1/126"};
  return {"172.19.0.1/30"};
}

std::vector<std::string> tun_route_addresses(const std::string& mode) {
  if (mode == "ipv6") return {"::/1", "8000::/1"};
  if (mode == "dualStack") return {};
  return {"0.0.0.0/1", "128.0.0.0/1"};
}

bool looks_ipv4(const std::string& value) {
  if (value.empty()) return false;
  return std::all_of(value.begin(), value.end(), [](unsigned char ch) {
    return std::isdigit(ch) || ch == '.';
  }) && value.find('.') != std::string::npos;
}

bool looks_ipv6(const std::string& value) {
  return value.find(':') != std::string::npos;
}

struct DohServer {
  std::string host;
  int port = 443;
  std::string path = "/dns-query";
};

DohServer parse_doh_server(const std::string& value) {
  DohServer parsed;
  std::string remainder = trim(value);
  const std::string scheme_prefix = "https://";
  if (remainder.size() >= scheme_prefix.size() &&
      std::equal(scheme_prefix.begin(), scheme_prefix.end(), remainder.begin(),
                 [](char a, char b) { return std::tolower(static_cast<unsigned char>(a)) == std::tolower(static_cast<unsigned char>(b)); })) {
    remainder = remainder.substr(scheme_prefix.size());
  }
  std::string authority = remainder;
  const auto slash = remainder.find('/');
  if (slash != std::string::npos) {
    authority = remainder.substr(0, slash);
    parsed.path = remainder.substr(slash);
  }
  std::string host = authority;
  if (!host.empty() && host.front() == '[') {
    const auto end = host.find(']');
    if (end != std::string::npos) {
      const std::string after = host.substr(end + 1);
      parsed.host = host.substr(1, end - 1);
      if (after.size() > 1 && after.front() == ':') {
        const int port = std::atoi(after.c_str() + 1);
        if (port > 0 && port <= 65535) parsed.port = port;
      }
      return parsed;
    }
  }
  const auto colon = host.rfind(':');
  if (colon != std::string::npos && host.find(':') == colon) {
    const int port = std::atoi(host.c_str() + colon + 1);
    if (port > 0 && port <= 65535) {
      parsed.port = port;
      host = host.substr(0, colon);
    }
  }
  parsed.host = host;
  return parsed;
}

struct DotServer {
  std::string host;
  int port = 853;
};

DotServer parse_dot_server(const std::string& value) {
  DotServer parsed;
  std::string remainder = trim(value);
  const std::string scheme_prefix = "tls://";
  if (remainder.size() >= scheme_prefix.size() &&
      std::equal(scheme_prefix.begin(), scheme_prefix.end(), remainder.begin(),
                 [](char a, char b) { return std::tolower(static_cast<unsigned char>(a)) == std::tolower(static_cast<unsigned char>(b)); })) {
    remainder = remainder.substr(scheme_prefix.size());
  }
  if (!remainder.empty() && remainder.front() == '[') {
    const auto end = remainder.find(']');
    if (end != std::string::npos) {
      const std::string after = remainder.substr(end + 1);
      parsed.host = remainder.substr(1, end - 1);
      if (after.size() > 1 && after.front() == ':') {
        const int port = std::atoi(after.c_str() + 1);
        if (port > 0 && port <= 65535) parsed.port = port;
      }
      return parsed;
    }
  }
  const auto colon_count = std::count(remainder.begin(), remainder.end(), ':');
  if (colon_count == 1) {
    const auto colon = remainder.find(':');
    const int port = std::atoi(remainder.c_str() + colon + 1);
    if (port > 0 && port <= 65535) {
      parsed.port = port;
      parsed.host = remainder.substr(0, colon);
      return parsed;
    }
  }
  parsed.host = remainder;
  return parsed;
}

std::string xray_dns_entry(const std::string& mode, const std::string& value) {
  const std::string trimmed = trim(value);
  if (trimmed.empty()) return trimmed;
  if (mode == "doh") {
    if (trimmed.rfind("https://", 0) == 0 || trimmed.rfind("https+local://", 0) == 0) {
      return trimmed;
    }
    return "https://" + trimmed;
  }
  if (mode == "dot") {
    if (trimmed.rfind("tls://", 0) == 0 || trimmed.rfind("tls+local://", 0) == 0) {
      return trimmed;
    }
    // Bracket bare IPv6 literals so the URL parser keeps the colons attached
    // to the host instead of treating them as port separators.
    if (trimmed.find(':') != std::string::npos && trimmed.front() != '[' &&
        std::count(trimmed.begin(), trimmed.end(), ':') > 1) {
      return "tls://[" + trimmed + "]";
    }
    return "tls://" + trimmed;
  }
  return trimmed;
}

void write_sing_box_dns_server(std::ostringstream& json,
                               const std::string& mode,
                               const std::string& tag,
                               const std::string& server,
                               const std::string& detour) {
  if (mode == "doh") {
    const auto parsed = parse_doh_server(server);
    json << "{\"type\":\"https\",\"tag\":";
    write_string(json, tag);
    json << ",\"server\":";
    write_string(json, parsed.host);
    json << ",\"server_port\":" << parsed.port;
    json << ",\"path\":";
    write_string(json, parsed.path);
    if (!detour.empty()) {
      json << ",\"detour\":";
      write_string(json, detour);
    }
    json << '}';
    return;
  }
  if (mode == "dot") {
    const auto parsed = parse_dot_server(server);
    json << "{\"type\":\"tls\",\"tag\":";
    write_string(json, tag);
    json << ",\"server\":";
    write_string(json, parsed.host);
    json << ",\"server_port\":" << parsed.port;
    if (!detour.empty()) {
      json << ",\"detour\":";
      write_string(json, detour);
    }
    json << '}';
    return;
  }
  json << "{\"type\":\"udp\",\"tag\":";
  write_string(json, tag);
  json << ",\"server\":";
  write_string(json, server);
  json << ",\"server_port\":53";
  if (!detour.empty()) {
    json << ",\"detour\":";
    write_string(json, detour);
  }
  json << '}';
}

std::vector<std::string> tun_route_excludes(const Profile& profile) {
  const auto server = trim(profile.server);
  if (looks_ipv6(server)) return {server + "/128"};
  if (looks_ipv4(server)) return {server + "/32"};
  return {};
}

std::string route_final(const ConfigOptions& options) {
  return options.split_tunnel_mode == "whitelist" || options.domain_split_tunnel_mode == "whitelist"
      ? "direct"
      : "proxy";
}

std::string path_basename(const std::string& path) {
  const size_t slash = path.find_last_of("\\/");
  return slash == std::string::npos ? path : path.substr(slash + 1);
}

std::string path_dirname(const std::string& path) {
  const size_t slash = path.find_last_of("\\/");
  if (slash == std::string::npos) return "";
  return path.substr(0, slash);
}

std::string without_extension(const std::string& value) {
  const size_t dot = value.find_last_of('.');
  return dot == std::string::npos ? value : value.substr(0, dot);
}

std::string regex_escape(const std::string& value) {
  std::string out;
  for (char ch : value) {
    switch (ch) {
      case '\\': case '.': case '^': case '$': case '|': case '?': case '*':
      case '+': case '(': case ')': case '[': case ']': case '{': case '}':
        out.push_back('\\');
        out.push_back(ch);
        break;
      default:
        out.push_back(ch);
        break;
    }
  }
  return out;
}

std::vector<std::string> sorted_unique(std::vector<std::string> values) {
  values.erase(std::remove_if(values.begin(), values.end(), [](const std::string& item) {
    return trim(item).empty();
  }), values.end());
  std::sort(values.begin(), values.end());
  values.erase(std::unique(values.begin(), values.end()), values.end());
  return values;
}

std::string lower_copy(std::string value) {
  return lower(std::move(value));
}

std::string process_matcher_json(const ConfigOptions& options) {
  std::vector<std::string> names;
  std::vector<std::string> paths;
  std::vector<std::string> regexes;
  for (size_t i = 0; i < options.split_tunnel_app_paths.size(); ++i) {
    const auto path = trim(options.split_tunnel_app_paths[i]);
    if (path.empty()) continue;
    paths.push_back(path);
    const auto base = path_basename(path);
    const auto stem = without_extension(base);
    names.push_back(base);
    names.push_back(lower_copy(base));
    names.push_back(stem);
    names.push_back(lower_copy(stem));
    regexes.push_back("(?i)^" + regex_escape(path) + "$");
    const auto dir = path_dirname(path);
    if (!dir.empty() && dir != path) {
      regexes.push_back("(?i)^" + regex_escape(dir) + "[\\\\/].+\\.exe$");
    }
  }
  names = sorted_unique(std::move(names));
  paths = sorted_unique(std::move(paths));
  regexes = sorted_unique(std::move(regexes));
  std::vector<std::string> matcher_objects;
  if (!names.empty()) {
    std::ostringstream object;
    object << "{\"process_name\":";
    write_string_array(object, names);
    object << '}';
    matcher_objects.push_back(object.str());
  }
  if (!paths.empty()) {
    std::ostringstream object;
    object << "{\"process_path\":";
    write_string_array(object, paths);
    object << '}';
    matcher_objects.push_back(object.str());
  }
  if (!regexes.empty()) {
    std::ostringstream object;
    object << "{\"process_path_regex\":";
    write_string_array(object, regexes);
    object << '}';
    matcher_objects.push_back(object.str());
  }
  if (matcher_objects.empty()) return "{}";
  if (matcher_objects.size() == 1) return matcher_objects.front();
  std::ostringstream json;
  json << "{\"type\":\"logical\",\"mode\":\"or\",\"rules\":[";
  for (size_t i = 0; i < matcher_objects.size(); ++i) {
    if (i > 0) json << ',';
    json << matcher_objects[i];
  }
  json << "]}";
  return json.str();
}

std::string domain_matcher_json(const ConfigOptions& options) {
  auto domains = sorted_unique(options.domain_split_tunnel_domains);
  std::ostringstream json;
  json << "{\"domain_suffix\":";
  write_string_array(json, domains);
  json << '}';
  return json.str();
}

std::string dns_matcher_json() {
  return "{\"type\":\"logical\",\"mode\":\"or\",\"rules\":[{\"protocol\":\"dns\"},{\"port\":53}]}";
}

void append_sing_box_route_rules(std::ostringstream& json, const ConfigOptions& options) {
  const bool app_whitelist = options.split_tunnel_mode == "whitelist" && !options.split_tunnel_app_paths.empty();
  const bool app_blacklist = options.split_tunnel_mode == "blacklist" && !options.split_tunnel_app_paths.empty();
  const bool domain_whitelist = options.domain_split_tunnel_mode == "whitelist" && !options.domain_split_tunnel_domains.empty();
  const bool domain_blacklist = options.domain_split_tunnel_mode == "blacklist" && !options.domain_split_tunnel_domains.empty();
  const bool has_whitelist = options.split_tunnel_mode == "whitelist" || options.domain_split_tunnel_mode == "whitelist";
  const bool has_blacklist = options.split_tunnel_mode == "blacklist" || options.domain_split_tunnel_mode == "blacklist";

  json << "{\"action\":\"sniff\"},{\"action\":\"resolve\",\"strategy\":\"" << dns_strategy(options.tun_ip_mode) << "\"}";
  if (!has_whitelist && !has_blacklist) {
    json << ",{\"type\":\"logical\",\"mode\":\"or\",\"rules\":[{\"protocol\":\"dns\"},{\"port\":53}],\"action\":\"hijack-dns\"}";
    json << ",{\"network\":\"udp\",\"port\":443,\"action\":\"reject\",\"method\":\"default\"}";
    json << ",{\"ip_is_private\":true,\"action\":\"route\",\"outbound\":\"direct\"}";
    return;
  }
  if (has_whitelist) {
    json << ",{\"network\":\"udp\",\"port\":443,\"action\":\"reject\",\"method\":\"default\"}";
    json << ",{\"ip_is_private\":true,\"action\":\"route\",\"outbound\":\"direct\"}";
    if (app_blacklist) json << ',' << process_matcher_json(options).substr(0, process_matcher_json(options).size() - 1) << ",\"action\":\"route\",\"outbound\":\"direct\"}";
    if (domain_blacklist) json << ',' << domain_matcher_json(options).substr(0, domain_matcher_json(options).size() - 1) << ",\"action\":\"route\",\"outbound\":\"direct\"}";
    if (app_whitelist) json << ",{\"type\":\"logical\",\"mode\":\"and\",\"rules\":[" << process_matcher_json(options) << ',' << dns_matcher_json() << "],\"action\":\"hijack-dns\"}";
    if (domain_whitelist) json << ",{\"type\":\"logical\",\"mode\":\"and\",\"rules\":[" << domain_matcher_json(options) << ',' << dns_matcher_json() << "],\"action\":\"hijack-dns\"}";
    if (app_whitelist) json << ',' << process_matcher_json(options).substr(0, process_matcher_json(options).size() - 1) << ",\"action\":\"route\",\"outbound\":\"proxy\"}";
    if (domain_whitelist) json << ',' << domain_matcher_json(options).substr(0, domain_matcher_json(options).size() - 1) << ",\"action\":\"route\",\"outbound\":\"proxy\"}";
    return;
  }
  json << ",{\"ip_is_private\":true,\"action\":\"route\",\"outbound\":\"direct\"}";
  if (app_blacklist) json << ',' << process_matcher_json(options).substr(0, process_matcher_json(options).size() - 1) << ",\"action\":\"route\",\"outbound\":\"direct\"}";
  if (domain_blacklist) json << ',' << domain_matcher_json(options).substr(0, domain_matcher_json(options).size() - 1) << ",\"action\":\"route\",\"outbound\":\"direct\"}";
  json << ",{\"type\":\"logical\",\"mode\":\"or\",\"rules\":[{\"protocol\":\"dns\"},{\"port\":53}],\"action\":\"hijack-dns\"}";
  json << ",{\"network\":\"udp\",\"port\":443,\"action\":\"reject\",\"method\":\"default\"}";
}

std::string sing_box_transport_json(const Profile& profile) {
  std::ostringstream json;
  if (profile.transport == "raw") return "";
  if (profile.transport == "ws") {
    json << "{\"type\":\"ws\",\"path\":";
    write_string(json, profile.path.empty() ? "/" : profile.path);
    if (!profile.host.empty()) {
      json << ",\"headers\":{\"Host\":";
      write_string(json, profile.host);
      json << '}';
    }
    json << '}';
    return json.str();
  }
  if (profile.transport == "grpc") {
    json << "{\"type\":\"grpc\",\"service_name\":";
    write_string(json, profile.service_name.empty() ? "grpc" : profile.service_name);
    json << '}';
    return json.str();
  }
  if (profile.transport == "http") {
    json << "{\"type\":\"http\",\"path\":";
    write_string(json, profile.path.empty() ? "/" : profile.path);
    if (!profile.host.empty()) {
      json << ",\"host\":[";
      write_string(json, profile.host);
      json << ']';
    }
    json << '}';
    return json.str();
  }
  if (profile.transport == "httpUpgrade") {
    json << "{\"type\":\"httpupgrade\",\"path\":";
    write_string(json, profile.path.empty() ? "/" : profile.path);
    if (!profile.host.empty()) {
      json << ",\"host\":";
      write_string(json, profile.host);
    }
    json << '}';
    return json.str();
  }
  if (profile.transport == "quic") return "{\"type\":\"quic\"}";
  if (profile.transport == "xhttp") throw std::runtime_error("XHTTP transport is only supported by Xray.");
  return "";
}

std::string sing_box_tls_json(const Profile& profile) {
  if (profile.tls_mode == "none" || profile.tls_mode.empty()) return "";
  std::ostringstream json;
  json << "{\"enabled\":true";
  if (!profile.sni.empty()) {
    json << ",\"server_name\":";
    write_string(json, profile.sni);
  }
  if (profile.allow_insecure) json << ",\"insecure\":true";
  if (!profile.alpn.empty()) {
    json << ",\"alpn\":";
    write_string_array(json, profile.alpn);
  }
  if (!profile.fingerprint.empty() || profile.tls_mode == "reality") {
    json << ",\"utls\":{\"enabled\":true,\"fingerprint\":";
    write_string(json, profile.fingerprint.empty() ? "chrome" : profile.fingerprint);
    json << '}';
  }
  if (profile.tls_mode == "reality") {
    json << ",\"reality\":{\"enabled\":true,\"public_key\":";
    write_string(json, require_value(profile.public_key, "REALITY public key"));
    json << ",\"short_id\":";
    write_string(json, profile.short_id);
    json << '}';
  }
  json << '}';
  return json.str();
}

std::string sing_box_outbound_json(const Profile& profile, const std::string& bind_interface) {
  std::ostringstream json;
  json << "{\"tag\":\"proxy\"";
  if (!trim(bind_interface).empty()) {
    json << ",\"bind_interface\":";
    write_string(json, trim(bind_interface));
  }
  if (profile.protocol == "vless") {
    json << ",\"type\":\"vless\",\"server\":";
    write_string(json, profile.server);
    json << ",\"server_port\":" << profile.port << ",\"uuid\":";
    write_string(json, require_value(profile.user_id, "VLESS user ID"));
    json << ",\"flow\":";
    write_string(json, profile.flow);
    json << ",\"packet_encoding\":\"xudp\"";
  } else if (profile.protocol == "vmess") {
    json << ",\"type\":\"vmess\",\"server\":";
    write_string(json, profile.server);
    json << ",\"server_port\":" << profile.port << ",\"uuid\":";
    write_string(json, require_value(profile.user_id, "VMess user ID"));
    json << ",\"security\":";
    write_string(json, profile.security.empty() ? "auto" : profile.security);
    json << ",\"alter_id\":" << profile.alter_id << ",\"packet_encoding\":\"xudp\"";
  } else if (profile.protocol == "trojan") {
    json << ",\"type\":\"trojan\",\"server\":";
    write_string(json, profile.server);
    json << ",\"server_port\":" << profile.port << ",\"password\":";
    write_string(json, require_value(profile.password, "Trojan password"));
  } else if (profile.protocol == "shadowsocks") {
    json << ",\"type\":\"shadowsocks\",\"server\":";
    write_string(json, profile.server);
    json << ",\"server_port\":" << profile.port << ",\"method\":";
    write_string(json, require_value(profile.method, "Shadowsocks method"));
    json << ",\"password\":";
    write_string(json, require_value(profile.password, "Shadowsocks password"));
    if (!profile.plugin.empty()) {
      json << ",\"plugin\":";
      write_string(json, profile.plugin);
      json << ",\"plugin_opts\":";
      write_string(json, profile.plugin_opts);
    }
  } else if (profile.protocol == "hysteria") {
    json << ",\"type\":\"hysteria\",\"server\":";
    write_string(json, profile.server);
    json << ",\"server_port\":" << profile.port;
    json << ",\"up_mbps\":" << require_positive_int(profile.upload_mbps, "Hysteria upload bandwidth");
    json << ",\"down_mbps\":" << require_positive_int(profile.download_mbps, "Hysteria download bandwidth");
    if (!profile.password.empty()) { json << ",\"auth_str\":"; write_string(json, profile.password); }
    if (!profile.hysteria_network.empty()) { json << ",\"network\":"; write_string(json, profile.hysteria_network); }
    if (!profile.obfs_password.empty()) { json << ",\"obfs\":"; write_string(json, profile.obfs_password); }
  } else if (profile.protocol == "hysteria2") {
    json << ",\"type\":\"hysteria2\",\"server\":";
    write_string(json, profile.server);
    if (profile.server_ports.empty()) {
      json << ",\"server_port\":" << profile.port;
    } else {
      json << ",\"server_ports\":";
      write_string_array(json, profile.server_ports);
    }
    if (!profile.password.empty()) { json << ",\"password\":"; write_string(json, profile.password); }
    if (profile.upload_mbps > 0) json << ",\"up_mbps\":" << profile.upload_mbps;
    if (profile.download_mbps > 0) json << ",\"down_mbps\":" << profile.download_mbps;
    if (!profile.hysteria_network.empty()) { json << ",\"network\":"; write_string(json, profile.hysteria_network); }
    if (!profile.obfs.empty() || !profile.obfs_password.empty()) {
      json << ",\"obfs\":{\"type\":";
      write_string(json, profile.obfs.empty() ? "salamander" : profile.obfs);
      json << ",\"password\":";
      write_string(json, require_value(profile.obfs_password, "Hysteria2 obfs password"));
      json << '}';
    }
  } else {
    throw std::runtime_error("Unsupported protocol: " + profile.protocol);
  }
  if (profile.protocol == "vless" || profile.protocol == "vmess" || profile.protocol == "trojan") {
    const auto transport = sing_box_transport_json(profile);
    if (!transport.empty()) json << ",\"transport\":" << transport;
  }
  const auto tls = sing_box_tls_json(profile);
  if (!tls.empty()) json << ",\"tls\":" << tls;
  json << '}';
  return json.str();
}

void serialize_json(std::ostringstream& out, const Json& json) {
  if (json.is_object()) {
    out << '{';
    bool first = true;
    for (const auto& entry : json.object()) {
      if (!first) out << ',';
      first = false;
      out << '"' << json_escape(entry.first) << "\":";
      serialize_json(out, entry.second);
    }
    out << '}';
  } else if (json.is_array()) {
    out << '[';
    const auto& items = json.array();
    for (size_t i = 0; i < items.size(); ++i) {
      if (i > 0) out << ',';
      serialize_json(out, items[i]);
    }
    out << ']';
  } else if (json.is_string()) {
    out << '"' << json_escape(json.string_value()) << '"';
  } else if (json.is_bool()) {
    out << (json.bool_value() ? "true" : "false");
  } else if (json.is_number()) {
    const double number = std::get<double>(json.value);
    if (number == static_cast<long long>(number)) {
      out << static_cast<long long>(number);
    } else {
      out << number;
    }
  } else {
    out << "null";
  }
}

std::string serialize_json(const Json& json) {
  std::ostringstream out;
  serialize_json(out, json);
  return out.str();
}

// --- Native sing-box TUN settings transform.
// Ported from lib/services/core_config_native_tun.dart so the native builder
// returns a final config instead of relying on Dart post-processing.

Json make_string_array(const std::vector<std::string>& values) {
  Json::Array array;
  for (const auto& value : values) array.push_back(Json(value));
  return Json(std::move(array));
}

std::vector<std::string> tun_string_field_values(const Json& value) {
  std::vector<std::string> values;
  if (value.is_string()) {
    const auto trimmed = trim(std::get<std::string>(value.value));
    if (!trimmed.empty()) values.push_back(trimmed);
    return values;
  }
  if (value.is_array()) {
    for (const auto& item : value.array()) {
      const auto trimmed = trim(item.string_value());
      if (!trimmed.empty()) values.push_back(trimmed);
    }
  }
  return values;
}

std::string tun_address_host(const std::string& value) {
  const auto trimmed = trim(value);
  if (!trimmed.empty() && trimmed.front() == '[') {
    const auto end = trimmed.find(']');
    if (end != std::string::npos && end > 1) {
      return trimmed.substr(1, end - 1);
    }
  }
  const auto slash = trimmed.find('/');
  return trim(slash == std::string::npos ? trimmed : trimmed.substr(0, slash));
}

bool is_ipv6_address_like(const std::string& value) {
  return tun_address_host(value).find(':') != std::string::npos;
}

bool matches_tun_ip_mode(const std::string& value, const std::string& mode) {
  if (mode == "ipv6") return is_ipv6_address_like(value);
  if (mode == "dualStack") return true;
  return !is_ipv6_address_like(value);
}

bool field_has_selected_ip_family(const Json& value, const std::string& mode) {
  for (const auto& item : tun_string_field_values(value)) {
    if (matches_tun_ip_mode(item, mode)) return true;
  }
  return false;
}

Json& ensure_map_field(Json& target, const std::string& field) {
  Json& value = target.member(field);
  if (!value.is_object()) value = Json(Json::Object{});
  return value;
}

Json& ensure_rules_list(Json& route) {
  Json& rules = route.member("rules");
  if (rules.is_array()) return rules;
  if (rules.is_object()) {
    Json::Array wrapped;
    wrapped.push_back(rules);
    rules = Json(std::move(wrapped));
    return rules;
  }
  rules = Json(Json::Array{});
  return rules;
}

void filter_ip_family_field(Json& target, const std::string& field, const std::string& mode,
                            const std::vector<std::string>* fallback) {
  const Json raw = target.at(field);
  const auto values = tun_string_field_values(raw);
  if (values.empty()) return;

  std::vector<std::string> filtered;
  for (const auto& value : values) {
    if (matches_tun_ip_mode(value, mode)) filtered.push_back(value);
  }
  if (filtered.empty()) {
    if (fallback == nullptr || fallback->empty()) {
      target.erase(field);
    } else {
      target.member(field) = make_string_array(*fallback);
    }
    return;
  }
  if (raw.is_string() && filtered.size() == 1) {
    target.member(field) = Json(filtered.front());
  } else {
    target.member(field) = make_string_array(filtered);
  }
}

void ensure_tun_address_field(Json& inbound, const std::string& mode) {
  if (mode == "dualStack") return;
  if (field_has_selected_ip_family(inbound.at("address"), mode)) return;
  const std::string legacy = mode == "ipv4" ? "inet4_address" : "inet6_address";
  if (field_has_selected_ip_family(inbound.at(legacy), mode)) return;
  inbound.member("address") = make_string_array(tun_addresses(mode));
}

void apply_tun_ip_mode_to_inbound(Json& inbound, const std::string& mode) {
  if (mode == "dualStack") {
    ensure_tun_address_field(inbound, mode);
    return;
  }
  const auto fallback = tun_addresses(mode);
  filter_ip_family_field(inbound, "address", mode, &fallback);
  filter_ip_family_field(inbound, "route_address", mode, nullptr);
  filter_ip_family_field(inbound, "route_exclude_address", mode, nullptr);
  if (mode == "ipv4") {
    inbound.erase("inet6_address");
    inbound.erase("inet6_route_address");
    inbound.erase("inet6_route_exclude_address");
  } else {
    inbound.erase("inet4_address");
    inbound.erase("inet4_route_address");
    inbound.erase("inet4_route_exclude_address");
  }
  ensure_tun_address_field(inbound, mode);
}

void apply_android_tun_compatibility(Json& inbound, const std::string& android_tun_stack) {
  inbound.erase("interface_name");
  inbound.erase("strict_route");
  inbound.erase("gso");
  inbound.member("stack") = Json(android_tun_stack);
}

void apply_android_route_compatibility(Json& config) {
  Json& route = ensure_map_field(config, "route");
  route.member("auto_detect_interface") = Json(true);
}

std::vector<Json*> sing_box_tun_inbounds(Json& config) {
  std::vector<Json*> result;
  if (!config.is_object()) return result;
  auto& obj = config.object_mut();
  const auto it = obj.find("inbounds");
  if (it == obj.end() || !it->second.is_array()) return result;
  for (Json& inbound : it->second.array_mut()) {
    if (!inbound.is_object()) continue;
    if (lower(trim(inbound.at("type").string_value())) == "tun") {
      result.push_back(&inbound);
    }
  }
  return result;
}

Json build_tun_inbound_matcher(const std::vector<Json*>& tun_inbounds) {
  std::vector<std::string> tags;
  for (const Json* inbound : tun_inbounds) {
    const auto tag = trim(inbound->at("tag").string_value());
    if (!tag.empty()) tags.push_back(tag);
  }
  if (tags.size() != tun_inbounds.size() || tags.empty()) return Json();
  if (tags.size() == 1) return Json(tags.front());
  return make_string_array(tags);
}

std::set<std::string> inbound_matcher_tags(const Json& value) {
  std::set<std::string> tags;
  if (value.is_string()) {
    const auto tag = trim(std::get<std::string>(value.value));
    if (!tag.empty()) tags.insert(tag);
  } else if (value.is_array()) {
    for (const auto& item : value.array()) {
      const auto tag = trim(item.string_value());
      if (!tag.empty()) tags.insert(tag);
    }
  }
  return tags;
}

bool rule_inbound_matches(const Json& rule_inbound, const Json& inbound_matcher) {
  if (inbound_matcher.is_null()) return rule_inbound.is_null();
  if (rule_inbound.is_null()) return true;
  const auto rule_tags = inbound_matcher_tags(rule_inbound);
  const auto target_tags = inbound_matcher_tags(inbound_matcher);
  return !rule_tags.empty() && !target_tags.empty() && rule_tags == target_tags;
}

bool field_contains_port(const Json& value, int port) {
  if (value.is_number()) {
    return static_cast<long long>(std::get<double>(value.value)) == port;
  }
  if (value.is_string()) {
    const auto& text = std::get<std::string>(value.value);
    const auto wanted = std::to_string(port);
    size_t start = 0;
    while (start <= text.size()) {
      const auto next = text.find(',', start);
      const auto item = trim(text.substr(start, next == std::string::npos ? std::string::npos : next - start));
      if (item == wanted) return true;
      if (next == std::string::npos) break;
      start = next + 1;
    }
    return false;
  }
  if (value.is_array()) {
    for (const auto& item : value.array()) {
      if (field_contains_port(item, port)) return true;
    }
  }
  return false;
}

bool rule_matches_dns(const Json& rule) {
  const Json& protocol = rule.at("protocol");
  if (protocol.is_string() && lower(trim(std::get<std::string>(protocol.value))) == "dns") {
    return true;
  }
  if (protocol.is_array()) {
    for (const auto& item : protocol.array()) {
      if (lower(trim(item.string_value())) == "dns") return true;
    }
  }
  if (field_contains_port(rule.at("port"), 53)) return true;
  const Json& children = rule.at("rules");
  if (children.is_array()) {
    for (const auto& child : children.array()) {
      if (child.is_object() && rule_matches_dns(child)) return true;
    }
  }
  return false;
}

bool is_dns_hijack_rule(const Json& rule, const Json& inbound_matcher) {
  if (lower(trim(rule.at("action").string_value())) != "hijack-dns") return false;
  return rule_inbound_matches(rule.at("inbound"), inbound_matcher) && rule_matches_dns(rule);
}

bool is_generic_resolve_rule(const Json& rule, const Json& inbound_matcher) {
  if (lower(trim(rule.at("action").string_value())) != "resolve") return false;
  if (!rule_inbound_matches(rule.at("inbound"), inbound_matcher)) return false;
  static const std::set<std::string> generic_resolve_keys = {
      "action", "inbound", "server", "strategy", "disable_cache",
      "disable_optimistic_cache", "rewrite_ttl", "timeout", "client_subnet"};
  for (const auto& entry : rule.object()) {
    if (generic_resolve_keys.find(entry.first) == generic_resolve_keys.end()) return false;
  }
  return true;
}

Json build_sing_box_dns_matcher_rule() {
  Json::Array rules;
  Json protocol_rule(Json::Object{});
  protocol_rule.member("protocol") = Json(std::string("dns"));
  Json port_rule(Json::Object{});
  port_rule.member("port") = Json(53.0);
  rules.push_back(std::move(protocol_rule));
  rules.push_back(std::move(port_rule));

  Json rule(Json::Object{});
  rule.member("type") = Json(std::string("logical"));
  rule.member("mode") = Json(std::string("or"));
  rule.member("rules") = Json(std::move(rules));
  return rule;
}

Json build_sing_box_dns_hijack_rule() {
  Json rule = build_sing_box_dns_matcher_rule();
  rule.member("action") = Json(std::string("hijack-dns"));
  return rule;
}

void apply_dns_strategy(Json& config, const std::string& mode) {
  if (!config.is_object()) return;
  auto& obj = config.object_mut();
  const auto it = obj.find("dns");
  if (it == obj.end() || !it->second.is_object()) return;
  it->second.member("strategy") = Json(dns_strategy(mode));
}

void ensure_resolve_rule_after_sniff(Json& config, const std::string& mode,
                                     const std::vector<Json*>& tun_inbounds) {
  Json& route = ensure_map_field(config, "route");
  Json& rules = ensure_rules_list(route);
  const auto strategy = dns_strategy(mode);
  const Json inbound_matcher = build_tun_inbound_matcher(tun_inbounds);

  for (Json& rule : rules.array_mut()) {
    if (!rule.is_object()) continue;
    if (is_generic_resolve_rule(rule, inbound_matcher)) {
      rule.member("strategy") = Json(strategy);
      return;
    }
  }

  Json resolve_rule(Json::Object{});
  resolve_rule.member("action") = Json(std::string("resolve"));
  resolve_rule.member("strategy") = Json(strategy);
  if (!inbound_matcher.is_null()) resolve_rule.member("inbound") = inbound_matcher;

  auto& items = rules.array_mut();
  for (size_t i = 0; i < items.size(); ++i) {
    const Json& rule = items[i];
    if (!rule.is_object()) continue;
    if (lower(trim(rule.at("action").string_value())) == "sniff" &&
        rule_inbound_matches(rule.at("inbound"), inbound_matcher)) {
      items.insert(items.begin() + static_cast<std::ptrdiff_t>(i) + 1, std::move(resolve_rule));
      return;
    }
  }

  Json sniff_rule(Json::Object{});
  sniff_rule.member("action") = Json(std::string("sniff"));
  if (!inbound_matcher.is_null()) sniff_rule.member("inbound") = inbound_matcher;
  items.insert(items.begin(), std::move(resolve_rule));
  items.insert(items.begin(), std::move(sniff_rule));
}

void ensure_dns_hijack_rule_after_resolve(Json& config, const std::vector<Json*>& tun_inbounds) {
  Json& route = ensure_map_field(config, "route");
  Json& rules = ensure_rules_list(route);
  const Json inbound_matcher = build_tun_inbound_matcher(tun_inbounds);

  for (const Json& rule : rules.array()) {
    if (!rule.is_object()) continue;
    if (is_dns_hijack_rule(rule, inbound_matcher)) return;
  }

  Json hijack_rule = build_sing_box_dns_hijack_rule();
  if (!inbound_matcher.is_null()) hijack_rule.member("inbound") = inbound_matcher;

  auto& items = rules.array_mut();
  for (size_t i = 0; i < items.size(); ++i) {
    const Json& rule = items[i];
    if (!rule.is_object()) continue;
    if (lower(trim(rule.at("action").string_value())) == "resolve" &&
        rule_inbound_matches(rule.at("inbound"), inbound_matcher)) {
      items.insert(items.begin() + static_cast<std::ptrdiff_t>(i) + 1, std::move(hijack_rule));
      return;
    }
  }
  for (size_t i = 0; i < items.size(); ++i) {
    const Json& rule = items[i];
    if (!rule.is_object()) continue;
    if (lower(trim(rule.at("action").string_value())) == "sniff" &&
        rule_inbound_matches(rule.at("inbound"), inbound_matcher)) {
      items.insert(items.begin() + static_cast<std::ptrdiff_t>(i) + 1, std::move(hijack_rule));
      return;
    }
  }
  items.insert(items.begin(), std::move(hijack_rule));
}

bool apply_native_sing_box_tun_settings(Json& config, const std::string& tun_ip_mode,
                                        const std::string& android_tun_stack,
                                        const std::string& tun_interface_name, int mtu,
                                        bool android_compatibility) {
  const auto tun_inbounds = sing_box_tun_inbounds(config);
  if (tun_inbounds.empty()) return false;

  const auto normalized_interface = trim(tun_interface_name);
  for (Json* inbound : tun_inbounds) {
    if (!normalized_interface.empty()) {
      inbound->member("interface_name") = Json(normalized_interface);
    }
    if (mtu > 0) inbound->member("mtu") = Json(static_cast<double>(mtu));
    if (android_compatibility) apply_android_tun_compatibility(*inbound, android_tun_stack);
    apply_tun_ip_mode_to_inbound(*inbound, tun_ip_mode);
  }
  if (android_compatibility) apply_android_route_compatibility(config);
  apply_dns_strategy(config, tun_ip_mode);
  ensure_resolve_rule_after_sniff(config, tun_ip_mode, tun_inbounds);
  ensure_dns_hijack_rule_after_resolve(config, tun_inbounds);
  return true;
}

std::string build_sing_box_config(const Profile& profile, const ConfigOptions& options) {
  if (!profile.sing_box_config_json.empty()) {
    Json config = JsonParser(profile.sing_box_config_json).parse();
    if (!config.is_object()) return profile.sing_box_config_json;
    const std::string tun_interface =
        options.is_windows ? trim(options.tun_interface_name) : std::string();
    const int tun_mtu = options.is_android ? 1400 : 0;
    const bool applied = apply_native_sing_box_tun_settings(
        config, options.tun_ip_mode, "gvisor", tun_interface, tun_mtu, options.is_android);
    return applied ? serialize_json(config) : profile.sing_box_config_json;
  }
  const bool tun = is_tun(options);
  const bool android_tun = tun && options.is_android;
  const auto dns_servers = options.dns_servers.empty() ? std::vector<std::string>{"1.1.1.1"} : options.dns_servers;
  const auto excludes = tun ? tun_route_excludes(profile) : std::vector<std::string>{};
  const bool has_route_default_interface = !trim(options.route_default_interface).empty();
  const bool strict_route = options.split_tunnel_mode != "whitelist" && options.domain_split_tunnel_mode != "whitelist";
  const auto interface_name = trim(options.tun_interface_name).empty() ? "EntropyVPN TUN" : trim(options.tun_interface_name);

  std::ostringstream json;
  json << "{\"log\":{\"level\":\"" << (tun ? "debug" : "info") << "\",\"timestamp\":true}";
  if (tun) {
    json << ",\"dns\":{\"servers\":[";
    if (!android_tun) json << "{\"type\":\"local\",\"tag\":\"dns-local\"},";
    write_sing_box_dns_server(json, options.dns_mode, "dns-remote", dns_servers.front(), "proxy");
    json << "],\"final\":\"dns-remote\",\"strategy\":\"" << dns_strategy(options.tun_ip_mode) << "\",\"independent_cache\":true}";
  }
  json << ",\"inbounds\":[";
  if (!tun) {
    json << "{\"type\":\"mixed\",\"tag\":\"mixed-in\",\"listen\":\"127.0.0.1\",\"listen_port\":2080,\"set_system_proxy\":true}";
  } else {
    json << "{\"type\":\"tun\",\"tag\":\"tun-in\"";
    if (!options.is_android) { json << ",\"interface_name\":"; write_string(json, interface_name); }
    json << ",\"mtu\":1400,\"stack\":\"" << (android_tun ? "gvisor" : "mixed") << "\",\"address\":";
    write_string_array(json, tun_addresses(options.tun_ip_mode));
    json << ",\"auto_route\":true";
    if (!options.is_android) json << ",\"strict_route\":" << (strict_route ? "true" : "false");
    const auto routes = tun_route_addresses(options.tun_ip_mode);
    if (!routes.empty()) { json << ",\"route_address\":"; write_string_array(json, routes); }
    if (!excludes.empty()) { json << ",\"route_exclude_address\":"; write_string_array(json, excludes); }
    json << '}';
  }
  json << "],\"outbounds\":[" << sing_box_outbound_json(profile, options.outbound_bind_interface) << ",{\"type\":\"direct\",\"tag\":\"direct\"}]";
  json << ",\"route\":{";
  bool first = true;
  if (tun) {
    json << "\"rules\":[";
    append_sing_box_route_rules(json, options);
    json << ']';
    first = false;
  }
  if (!first) json << ',';
  json << "\"final\":\"" << route_final(options) << "\"";
  if (tun && !android_tun) json << ",\"default_domain_resolver\":\"dns-local\"";
  json << ",\"auto_detect_interface\":" << (tun ? (android_tun || !has_route_default_interface ? "true" : "false") : "true");
  if (tun && has_route_default_interface && !android_tun) {
    json << ",\"default_interface\":";
    write_string(json, trim(options.route_default_interface));
  }
  json << "}}";
  return json.str();
}

std::string xray_stream_json(const Profile& profile, const std::string& bind_interface) {
  if (profile.transport == "quic") {
    throw std::runtime_error("QUIC transport is not supported for Xray in this desktop wrapper yet.");
  }
  std::ostringstream json;
  const std::string network = profile.transport == "raw" ? "raw" :
      profile.transport == "http" ? "xhttp" :
      profile.transport == "httpUpgrade" ? "httpupgrade" :
      profile.transport;
  const std::string security = profile.tls_mode == "reality" ? "reality" : (profile.tls_mode == "tls" ? "tls" : "none");
  json << "{\"network\":";
  write_string(json, network);
  json << ",\"security\":";
  write_string(json, security);
  if (profile.tls_mode == "tls") {
    json << ",\"tlsSettings\":{";
    bool first = true;
    if (!profile.sni.empty()) { json << "\"serverName\":"; write_string(json, profile.sni); first = false; }
    if (profile.allow_insecure) { if (!first) json << ','; json << "\"allowInsecure\":true"; first = false; }
    if (!profile.alpn.empty()) { if (!first) json << ','; json << "\"alpn\":"; write_string_array(json, profile.alpn); first = false; }
    if (!profile.fingerprint.empty()) { if (!first) json << ','; json << "\"fingerprint\":"; write_string(json, profile.fingerprint); }
    json << '}';
  }
  if (profile.tls_mode == "reality") {
    json << ",\"realitySettings\":{\"serverName\":";
    write_string(json, profile.sni.empty() ? profile.server : profile.sni);
    json << ",\"fingerprint\":";
    write_string(json, profile.fingerprint.empty() ? "chrome" : profile.fingerprint);
    json << ",\"password\":";
    write_string(json, require_value(profile.public_key, "REALITY public key"));
    json << ",\"shortId\":";
    write_string(json, profile.short_id);
    json << ",\"spiderX\":";
    write_string(json, profile.spider_x);
    json << '}';
  }
  if (!trim(bind_interface).empty()) {
    json << ",\"sockopt\":{\"interface\":";
    write_string(json, trim(bind_interface));
    json << '}';
  }
  if (profile.transport == "ws") {
    json << ",\"wsSettings\":{\"path\":";
    write_string(json, profile.path.empty() ? "/" : profile.path);
    if (!profile.host.empty()) { json << ",\"headers\":{\"Host\":"; write_string(json, profile.host); json << '}'; }
    json << '}';
  } else if (profile.transport == "grpc") {
    json << ",\"grpcSettings\":{\"serviceName\":";
    write_string(json, profile.service_name.empty() ? "grpc" : profile.service_name);
    if (!profile.authority.empty()) { json << ",\"authority\":"; write_string(json, profile.authority); }
    json << '}';
  } else if (profile.transport == "httpUpgrade") {
    json << ",\"httpupgradeSettings\":{\"path\":";
    write_string(json, profile.path.empty() ? "/" : profile.path);
    if (!profile.host.empty()) { json << ",\"host\":"; write_string(json, profile.host); }
    json << '}';
  } else if (profile.transport == "http" || profile.transport == "xhttp") {
    json << ",\"xhttpSettings\":{\"path\":";
    write_string(json, profile.path.empty() ? "/" : profile.path);
    if (!profile.host.empty()) { json << ",\"host\":"; write_string(json, profile.host); }
    json << '}';
  }
  json << '}';
  return json.str();
}

std::string xray_outbound_json(const Profile& profile, const ConfigOptions& options) {
  const auto server = trim(options.xray_server_address_override).empty() ? profile.server : trim(options.xray_server_address_override);
  std::ostringstream json;
  json << "{\"tag\":\"proxy\"";
  if (profile.protocol == "vless") {
    json << ",\"protocol\":\"vless\",\"settings\":{\"address\":";
    write_string(json, server);
    json << ",\"port\":" << profile.port << ",\"id\":";
    write_string(json, require_value(profile.user_id, "VLESS user ID"));
    json << ",\"encryption\":";
    write_string(json, profile.security.empty() ? "none" : profile.security);
    json << ",\"flow\":";
    write_string(json, profile.flow);
    json << ",\"level\":0}";
  } else if (profile.protocol == "vmess") {
    json << ",\"protocol\":\"vmess\",\"settings\":{\"address\":";
    write_string(json, server);
    json << ",\"port\":" << profile.port << ",\"id\":";
    write_string(json, require_value(profile.user_id, "VMess user ID"));
    json << ",\"security\":";
    write_string(json, profile.security.empty() ? "auto" : profile.security);
    json << ",\"alterId\":" << profile.alter_id << ",\"level\":0,\"experiments\":\"\"}";
  } else if (profile.protocol == "trojan") {
    json << ",\"protocol\":\"trojan\",\"settings\":{\"address\":";
    write_string(json, server);
    json << ",\"port\":" << profile.port << ",\"password\":";
    write_string(json, require_value(profile.password, "Trojan password"));
    json << ",\"level\":0}";
  } else if (profile.protocol == "shadowsocks") {
    if (!profile.plugin.empty()) throw std::runtime_error("Xray desktop wrapper does not support Shadowsocks plugins yet.");
    json << ",\"protocol\":\"shadowsocks\",\"settings\":{\"servers\":[{\"address\":";
    write_string(json, server);
    json << ",\"port\":" << profile.port << ",\"method\":";
    write_string(json, require_value(profile.method, "Shadowsocks method"));
    json << ",\"password\":";
    write_string(json, require_value(profile.password, "Shadowsocks password"));
    json << "}]}";
  } else {
    throw std::runtime_error(profile.protocol + " links must be run with sing-box.");
  }
  json << ",\"streamSettings\":" << xray_stream_json(profile, options.outbound_bind_interface) << '}';
  return json.str();
}

void append_xray_domain_rule(std::ostringstream& json, const ConfigOptions& options, const std::string& outbound) {
  auto domains = sorted_unique(options.domain_split_tunnel_domains);
  std::vector<std::string> matchers;
  for (const auto& domain : domains) matchers.push_back("domain:" + domain);
  json << "{\"type\":\"field\",\"domain\":";
  write_string_array(json, matchers);
  json << ",\"outboundTag\":";
  write_string(json, outbound);
  json << '}';
}

std::string build_xray_config(const Profile& profile, const ConfigOptions& options) {
  if (!profile.xray_config_json.empty()) return profile.xray_config_json;
  const bool tun = is_tun(options);
  const bool use_android_hev_dns_routing = options.is_android && !tun;
  const bool use_dns_routing = use_android_hev_dns_routing || tun;
  const bool domain_whitelist = options.domain_split_tunnel_mode == "whitelist" && !options.domain_split_tunnel_domains.empty();
  const bool domain_blacklist = options.domain_split_tunnel_mode == "blacklist" && !options.domain_split_tunnel_domains.empty();
  const auto interface_name = trim(options.tun_interface_name).empty() ? "xray0" : trim(options.tun_interface_name);
  const auto raw_dns_servers = options.dns_servers.empty() ? std::vector<std::string>{"1.1.1.1"} : options.dns_servers;
  std::vector<std::string> dns_servers;
  dns_servers.reserve(raw_dns_servers.size());
  for (const auto& server : raw_dns_servers) {
    dns_servers.push_back(xray_dns_entry(options.dns_mode, server));
  }

  std::ostringstream json;
  json << "{\"log\":{\"loglevel\":\"warning\"}";
  if (use_dns_routing) {
    json << ",\"dns\":{\"servers\":";
    write_string_array(json, dns_servers);
    json << ",\"queryStrategy\":\"" << xray_dns_strategy(options.tun_ip_mode) << "\"";
    if (tun) json << ",\"tag\":\"dns-query\"";
    json << '}';
  }
  json << ",\"inbounds\":[";
  if (!tun) {
    json << "{\"tag\":\"socks-in\",\"protocol\":\"socks\",\"listen\":\"127.0.0.1\",\"port\":2080,\"settings\":{\"udp\":true},\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}},";
    json << "{\"tag\":\"http-in\",\"protocol\":\"http\",\"listen\":\"127.0.0.1\",\"port\":2081,\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}}";
  } else {
    json << "{\"tag\":\"tun-in\",\"protocol\":\"tun\",\"settings\":{\"name\":";
    write_string(json, interface_name);
    json << ",\"MTU\":1400,\"userLevel\":0}";
    if (options.domain_split_tunnel_mode != "off") {
      json << ",\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}";
    }
    json << '}';
  }
  json << "],\"outbounds\":[" << xray_outbound_json(profile, options);
  if (use_dns_routing) {
    json << ",{\"tag\":\"dns-out\",\"protocol\":\"dns\"";
    if (options.tun_ip_mode == "ipv4") json << ",\"settings\":{\"rules\":[{\"action\":\"reject\",\"qtype\":28}]}";
    if (options.tun_ip_mode == "ipv6") json << ",\"settings\":{\"rules\":[{\"action\":\"reject\",\"qtype\":1}]}";
    json << '}';
  }
  json << ",{\"tag\":\"direct\",\"protocol\":\"freedom\"";
  if (tun && !trim(options.outbound_bind_interface).empty()) {
    json << ",\"streamSettings\":{\"sockopt\":{\"interface\":";
    write_string(json, trim(options.outbound_bind_interface));
    json << "}}";
  }
  json << "},{\"tag\":\"block\",\"protocol\":\"blackhole\"}]";

  const bool has_rules = use_dns_routing || tun || domain_whitelist || domain_blacklist;
  if (has_rules) {
    json << ",\"routing\":{\"domainStrategy\":\"AsIs\",\"rules\":[";
    bool first = true;
    if (use_dns_routing) {
      json << "{\"type\":\"field\",\"inboundTag\":[\"" << (tun ? "tun-in" : "socks-in") << "\"],\"port\":\"53\",\"outboundTag\":\"dns-out\"}";
      first = false;
    }
    if (tun) {
      if (!first) json << ',';
      json << "{\"type\":\"field\",\"network\":\"udp\",\"port\":\"443\",\"outboundTag\":\"block\"}";
      first = false;
    }
    if (domain_whitelist || domain_blacklist) {
      if (!first) json << ',';
      append_xray_domain_rule(json, options, domain_whitelist ? "proxy" : "direct");
      first = false;
    }
    if (options.domain_split_tunnel_mode == "whitelist") {
      if (!first) json << ',';
      json << "{\"type\":\"field\",\"network\":\"tcp,udp\",\"outboundTag\":\"direct\"}";
    }
    json << "]}";
  }
  json << '}';
  return json.str();
}

std::string build_core_config(const char* profile_json, const char* options_json) {
  const auto profile = profile_from_json(profile_json == nullptr ? "{}" : profile_json);
  const auto options = options_from_json(options_json == nullptr ? "{}" : options_json);
  if (options.core == "singBox") return build_sing_box_config(profile, options);
  if (options.core == "xray") return build_xray_config(profile, options);
  throw std::runtime_error("Unsupported core: " + options.core);
}

std::string json_non_empty(const Json& value) {
  return trim(value.string_value());
}

std::vector<std::string> json_string_list(const Json& value) {
  std::vector<std::string> values;
  if (value.is_array()) {
    for (const auto& item : value.array()) {
      const auto text = json_non_empty(item);
      if (!text.empty()) values.push_back(text);
    }
    return values;
  }
  const auto single = json_non_empty(value);
  if (!single.empty()) values.push_back(single);
  return values;
}

const Json* first_json_object(const Json& value) {
  if (!value.is_array()) return nullptr;
  for (const auto& item : value.array()) {
    if (item.is_object()) return &item;
  }
  return nullptr;
}

std::string json_first_string(const Json& object, std::initializer_list<const char*> keys) {
  for (const auto* key : keys) {
    const auto value = json_non_empty(object.at(key));
    if (!value.empty()) return value;
  }
  return "";
}

int config_score_xray(const Json& root) {
  int score = 0;
  for (const auto* field : {"routing", "api", "policy", "transport", "stats", "reverse", "fakedns", "metrics", "observatory", "burstObservatory", "geodata"}) {
    if (root.contains(field)) score += 3;
  }
  const auto& routing = root.at("routing");
  for (const auto* field : {"rules", "balancers", "domainStrategy", "domainMatcher"}) {
    if (routing.contains(field)) score += 2;
  }
  for (const auto* key : {"inbounds", "outbounds"}) {
    for (const auto& item : root.at(key).array()) {
      if (!item.is_object()) continue;
      if (item.contains("protocol")) score += 6;
      for (const auto* field : {"streamSettings", "sendThrough", "proxySettings", "mux", "targetStrategy"}) {
        if (item.contains(field)) score += 2;
      }
    }
  }
  return score;
}

int config_score_sing_box(const Json& root) {
  int score = 0;
  for (const auto* field : {"route", "ntp", "certificate", "certificate_providers", "http_clients", "endpoints", "services", "experimental"}) {
    if (root.contains(field)) score += 3;
  }
  const auto& route = root.at("route");
  for (const auto* field : {"rules", "rule_set", "final", "auto_detect_interface", "default_interface", "default_domain_resolver"}) {
    if (route.contains(field)) score += 2;
  }
  for (const auto* key : {"inbounds", "outbounds"}) {
    for (const auto& item : root.at(key).array()) {
      if (!item.is_object()) continue;
      if (item.contains("type")) score += 6;
      for (const auto* field : {"listen_port", "server_port", "tls", "transport", "dialer"}) {
        if (item.contains(field)) score += 2;
      }
    }
  }
  return score;
}

std::string protocol_for_core_protocol(const std::string& protocol) {
  if (protocol == "vmess" || protocol == "trojan" || protocol == "shadowsocks" || protocol == "hysteria" || protocol == "hysteria2") return protocol;
  return "vless";
}

std::string xray_transport(const Json& stream) {
  const auto network = lower(json_non_empty(stream.at("network")));
  if (network == "ws" || network == "websocket") return "ws";
  if (network == "grpc") return "grpc";
  if (network == "http") return "http";
  if (network == "httpupgrade" || network == "http-upgrade") return "httpUpgrade";
  if (network == "quic") return "quic";
  if (network == "xhttp" || network == "splithttp" || network == "split-http") return "xhttp";
  return "raw";
}

std::string xray_tls_mode(const Json& stream) {
  const auto security = lower(json_non_empty(stream.at("security")));
  if (security == "reality") return "reality";
  if (security == "tls") return "tls";
  return "none";
}

const Json& xray_transport_settings(const Json& stream) {
  const auto network = lower(json_non_empty(stream.at("network")));
  if (network == "ws" || network == "websocket") return stream.at("wsSettings");
  if (network == "grpc") return stream.at("grpcSettings");
  if (network == "http") return stream.at("httpSettings");
  if (network == "xhttp" || network == "splithttp" || network == "split-http") return stream.at("xhttpSettings");
  if (network == "httpupgrade" || network == "http-upgrade") return stream.at("httpupgradeSettings");
  if (network == "quic") return stream.at("quicSettings");
  return stream.at("tcpSettings");
}

std::string transport_host(const Json& transport) {
  auto host = json_non_empty(transport.at("host"));
  if (!host.empty()) return host;
  host = json_non_empty(transport.at("Host"));
  if (!host.empty()) return host;
  const auto& headers = transport.at("headers");
  const auto values = json_string_list(headers.at("Host"));
  if (!values.empty()) return values.front();
  host = json_non_empty(headers.at("host"));
  return host;
}

std::string transport_authority(const Json& transport) {
  auto authority = json_non_empty(transport.at("authority"));
  if (!authority.empty()) return authority;
  const auto& headers = transport.at("headers");
  authority = json_non_empty(headers.at(":authority"));
  if (!authority.empty()) return authority;
  return json_non_empty(headers.at("authority"));
}

void fill_xray_stream(Profile& profile, const Json& stream) {
  profile.transport = xray_transport(stream);
  profile.tls_mode = xray_tls_mode(stream);
  const auto& reality = stream.at("realitySettings");
  const auto& tls = stream.at("tlsSettings");
  profile.sni = json_first_string(reality, {"serverName", "server_name"});
  if (profile.sni.empty()) profile.sni = json_first_string(tls, {"serverName", "server_name"});
  auto alpn = json_string_list(reality.at("alpn"));
  if (alpn.empty()) alpn = json_string_list(tls.at("alpn"));
  profile.alpn = alpn;
  profile.fingerprint = json_non_empty(reality.at("fingerprint"));
  if (profile.fingerprint.empty()) profile.fingerprint = json_non_empty(tls.at("fingerprint"));
  profile.public_key = json_non_empty(reality.at("publicKey"));
  profile.short_id = json_non_empty(reality.at("shortId"));
  profile.spider_x = json_non_empty(reality.at("spiderX"));
  profile.allow_insecure = tls.at("allowInsecure").bool_value();
  const auto& transport = xray_transport_settings(stream);
  profile.host = transport_host(transport);
  profile.path = json_non_empty(transport.at("path"));
  const auto& grpc = stream.at("grpcSettings");
  profile.service_name = json_first_string(grpc, {"serviceName", "service_name"});
  profile.authority = json_non_empty(grpc.at("authority"));
  if (profile.authority.empty()) profile.authority = transport_authority(transport);
}

Profile endpoint_from_xray_outbound(const Json& outbound) {
  Profile profile;
  const auto protocol = lower(json_non_empty(outbound.at("protocol")));
  if (!(protocol == "vless" || protocol == "vmess" || protocol == "trojan" || protocol == "shadowsocks")) return profile;
  profile.protocol = protocol_for_core_protocol(protocol);
  const auto& settings = outbound.at("settings");
  const auto& stream = outbound.at("streamSettings");
  if (protocol == "vless" || protocol == "vmess") {
    if (settings.at("vnext").is_array()) {
      for (const auto& item : settings.at("vnext").array()) {
        if (!item.is_object()) continue;
        profile.server = json_first_string(item, {"address", "server"});
        if (profile.server.empty()) continue;
        profile.port = item.at("port").int_value();
        if (const Json* user = first_json_object(item.at("users"))) {
          profile.user_id = json_first_string(*user, {"id", "uuid"});
          profile.security = json_first_string(*user, {"security", "encryption"});
          profile.alter_id = user->at("alterId").int_value();
          profile.flow = json_non_empty(user->at("flow"));
        }
        fill_xray_stream(profile, stream);
        return profile;
      }
    } else {
      profile.server = json_first_string(settings, {"address", "server"});
      if (profile.server.empty()) return Profile();
      profile.port = settings.at("port").int_value();
      profile.user_id = json_first_string(settings, {"id", "uuid"});
      profile.security = json_first_string(settings, {"security", "encryption"});
      profile.alter_id = settings.at("alterId").int_value();
      profile.flow = json_non_empty(settings.at("flow"));
      fill_xray_stream(profile, stream);
      return profile;
    }
  } else {
    if (settings.at("servers").is_array()) {
      for (const auto& item : settings.at("servers").array()) {
        if (!item.is_object()) continue;
        profile.server = json_first_string(item, {"address", "server"});
        if (profile.server.empty()) continue;
        profile.port = item.at("port").int_value();
        profile.password = json_non_empty(item.at("password"));
        profile.method = json_non_empty(item.at("method"));
        profile.security = json_non_empty(item.at("security"));
        fill_xray_stream(profile, stream);
        return profile;
      }
    } else {
      profile.server = json_first_string(settings, {"address", "server"});
      if (profile.server.empty()) return Profile();
      profile.port = settings.at("port").int_value();
      profile.password = json_non_empty(settings.at("password"));
      profile.method = json_non_empty(settings.at("method"));
      profile.security = json_non_empty(settings.at("security"));
      fill_xray_stream(profile, stream);
      return profile;
    }
  }
  return Profile();
}

std::string sing_box_transport(const Json& transport) {
  const auto type = lower(json_non_empty(transport.at("type")));
  if (type == "ws" || type == "websocket") return "ws";
  if (type == "grpc") return "grpc";
  if (type == "http") return "http";
  if (type == "httpupgrade" || type == "http-upgrade") return "httpUpgrade";
  if (type == "quic") return "quic";
  if (type == "xhttp" || type == "splithttp" || type == "split-http") return "xhttp";
  return "raw";
}

std::string sing_box_tls_mode(const Json& tls) {
  if (!tls.at("enabled").bool_value()) return "none";
  if (tls.at("reality").at("enabled").bool_value()) return "reality";
  return "tls";
}

Profile endpoint_from_sing_box_outbound(const Json& outbound) {
  Profile profile;
  const auto type = lower(json_non_empty(outbound.at("type")));
  if (type.empty() || type == "block" || type == "direct" || type == "dns" || type == "selector" || type == "urltest") return profile;
  profile.server = json_non_empty(outbound.at("server"));
  if (profile.server.empty()) return Profile();
  profile.protocol = protocol_for_core_protocol(type);
  profile.port = outbound.at("server_port").int_value();
  profile.server_ports = json_string_list(outbound.at("server_ports"));
  if (profile.port == 0 && !profile.server_ports.empty()) profile.port = first_server_port(profile.server_ports);
  profile.user_id = json_non_empty(outbound.at("uuid"));
  profile.password = json_non_empty(outbound.at("password"));
  profile.method = json_non_empty(outbound.at("method"));
  profile.security = json_non_empty(outbound.at("security"));
  profile.flow = json_non_empty(outbound.at("flow"));
  const auto& tls = outbound.at("tls");
  const auto& reality = tls.at("reality");
  const auto& utls = tls.at("utls");
  const auto& transport = outbound.at("transport");
  profile.transport = sing_box_transport(transport);
  profile.tls_mode = sing_box_tls_mode(tls);
  profile.sni = json_non_empty(tls.at("server_name"));
  profile.alpn = json_string_list(tls.at("alpn"));
  profile.host = transport_host(transport);
  profile.path = json_non_empty(transport.at("path"));
  profile.service_name = json_first_string(transport, {"service_name", "serviceName"});
  profile.authority = transport_authority(transport);
  profile.fingerprint = json_non_empty(utls.at("fingerprint"));
  profile.public_key = json_non_empty(reality.at("public_key"));
  profile.short_id = json_non_empty(reality.at("short_id"));
  profile.allow_insecure = tls.at("insecure").bool_value();
  profile.upload_mbps = outbound.at("up_mbps").int_value();
  profile.download_mbps = outbound.at("down_mbps").int_value();
  profile.hysteria_network = json_non_empty(outbound.at("network"));
  const auto& obfs = outbound.at("obfs");
  if (obfs.is_object()) {
    profile.obfs = json_non_empty(obfs.at("type"));
    profile.obfs_password = json_non_empty(obfs.at("password"));
  } else {
    profile.obfs_password = json_non_empty(obfs);
  }
  return profile;
}

const Json* resolve_sing_box_outbound(const std::string& tag, const std::map<std::string, const Json*>& by_tag, std::set<std::string>& seen) {
  if (!seen.insert(tag).second) return nullptr;
  const auto it = by_tag.find(tag);
  if (it == by_tag.end()) return nullptr;
  const auto* outbound = it->second;
  if (!endpoint_from_sing_box_outbound(*outbound).server.empty()) return outbound;
  for (const auto& child : outbound->at("outbounds").array()) {
    const auto child_tag = json_non_empty(child);
    if (child_tag.empty()) continue;
    if (const auto* resolved = resolve_sing_box_outbound(child_tag, by_tag, seen)) return resolved;
  }
  return nullptr;
}

Profile extract_xray_endpoint(const Json& root) {
  for (const auto& item : root.at("outbounds").array()) {
    if (!item.is_object()) continue;
    auto endpoint = endpoint_from_xray_outbound(item);
    if (!endpoint.server.empty()) return endpoint;
  }
  return Profile();
}

Profile extract_sing_box_endpoint(const Json& root) {
  std::map<std::string, const Json*> by_tag;
  for (const auto& item : root.at("outbounds").array()) {
    if (!item.is_object()) continue;
    const auto tag = json_non_empty(item.at("tag"));
    if (!tag.empty()) by_tag[tag] = &item;
  }
  const auto final_tag = json_non_empty(root.at("route").at("final"));
  if (!final_tag.empty()) {
    std::set<std::string> seen;
    if (const auto* resolved = resolve_sing_box_outbound(final_tag, by_tag, seen)) {
      auto endpoint = endpoint_from_sing_box_outbound(*resolved);
      if (!endpoint.server.empty()) return endpoint;
    }
  }
  for (const auto& item : root.at("outbounds").array()) {
    if (!item.is_object()) continue;
    auto endpoint = endpoint_from_sing_box_outbound(item);
    if (!endpoint.server.empty()) return endpoint;
  }
  return Profile();
}

std::string core_config_profile_json(const char* raw_input, const char* options_json) {
  std::string text = raw_input == nullptr ? "" : raw_input;
  text = trim(text);
  if (!text.empty() && static_cast<unsigned char>(text.front()) == 0xEF) text.erase(0, 3);
  if (text.empty() || text.front() != '{') return "";
  const auto root = JsonParser(text).parse();
  if (!root.is_object()) return "";
  const auto xray_score = config_score_xray(root);
  const auto sing_box_score = config_score_sing_box(root);
  if ((xray_score == 0 && sing_box_score == 0) || xray_score == sing_box_score) return "";
  const auto options = JsonParser(options_json == nullptr ? "{}" : options_json).parse();
  const auto source_label = json_non_empty(options.at("sourceLabel"));
  const auto fallback_label = json_non_empty(options.at("fallbackLabel"));
  const auto config_directory = json_non_empty(options.at("configDirectory"));
  const bool is_sing_box = sing_box_score > xray_score;
  auto profile = is_sing_box ? extract_sing_box_endpoint(root) : extract_xray_endpoint(root);
  profile.protocol = profile.protocol.empty() ? "vless" : profile.protocol;
  profile.transport = profile.transport.empty() ? "raw" : profile.transport;
  profile.tls_mode = profile.tls_mode.empty() ? "none" : profile.tls_mode;
  const auto remark = !source_label.empty() ? source_label :
      !json_non_empty(root.at("remark")).empty() ? json_non_empty(root.at("remark")) :
      !json_non_empty(root.at("name")).empty() ? json_non_empty(root.at("name")) :
      !fallback_label.empty() ? fallback_label :
      (is_sing_box ? "Sing-box config" : "Xray config");

  std::ostringstream json;
  bool first = true;
  json << '{';
  add_string(json, first, "protocol", profile.protocol);
  add_string(json, first, "server", profile.server);
  add_int(json, first, "port", profile.port, false);
  add_string(json, first, "transport", profile.transport);
  add_string(json, first, "tlsMode", profile.tls_mode);
  add_string(json, first, "remark", remark);
  add_string(json, first, "userId", profile.user_id);
  add_string(json, first, "password", profile.password);
  add_string(json, first, "method", profile.method);
  add_string(json, first, "security", profile.security);
  add_int(json, first, "alterId", profile.alter_id);
  add_string(json, first, "flow", profile.flow);
  add_string(json, first, "sni", profile.sni);
  add_string_array(json, first, "alpn", profile.alpn);
  add_string(json, first, "host", profile.host);
  add_string(json, first, "path", profile.path);
  add_string(json, first, "serviceName", profile.service_name);
  add_string(json, first, "authority", profile.authority);
  add_string(json, first, "fingerprint", profile.fingerprint);
  add_string(json, first, "publicKey", profile.public_key);
  add_string(json, first, "shortId", profile.short_id);
  add_string(json, first, "spiderX", profile.spider_x);
  add_bool(json, first, "allowInsecure", profile.allow_insecure);
  add_string_array(json, first, "serverPorts", profile.server_ports);
  add_int(json, first, "uploadMbps", profile.upload_mbps);
  add_int(json, first, "downloadMbps", profile.download_mbps);
  add_string(json, first, "hysteriaNetwork", profile.hysteria_network);
  add_string(json, first, "obfs", profile.obfs);
  add_string(json, first, "obfsPassword", profile.obfs_password);
  if (is_sing_box) {
    add_string(json, first, "singBoxOutboundType", profile.protocol);
    add_string(json, first, "singBoxConfigJson", text);
    add_string(json, first, "singBoxConfigDirectory", config_directory);
  } else {
    add_string(json, first, "xrayOutboundProtocol", profile.protocol);
    add_string(json, first, "xrayConfigJson", text);
    add_string(json, first, "xrayConfigDirectory", config_directory);
  }
  json << '}';
  return json.str();
}

char* copy_string(const std::string& value) {
  auto* buffer = new char[value.size() + 1];
  std::memcpy(buffer, value.c_str(), value.size() + 1);
  return buffer;
}

}  // namespace

extern "C" ENTROPY_EXPORT char* entropy_parse_share_link(const char* raw_input, char** error_message) {
  if (error_message != nullptr) {
    *error_message = nullptr;
  }
  try {
    return copy_string(to_json(parse_profile(raw_input)));
  } catch (const std::exception& error) {
    if (error_message != nullptr) {
      *error_message = copy_string(error.what());
    }
    return nullptr;
  } catch (...) {
    if (error_message != nullptr) {
      *error_message = copy_string("Unsupported link format.");
    }
    return nullptr;
  }
}

extern "C" ENTROPY_EXPORT char* entropy_parse_share_links(const char* raw_input, char** error_message) {
  if (error_message != nullptr) {
    *error_message = nullptr;
  }
  try {
    return copy_string(parse_share_links_json(raw_input));
  } catch (const std::exception& error) {
    if (error_message != nullptr) {
      *error_message = copy_string(error.what());
    }
    return nullptr;
  } catch (...) {
    if (error_message != nullptr) {
      *error_message = copy_string("Failed to parse subscription links.");
    }
    return nullptr;
  }
}

extern "C" ENTROPY_EXPORT char* entropy_try_decode_subscription_base64(const char* raw_input, char** error_message) {
  if (error_message != nullptr) {
    *error_message = nullptr;
  }
  try {
    const auto decoded = try_decode_subscription_base64_text(raw_input);
    return decoded.empty() ? nullptr : copy_string(decoded);
  } catch (...) {
    return nullptr;
  }
}

extern "C" ENTROPY_EXPORT char* entropy_parse_core_config(const char* raw_input, const char* options_json, char** error_message) {
  if (error_message != nullptr) {
    *error_message = nullptr;
  }
  try {
    const auto profile_json = core_config_profile_json(raw_input, options_json);
    return profile_json.empty() ? nullptr : copy_string(profile_json);
  } catch (const std::exception& error) {
    if (error_message != nullptr) {
      *error_message = copy_string(error.what());
    }
    return nullptr;
  } catch (...) {
    if (error_message != nullptr) {
      *error_message = copy_string("Failed to parse native config.");
    }
    return nullptr;
  }
}

extern "C" ENTROPY_EXPORT char* entropy_build_core_config(const char* profile_json, const char* options_json, char** error_message) {
  if (error_message != nullptr) {
    *error_message = nullptr;
  }
  try {
    return copy_string(build_core_config(profile_json, options_json));
  } catch (const std::exception& error) {
    if (error_message != nullptr) {
      *error_message = copy_string(error.what());
    }
    return nullptr;
  } catch (...) {
    if (error_message != nullptr) {
      *error_message = copy_string("Failed to build core config.");
    }
    return nullptr;
  }
}

extern "C" ENTROPY_EXPORT char* entropy_measure_tcp_pings(const char* targets_json, int timeout_ms, int max_concurrent, char** error_message) {
  if (error_message != nullptr) {
    *error_message = nullptr;
  }
  try {
    return copy_string(measure_tcp_pings_json(targets_json, timeout_ms, max_concurrent));
  } catch (const std::exception& error) {
    if (error_message != nullptr) {
      *error_message = copy_string(error.what());
    }
    return nullptr;
  } catch (...) {
    if (error_message != nullptr) {
      *error_message = copy_string("Failed to measure TCP pings.");
    }
    return nullptr;
  }
}

extern "C" ENTROPY_EXPORT void entropy_free_string(char* value) {
  delete[] value;
}
