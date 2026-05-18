#include "flutter_window.h"

#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <cwchar>
#include <d2d1.h>
#include <dwmapi.h>
#include <dwrite.h>
#include <dwrite_3.h>
#include <optional>
#include <shellapi.h>
#include <string>
#include <utility>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "windows_runtime_channel.h"
#include "windows_app_catalog_channel.h"
#include "windows_tun_channel.h"

namespace {

constexpr UINT kTrayIconId = 1;
constexpr UINT kTrayIconCallbackMessage = WM_APP + 1;
constexpr UINT_PTR kTrayOpenCommand = 1001;
constexpr UINT_PTR kTrayQuitCommand = 1002;
constexpr wchar_t kTrayTooltip[] = L"EntropyVPN";
constexpr char kWindowsLifecycleChannelName[] =
    "entropy_vpn/windows_lifecycle";
constexpr char kWindowsTrayMenuChannelName[] =
    "entropy_vpn/windows_tray_menu";
constexpr char kSetTrayMenuItemsMethod[] = "setItems";
constexpr char kSelectTrayMenuItemMethod[] = "selectItem";
constexpr wchar_t kTrayMenuWindowClassName[] =
    L"ENTROPY_VPN_TRAY_MENU_WINDOW";
constexpr int kTrayMenuMinWidth = 168;
constexpr int kTrayMenuItemHeight = 34;
constexpr int kTrayMenuSeparatorHeight = 6;
constexpr int kTrayMenuHorizontalPadding = 16;
constexpr int kTrayMenuVerticalPadding = 0;
constexpr int kTrayMenuCornerRadius = 9;
constexpr int kTrayMenuFlagWidth = 20;
constexpr int kTrayMenuFlagHeight = 15;
constexpr int kTrayMenuFlagGap = 8;
constexpr int kTrayMenuSubmenuArrowWidth = 7;
constexpr int kTrayMenuSubmenuArrowGap = 12;
constexpr int kTrayMenuFontPointSize = 9;
constexpr int kTrayMenuScrollMargin = 12;
constexpr int kTrayMenuMinVisibleHeight = 96;
constexpr wchar_t kTrayMenuFontFamily[] = L"Golos Text";
constexpr wchar_t kTrayMenuFontAssetPath[] =
    L"data\\flutter_assets\\assets\\fonts\\GolosText-Regular.ttf";
constexpr wchar_t kTrayMenuEmojiFontFamily[] = L"Twemoji Mozilla";
constexpr wchar_t kTrayMenuEmojiFontAssetPath[] =
    L"data\\flutter_assets\\assets\\fonts\\Twemoji.Mozilla.ttf";
const COLORREF kTrayMenuBackgroundColor = RGB(0, 0, 0);
const COLORREF kTrayMenuSelectedColor = RGB(32, 32, 32);
const COLORREF kTrayMenuCheckedColor = RGB(18, 18, 18);
const COLORREF kTrayMenuSeparatorColor = RGB(74, 74, 74);
const COLORREF kTrayMenuTextColor = RGB(255, 255, 255);
const COLORREF kTrayMenuDisabledTextColor = RGB(122, 122, 122);

using EncodableList = flutter::EncodableList;
using EncodableMap = flutter::EncodableMap;
using EncodableValue = flutter::EncodableValue;

std::wstring GetExecutableDirectory() {
  wchar_t module_path[MAX_PATH]{};
  DWORD length = GetModuleFileNameW(nullptr, module_path, MAX_PATH);
  if (length == 0 || length == MAX_PATH) {
    return L"";
  }

  std::wstring directory(module_path, length);
  const size_t separator = directory.find_last_of(L"\\/");
  if (separator == std::wstring::npos) {
    return L"";
  }
  directory.resize(separator);
  return directory;
}

std::wstring GetTrayMenuFontPath() {
  std::wstring directory = GetExecutableDirectory();
  if (directory.empty()) {
    return L"";
  }
  return directory + L"\\" + kTrayMenuFontAssetPath;
}

std::wstring GetTrayMenuEmojiFontPath() {
  std::wstring directory = GetExecutableDirectory();
  if (directory.empty()) {
    return L"";
  }
  return directory + L"\\" + kTrayMenuEmojiFontAssetPath;
}

std::wstring WideFromUtf8(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }

  const int required = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                           value.data(),
                                           static_cast<int>(value.size()),
                                           nullptr, 0);
  if (required <= 0) {
    return std::wstring();
  }

  std::wstring result;
  result.resize(required);
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), required);
  return result;
}

const EncodableValue* FindValue(const EncodableMap& map, const char* key) {
  const auto iterator = map.find(EncodableValue(std::string(key)));
  if (iterator == map.end()) {
    return nullptr;
  }
  return &iterator->second;
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

bool ReadInt(const EncodableMap& map, const char* key, int* value) {
  const EncodableValue* entry = FindValue(map, key);
  if (entry == nullptr) {
    return false;
  }
  if (const auto typed = std::get_if<int32_t>(entry)) {
    *value = *typed;
    return true;
  }
  if (const auto typed = std::get_if<int64_t>(entry)) {
    *value = static_cast<int>(*typed);
    return true;
  }
  return false;
}

POINT GetPointFromLParam(LPARAM lparam) {
  POINT point{};
  point.x = static_cast<LONG>(static_cast<short>(LOWORD(lparam)));
  point.y = static_cast<LONG>(static_cast<short>(HIWORD(lparam)));
  return point;
}

HCURSOR GetTrayMenuArrowCursor() {
  static HCURSOR cursor = LoadCursor(nullptr, IDC_ARROW);
  return cursor;
}

void SetTrayMenuArrowCursor() {
  HCURSOR cursor = GetTrayMenuArrowCursor();
  if (cursor != nullptr) {
    SetCursor(cursor);
  }
}

bool ApplyTrayMenuDwmRoundedCorners(HWND hwnd) {
  // DWMWA_WINDOW_CORNER_PREFERENCE (33) + DWMWCP_ROUND (2) — Windows 11+ only.
  // The DWM compositor rounds the corners with GPU antialiasing, replacing
  // the aliased region-based clip used on older OS versions.
  constexpr DWORD kDwmwaWindowCornerPreference = 33;
  constexpr DWORD kDwmwcpRound = 2;
  const DWORD preference = kDwmwcpRound;
  return SUCCEEDED(DwmSetWindowAttribute(
      hwnd, kDwmwaWindowCornerPreference, &preference, sizeof(preference)));
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  ReleaseTrayMenuResources();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();



  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);

  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  lifecycle_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          kWindowsLifecycleChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  ConfigureTrayChannel();
  windows_app_catalog_channel_ =
      CreateWindowsAppCatalogChannel(flutter_controller_->engine()->messenger());
  windows_tun_channel_ =
      CreateWindowsTunChannel(flutter_controller_->engine()->messenger());
  WindowsRuntimeChannels windows_runtime_channels =
      CreateWindowsRuntimeChannels(flutter_controller_->engine()->messenger());
  windows_runtime_channel_ = std::move(windows_runtime_channels.method);
  windows_runtime_events_channel_ =
      std::move(windows_runtime_channels.events);
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  AddTrayIcon();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });




  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  ReleaseTrayMenuResources();
  windows_app_catalog_channel_ = nullptr;
  windows_tun_channel_ = nullptr;
  tray_channel_ = nullptr;
  lifecycle_channel_ = nullptr;

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  switch (message) {
    case kTrayIconCallbackMessage:
      switch (LOWORD(lparam)) {
        case NIN_SELECT:
        case NIN_KEYSELECT:
        case WM_LBUTTONUP:
        case WM_LBUTTONDBLCLK:
          ShowWindowFromTray();
          return 0;
        case WM_RBUTTONUP:
        case WM_CONTEXTMENU:
          ShowTrayMenu();
          return 0;
      }
      return 0;

    case WM_CLOSE:
      if (!is_quitting_) {
        HideWindowToTray();
        return 0;
      }
      break;

    case WM_COMMAND:
      switch (LOWORD(wparam)) {
        case kTrayOpenCommand:
          ShowWindowFromTray();
          return 0;
        case kTrayQuitCommand:
          QuitFromTray();
          return 0;
      }
      break;
  }

  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::AddTrayIcon() {
  if (tray_icon_added_) {
    return;
  }

  NOTIFYICONDATA nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = GetHandle();
  nid.uID = kTrayIconId;
  nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  nid.uCallbackMessage = kTrayIconCallbackMessage;
  nid.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(nid.szTip, kTrayTooltip);

  if (Shell_NotifyIcon(NIM_ADD, &nid)) {
    tray_icon_added_ = true;
    nid.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIcon(NIM_SETVERSION, &nid);
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_added_) {
    return;
  }

  NOTIFYICONDATA nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = GetHandle();
  nid.uID = kTrayIconId;
  Shell_NotifyIcon(NIM_DELETE, &nid);
  tray_icon_added_ = false;
}

