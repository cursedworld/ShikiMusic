#include "taskbar_controls.h"

#include <algorithm>

// The Windows 10 SDK's GDI+ headers use unqualified min/max with NOMINMAX.
namespace Gdiplus {
using std::max;
using std::min;
}
#pragma warning(push)
#pragma warning(disable : 4458)
#include <gdiplus.h>
#pragma warning(pop)

#include <utility>

namespace {
constexpr UINT kFirstButton = 0x6B00;
constexpr const char* kActions[] = {"favorite", "previous", "toggle", "next"};

std::wstring Wide(const std::string& text) {
  const int count = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                      static_cast<int>(text.size()), nullptr, 0);
  if (count <= 0) return {};
  std::wstring result(static_cast<size_t>(count), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      result.data(), count);
  return result;
}

bool Flag(const flutter::EncodableMap& values, const char* name) {
  const auto it = values.find(flutter::EncodableValue(name));
  if (it == values.end()) return false;
  const auto* value = std::get_if<bool>(&it->second);
  return value && *value;
}

bool LightTaskbar() {
  DWORD light = 0;
  DWORD size = sizeof(light);
  RegGetValueW(HKEY_CURRENT_USER,
               L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
               L"SystemUsesLightTheme", RRF_RT_REG_DWORD, nullptr, &light, &size);
  return light != 0;
}

HICON DrawButton(int kind, bool light) {
  using namespace Gdiplus;
  Bitmap bitmap(32, 32, PixelFormat32bppARGB);
  Graphics graphics(&bitmap);
  graphics.Clear(Color(0, 0, 0, 0));
  graphics.SetSmoothingMode(SmoothingModeAntiAlias);
  const Color foreground = light ? Color(255, 35, 35, 35)
                                 : Color(255, 240, 240, 240);
  Pen pen(foreground, 2.2f);
  pen.SetStartCap(LineCapRound);
  pen.SetEndCap(LineCapRound);
  SolidBrush brush(foreground);
  if (kind == 0 || kind == 1) {
    graphics.DrawEllipse(&pen, 5.0f, 5.0f, 22.0f, 22.0f);
    if (kind == 0) {
      graphics.DrawLine(&pen, 10.0f, 16.0f, 22.0f, 16.0f);
      graphics.DrawLine(&pen, 16.0f, 10.0f, 16.0f, 22.0f);
    } else {
      graphics.DrawLine(&pen, 10.0f, 16.0f, 14.0f, 20.0f);
      graphics.DrawLine(&pen, 14.0f, 20.0f, 22.0f, 11.0f);
    }
  } else if (kind == 2) {
    const Point points[] = {Point(23, 6), Point(9, 16), Point(23, 26)};
    graphics.FillPolygon(&brush, points, 3);
    graphics.FillRectangle(&brush, 5, 6, 3, 20);
  } else if (kind == 3) {
    const Point points[] = {Point(10, 5), Point(25, 16), Point(10, 27)};
    graphics.FillPolygon(&brush, points, 3);
  } else if (kind == 4) {
    graphics.FillRectangle(&brush, 8, 6, 5, 20);
    graphics.FillRectangle(&brush, 19, 6, 5, 20);
  } else {
    const Point points[] = {Point(9, 6), Point(23, 16), Point(9, 26)};
    graphics.FillPolygon(&brush, points, 3);
    graphics.FillRectangle(&brush, 24, 6, 3, 20);
  }
  HICON icon = nullptr;
  bitmap.GetHICON(&icon);
  return icon;
}
}  // namespace

TaskbarControls::TaskbarControls(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window),
      created_message_(RegisterWindowMessageW(L"TaskbarButtonCreated")) {
  Gdiplus::GdiplusStartupInput input;
  if (Gdiplus::GdiplusStartup(&graphics_token_, &input, nullptr) == Gdiplus::Ok) {
    CreateIcons();
  }
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "shiki/taskbar_controls", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "update") {
          result->NotImplemented();
          return;
        }
        const auto* values = call.arguments()
            ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
        if (!values) {
          result->Error("invalid_arguments", "Expected playback state");
          return;
        }
        has_track_ = Flag(*values, "hasTrack");
        playing_ = Flag(*values, "playing");
        favorite_ = Flag(*values, "favorite");
        constexpr const char* names[] = {"favoriteTip", "previousTip", "playPauseTip", "nextTip"};
        for (size_t i = 0; i < tips_.size(); ++i) {
          const auto found = values->find(flutter::EncodableValue(names[i]));
          if (found != values->end()) {
            if (const auto* text = std::get_if<std::string>(&found->second)) {
              tips_[i] = Wide(*text);
            }
          }
        }
        UpdateButtons();
        result->Success();
      });
}

TaskbarControls::~TaskbarControls() {
  channel_->SetMethodCallHandler(nullptr);
  channel_.reset();
  if (taskbar_) taskbar_->Release();
  DestroyIcons();
  if (graphics_token_) Gdiplus::GdiplusShutdown(graphics_token_);
}

void TaskbarControls::DestroyIcons() {
  for (auto& icon : icons_) {
    if (icon) DestroyIcon(icon);
    icon = nullptr;
  }
}

void TaskbarControls::CreateIcons() {
  DestroyIcons();
  if (!graphics_token_) return;
  const bool light = LightTaskbar();
  for (size_t i = 0; i < icons_.size(); ++i) {
    icons_[i] = DrawButton(static_cast<int>(i), light);
  }
}

void TaskbarControls::ConnectTaskbar() {
  added_ = false;
  if (taskbar_) taskbar_->Release();
  taskbar_ = nullptr;
  if (FAILED(CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&taskbar_)))) return;
  if (FAILED(taskbar_->HrInit())) {
    taskbar_->Release();
    taskbar_ = nullptr;
    return;
  }
  UpdateButtons();
}

void TaskbarControls::UpdateButtons() {
  if (!taskbar_) return;
  THUMBBUTTON buttons[4]{};
  const HICON selected[] = {icons_[favorite_ ? 1 : 0], icons_[2],
                            icons_[playing_ ? 4 : 3], icons_[5]};
  for (UINT i = 0; i < ARRAYSIZE(buttons); ++i) {
    buttons[i].dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
    buttons[i].iId = kFirstButton + i;
    buttons[i].hIcon = selected[i];
    buttons[i].dwFlags = has_track_ ? THBF_ENABLED : THBF_DISABLED;
    wcsncpy_s(buttons[i].szTip, tips_[i].c_str(), _TRUNCATE);
  }
  const HRESULT status = added_
      ? taskbar_->ThumbBarUpdateButtons(window_, ARRAYSIZE(buttons), buttons)
      : taskbar_->ThumbBarAddButtons(window_, ARRAYSIZE(buttons), buttons);
  if (SUCCEEDED(status)) added_ = true;
}

bool TaskbarControls::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (created_message_ != 0 && message == created_message_) {
    // Explorer may have restarted; create a fresh COM connection and toolbar.
    ConnectTaskbar();
    return true;
  }
  if (message == WM_THEMECHANGED || message == WM_SYSCOLORCHANGE ||
      message == WM_SETTINGCHANGE) {
    CreateIcons();
    UpdateButtons();
  }
  if (message != WM_COMMAND || HIWORD(wparam) != THBN_CLICKED) return false;
  const UINT id = LOWORD(wparam);
  if (id < kFirstButton || id >= kFirstButton + 4) return false;
  if (has_track_) {
    channel_->InvokeMethod("action", std::make_unique<flutter::EncodableValue>(
        kActions[id - kFirstButton]));
  }
  return true;
}
