#include "flutter_window.h"

#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cwchar>
#include <optional>
#include <shellapi.h>
#include <string>
#include <utility>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
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
constexpr wchar_t kTrayMenuFallbackFontFamily[] = L"Segoe UI";
constexpr wchar_t kTrayMenuFontAssetPath[] =
    L"data\\flutter_assets\\assets\\fonts\\GolosText-Variable.ttf";
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
  windows_tun_channel_ =
      CreateWindowsTunChannel(flutter_controller_->engine()->messenger());
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

HFONT FlutterWindow::GetTrayMenuFont() {
  if (!tray_menu_font_resource_initialized_) {
    tray_menu_font_resource_initialized_ = true;
    const std::wstring font_path = GetTrayMenuFontPath();
    if (!font_path.empty() &&
        GetFileAttributesW(font_path.c_str()) != INVALID_FILE_ATTRIBUTES &&
        AddFontResourceExW(font_path.c_str(), FR_PRIVATE, nullptr) > 0) {
      tray_menu_font_resource_path_ = font_path;
    }
  }

  const UINT dpi = GetTrayMenuDpi();
  if (tray_menu_font_ != nullptr && tray_menu_font_dpi_ == dpi) {
    return tray_menu_font_;
  }

  if (tray_menu_font_ != nullptr) {
    DeleteObject(tray_menu_font_);
    tray_menu_font_ = nullptr;
  }

  tray_menu_font_dpi_ = dpi;
  const int font_height =
      -MulDiv(kTrayMenuFontPointSize, static_cast<int>(dpi), 72);
  tray_menu_font_ =
      CreateFontW(font_height, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                  DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                  CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
                  kTrayMenuFontFamily);
  if (tray_menu_font_ == nullptr) {
    tray_menu_font_ =
        CreateFontW(font_height, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                    DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                    CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
                    kTrayMenuFallbackFontFamily);
  }

  return tray_menu_font_;
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
  RebuildTrayMenuItems();
  HideTrayMenu();
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

  HDC hdc = GetDC(GetHandle());
  HFONT font = GetTrayMenuFont();
  HGDIOBJ old_font = nullptr;
  if (hdc != nullptr && font != nullptr) {
    old_font = SelectObject(hdc, font);
  }

  for (const TrayMenuItem& item : items) {
    if (item.separator) {
      menu_size.cy += ScaleTrayMenuMetric(kTrayMenuSeparatorHeight);
      continue;
    }

    menu_size.cy += ScaleTrayMenuMetric(kTrayMenuItemHeight);
    if (hdc == nullptr || item.label.empty()) {
      continue;
    }

    SIZE text_size{};
    if (GetTextExtentPoint32W(hdc, item.label.c_str(),
                              static_cast<int>(item.label.size()),
                              &text_size)) {
      const int flag_width = item.flag_path.empty()
                                 ? 0
                                 : ScaleTrayMenuMetric(kTrayMenuFlagWidth +
                                                       kTrayMenuFlagGap);
      const int submenu_width =
          item.children.empty()
              ? 0
              : ScaleTrayMenuMetric(kTrayMenuSubmenuArrowWidth +
                                    kTrayMenuSubmenuArrowGap);
      menu_size.cx =
          std::max(menu_size.cx,
                   static_cast<LONG>(
                       static_cast<int>(text_size.cx) + flag_width +
                       submenu_width +
                       ScaleTrayMenuMetric(kTrayMenuHorizontalPadding * 2 +
                                           item.indent)));
    }
  }

  if (old_font != nullptr) {
    SelectObject(hdc, old_font);
  }
  if (hdc != nullptr) {
    ReleaseDC(GetHandle(), hdc);
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

  const int corner_diameter = ScaleTrayMenuMetric(kTrayMenuCornerRadius * 2);
  HRGN submenu_region =
      CreateRoundRectRgn(0, 0, window_size.cx + 1, window_size.cy + 1,
                         corner_diameter, corner_diameter);
  if (submenu_region != nullptr &&
      SetWindowRgn(submenu_window, submenu_region, FALSE) == 0) {
    DeleteObject(submenu_region);
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

  HFONT font = GetTrayMenuFont();
  HGDIOBJ old_font = nullptr;
  if (font != nullptr) {
    old_font = SelectObject(hdc, font);
  }
  const int old_background_mode = SetBkMode(hdc, TRANSPARENT);
  const COLORREF old_text_color = GetTextColor(hdc);
  const SIZE content_size{client_rect.right - client_rect.left,
                          content_height > 0
                              ? content_height
                              : client_rect.bottom - client_rect.top};
  std::unique_ptr<Gdiplus::Graphics> graphics;

  for (int index = 0; index < static_cast<int>(items.size()); ++index) {
    const TrayMenuItem& item = items[index];
    RECT item_rect = GetTrayMenuItemRect(items, index, content_size);
    OffsetRect(&item_rect, 0, -scroll_offset);
    if (item_rect.bottom < client_rect.top || item_rect.top > client_rect.bottom) {
      continue;
    }

    if (!item.separator && (item.selected || index == hover_index)) {
      const COLORREF row_color =
          index == hover_index ? kTrayMenuSelectedColor
                               : kTrayMenuCheckedColor;
      HBRUSH row_brush = CreateSolidBrush(row_color);
      if (row_brush != nullptr) {
        RECT fill_rect = item_rect;
        fill_rect.right += ScaleTrayMenuMetric(1);
        fill_rect.bottom += ScaleTrayMenuMetric(1);
        FillRect(hdc, &fill_rect, row_brush);
        DeleteObject(row_brush);
      }
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

    SetTextColor(hdc, item.enabled ? kTrayMenuTextColor
                                   : kTrayMenuDisabledTextColor);
    DrawTextW(hdc, item.label.c_str(), -1, &text_rect,
              DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_NOPREFIX |
                  DT_END_ELLIPSIS);

    if (!item.children.empty()) {
      const int arrow_width = ScaleTrayMenuMetric(kTrayMenuSubmenuArrowWidth);
      const int arrow_height = ScaleTrayMenuMetric(kTrayMenuSubmenuArrowWidth);
      const int arrow_center_x =
          item_rect.right - horizontal_padding - arrow_width / 2;
      const int arrow_center_y =
          item_rect.top + (item_rect.bottom - item_rect.top) / 2;
      HPEN arrow_pen =
          CreatePen(PS_SOLID, ScaleTrayMenuMetric(1), kTrayMenuTextColor);
      if (arrow_pen != nullptr) {
        HGDIOBJ old_pen = SelectObject(hdc, arrow_pen);
        MoveToEx(hdc, arrow_center_x - arrow_width / 2,
                 arrow_center_y - arrow_height / 2, nullptr);
        LineTo(hdc, arrow_center_x + arrow_width / 2, arrow_center_y);
        LineTo(hdc, arrow_center_x - arrow_width / 2,
               arrow_center_y + arrow_height / 2);
        if (old_pen != nullptr) {
          SelectObject(hdc, old_pen);
        }
        DeleteObject(arrow_pen);
      }
    }
  }

  graphics.reset();
  SetTextColor(hdc, old_text_color);
  SetBkMode(hdc, old_background_mode);
  if (old_font != nullptr) {
    SelectObject(hdc, old_font);
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
      HideTrayMenu();
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
        HideTrayMenu();
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

  tray_flag_images_.clear();
  if (tray_gdiplus_token_ != 0) {
    Gdiplus::GdiplusShutdown(tray_gdiplus_token_);
    tray_gdiplus_token_ = 0;
  }

  if (tray_menu_font_ != nullptr) {
    DeleteObject(tray_menu_font_);
    tray_menu_font_ = nullptr;
  }
  tray_menu_font_dpi_ = 0;

  if (!tray_menu_font_resource_path_.empty()) {
    RemoveFontResourceExW(tray_menu_font_resource_path_.c_str(), FR_PRIVATE,
                          nullptr);
    tray_menu_font_resource_path_.clear();
  }
  tray_menu_font_resource_initialized_ = false;
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

  const int corner_diameter = ScaleTrayMenuMetric(kTrayMenuCornerRadius * 2);
  HRGN menu_region =
      CreateRoundRectRgn(0, 0, window_size.cx + 1, window_size.cy + 1,
                         corner_diameter, corner_diameter);
  if (menu_region != nullptr &&
      SetWindowRgn(menu_window, menu_region, FALSE) == 0) {
    DeleteObject(menu_region);
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