bool FlutterWindow::EnsureTrayDirectWrite() {
  if (tray_dwrite_init_failed_) {
    return false;
  }
  if (tray_d2d_factory_ != nullptr && tray_dwrite_factory_ != nullptr &&
      tray_dwrite_collection_ != nullptr) {
    return true;
  }

  if (tray_d2d_factory_ == nullptr) {
    HRESULT hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                                   __uuidof(ID2D1Factory),
                                   reinterpret_cast<void**>(&tray_d2d_factory_));
    if (FAILED(hr)) {
      tray_dwrite_init_failed_ = true;
      return false;
    }
  }

  if (tray_dwrite_factory_ == nullptr) {
    HRESULT hr = DWriteCreateFactory(
        DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
        reinterpret_cast<IUnknown**>(&tray_dwrite_factory_));
    if (FAILED(hr)) {
      tray_dwrite_init_failed_ = true;
      return false;
    }
  }

  if (tray_dwrite_collection_ != nullptr) {
    return true;
  }

  IDWriteFactory3* factory3 = nullptr;
  if (FAILED(tray_dwrite_factory_->QueryInterface(
          __uuidof(IDWriteFactory3), reinterpret_cast<void**>(&factory3)))) {
    tray_dwrite_init_failed_ = true;
    return false;
  }

  bool succeeded = false;
  do {
    IDWriteFontSetBuilder* builder = nullptr;
    if (FAILED(factory3->CreateFontSetBuilder(&builder))) {
      break;
    }

    const std::wstring font_paths[] = {GetTrayMenuFontPath(),
                                       GetTrayMenuEmojiFontPath()};
    bool added_any = false;
    for (const std::wstring& font_path : font_paths) {
      if (font_path.empty() ||
          GetFileAttributesW(font_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
        continue;
      }

      IDWriteFontFile* font_file = nullptr;
      if (FAILED(factory3->CreateFontFileReference(font_path.c_str(), nullptr,
                                                    &font_file))) {
        continue;
      }

      BOOL is_supported = FALSE;
      DWRITE_FONT_FILE_TYPE file_type = DWRITE_FONT_FILE_TYPE_UNKNOWN;
      DWRITE_FONT_FACE_TYPE face_type = DWRITE_FONT_FACE_TYPE_UNKNOWN;
      UINT32 face_count = 0;
      if (FAILED(font_file->Analyze(&is_supported, &file_type, &face_type,
                                     &face_count)) ||
          !is_supported || face_count == 0) {
        font_file->Release();
        continue;
      }

      for (UINT32 i = 0; i < face_count; ++i) {
        IDWriteFontFaceReference* face_ref = nullptr;
        if (SUCCEEDED(factory3->CreateFontFaceReference(
                font_file, i, DWRITE_FONT_SIMULATIONS_NONE, &face_ref))) {
          if (SUCCEEDED(builder->AddFontFaceReference(face_ref))) {
            added_any = true;
          }
          face_ref->Release();
        }
      }
      font_file->Release();
    }

    if (!added_any) {
      builder->Release();
      break;
    }

    IDWriteFontSet* font_set = nullptr;
    HRESULT hr = builder->CreateFontSet(&font_set);
    builder->Release();
    if (FAILED(hr)) {
      break;
    }

    IDWriteFontCollection1* collection1 = nullptr;
    hr = factory3->CreateFontCollectionFromFontSet(font_set, &collection1);
    font_set->Release();
    if (FAILED(hr)) {
      break;
    }

    tray_dwrite_collection_ = collection1;
    succeeded = true;
  } while (false);

  if (succeeded && tray_dwrite_fallback_ == nullptr) {
    IDWriteFactory2* factory2 = nullptr;
    if (SUCCEEDED(factory3->QueryInterface(
            __uuidof(IDWriteFactory2), reinterpret_cast<void**>(&factory2)))) {
      IDWriteFontFallbackBuilder* fb_builder = nullptr;
      if (SUCCEEDED(factory2->CreateFontFallbackBuilder(&fb_builder))) {
        static const DWRITE_UNICODE_RANGE kEmojiRanges[] = {
            {0x00A9, 0x00A9}, {0x00AE, 0x00AE}, {0x200D, 0x200D},
            {0x203C, 0x203C}, {0x2049, 0x2049}, {0x20E3, 0x20E3},
            {0x2122, 0x2122}, {0x2139, 0x2139}, {0x2194, 0x2199},
            {0x21A9, 0x21AA}, {0x231A, 0x231B}, {0x2328, 0x2328},
            {0x23CF, 0x23CF}, {0x23E9, 0x23F3}, {0x23F8, 0x23FA},
            {0x24C2, 0x24C2}, {0x25AA, 0x25AB}, {0x25B6, 0x25B6},
            {0x25C0, 0x25C0}, {0x25FB, 0x25FE}, {0x2600, 0x27BF},
            {0x2934, 0x2935}, {0x2B00, 0x2BFF}, {0x3030, 0x3030},
            {0x303D, 0x303D}, {0x3297, 0x3297}, {0x3299, 0x3299},
            {0xFE0F, 0xFE0F}, {0x1F000, 0x1F02F}, {0x1F0A0, 0x1F0FF},
            {0x1F100, 0x1F64F}, {0x1F680, 0x1F6FF}, {0x1F700, 0x1F77F},
            {0x1F780, 0x1F7FF}, {0x1F800, 0x1F8FF}, {0x1F900, 0x1F9FF},
            {0x1FA00, 0x1FAFF}, {0x1FB00, 0x1FBFF},
        };
        const WCHAR* target_families[] = {kTrayMenuEmojiFontFamily};
        fb_builder->AddMapping(
            kEmojiRanges,
            static_cast<UINT32>(sizeof(kEmojiRanges) / sizeof(kEmojiRanges[0])),
            target_families, 1, tray_dwrite_collection_, nullptr, nullptr,
            1.0f);

        IDWriteFontFallback* system_fallback = nullptr;
        if (SUCCEEDED(factory2->GetSystemFontFallback(&system_fallback)) &&
            system_fallback != nullptr) {
          fb_builder->AddMappings(system_fallback);
          system_fallback->Release();
        }

        fb_builder->CreateFontFallback(&tray_dwrite_fallback_);
        fb_builder->Release();
      }
      factory2->Release();
    }
  }

  factory3->Release();
  if (!succeeded) {
    tray_dwrite_init_failed_ = true;
    return false;
  }
  return true;
}

