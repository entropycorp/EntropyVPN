// winsock2 must come before <windows.h> (pulled in transitively below) to
// avoid the legacy winsock 1.1 declarations colliding with winsock2.
#include <winsock2.h>
#include <ws2tcpip.h>

#include "entropy_vpn_killswitch.h"

#include <fwpmu.h>
#include <iphlpapi.h>
#include <rpc.h>

#include <mutex>

namespace entropy_vpn_service {
namespace {

// Stable GUIDs so the same sublayer/provider entry is reused across runs.
// {ENTROPY-VPN-KILLSWITCH-PROVIDER} 8b8e0f0a-4ad2-4f55-9a25-58d7a8d1d9c1
constexpr GUID kKillswitchProviderGuid = {
    0x8b8e0f0a,
    0x4ad2,
    0x4f55,
    {0x9a, 0x25, 0x58, 0xd7, 0xa8, 0xd1, 0xd9, 0xc1}};
// {ENTROPY-VPN-KILLSWITCH-SUBLAYER} 2c7e74b8-3a35-4dc3-bd14-7c4a86b56ab2
constexpr GUID kKillswitchSublayerGuid = {
    0x2c7e74b8,
    0x3a35,
    0x4dc3,
    {0xbd, 0x14, 0x7c, 0x4a, 0x86, 0xb5, 0x6a, 0xb2}};

std::mutex g_killswitch_mutex;

class FwpEngine {
 public:
  FwpEngine() = default;
  ~FwpEngine() {
    if (handle_ != nullptr) {
      FwpmEngineClose0(handle_);
    }
  }
  FwpEngine(const FwpEngine&) = delete;
  FwpEngine& operator=(const FwpEngine&) = delete;

  DWORD Open() {
    FWPM_SESSION0 session{};
    session.displayData.name = const_cast<wchar_t*>(L"EntropyVPN Killswitch");
    session.displayData.description =
        const_cast<wchar_t*>(L"EntropyVPN killswitch transient session");
    return FwpmEngineOpen0(nullptr, RPC_C_AUTHN_WINNT, nullptr, &session,
                           &handle_);
  }

  HANDLE handle() const { return handle_; }

