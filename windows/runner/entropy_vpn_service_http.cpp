#include "entropy_vpn_service_http.h"

#include <windows.h>
#include <winhttp.h>

#include "entropy_vpn_service_common.h"

namespace entropy_vpn_service {
namespace {

constexpr wchar_t kUserAgent[] = L"EntropyVPN-Updater/1";

// RAII for the WinHTTP handle trio.
class WinHttpHandle {
 public:
  explicit WinHttpHandle(HINTERNET handle = nullptr) : handle_(handle) {}
  ~WinHttpHandle() {
    if (handle_ != nullptr) {
      WinHttpCloseHandle(handle_);
    }
  }
  WinHttpHandle(const WinHttpHandle&) = delete;
  WinHttpHandle& operator=(const WinHttpHandle&) = delete;
  WinHttpHandle(WinHttpHandle&& other) noexcept : handle_(other.handle_) {
    other.handle_ = nullptr;
  }
  HINTERNET get() const { return handle_; }
  void reset(HINTERNET handle) {
    if (handle_ != nullptr) {
      WinHttpCloseHandle(handle_);
    }
    handle_ = handle;
  }

 private:
  HINTERNET handle_ = nullptr;
};

HttpResult Fail(const std::string& message) {
  HttpResult result;
  result.ok = false;
  result.error = message;
  return result;
}

HttpResult FailWin32(const std::string& message) {
  return Fail(message + ": " + ErrorMessage(GetLastError()));
}

// Opens the session/connection/request handles and runs the request up to
// (but not including) reading the response body. `extra_headers` is appended
// verbatim (each header must end with CRLF). On success the request handle is
// moved into `request` and the HTTP status code into `status`.
bool BeginRequest(const std::wstring& url,
                  const std::wstring& extra_headers,
                  WinHttpHandle* session,
                  WinHttpHandle* connection,
                  WinHttpHandle* request,
                  unsigned int* status,
                  std::string* error) {
  URL_COMPONENTS components{};
  components.dwStructSize = sizeof(components);
  wchar_t host[256] = {0};
  wchar_t path[2048] = {0};
  components.lpszHostName = host;
  components.dwHostNameLength = ARRAYSIZE(host);
  components.lpszUrlPath = path;
  components.dwUrlPathLength = ARRAYSIZE(path);

  if (WinHttpCrackUrl(url.c_str(), 0, 0, &components) == 0) {
    *error = "Could not parse update URL.";
    return false;
  }
  if (components.nScheme != INTERNET_SCHEME_HTTPS) {
    *error = "Refusing a non-HTTPS update URL.";
    return false;
  }

  session->reset(WinHttpOpen(kUserAgent, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                             WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS,
                             0));
  if (session->get() == nullptr) {
    *error = "WinHttpOpen failed: " + ErrorMessage(GetLastError());
    return false;
  }

  connection->reset(WinHttpConnect(session->get(), host,
                                   components.nPort, 0));
  if (connection->get() == nullptr) {
    *error = "WinHttpConnect failed: " + ErrorMessage(GetLastError());
    return false;
  }

  request->reset(WinHttpOpenRequest(
      connection->get(), L"GET", path, nullptr, WINHTTP_NO_REFERER,
      WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE));
  if (request->get() == nullptr) {
    *error = "WinHttpOpenRequest failed: " + ErrorMessage(GetLastError());
    return false;
  }

  if (WinHttpSendRequest(
          request->get(),
          extra_headers.empty() ? WINHTTP_NO_ADDITIONAL_HEADERS
                                : extra_headers.c_str(),
          extra_headers.empty() ? 0 : static_cast<DWORD>(-1L),
          WINHTTP_NO_REQUEST_DATA, 0, 0, 0) == 0) {
    *error = "WinHttpSendRequest failed: " + ErrorMessage(GetLastError());
    return false;
  }
  if (WinHttpReceiveResponse(request->get(), nullptr) == 0) {
    *error = "WinHttpReceiveResponse failed: " + ErrorMessage(GetLastError());
    return false;
  }

  DWORD status_code = 0;
  DWORD status_size = sizeof(status_code);
  if (WinHttpQueryHeaders(
          request->get(),
          WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
          WINHTTP_HEADER_NAME_BY_INDEX, &status_code, &status_size,
          WINHTTP_NO_HEADER_INDEX) == 0) {
    *error = "WinHttpQueryHeaders failed: " + ErrorMessage(GetLastError());
    return false;
  }
  *status = status_code;
  return true;
}

}  // namespace

HttpResult HttpGetString(const std::wstring& url,
                         size_t max_bytes,
                         const std::string& accept_header) {
  std::wstring headers;
  if (!accept_header.empty()) {
    headers = L"Accept: " + WideFromUtf8(accept_header) + L"\r\n";
  }
  WinHttpHandle session;
  WinHttpHandle connection;
  WinHttpHandle request;
  unsigned int status = 0;
  std::string error;
  if (!BeginRequest(url, headers, &session, &connection, &request,
                    &status, &error)) {
    return Fail(error);
  }

  HttpResult result;
  result.status = status;
  if (status < 200 || status >= 300) {
    return Fail("Update server returned HTTP " + std::to_string(status) + ".");
  }

  std::string body;
  while (true) {
    DWORD available = 0;
    if (WinHttpQueryDataAvailable(request.get(), &available) == 0) {
      return FailWin32("WinHttpQueryDataAvailable failed");
    }
    if (available == 0) {
      break;
    }
    if (body.size() + available > max_bytes) {
      return Fail("Update response exceeded the size limit.");
    }
    std::string chunk(available, '\0');
    DWORD read = 0;
    if (WinHttpReadData(request.get(), chunk.data(), available, &read) == 0) {
      return FailWin32("WinHttpReadData failed");
    }
    if (read == 0) {
      break;
    }
    body.append(chunk.data(), read);
  }

  result.ok = true;
  result.body = std::move(body);
  return result;
}

HttpResult HttpDownloadRangeToFile(
    const std::wstring& url,
    const std::wstring& dest_path,
    uint64_t range_offset,
    uint64_t range_length,
    const std::function<void(uint64_t, uint64_t)>& progress) {
  // A zero-byte slice is legal (e.g. an empty file inside the pack). Skip the
  // network round-trip and just create the empty staging file.
  if (range_length == 0) {
    HANDLE file = CreateFileW(dest_path.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
      return FailWin32("Could not open the staging file");
    }
    CloseHandle(file);
    HttpResult result;
    result.ok = true;
    result.status = 206;
    return result;
  }

  const uint64_t range_end = range_offset + range_length - 1;
  const std::wstring headers = L"Range: bytes=" +
                               std::to_wstring(range_offset) + L"-" +
                               std::to_wstring(range_end) + L"\r\n";

  WinHttpHandle session;
  WinHttpHandle connection;
  WinHttpHandle request;
  unsigned int status = 0;
  std::string error;
  if (!BeginRequest(url, headers, &session, &connection, &request,
                    &status, &error)) {
    return Fail(error);
  }

  HttpResult result;
  result.status = status;
  // 200 OK means the server ignored Range and is sending the entire pack -
  // accepting it would scribble the wrong bytes into this staging blob.
  if (status != 206) {
    return Fail("Update server returned HTTP " + std::to_string(status) +
                " for a range request (expected 206).");
  }

  HANDLE file = CreateFileW(dest_path.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return FailWin32("Could not open the staging file");
  }

  uint64_t received = 0;
  bool ok = true;
  while (ok) {
    DWORD available = 0;
    if (WinHttpQueryDataAvailable(request.get(), &available) == 0) {
      error = "WinHttpQueryDataAvailable failed: " +
              ErrorMessage(GetLastError());
      ok = false;
      break;
    }
    if (available == 0) {
      break;
    }
    std::string chunk(available, '\0');
    DWORD read = 0;
    if (WinHttpReadData(request.get(), chunk.data(), available, &read) == 0) {
      error = "WinHttpReadData failed: " + ErrorMessage(GetLastError());
      ok = false;
      break;
    }
    if (read == 0) {
      break;
    }
    DWORD written = 0;
    if (WriteFile(file, chunk.data(), read, &written, nullptr) == 0 ||
        written != read) {
      error = "Could not write the staging file: " +
              ErrorMessage(GetLastError());
      ok = false;
      break;
    }
    received += read;
    if (progress) {
      progress(received, range_length);
    }
  }

  CloseHandle(file);
  if (!ok) {
    DeleteFileW(dest_path.c_str());
    return Fail(error);
  }
  if (received != range_length) {
    DeleteFileW(dest_path.c_str());
    return Fail("Update server returned " + std::to_string(received) +
                " bytes for a " + std::to_string(range_length) +
                "-byte range request.");
  }

  result.ok = true;
  return result;
}

}  // namespace entropy_vpn_service