IDWriteTextFormat* FlutterWindow::GetTrayMenuTextFormat() {
  if (tray_dwrite_factory_ == nullptr || tray_dwrite_collection_ == nullptr) {
    return nullptr;
  }

  const UINT dpi = GetTrayMenuDpi();
  if (tray_dwrite_text_format_ != nullptr && tray_dwrite_text_format_dpi_ == dpi) {
    return tray_dwrite_text_format_;
  }

  if (tray_dwrite_text_format_ != nullptr) {
    tray_dwrite_text_format_->Release();
    tray_dwrite_text_format_ = nullptr;
  }
  tray_dwrite_text_format_dpi_ = dpi;

  const float font_size =
      static_cast<float>(MulDiv(kTrayMenuFontPointSize, static_cast<int>(dpi), 72));
  IDWriteTextFormat* format = nullptr;
  HRESULT hr = tray_dwrite_factory_->CreateTextFormat(
      kTrayMenuFontFamily, tray_dwrite_collection_, DWRITE_FONT_WEIGHT_NORMAL,
      DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, font_size, L"en-us",
      &format);
  if (FAILED(hr) || format == nullptr) {
    return nullptr;
  }

  format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING);
  format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
  format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);

  IDWriteInlineObject* ellipsis_sign = nullptr;
  if (SUCCEEDED(tray_dwrite_factory_->CreateEllipsisTrimmingSign(
          format, &ellipsis_sign)) &&
      ellipsis_sign != nullptr) {
    DWRITE_TRIMMING trimming{DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
    format->SetTrimming(&trimming, ellipsis_sign);
    ellipsis_sign->Release();
  }

  if (tray_dwrite_fallback_ != nullptr) {
    IDWriteTextFormat1* format1 = nullptr;
    if (SUCCEEDED(format->QueryInterface(
            __uuidof(IDWriteTextFormat1),
            reinterpret_cast<void**>(&format1)))) {
      format1->SetFontFallback(tray_dwrite_fallback_);
      format1->Release();
    }
  }

  tray_dwrite_text_format_ = format;
  return format;
}

bool FlutterWindow::EnsureTrayDCRenderTarget() {
  if (tray_dc_render_target_ != nullptr) {
    return true;
  }
  if (tray_d2d_factory_ == nullptr) {
    return false;
  }

  D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
      D2D1_RENDER_TARGET_TYPE_DEFAULT,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), 0,
      0, D2D1_RENDER_TARGET_USAGE_NONE, D2D1_FEATURE_LEVEL_DEFAULT);

  HRESULT hr = tray_d2d_factory_->CreateDCRenderTarget(&props,
                                                       &tray_dc_render_target_);
  if (FAILED(hr) || tray_dc_render_target_ == nullptr) {
    return false;
  }

  tray_dc_render_target_->SetTextAntialiasMode(
      D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE);
  return true;
}

void FlutterWindow::ReleaseTrayDCRenderTargetResources() {
  if (tray_text_brush_enabled_ != nullptr) {
    tray_text_brush_enabled_->Release();
    tray_text_brush_enabled_ = nullptr;
  }
  if (tray_text_brush_disabled_ != nullptr) {
    tray_text_brush_disabled_->Release();
    tray_text_brush_disabled_ = nullptr;
  }
  if (tray_dc_render_target_ != nullptr) {
    tray_dc_render_target_->Release();
    tray_dc_render_target_ = nullptr;
  }
}

UINT FlutterWindow::GetTrayMenuDpi() {
  HWND hwnd = GetHandle();
  HDC hdc = GetDC(hwnd);
  if (hdc == nullptr) {
    return 96;
  }

  const int dpi = GetDeviceCaps(hdc, LOGPIXELSX);
  ReleaseDC(hwnd, hdc);
  if (dpi <= 0) {
    return 96;
  }
  return static_cast<UINT>(dpi);
}

int FlutterWindow::ScaleTrayMenuMetric(int value) {
  return MulDiv(value, static_cast<int>(GetTrayMenuDpi()), 96);
}

void FlutterWindow::ConfigureTrayChannel() {
  tray_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          kWindowsTrayMenuChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  tray_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == kSetTrayMenuItemsMethod) {
          UpdateTraySwitchItems(call.arguments());
          result->Success();
          return;
        }

        result->NotImplemented();
      });
}

bool FlutterWindow::ReadTrayMenuItem(const EncodableMap& map,
                                     TrayMenuItem* item) {
  if (item == nullptr) {
    return false;
  }

  bool separator = false;
  if (ReadBool(map, "separator", &separator) && separator) {
    item->separator = true;
    item->enabled = false;
    return true;
  }

  std::string token;
  std::string label;
  if (!ReadString(map, "token", &token) || !ReadString(map, "label", &label) ||
      token.empty() || label.empty()) {
    return false;
  }

  item->token = token;
  item->label = WideFromUtf8(label);
  if (item->label.empty()) {
    return false;
  }

  std::string flag_path;
  if (ReadString(map, "flagPath", &flag_path) && !flag_path.empty()) {
    item->flag_path = WideFromUtf8(flag_path);
  }
  ReadBool(map, "selected", &item->selected);
  ReadBool(map, "enabled", &item->enabled);
  ReadInt(map, "indent", &item->indent);
  item->indent = std::clamp(item->indent, 0, 48);

  const EncodableValue* children_value = FindValue(map, "children");
  const auto* children =
      children_value == nullptr ? nullptr
                                : std::get_if<EncodableList>(children_value);
  if (children != nullptr) {
    item->children.reserve(children->size());
    for (const EncodableValue& child_value : *children) {
      const auto* child_map = std::get_if<EncodableMap>(&child_value);
      if (child_map == nullptr) {
        continue;
      }

      TrayMenuItem child;
      if (ReadTrayMenuItem(*child_map, &child)) {
        item->children.push_back(std::move(child));
      }
    }
  }

  return true;
}

void FlutterWindow::UpdateTraySwitchItems(
    const flutter::EncodableValue* arguments) {
  const auto* list = arguments == nullptr
                         ? nullptr
                         : std::get_if<EncodableList>(arguments);
  std::vector<TrayMenuItem> next_items;
  if (list != nullptr) {
    next_items.reserve(list->size());
    for (const EncodableValue& value : *list) {
      const auto* map = std::get_if<EncodableMap>(&value);
      if (map == nullptr) {
        continue;
      }

      TrayMenuItem item;
      if (ReadTrayMenuItem(*map, &item)) {
        next_items.push_back(std::move(item));
      }
    }
  }

  tray_switch_items_ = std::move(next_items);

  const auto same_shape = [](const std::vector<TrayMenuItem>& a,
                             const std::vector<TrayMenuItem>& b) {
    if (a.size() != b.size()) {
      return false;
    }
    for (size_t i = 0; i < a.size(); ++i) {
      if (a[i].separator != b[i].separator ||
          a[i].command_id != b[i].command_id ||
          a[i].children.empty() != b[i].children.empty()) {
        return false;
      }
    }
    return true;
  };

  std::vector<TrayMenuItem> previous_menu_items;
  if (tray_menu_window_ != nullptr) {
    previous_menu_items = tray_menu_items_;
  }

  RebuildTrayMenuItems();

  if (tray_menu_window_ == nullptr) {
    return;
  }

  if (!same_shape(previous_menu_items, tray_menu_items_)) {
    HideTrayMenu();
    return;
  }

  InvalidateRect(tray_menu_window_, nullptr, FALSE);

  if (tray_submenu_window_ != nullptr) {
    const int parent = tray_submenu_parent_index_;
    if (parent < 0 ||
        parent >= static_cast<int>(tray_menu_items_.size()) ||
        tray_menu_items_[parent].children.empty() ||
        !same_shape(tray_submenu_items_,
                    tray_menu_items_[parent].children)) {
      HideTraySubmenu();
    } else {
      tray_submenu_items_ = tray_menu_items_[parent].children;
      InvalidateRect(tray_submenu_window_, nullptr, FALSE);
    }
  }
}