 private:
  HANDLE handle_ = nullptr;
};

// Ensures the killswitch provider/sublayer entries exist. Both are kept
// persistent so a crash mid-engage leaves a recoverable state and a future
// disengage can still tear everything down.
DWORD EnsureProviderAndSublayer(HANDLE engine, std::string* error_step) {
  FWPM_PROVIDER0 provider{};
  provider.providerKey = kKillswitchProviderGuid;
  provider.displayData.name = const_cast<wchar_t*>(L"EntropyVPN Killswitch");
  provider.displayData.description =
      const_cast<wchar_t*>(L"EntropyVPN killswitch filter provider");
  DWORD result = FwpmProviderAdd0(engine, &provider, nullptr);
  if (result != NO_ERROR && result != FWP_E_ALREADY_EXISTS) {
    *error_step = "provider-add";
    return result;
  }

  FWPM_SUBLAYER0 sublayer{};
  sublayer.subLayerKey = kKillswitchSublayerGuid;
  sublayer.providerKey = const_cast<GUID*>(&kKillswitchProviderGuid);
  sublayer.displayData.name = const_cast<wchar_t*>(L"EntropyVPN Killswitch");
  sublayer.displayData.description =
      const_cast<wchar_t*>(L"EntropyVPN killswitch filters");
  // Weight high enough to outrank most third-party filters at the same layer.
  sublayer.weight = 0x8000;
  result = FwpmSubLayerAdd0(engine, &sublayer, nullptr);
  if (result != NO_ERROR && result != FWP_E_ALREADY_EXISTS) {
    *error_step = "sublayer-add";
    return result;
  }
  return NO_ERROR;
}

// Deletes every filter inside our sublayer. Filters added under the
// killswitch provider key can be enumerated cheaply by FWPM enum APIs.
DWORD ClearExistingFilters(HANDLE engine) {
  HANDLE enum_handle = nullptr;
  FWPM_FILTER_ENUM_TEMPLATE0 enum_template{};
  enum_template.providerKey = const_cast<GUID*>(&kKillswitchProviderGuid);
  enum_template.actionMask = 0xFFFFFFFF;
  DWORD result = FwpmFilterCreateEnumHandle0(engine, &enum_template,
                                             &enum_handle);
  if (result != NO_ERROR) {
    return result;
  }
  FWPM_FILTER0** entries = nullptr;
  UINT32 count = 0;
  result = FwpmFilterEnum0(engine, enum_handle, 0xFFFFFFFF, &entries, &count);
  if (result == NO_ERROR && entries != nullptr) {
    for (UINT32 i = 0; i < count; ++i) {
      FwpmFilterDeleteByKey0(engine, &entries[i]->filterKey);
    }
    FwpmFreeMemory0(reinterpret_cast<void**>(&entries));
  }
  FwpmFilterDestroyEnumHandle0(engine, enum_handle);
  return NO_ERROR;
}

DWORD AddFilter(HANDLE engine,
                const GUID& layer,
                FWP_ACTION_TYPE action,
                UINT64 weight,
                const std::wstring& description,
                std::vector<FWPM_FILTER_CONDITION0>* conditions) {
  FWPM_FILTER0 filter{};
  filter.subLayerKey = kKillswitchSublayerGuid;
  filter.providerKey = const_cast<GUID*>(&kKillswitchProviderGuid);
  filter.layerKey = layer;
  filter.action.type = action;
  filter.weight.type = FWP_UINT64;
  filter.weight.uint64 = const_cast<UINT64*>(&weight);
  filter.flags = FWPM_FILTER_FLAG_PERSISTENT;
  filter.displayData.name = const_cast<wchar_t*>(L"EntropyVPN Killswitch");
  filter.displayData.description =
      const_cast<wchar_t*>(description.c_str());
  if (conditions != nullptr && !conditions->empty()) {
    filter.filterCondition = conditions->data();
    filter.numFilterConditions = static_cast<UINT32>(conditions->size());
  }
  return FwpmFilterAdd0(engine, &filter, nullptr, nullptr);
}

DWORD AddLoopbackPermit(HANDLE engine, const GUID& layer, UINT64 weight) {
  FWPM_FILTER_CONDITION0 condition{};
  condition.fieldKey = FWPM_CONDITION_FLAGS;
  condition.matchType = FWP_MATCH_FLAGS_ANY_SET;
  condition.conditionValue.type = FWP_UINT32;
  condition.conditionValue.uint32 = FWP_CONDITION_FLAG_IS_LOOPBACK;
  std::vector<FWPM_FILTER_CONDITION0> conditions{condition};
  return AddFilter(engine, layer, FWP_ACTION_PERMIT, weight,
                   L"Permit loopback", &conditions);
}

DWORD AddDhcpPermit(HANDLE engine,
                    const GUID& layer,
                    UINT64 weight,
                    UINT16 port_v4) {
  // Permit outbound UDP to DHCP server port so reconnecting to a different
  // physical network works while the killswitch is engaged.
  FWPM_FILTER_CONDITION0 protocol{};
  protocol.fieldKey = FWPM_CONDITION_IP_PROTOCOL;
  protocol.matchType = FWP_MATCH_EQUAL;
  protocol.conditionValue.type = FWP_UINT8;
  protocol.conditionValue.uint8 = IPPROTO_UDP;

  FWPM_FILTER_CONDITION0 dst_port{};
  dst_port.fieldKey = FWPM_CONDITION_IP_REMOTE_PORT;
  dst_port.matchType = FWP_MATCH_EQUAL;
  dst_port.conditionValue.type = FWP_UINT16;
  dst_port.conditionValue.uint16 = port_v4;

  std::vector<FWPM_FILTER_CONDITION0> conditions{protocol, dst_port};
  return AddFilter(engine, layer, FWP_ACTION_PERMIT, weight,
                   L"Permit DHCP", &conditions);
}

DWORD AddAppPermit(HANDLE engine,
                   const GUID& layer,
                   UINT64 weight,
                   const std::wstring& exe_path) {
  FWP_BYTE_BLOB* blob = nullptr;
  DWORD result = FwpmGetAppIdFromFileName0(exe_path.c_str(), &blob);
  if (result != NO_ERROR) {
    return result;
  }
  FWPM_FILTER_CONDITION0 condition{};
  condition.fieldKey = FWPM_CONDITION_ALE_APP_ID;
  condition.matchType = FWP_MATCH_EQUAL;
  condition.conditionValue.type = FWP_BYTE_BLOB_TYPE;
  condition.conditionValue.byteBlob = blob;
  std::vector<FWPM_FILTER_CONDITION0> conditions{condition};
  const DWORD add_result =
      AddFilter(engine, layer, FWP_ACTION_PERMIT, weight,
                L"Permit VPN core executable", &conditions);
  FwpmFreeMemory0(reinterpret_cast<void**>(&blob));
  return add_result;
}

DWORD AddBlockAll(HANDLE engine, const GUID& layer, UINT64 weight) {
  return AddFilter(engine, layer, FWP_ACTION_BLOCK, weight,
                   L"Block all outbound", nullptr);
}

DWORD InstallFilterSet(HANDLE engine,
                       const std::vector<std::wstring>& permit_exe_paths,
                       std::string* error_step) {
  const GUID layers_v4[] = {FWPM_LAYER_ALE_AUTH_CONNECT_V4};
  const GUID layers_v6[] = {FWPM_LAYER_ALE_AUTH_CONNECT_V6};

  auto install_for = [&](const GUID& layer, bool is_v4) -> DWORD {
    DWORD result =
        AddLoopbackPermit(engine, layer, /*weight=*/0xF000000000000000ULL);
    if (result != NO_ERROR) {
      *error_step = "permit-loopback";
      return result;
    }
    if (is_v4) {
      result = AddDhcpPermit(engine, layer,
                             /*weight=*/0xE000000000000000ULL, /*port=*/67);
      if (result != NO_ERROR && result != FWP_E_DUPLICATE_CONDITION) {
        *error_step = "permit-dhcp";
        return result;
      }
    } else {
      result = AddDhcpPermit(engine, layer,
                             /*weight=*/0xE000000000000000ULL, /*port=*/547);
      if (result != NO_ERROR && result != FWP_E_DUPLICATE_CONDITION) {
        *error_step = "permit-dhcpv6";
        return result;
      }
    }
    for (const auto& exe_path : permit_exe_paths) {
      if (exe_path.empty()) {
        continue;
      }
      result = AddAppPermit(engine, layer,
                            /*weight=*/0xD000000000000000ULL, exe_path);
      if (result != NO_ERROR) {
        *error_step = "permit-app";
        return result;
      }
    }
    result = AddBlockAll(engine, layer, /*weight=*/0x0000000000000001ULL);
    if (result != NO_ERROR) {
      *error_step = "block-all";
      return result;
    }
    return NO_ERROR;
  };

  for (const GUID& layer : layers_v4) {
    const DWORD result = install_for(layer, true);
    if (result != NO_ERROR) {
      return result;
    }
  }
  for (const GUID& layer : layers_v6) {
    const DWORD result = install_for(layer, false);
    if (result != NO_ERROR) {
      return result;
    }
  }
  return NO_ERROR;
}

}  // namespace

DWORD EngageKillswitch(const std::vector<std::wstring>& permit_exe_paths,
                       std::string* error_step) {
  std::lock_guard<std::mutex> lock(g_killswitch_mutex);
  FwpEngine engine;
  DWORD result = engine.Open();
  if (result != NO_ERROR) {
    *error_step = "engine-open";
    return result;
  }

  result = FwpmTransactionBegin0(engine.handle(), 0);
  if (result != NO_ERROR) {
    *error_step = "transaction-begin";
    return result;
  }

  result = EnsureProviderAndSublayer(engine.handle(), error_step);
  if (result == NO_ERROR) {
    // Rebuild the filter set from scratch each time, so re-engaging picks up
    // any change in the permitted core executable path.
    result = ClearExistingFilters(engine.handle());
    if (result != NO_ERROR) {
      *error_step = "clear-existing-filters";
    }
  }
  if (result == NO_ERROR) {
    result = InstallFilterSet(engine.handle(), permit_exe_paths, error_step);
  }

  if (result != NO_ERROR) {
    FwpmTransactionAbort0(engine.handle());
    return result;
  }

  result = FwpmTransactionCommit0(engine.handle());
  if (result != NO_ERROR) {
    *error_step = "transaction-commit";
    return result;
  }
  return NO_ERROR;
}

DWORD DisengageKillswitch(bool* changed) {
  std::lock_guard<std::mutex> lock(g_killswitch_mutex);
  if (changed != nullptr) {
    *changed = false;
  }
  FwpEngine engine;
  DWORD result = engine.Open();
  if (result != NO_ERROR) {
    return result;
  }

  result = FwpmTransactionBegin0(engine.handle(), 0);
  if (result != NO_ERROR) {
    return result;
  }

  bool any_removed = false;
  // Best-effort filter purge: enumerate everything under our provider key and
  // delete it. ClearExistingFilters here doesn't report whether anything was
  // removed, so we peek at sublayer-delete to set `changed`.
  ClearExistingFilters(engine.handle());

  const DWORD sub_result =
      FwpmSubLayerDeleteByKey0(engine.handle(), &kKillswitchSublayerGuid);
  if (sub_result == NO_ERROR) {
    any_removed = true;
  } else if (sub_result != FWP_E_SUBLAYER_NOT_FOUND) {
    FwpmTransactionAbort0(engine.handle());
    return sub_result;
  }

  const DWORD provider_result =
      FwpmProviderDeleteByKey0(engine.handle(), &kKillswitchProviderGuid);
  if (provider_result != NO_ERROR &&
      provider_result != FWP_E_PROVIDER_NOT_FOUND) {
    FwpmTransactionAbort0(engine.handle());
    return provider_result;
  }

  result = FwpmTransactionCommit0(engine.handle());
  if (result != NO_ERROR) {
    return result;
  }
  if (changed != nullptr) {
    *changed = any_removed;
  }
  return NO_ERROR;
}

}  // namespace entropy_vpn_service
