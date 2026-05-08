#include "flutter_window.h"

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <optional>
#include <shellapi.h>

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

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

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
  windows_tun_channel_ = nullptr;
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

void FlutterWindow::ShowTrayMenu() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }

  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }

  AppendMenuW(menu, MF_STRING, kTrayOpenCommand, L"Open EntropyVPN");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayQuitCommand, L"Quit EntropyVPN");

  POINT cursor_position{};
  GetCursorPos(&cursor_position);

  SetForegroundWindow(hwnd);
  TrackPopupMenu(menu, TPM_BOTTOMALIGN | TPM_LEFTALIGN, cursor_position.x,
                 cursor_position.y, 0, hwnd, nullptr);
  DestroyMenu(menu);
  PostMessage(hwnd, WM_NULL, 0, 0);
}

void FlutterWindow::ShowWindowFromTray() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }

  ShowWindow(hwnd, IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(hwnd);
}

void FlutterWindow::HideWindowToTray() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }

  ShowWindow(hwnd, SW_HIDE);
}

void FlutterWindow::QuitFromTray() {
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