void FlutterWindow::RebuildTrayMenuItems() {
  tray_menu_items_.clear();

  TrayMenuItem open_item;
  open_item.command_id = kTrayOpenCommand;
  open_item.label = L"Open";
  tray_menu_items_.push_back(std::move(open_item));

  TrayMenuItem separator;
  separator.separator = true;
  separator.enabled = false;
  tray_menu_items_.push_back(separator);

  if (!tray_switch_items_.empty()) {
    tray_menu_items_.insert(tray_menu_items_.end(), tray_switch_items_.begin(),
                            tray_switch_items_.end());
    tray_menu_items_.push_back(separator);
  }

  TrayMenuItem quit_item;
  quit_item.command_id = kTrayQuitCommand;
  quit_item.label = L"Quit";
  tray_menu_items_.push_back(std::move(quit_item));
}

bool FlutterWindow::EnsureTrayMenuWindowClass() {
  HINSTANCE instance = GetModuleHandle(nullptr);
  WNDCLASSEXW existing_class{};
  existing_class.cbSize = sizeof(existing_class);
  if (GetClassInfoExW(instance, kTrayMenuWindowClassName, &existing_class)) {
    return true;
  }

  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.style = CS_HREDRAW | CS_VREDRAW;
  window_class.lpfnWndProc = FlutterWindow::TrayMenuWindowProc;
  window_class.hInstance = instance;
  window_class.hCursor = GetTrayMenuArrowCursor();
  window_class.lpszClassName = kTrayMenuWindowClassName;

  return RegisterClassExW(&window_class) != 0 ||
         GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
}

void FlutterWindow::HideTrayMenu() {
  HideTraySubmenu();
  if (tray_menu_window_ == nullptr) {
    return;
  }

  HWND menu_window = tray_menu_window_;
  tray_menu_window_ = nullptr;
  tray_menu_hover_index_ = -1;
  tray_menu_scroll_offset_ = 0;
  tray_menu_content_height_ = 0;
  tray_menu_window_height_ = 0;
  if (GetCapture() == menu_window) {
    ReleaseCapture();
  }
  DestroyWindow(menu_window);
}

void FlutterWindow::HideTraySubmenu() {
  if (tray_submenu_window_ == nullptr) {
    tray_submenu_items_.clear();
    tray_submenu_parent_index_ = -1;
    tray_submenu_hover_index_ = -1;
    tray_submenu_scroll_offset_ = 0;
    tray_submenu_content_height_ = 0;
    tray_submenu_window_height_ = 0;
    return;
  }

  HWND submenu_window = tray_submenu_window_;
  tray_submenu_window_ = nullptr;
  tray_submenu_items_.clear();
  tray_submenu_parent_index_ = -1;
  tray_submenu_hover_index_ = -1;
  tray_submenu_scroll_offset_ = 0;
  tray_submenu_content_height_ = 0;
  tray_submenu_window_height_ = 0;
  DestroyWindow(submenu_window);
}

SIZE FlutterWindow::GetTrayMenuSize(const std::vector<TrayMenuItem>& items) {
  if (items.empty()) {
    return SIZE{ScaleTrayMenuMetric(kTrayMenuMinWidth),
                ScaleTrayMenuMetric(kTrayMenuVerticalPadding * 2)};
  }

  SIZE menu_size{};
  menu_size.cx = ScaleTrayMenuMetric(kTrayMenuMinWidth);
  menu_size.cy = ScaleTrayMenuMetric(kTrayMenuVerticalPadding * 2);

  IDWriteTextFormat* format =
      EnsureTrayDirectWrite() ? GetTrayMenuTextFormat() : nullptr;

  for (const TrayMenuItem& item : items) {
    if (item.separator) {
      menu_size.cy += ScaleTrayMenuMetric(kTrayMenuSeparatorHeight);
      continue;
    }

    menu_size.cy += ScaleTrayMenuMetric(kTrayMenuItemHeight);
    if (format == nullptr || item.label.empty()) {
      continue;
    }

    IDWriteTextLayout* layout = nullptr;
    if (FAILED(tray_dwrite_factory_->CreateTextLayout(
            item.label.c_str(), static_cast<UINT32>(item.label.size()), format,
            FLT_MAX, FLT_MAX, &layout)) ||
        layout == nullptr) {
      continue;
    }
    DWRITE_TEXT_METRICS metrics{};
    HRESULT hr = layout->GetMetrics(&metrics);
    layout->Release();
    if (FAILED(hr)) {
      continue;
    }

    const int text_width = static_cast<int>(
        std::ceil(metrics.widthIncludingTrailingWhitespace));
    const int flag_width =
        item.flag_path.empty()
            ? 0
            : ScaleTrayMenuMetric(kTrayMenuFlagWidth + kTrayMenuFlagGap);
    const int submenu_width =
        item.children.empty()
            ? 0
            : ScaleTrayMenuMetric(kTrayMenuSubmenuArrowWidth +
                                  kTrayMenuSubmenuArrowGap);
    menu_size.cx =
        std::max(menu_size.cx,
                 static_cast<LONG>(
                     text_width + flag_width + submenu_width +
                     ScaleTrayMenuMetric(kTrayMenuHorizontalPadding * 2 +
                                         item.indent)));
  }

  return menu_size;
}

RECT FlutterWindow::GetTrayMenuItemRect(
    const std::vector<TrayMenuItem>& items,
    int item_index,
    SIZE menu_size) {
  RECT rect{};
  if (item_index < 0 || item_index >= static_cast<int>(items.size())) {
    return rect;
  }

  LONG top = ScaleTrayMenuMetric(kTrayMenuVerticalPadding);
  for (int index = 0; index <= item_index; ++index) {
    const TrayMenuItem& item = items[index];
    const LONG height =
        ScaleTrayMenuMetric(item.separator ? kTrayMenuSeparatorHeight
                                           : kTrayMenuItemHeight);
    rect.left = 0;
    rect.top = top;
    rect.right = menu_size.cx;
    rect.bottom = top + height;
    top += height;
  }
  return rect;
}

int FlutterWindow::GetTrayMenuItemIndexAtPoint(
    const std::vector<TrayMenuItem>& items,
    POINT point,
    int scroll_offset) {
  const SIZE menu_size = GetTrayMenuSize(items);
  point.y += scroll_offset;
  RECT menu_rect{0, 0, menu_size.cx, menu_size.cy};
  if (!PtInRect(&menu_rect, point)) {
    return -1;
  }

  for (int index = 0; index < static_cast<int>(items.size()); ++index) {
    const TrayMenuItem& item = items[index];
    if (item.separator || !item.enabled) {
      continue;
    }

    RECT item_rect = GetTrayMenuItemRect(items, index, menu_size);
    if (PtInRect(&item_rect, point)) {
      return index;
    }
  }
  return -1;
}

bool FlutterWindow::IsPointInWindow(HWND window, POINT screen_point) {
  if (window == nullptr) {
    return false;
  }

  RECT window_rect{};
  return GetWindowRect(window, &window_rect) &&
         PtInRect(&window_rect, screen_point);
}

