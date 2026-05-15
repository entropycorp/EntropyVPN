const EncodableValue* FindValue(const EncodableMap& map, const char* key) {
  const auto iterator = map.find(EncodableValue(std::string(key)));
  if (iterator == map.end()) {
    return nullptr;
  }
  return &iterator->second;
}

bool ReadInt64(const EncodableMap& map, const char* key, int64_t* value) {
  const EncodableValue* entry = FindValue(map, key);
  if (entry == nullptr) {
    return false;
  }
  if (const auto typed = std::get_if<int64_t>(entry)) {
    *value = *typed;
    return true;
  }
  if (const auto typed = std::get_if<int32_t>(entry)) {
    *value = *typed;
    return true;
  }
  return false;
}

bool ReadString(const EncodableMap& map, const char* key, std::string* value) {
  const EncodableValue* entry = FindValue(map, key);
  if (entry == nullptr) {
    return false;
  }
  if (const auto typed = std::get_if<std::string>(entry)) {
    *value = *typed;
    return true;
  }
  return false;
}

bool ReadBool(const EncodableMap& map, const char* key, bool* value) {
  const EncodableValue* entry = FindValue(map, key);
  if (entry == nullptr) {
    return false;
  }
  if (const auto typed = std::get_if<bool>(entry)) {
    *value = *typed;
    return true;
  }
  return false;
}

void AddFailure(EncodableMap* response, const std::string& step, DWORD error) {
  response->insert_or_assign(EncodableValue("ok"), EncodableValue(false));
  response->insert_or_assign(EncodableValue("failedStep"), EncodableValue(step));
  response->insert_or_assign(EncodableValue("error"),
                             EncodableValue(ErrorMessage(error)));
  response->insert_or_assign(EncodableValue("errorCode"),
                             EncodableValue(static_cast<int64_t>(error)));
}

void AddSuccess(EncodableMap* response) {
  response->insert_or_assign(EncodableValue("ok"), EncodableValue(true));
}

class ScopedServiceHandle {
 public:
  explicit ScopedServiceHandle(SC_HANDLE handle) : handle_(handle) {}
  ~ScopedServiceHandle() {
    if (handle_ != nullptr) {
      CloseServiceHandle(handle_);
    }
  }

  ScopedServiceHandle(const ScopedServiceHandle&) = delete;
  ScopedServiceHandle& operator=(const ScopedServiceHandle&) = delete;

  SC_HANDLE get() const { return handle_; }

 private:
  SC_HANDLE handle_ = nullptr;
};

std::string ServiceStateToString(DWORD state) {
  switch (state) {
    case SERVICE_STOPPED:
      return "stopped";
    case SERVICE_START_PENDING:
      return "startPending";
    case SERVICE_STOP_PENDING:
      return "stopPending";
    case SERVICE_RUNNING:
      return "running";
    case SERVICE_CONTINUE_PENDING:
      return "continuePending";
    case SERVICE_PAUSE_PENDING:
      return "pausePending";
    case SERVICE_PAUSED:
      return "paused";
    default:
      return "unknown";
  }
}

bool ReadStringList(const EncodableMap& map,
                    const char* key,
                    std::vector<std::string>* values) {
  const EncodableValue* entry = FindValue(map, key);
  if (entry == nullptr) {
    return false;
  }
  const auto* list = std::get_if<EncodableList>(entry);
  if (list == nullptr) {
    return false;
  }
  values->clear();
  values->reserve(list->size());
  for (const EncodableValue& item : *list) {
    const auto* text = std::get_if<std::string>(&item);
    if (text != nullptr && !text->empty()) {
      values->push_back(*text);
    }
  }
  return true;
}

bool ReadStringListAllowEmpty(const EncodableMap& map,
                              const char* key,
                              std::vector<std::string>* values) {
  const EncodableValue* entry = FindValue(map, key);
  if (entry == nullptr) {
    return false;
  }
  const auto* list = std::get_if<EncodableList>(entry);
  if (list == nullptr) {
    return false;
  }
  values->clear();
  values->reserve(list->size());
  for (const EncodableValue& item : *list) {
    const auto* text = std::get_if<std::string>(&item);
    if (text == nullptr) {
      return false;
    }
    values->push_back(*text);
  }
  return true;
}

void AddPidList(EncodableMap* response,
                const std::string& key,
                const std::vector<DWORD>& pids) {
  EncodableList values;
  values.reserve(pids.size());
  for (DWORD pid : pids) {
    values.emplace_back(EncodableValue(static_cast<int64_t>(pid)));
  }
  response->insert_or_assign(EncodableValue(key),
                             EncodableValue(std::move(values)));
}

