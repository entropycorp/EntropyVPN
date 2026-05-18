#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/event_channel.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include "win32_window.h"

#include <d2d1.h>
#include <dwrite_3.h>
#include <gdiplus.h>
#include <map>
#include <memory>
#include <string>
#include <vector>


class FlutterWindow : public Win32Window {
 public:

  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:

  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  struct TrayMenuItem {
    UINT_PTR command_id = 0;
    std::wstring label;
    std::wstring flag_path;
    std::string token;
    bool separator = false;
    bool selected = false;
    bool enabled = true;
    int indent = 0;
    std::vector<TrayMenuItem> children;
  };

  void AddTrayIcon();
  void RemoveTrayIcon();
  void ShowTrayMenu();
  void ShowWindowFromTray();
  void HideWindowToTray();
  void QuitFromTray();
  void FinishQuit();
  UINT GetTrayMenuDpi();
  int ScaleTrayMenuMetric(int value);
  void ConfigureTrayChannel();
  bool ReadTrayMenuItem(const flutter::EncodableMap& map, TrayMenuItem* item);
  void UpdateTraySwitchItems(const flutter::EncodableValue* arguments);
  void RebuildTrayMenuItems();
  bool EnsureTrayMenuWindowClass();
  void HideTrayMenu();
  void HideTraySubmenu();
  void ShowTraySubmenu(int parent_index);
  bool IsPointInWindow(HWND window, POINT screen_point);
  bool GetTrayMenuItemAtCursor(TrayMenuItem* item);
  void UpdateTrayMenuHoverFromCursor();
  SIZE GetTrayMenuSize(const std::vector<TrayMenuItem>& items);
  RECT GetTrayMenuItemRect(const std::vector<TrayMenuItem>& items,
                           int item_index, SIZE menu_size);
  int GetTrayMenuItemIndexAtPoint(const std::vector<TrayMenuItem>& items,
                                  POINT point, int scroll_offset);
  void PaintTrayMenu(HWND menu_window, const std::vector<TrayMenuItem>& items,
                     int hover_index, int scroll_offset, int content_height);
  bool EnsureTrayDirectWrite();
  bool EnsureTrayDCRenderTarget();
  IDWriteTextFormat* GetTrayMenuTextFormat();
  void ReleaseTrayDCRenderTargetResources();
  bool EnsureTrayGdiplus();
  Gdiplus::Image* GetTrayFlagImage(const std::wstring& flag_path);
  void InvokeTrayMenuItem(const TrayMenuItem& item);
  LRESULT TrayMenuMessageHandler(HWND window, UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept;
  static LRESULT CALLBACK TrayMenuWindowProc(HWND window, UINT const message,
                                             WPARAM const wparam,
                                             LPARAM const lparam) noexcept;
  void ReleaseTrayMenuResources();

  flutter::DartProject project_;


  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      lifecycle_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      windows_app_catalog_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      windows_tun_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      windows_runtime_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      windows_runtime_events_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      tray_channel_;
  std::vector<TrayMenuItem> tray_switch_items_;
  std::vector<TrayMenuItem> tray_menu_items_;
  ID2D1Factory* tray_d2d_factory_ = nullptr;
  IDWriteFactory* tray_dwrite_factory_ = nullptr;
  IDWriteFontCollection* tray_dwrite_collection_ = nullptr;
  IDWriteFontFallback* tray_dwrite_fallback_ = nullptr;
  IDWriteTextFormat* tray_dwrite_text_format_ = nullptr;
  UINT tray_dwrite_text_format_dpi_ = 0;
  ID2D1DCRenderTarget* tray_dc_render_target_ = nullptr;
  ID2D1SolidColorBrush* tray_text_brush_enabled_ = nullptr;
  ID2D1SolidColorBrush* tray_text_brush_disabled_ = nullptr;
  bool tray_dwrite_init_failed_ = false;
  ULONG_PTR tray_gdiplus_token_ = 0;
  std::map<std::wstring, std::unique_ptr<Gdiplus::Image>> tray_flag_images_;
  HWND tray_menu_window_ = nullptr;
  int tray_menu_hover_index_ = -1;
  int tray_menu_scroll_offset_ = 0;
  int tray_menu_content_height_ = 0;
  int tray_menu_window_height_ = 0;
  HWND tray_submenu_window_ = nullptr;
  std::vector<TrayMenuItem> tray_submenu_items_;
  int tray_submenu_parent_index_ = -1;
  int tray_submenu_hover_index_ = -1;
  int tray_submenu_scroll_offset_ = 0;
  int tray_submenu_content_height_ = 0;
  int tray_submenu_window_height_ = 0;
  bool tray_icon_added_ = false;
  bool is_quitting_ = false;
};

#endif