void FlutterWindow::ShowTraySubmenu(int parent_index) {
  if (tray_menu_window_ == nullptr || parent_index < 0 ||
      parent_index >= static_cast<int>(tray_menu_items_.size()) ||
      tray_menu_items_[parent_index].children.empty()) {
    HideTraySubmenu();
    return;
  }

  if (tray_submenu_window_ != nullptr &&
      tray_submenu_parent_index_ == parent_index) {
    return;
  }

  const std::vector<TrayMenuItem> submenu_items =
      tray_menu_items_[parent_index].children;
  HideTraySubmenu();
  tray_submenu_items_ = submenu_items;

  RECT menu_window_rect{};
  if (!GetWindowRect(tray_menu_window_, &menu_window_rect)) {
    HideTraySubmenu();
    return;
  }

  const SIZE content_size = GetTrayMenuSize(tray_submenu_items_);
  SIZE window_size = content_size;
  const SIZE main_content_size{
      menu_window_rect.right - menu_window_rect.left,
      tray_menu_content_height_ > 0
          ? tray_menu_content_height_
          : menu_window_rect.bottom - menu_window_rect.top};
  RECT parent_rect =
      GetTrayMenuItemRect(tray_menu_items_, parent_index, main_content_size);
  OffsetRect(&parent_rect, 0, -tray_menu_scroll_offset_);

  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  POINT anchor_point{menu_window_rect.right,
                     menu_window_rect.top + parent_rect.top};
  const bool has_monitor_info = GetMonitorInfoW(
      MonitorFromPoint(anchor_point, MONITOR_DEFAULTTONEAREST), &monitor_info);
  if (has_monitor_info) {
    const LONG available_height =
        std::max(ScaleTrayMenuMetric(kTrayMenuMinVisibleHeight),
                 static_cast<int>(monitor_info.rcWork.bottom -
                                  monitor_info.rcWork.top) -
                     ScaleTrayMenuMetric(kTrayMenuScrollMargin * 2));
    window_size.cy = std::min(content_size.cy, available_height);
  }

  POINT submenu_position{menu_window_rect.right - ScaleTrayMenuMetric(1),
                         menu_window_rect.top + parent_rect.top};
  if (has_monitor_info) {
    if (submenu_position.x + window_size.cx > monitor_info.rcWork.right) {
      submenu_position.x =
          menu_window_rect.left - window_size.cx + ScaleTrayMenuMetric(1);
    }
    if (submenu_position.x < monitor_info.rcWork.left) {
      submenu_position.x = monitor_info.rcWork.left;
    }
    if (submenu_position.y + window_size.cy > monitor_info.rcWork.bottom) {
      submenu_position.y = monitor_info.rcWork.bottom - window_size.cy;
    }
    if (submenu_position.y < monitor_info.rcWork.top) {
      submenu_position.y = monitor_info.rcWork.top;
    }
  }

  HWND submenu_window = CreateWindowExW(
      WS_EX_TOOLWINDOW | WS_EX_TOPMOST, kTrayMenuWindowClassName, L"",
      WS_POPUP, static_cast<int>(submenu_position.x),
      static_cast<int>(submenu_position.y), static_cast<int>(window_size.cx),
      static_cast<int>(window_size.cy), GetHandle(), nullptr,
      GetModuleHandle(nullptr), this);
  if (submenu_window == nullptr) {
    HideTraySubmenu();
    return;
  }

  tray_submenu_window_ = submenu_window;
  tray_submenu_parent_index_ = parent_index;
  tray_submenu_hover_index_ = -1;
  tray_submenu_scroll_offset_ = 0;
  tray_submenu_content_height_ = content_size.cy;
  tray_submenu_window_height_ = window_size.cy;

  if (!ApplyTrayMenuDwmRoundedCorners(submenu_window)) {
    const int corner_diameter = ScaleTrayMenuMetric(kTrayMenuCornerRadius * 2);
    HRGN submenu_region =
        CreateRoundRectRgn(0, 0, window_size.cx + 1, window_size.cy + 1,
                           corner_diameter, corner_diameter);
    if (submenu_region != nullptr &&
        SetWindowRgn(submenu_window, submenu_region, FALSE) == 0) {
      DeleteObject(submenu_region);
    }
  }

  ShowWindow(submenu_window, SW_SHOWNOACTIVATE);
  UpdateWindow(submenu_window);
}

bool FlutterWindow::GetTrayMenuItemAtCursor(TrayMenuItem* item) {
  if (item == nullptr) {
    return false;
  }

  POINT cursor_position{};
  GetCursorPos(&cursor_position);
  if (IsPointInWindow(tray_submenu_window_, cursor_position)) {
    POINT submenu_point = cursor_position;
    ScreenToClient(tray_submenu_window_, &submenu_point);
    const int item_index = GetTrayMenuItemIndexAtPoint(
        tray_submenu_items_, submenu_point, tray_submenu_scroll_offset_);
    if (item_index >= 0 &&
        item_index < static_cast<int>(tray_submenu_items_.size())) {
      *item = tray_submenu_items_[item_index];
      return true;
    }
  }

  if (IsPointInWindow(tray_menu_window_, cursor_position)) {
    POINT menu_point = cursor_position;
    ScreenToClient(tray_menu_window_, &menu_point);
    const int item_index = GetTrayMenuItemIndexAtPoint(
        tray_menu_items_, menu_point, tray_menu_scroll_offset_);
    if (item_index >= 0 &&
        item_index < static_cast<int>(tray_menu_items_.size())) {
      *item = tray_menu_items_[item_index];
      return true;
    }
  }

  return false;
}

void FlutterWindow::UpdateTrayMenuHoverFromCursor() {
  POINT cursor_position{};
  GetCursorPos(&cursor_position);

  if (IsPointInWindow(tray_submenu_window_, cursor_position)) {
    POINT submenu_point = cursor_position;
    ScreenToClient(tray_submenu_window_, &submenu_point);
    const int next_submenu_hover = GetTrayMenuItemIndexAtPoint(
        tray_submenu_items_, submenu_point, tray_submenu_scroll_offset_);
    if (next_submenu_hover != tray_submenu_hover_index_) {
      tray_submenu_hover_index_ = next_submenu_hover;
      InvalidateRect(tray_submenu_window_, nullptr, FALSE);
    }
    if (tray_submenu_parent_index_ != tray_menu_hover_index_) {
      tray_menu_hover_index_ = tray_submenu_parent_index_;
      InvalidateRect(tray_menu_window_, nullptr, FALSE);
    }
    return;
  }

  int next_menu_hover = -1;
  if (IsPointInWindow(tray_menu_window_, cursor_position)) {
    POINT menu_point = cursor_position;
    ScreenToClient(tray_menu_window_, &menu_point);
    next_menu_hover = GetTrayMenuItemIndexAtPoint(
        tray_menu_items_, menu_point, tray_menu_scroll_offset_);
  }

  if (next_menu_hover != tray_menu_hover_index_) {
    tray_menu_hover_index_ = next_menu_hover;
    InvalidateRect(tray_menu_window_, nullptr, FALSE);
  }

  if (next_menu_hover >= 0 &&
      next_menu_hover < static_cast<int>(tray_menu_items_.size()) &&
      !tray_menu_items_[next_menu_hover].children.empty()) {
    ShowTraySubmenu(next_menu_hover);
  } else {
    HideTraySubmenu();
  }
}

