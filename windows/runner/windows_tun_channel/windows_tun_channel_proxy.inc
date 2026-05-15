DWORD ReadRegistryDword(HKEY key, const wchar_t* name, DWORD fallback) {
  DWORD value = fallback;
  DWORD type = 0;
  DWORD size = sizeof(value);
  const DWORD result =
      RegQueryValueExW(key, name, nullptr, &type,
                       reinterpret_cast<LPBYTE>(&value), &size);
  if (result != ERROR_SUCCESS || type != REG_DWORD) {
    return fallback;
  }
  return value;
}

std::wstring ReadRegistryString(HKEY key, const wchar_t* name) {
  DWORD type = 0;
  DWORD size = 0;
  DWORD result = RegQueryValueExW(key, name, nullptr, &type, nullptr, &size);
  if (result != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ) ||
      size == 0) {
    return std::wstring();
  }

  std::vector<wchar_t> buffer((size / sizeof(wchar_t)) + 1);
  result = RegQueryValueExW(key, name, nullptr, &type,
                            reinterpret_cast<LPBYTE>(buffer.data()), &size);
  if (result != ERROR_SUCCESS) {
    return std::wstring();
  }
  buffer.back() = L'\0';
  return std::wstring(buffer.data());
}

DWORD SetRegistryStringOrDelete(HKEY key,
                                const wchar_t* name,
                                const EncodableValue* value) {
  if (value == nullptr || std::holds_alternative<std::monostate>(*value)) {
    const DWORD result = RegDeleteValueW(key, name);
    return result == ERROR_FILE_NOT_FOUND ? ERROR_SUCCESS : result;
  }
  const auto* string_value = std::get_if<std::string>(value);
  if (string_value == nullptr) {
    return ERROR_INVALID_PARAMETER;
  }
  const std::wstring wide = WideFromUtf8(*string_value);
  return RegSetValueExW(
      key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(wide.c_str()),
      static_cast<DWORD>((wide.size() + 1) * sizeof(wchar_t)));
}

DWORD RefreshSystemProxySettings() {
  if (InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr,
                         0) == 0) {
    return GetLastError();
  }
  if (InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0) == 0) {
    return GetLastError();
  }
  return ERROR_SUCCESS;
}

EncodableValue CaptureSystemProxy() {
  EncodableMap response;
  HKEY key = nullptr;
  DWORD result = RegOpenKeyExW(HKEY_CURRENT_USER, kInternetSettingsRegistryPath,
                               0, KEY_QUERY_VALUE, &key);
  if (result != ERROR_SUCCESS) {
    AddFailure(&response, "registry-open", result);
    return EncodableValue(std::move(response));
  }

  const DWORD enabled = ReadRegistryDword(key, L"ProxyEnable", 0);
  const std::wstring server = ReadRegistryString(key, L"ProxyServer");
  const std::wstring override = ReadRegistryString(key, L"ProxyOverride");
  RegCloseKey(key);

  response.insert_or_assign(EncodableValue("enabled"),
                            EncodableValue(enabled == 1));
  response.insert_or_assign(EncodableValue("server"),
                            EncodableValue(Utf8FromWide(server.c_str())));
  response.insert_or_assign(EncodableValue("override"),
                            EncodableValue(Utf8FromWide(override.c_str())));
  AddSuccess(&response);
  return EncodableValue(std::move(response));
}

EncodableValue SetSystemProxy(const EncodableMap& arguments) {
  EncodableMap response;
  bool enabled = false;
  if (!ReadBool(arguments, "enabled", &enabled)) {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }

  HKEY key = nullptr;
  DWORD disposition = 0;
  DWORD result = RegCreateKeyExW(HKEY_CURRENT_USER,
                                 kInternetSettingsRegistryPath, 0, nullptr,
                                 REG_OPTION_NON_VOLATILE, KEY_SET_VALUE,
                                 nullptr, &key, &disposition);
  if (result != ERROR_SUCCESS) {
    AddFailure(&response, "registry-open", result);
    return EncodableValue(std::move(response));
  }

  DWORD enabled_value = enabled ? 1 : 0;
  result = RegSetValueExW(key, L"ProxyEnable", 0, REG_DWORD,
                          reinterpret_cast<const BYTE*>(&enabled_value),
                          sizeof(enabled_value));
  if (result == ERROR_SUCCESS) {
    result =
        SetRegistryStringOrDelete(key, L"ProxyServer",
                                  FindValue(arguments, "server"));
  }
  if (result == ERROR_SUCCESS) {
    result =
        SetRegistryStringOrDelete(key, L"ProxyOverride",
                                  FindValue(arguments, "override"));
  }
  RegCloseKey(key);

  if (result != ERROR_SUCCESS) {
    AddFailure(&response, "registry-set", result);
    return EncodableValue(std::move(response));
  }

  result = RefreshSystemProxySettings();
  if (result != ERROR_SUCCESS) {
    AddFailure(&response, "proxy-refresh", result);
    return EncodableValue(std::move(response));
  }

  AddSuccess(&response);
  return EncodableValue(std::move(response));
}

EncodableValue RelaunchAsAdministrator(const EncodableMap& arguments) {
  EncodableMap response;
  std::string executable;
  std::string working_directory;
  std::string relaunch_arguments;
  if (!ReadString(arguments, "executable", &executable) ||
      executable.empty()) {
    AddFailure(&response, "arguments", ERROR_INVALID_PARAMETER);
    return EncodableValue(std::move(response));
  }
  ReadString(arguments, "workingDirectory", &working_directory);
  ReadString(arguments, "arguments", &relaunch_arguments);

  const std::wstring executable_wide = WideFromUtf8(executable);
  const std::wstring working_directory_wide = WideFromUtf8(working_directory);
  const std::wstring arguments_wide = WideFromUtf8(relaunch_arguments);
  HINSTANCE launch_result = ShellExecuteW(
      nullptr, L"runas", executable_wide.c_str(),
      arguments_wide.empty() ? nullptr : arguments_wide.c_str(),
      working_directory_wide.empty() ? nullptr : working_directory_wide.c_str(),
      SW_SHOWNORMAL);
  const INT_PTR code = reinterpret_cast<INT_PTR>(launch_result);
  if (code <= 32) {
    AddFailure(&response, "shell-execute",
               code > 0 ? static_cast<DWORD>(code) : GetLastError());
    return EncodableValue(std::move(response));
  }

  AddSuccess(&response);
  return EncodableValue(std::move(response));
}

void AddFailureMessage(EncodableMap* response,
                       const std::string& step,
                       const std::string& message,
                       DWORD error_code = ERROR_GEN_FAILURE) {
  response->insert_or_assign(EncodableValue("ok"), EncodableValue(false));
  response->insert_or_assign(EncodableValue("failedStep"), EncodableValue(step));
  response->insert_or_assign(EncodableValue("error"), EncodableValue(message));
  response->insert_or_assign(EncodableValue("errorCode"),
                             EncodableValue(static_cast<int64_t>(error_code)));
}