void FlutterWindow::PaintTrayMenu(HWND menu_window,
                                  const std::vector<TrayMenuItem>& items,
                                  int hover_index,
                                  int scroll_offset,
                                  int content_height) {
  PAINTSTRUCT paint{};
  HDC window_hdc = BeginPaint(menu_window, &paint);
  if (window_hdc == nullptr) {
    return;
  }

  RECT client_rect{};
  GetClientRect(menu_window, &client_rect);
  const int client_width = client_rect.right - client_rect.left;
  const int client_height = client_rect.bottom - client_rect.top;

  HDC buffer_hdc = nullptr;
  HBITMAP buffer_bitmap = nullptr;
  HGDIOBJ old_buffer_bitmap = nullptr;
  HDC hdc = window_hdc;

  if (client_width > 0 && client_height > 0) {
    buffer_hdc = CreateCompatibleDC(window_hdc);
    if (buffer_hdc != nullptr) {
      buffer_bitmap =
          CreateCompatibleBitmap(window_hdc, client_width, client_height);
      if (buffer_bitmap != nullptr) {
        old_buffer_bitmap = SelectObject(buffer_hdc, buffer_bitmap);
        hdc = buffer_hdc;
      } else {
        DeleteDC(buffer_hdc);
        buffer_hdc = nullptr;
      }
    }
  }

  HBRUSH background_brush = CreateSolidBrush(kTrayMenuBackgroundColor);
  if (background_brush != nullptr) {
    FillRect(hdc, &client_rect, background_brush);
    DeleteObject(background_brush);
  }

  const SIZE content_size{client_rect.right - client_rect.left,
                          content_height > 0
                              ? content_height
                              : client_rect.bottom - client_rect.top};
  std::unique_ptr<Gdiplus::Graphics> graphics;

  struct TrayMenuTextDraw {
    RECT rect;
    std::wstring label;
    bool enabled;
  };
  struct TrayMenuArrowDraw {
    D2D1_POINT_2F top;
    D2D1_POINT_2F tip;
    D2D1_POINT_2F bottom;
  };
  std::vector<TrayMenuTextDraw> text_commands;
  std::vector<TrayMenuArrowDraw> arrow_commands;
  text_commands.reserve(items.size());

  const int separator_half_strip =
      ScaleTrayMenuMetric(kTrayMenuSeparatorHeight) / 2;

  for (int index = 0; index < static_cast<int>(items.size()); ++index) {
    const TrayMenuItem& item = items[index];
    if (item.separator || (!item.selected && index != hover_index)) {
      continue;
    }
    RECT item_rect = GetTrayMenuItemRect(items, index, content_size);
    OffsetRect(&item_rect, 0, -scroll_offset);
    if (item_rect.bottom < client_rect.top ||
        item_rect.top > client_rect.bottom) {
      continue;
    }

    const COLORREF row_color = index == hover_index ? kTrayMenuSelectedColor
                                                    : kTrayMenuCheckedColor;
    HBRUSH row_brush = CreateSolidBrush(row_color);
    if (row_brush == nullptr) {
      continue;
    }
    RECT fill_rect = item_rect;
    if (index > 0 && items[index - 1].separator) {
      fill_rect.top -= separator_half_strip;
    }
    if (index + 1 < static_cast<int>(items.size()) &&
        items[index + 1].separator) {
      fill_rect.bottom += separator_half_strip;
    }
    fill_rect.right += ScaleTrayMenuMetric(1);
    fill_rect.bottom += ScaleTrayMenuMetric(1);
    FillRect(hdc, &fill_rect, row_brush);
    DeleteObject(row_brush);
  }

  for (int index = 0; index < static_cast<int>(items.size()); ++index) {
    const TrayMenuItem& item = items[index];
    RECT item_rect = GetTrayMenuItemRect(items, index, content_size);
    OffsetRect(&item_rect, 0, -scroll_offset);
    if (item_rect.bottom < client_rect.top || item_rect.top > client_rect.bottom) {
      continue;
    }

    if (item.separator) {
      const int line_y =
          item_rect.top + (item_rect.bottom - item_rect.top) / 2;
      HPEN separator_pen =
          CreatePen(PS_SOLID, ScaleTrayMenuMetric(1), kTrayMenuSeparatorColor);
      if (separator_pen != nullptr) {
        HGDIOBJ old_pen = SelectObject(hdc, separator_pen);
        MoveToEx(hdc, item_rect.left, line_y, nullptr);
        LineTo(hdc, item_rect.right, line_y);
        if (old_pen != nullptr) {
          SelectObject(hdc, old_pen);
        }
        DeleteObject(separator_pen);
      }
      continue;
    }

    RECT text_rect = item_rect;
    const int horizontal_padding =
        ScaleTrayMenuMetric(kTrayMenuHorizontalPadding);
    const int indent = ScaleTrayMenuMetric(item.indent);
    text_rect.left += horizontal_padding + indent;
    text_rect.right -= horizontal_padding;
    if (!item.children.empty()) {
      text_rect.right -= ScaleTrayMenuMetric(kTrayMenuSubmenuArrowWidth +
                                             kTrayMenuSubmenuArrowGap);
    }

    if (!item.flag_path.empty()) {
      const int flag_width = ScaleTrayMenuMetric(kTrayMenuFlagWidth);
      const int flag_height = ScaleTrayMenuMetric(kTrayMenuFlagHeight);
      const int flag_gap = ScaleTrayMenuMetric(kTrayMenuFlagGap);
      const int flag_y =
          item_rect.top + (item_rect.bottom - item_rect.top - flag_height) / 2;
      Gdiplus::Image* flag_image = GetTrayFlagImage(item.flag_path);
      if (flag_image != nullptr) {
        if (!graphics) {
          graphics = std::make_unique<Gdiplus::Graphics>(hdc);
          graphics->SetInterpolationMode(
              Gdiplus::InterpolationModeHighQualityBicubic);
          graphics->SetPixelOffsetMode(Gdiplus::PixelOffsetModeHalf);
        }
        graphics->DrawImage(flag_image, text_rect.left, flag_y, flag_width,
                            flag_height);
      }
      text_rect.left += flag_width + flag_gap;
    }

    text_commands.push_back({text_rect, item.label, item.enabled});

    if (!item.children.empty()) {
      const int arrow_width = ScaleTrayMenuMetric(kTrayMenuSubmenuArrowWidth);
      const int arrow_height = ScaleTrayMenuMetric(kTrayMenuSubmenuArrowWidth);
      const float half_w = static_cast<float>(arrow_width) / 2.0f;
      const float half_h = static_cast<float>(arrow_height) / 2.0f;
      const float arrow_center_x = static_cast<float>(
          item_rect.right - horizontal_padding) - half_w;
      const float arrow_center_y = static_cast<float>(
          item_rect.top + (item_rect.bottom - item_rect.top) / 2);
      arrow_commands.push_back(TrayMenuArrowDraw{
          D2D1::Point2F(arrow_center_x - half_w, arrow_center_y - half_h),
          D2D1::Point2F(arrow_center_x + half_w, arrow_center_y),
          D2D1::Point2F(arrow_center_x - half_w, arrow_center_y + half_h)});
    }
  }

  graphics.reset();

  if ((!text_commands.empty() || !arrow_commands.empty()) &&
      EnsureTrayDirectWrite() && EnsureTrayDCRenderTarget()) {
    IDWriteTextFormat* format = GetTrayMenuTextFormat();
    if (format != nullptr) {
      const RECT bind_rect{0, 0, client_width, client_height};
      if (SUCCEEDED(tray_dc_render_target_->BindDC(hdc, &bind_rect))) {
        const auto color_to_d2d = [](COLORREF c) {
          return D2D1::ColorF(
              static_cast<int>(GetRValue(c)) / 255.0f,
              static_cast<int>(GetGValue(c)) / 255.0f,
              static_cast<int>(GetBValue(c)) / 255.0f, 1.0f);
        };
        if (tray_text_brush_enabled_ == nullptr) {
          tray_dc_render_target_->CreateSolidColorBrush(
              color_to_d2d(kTrayMenuTextColor), &tray_text_brush_enabled_);
        }
        if (tray_text_brush_disabled_ == nullptr) {
          tray_dc_render_target_->CreateSolidColorBrush(
              color_to_d2d(kTrayMenuDisabledTextColor),
              &tray_text_brush_disabled_);
        }

        if (tray_text_brush_enabled_ != nullptr &&
            tray_text_brush_disabled_ != nullptr) {
          tray_dc_render_target_->BeginDraw();
          tray_dc_render_target_->SetTransform(D2D1::Matrix3x2F::Identity());

          for (const TrayMenuTextDraw& cmd : text_commands) {
            const D2D1_RECT_F layout_rect = D2D1::RectF(
                static_cast<float>(cmd.rect.left),
                static_cast<float>(cmd.rect.top),
                static_cast<float>(cmd.rect.right),
                static_cast<float>(cmd.rect.bottom));
            ID2D1SolidColorBrush* brush = cmd.enabled
                                              ? tray_text_brush_enabled_
                                              : tray_text_brush_disabled_;
            tray_dc_render_target_->DrawTextW(
                cmd.label.c_str(), static_cast<UINT32>(cmd.label.size()),
                format, layout_rect, brush,
                D2D1_DRAW_TEXT_OPTIONS_CLIP |
                    D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
          }

          const float arrow_stroke =
              static_cast<float>(ScaleTrayMenuMetric(1));
          for (const TrayMenuArrowDraw& arrow : arrow_commands) {
            tray_dc_render_target_->DrawLine(arrow.top, arrow.tip,
                                             tray_text_brush_enabled_,
                                             arrow_stroke);
            tray_dc_render_target_->DrawLine(arrow.tip, arrow.bottom,
                                             tray_text_brush_enabled_,
                                             arrow_stroke);
          }

          if (tray_dc_render_target_->EndDraw() == D2DERR_RECREATE_TARGET) {
            ReleaseTrayDCRenderTargetResources();
          }
        }
      }
    }
  }

  if (buffer_hdc != nullptr && buffer_bitmap != nullptr) {
    BitBlt(window_hdc, 0, 0, client_width, client_height, buffer_hdc, 0, 0,
           SRCCOPY);
    if (old_buffer_bitmap != nullptr) {
      SelectObject(buffer_hdc, old_buffer_bitmap);
    }
    DeleteObject(buffer_bitmap);
    DeleteDC(buffer_hdc);
  }
  EndPaint(menu_window, &paint);
}

bool FlutterWindow::EnsureTrayGdiplus() {
  if (tray_gdiplus_token_ != 0) {
    return true;
  }

  Gdiplus::GdiplusStartupInput startup_input;
  return Gdiplus::GdiplusStartup(&tray_gdiplus_token_, &startup_input,
                                 nullptr) == Gdiplus::Ok;
}

Gdiplus::Image* FlutterWindow::GetTrayFlagImage(
    const std::wstring& flag_path) {
  if (flag_path.empty()) {
    return nullptr;
  }

  const auto cached = tray_flag_images_.find(flag_path);
  if (cached != tray_flag_images_.end()) {
    return cached->second.get();
  }

  if (!EnsureTrayGdiplus()) {
    return nullptr;
  }

  auto image = std::make_unique<Gdiplus::Image>(flag_path.c_str());
  if (image->GetLastStatus() != Gdiplus::Ok) {
    return nullptr;
  }

  Gdiplus::Image* result = image.get();
  tray_flag_images_[flag_path] = std::move(image);
  return result;
}

void FlutterWindow::InvokeTrayMenuItem(const TrayMenuItem& item) {
  switch (item.command_id) {
    case kTrayOpenCommand:
      ShowWindowFromTray();
      return;
    case kTrayQuitCommand:
      QuitFromTray();
      return;
  }

  if (!item.token.empty() && tray_channel_) {
    tray_channel_->InvokeMethod(
        kSelectTrayMenuItemMethod,
        std::make_unique<flutter::EncodableValue>(item.token));
  }
}

LRESULT FlutterWindow::TrayMenuMessageHandler(HWND window, UINT const message,
                                              WPARAM const wparam,
                                              LPARAM const lparam) noexcept {
  switch (message) {
    case WM_NCHITTEST:
      return HTCLIENT;

    case WM_SETCURSOR:
      SetTrayMenuArrowCursor();
      return TRUE;

    case WM_NCMOUSEMOVE:
      SetTrayMenuArrowCursor();
      return 0;

    case WM_ERASEBKGND:
      return 1;

    case WM_PAINT:
      if (window == tray_submenu_window_) {
        PaintTrayMenu(window, tray_submenu_items_, tray_submenu_hover_index_,
                      tray_submenu_scroll_offset_,
                      tray_submenu_content_height_);
      } else {
        PaintTrayMenu(window, tray_menu_items_, tray_menu_hover_index_,
                      tray_menu_scroll_offset_, tray_menu_content_height_);
      }
      return 0;

    case WM_MOUSEMOVE: {
      SetTrayMenuArrowCursor();
      UpdateTrayMenuHoverFromCursor();
      return 0;
    }

    case WM_MOUSEWHEEL: {
      SetTrayMenuArrowCursor();
      POINT cursor_position{};
      GetCursorPos(&cursor_position);
      const bool over_submenu =
          IsPointInWindow(tray_submenu_window_, cursor_position);
      int& scroll_offset =
          over_submenu ? tray_submenu_scroll_offset_ : tray_menu_scroll_offset_;
      const int content_height =
          over_submenu ? tray_submenu_content_height_ : tray_menu_content_height_;
      const int window_height =
          over_submenu ? tray_submenu_window_height_ : tray_menu_window_height_;
      HWND scroll_window = over_submenu ? tray_submenu_window_ : tray_menu_window_;
      const int max_scroll = std::max(0, content_height - window_height);
      if (max_scroll <= 0) {
        return 0;
      }

      const int wheel_delta = GET_WHEEL_DELTA_WPARAM(wparam);
      const int scroll_step = ScaleTrayMenuMetric(kTrayMenuItemHeight);
      const int next_scroll = std::clamp(
          scroll_offset - MulDiv(wheel_delta, scroll_step, WHEEL_DELTA),
          0, max_scroll);
      if (next_scroll != scroll_offset) {
        scroll_offset = next_scroll;
        UpdateTrayMenuHoverFromCursor();
        InvalidateRect(scroll_window, nullptr, FALSE);
      }
      return 0;
    }

    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN:
      SetTrayMenuArrowCursor();
      return 0;

    case WM_LBUTTONUP: {
      SetTrayMenuArrowCursor();
      TrayMenuItem item;
      const bool has_item = GetTrayMenuItemAtCursor(&item);
      const bool dismiss_menu = !has_item ||
                                item.command_id == kTrayOpenCommand ||
                                item.command_id == kTrayQuitCommand;
      if (dismiss_menu) {
        HideTrayMenu();
      }
      if (has_item && (item.command_id != 0 || !item.token.empty())) {
        InvokeTrayMenuItem(item);
      }
      return 0;
    }

    case WM_RBUTTONUP:
    case WM_MBUTTONUP:
    case WM_CANCELMODE:
      HideTrayMenu();
      return 0;

    case WM_KEYDOWN:
      if (wparam == VK_ESCAPE) {
        HideTrayMenu();
        return 0;
      }
      if ((wparam == VK_RETURN || wparam == VK_SPACE) &&
          ((tray_submenu_hover_index_ >= 0 &&
            tray_submenu_hover_index_ <
                static_cast<int>(tray_submenu_items_.size())) ||
           (tray_menu_hover_index_ >= 0 &&
            tray_menu_hover_index_ < static_cast<int>(tray_menu_items_.size())))) {
        const TrayMenuItem item =
            tray_submenu_hover_index_ >= 0
                ? tray_submenu_items_[tray_submenu_hover_index_]
                : tray_menu_items_[tray_menu_hover_index_];
        const bool dismiss_menu = item.command_id == kTrayOpenCommand ||
                                  item.command_id == kTrayQuitCommand;
        if (dismiss_menu) {
          HideTrayMenu();
        }
        if (item.command_id != 0 || !item.token.empty()) {
          InvokeTrayMenuItem(item);
        }
        return 0;
      }
      break;

    case WM_KILLFOCUS:
      HideTrayMenu();
      return 0;

    case WM_NCDESTROY:
      if (GetCapture() == window) {
        ReleaseCapture();
      }
      if (tray_menu_window_ == window) {
        HideTraySubmenu();
        tray_menu_window_ = nullptr;
        tray_menu_hover_index_ = -1;
        tray_menu_scroll_offset_ = 0;
        tray_menu_content_height_ = 0;
        tray_menu_window_height_ = 0;
      }
      if (tray_submenu_window_ == window) {
        tray_submenu_window_ = nullptr;
        tray_submenu_items_.clear();
        tray_submenu_parent_index_ = -1;
        tray_submenu_hover_index_ = -1;
        tray_submenu_scroll_offset_ = 0;
        tray_submenu_content_height_ = 0;
        tray_submenu_window_height_ = 0;
      }
      SetWindowLongPtr(window, GWLP_USERDATA, 0);
      break;
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT CALLBACK FlutterWindow::TrayMenuWindowProc(
    HWND window,
    UINT const message,
    WPARAM const wparam,
    LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto create_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    auto that = static_cast<FlutterWindow*>(create_struct->lpCreateParams);
    SetWindowLongPtr(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(that));
    return TRUE;
  }

  auto that =
      reinterpret_cast<FlutterWindow*>(GetWindowLongPtr(window, GWLP_USERDATA));
  if (that != nullptr) {
    return that->TrayMenuMessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

void FlutterWindow::ReleaseTrayMenuResources() {
  HideTrayMenu();

  ReleaseTrayDCRenderTargetResources();
  if (tray_dwrite_text_format_ != nullptr) {
    tray_dwrite_text_format_->Release();
    tray_dwrite_text_format_ = nullptr;
  }
  tray_dwrite_text_format_dpi_ = 0;
  if (tray_dwrite_fallback_ != nullptr) {
    tray_dwrite_fallback_->Release();
    tray_dwrite_fallback_ = nullptr;
  }
  if (tray_dwrite_collection_ != nullptr) {
    tray_dwrite_collection_->Release();
    tray_dwrite_collection_ = nullptr;
  }
  if (tray_dwrite_factory_ != nullptr) {
    tray_dwrite_factory_->Release();
    tray_dwrite_factory_ = nullptr;
  }
  if (tray_d2d_factory_ != nullptr) {
    tray_d2d_factory_->Release();
    tray_d2d_factory_ = nullptr;
  }
  tray_dwrite_init_failed_ = false;

  tray_flag_images_.clear();
  if (tray_gdiplus_token_ != 0) {
    Gdiplus::GdiplusShutdown(tray_gdiplus_token_);
    tray_gdiplus_token_ = 0;
  }
}

void FlutterWindow::ShowTrayMenu() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }

  HideTrayMenu();
  if (!EnsureTrayMenuWindowClass()) {
    return;
  }
  RebuildTrayMenuItems();

  POINT cursor_position{};
  GetCursorPos(&cursor_position);
  const SIZE content_size = GetTrayMenuSize(tray_menu_items_);
  SIZE window_size = content_size;

  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  const bool has_monitor_info = GetMonitorInfoW(
      MonitorFromPoint(cursor_position, MONITOR_DEFAULTTONEAREST),
      &monitor_info);
  if (has_monitor_info) {
    const LONG available_height =
        std::max(ScaleTrayMenuMetric(kTrayMenuMinVisibleHeight),
                 static_cast<int>(monitor_info.rcWork.bottom -
                                  monitor_info.rcWork.top) -
                     ScaleTrayMenuMetric(kTrayMenuScrollMargin * 2));
    window_size.cy = std::min(content_size.cy, available_height);
  }

  POINT menu_position{cursor_position.x, cursor_position.y - window_size.cy};
  if (has_monitor_info) {
    if (menu_position.x + window_size.cx > monitor_info.rcWork.right) {
      menu_position.x = monitor_info.rcWork.right - window_size.cx;
    }
    if (menu_position.x < monitor_info.rcWork.left) {
      menu_position.x = monitor_info.rcWork.left;
    }
    if (menu_position.y < monitor_info.rcWork.top) {
      menu_position.y = cursor_position.y;
    }
    if (menu_position.y + window_size.cy > monitor_info.rcWork.bottom) {
      menu_position.y = monitor_info.rcWork.bottom - window_size.cy;
    }
  }

  HWND menu_window = CreateWindowExW(
      WS_EX_TOOLWINDOW | WS_EX_TOPMOST, kTrayMenuWindowClassName, L"",
      WS_POPUP, static_cast<int>(menu_position.x),
      static_cast<int>(menu_position.y), static_cast<int>(window_size.cx),
      static_cast<int>(window_size.cy), hwnd, nullptr, GetModuleHandle(nullptr),
      this);
  if (menu_window == nullptr) {
    return;
  }

  tray_menu_window_ = menu_window;
  tray_menu_hover_index_ = -1;
  tray_menu_scroll_offset_ = 0;
  tray_menu_content_height_ = content_size.cy;
  tray_menu_window_height_ = window_size.cy;

  if (!ApplyTrayMenuDwmRoundedCorners(menu_window)) {
    const int corner_diameter = ScaleTrayMenuMetric(kTrayMenuCornerRadius * 2);
    HRGN menu_region =
        CreateRoundRectRgn(0, 0, window_size.cx + 1, window_size.cy + 1,
                           corner_diameter, corner_diameter);
    if (menu_region != nullptr &&
        SetWindowRgn(menu_window, menu_region, FALSE) == 0) {
      DeleteObject(menu_region);
    }
  }

  ShowWindow(menu_window, SW_SHOWNORMAL);
  SetForegroundWindow(menu_window);
  SetFocus(menu_window);
  SetCapture(menu_window);
  SetTrayMenuArrowCursor();
  UpdateWindow(menu_window);
  PostMessage(hwnd, WM_NULL, 0, 0);
}

void FlutterWindow::ShowWindowFromTray() {
  HideTrayMenu();
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }

  ShowWindow(hwnd, IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(hwnd);
}

void FlutterWindow::HideWindowToTray() {
  HideTrayMenu();
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }

  ShowWindow(hwnd, SW_HIDE);
}

void FlutterWindow::QuitFromTray() {
  HideTrayMenu();
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  if (is_quitting_) {
    return;
  }

  is_quitting_ = true;
  RemoveTrayIcon();
  HideWindowToTray();
  if (!lifecycle_channel_) {
    FinishQuit();
    return;
  }

  auto result_handler =
      std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue* result) { FinishQuit(); },
          [this](const std::string& error_code,
                 const std::string& error_message,
                 const flutter::EncodableValue* error_details) {
            FinishQuit();
          },
          [this]() { FinishQuit(); });

  lifecycle_channel_->InvokeMethod("quit", nullptr, std::move(result_handler));
}

void FlutterWindow::FinishQuit() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }

  RemoveTrayIcon();
  DestroyWindow(hwnd);
}
