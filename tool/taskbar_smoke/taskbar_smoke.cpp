// Native smoke: uses its own minimized window and a fake Dart messenger.
// Never opens the player's library or changes another application's windows.
#include "taskbar_controls.h"

#include <iostream>
#include <vector>

namespace {
TaskbarControls* controls = nullptr;
LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (controls && controls->HandleMessage(message, wparam, lparam)) return 0;
  return DefWindowProc(window, message, wparam, lparam);
}

class Messenger : public flutter::BinaryMessenger {
 public:
  flutter::BinaryMessageHandler handler;
  mutable std::vector<std::string> actions;

  void Send(const std::string&, const uint8_t* data, size_t length,
            flutter::BinaryReply reply = nullptr) const override {
    auto call = flutter::StandardMethodCodec::GetInstance().DecodeMethodCall(data, length);
    if (call && call->method_name() == "action" && call->arguments()) {
      if (const auto* action = std::get_if<std::string>(call->arguments())) actions.push_back(*action);
    }
    if (reply) reply(nullptr, 0);
  }

  void SetMessageHandler(const std::string&, flutter::BinaryMessageHandler callback) override {
    handler = std::move(callback);
  }

  bool State(bool enabled, bool playing, bool favorite) {
    flutter::EncodableMap state{
      {flutter::EncodableValue("hasTrack"), flutter::EncodableValue(enabled)},
      {flutter::EncodableValue("playing"), flutter::EncodableValue(playing)},
      {flutter::EncodableValue("favorite"), flutter::EncodableValue(favorite)},
    };
    const flutter::MethodCall<flutter::EncodableValue> call("update",
        std::make_unique<flutter::EncodableValue>(state));
    auto data = flutter::StandardMethodCodec::GetInstance().EncodeMethodCall(call);
    bool success = false;
    handler(data->data(), data->size(), [&](const uint8_t* reply, size_t size) {
      success = reply && size > 0 && reply[0] == 0;
    });
    return success;
  }
};

bool Run(HWND window) {
  Messenger messenger;
  {
    TaskbarControls toolbar(window, &messenger);
    controls = &toolbar;
    ShowWindow(window, SW_SHOWMINNOACTIVE);
    const ULONGLONG deadline = GetTickCount64() + 5000;
    while (!toolbar.ready() && GetTickCount64() < deadline) {
      MSG message;
      while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&message);
        DispatchMessage(&message);
      }
      MsgWaitForMultipleObjects(0, nullptr, FALSE, 20, QS_ALLINPUT);
    }
    if (!toolbar.ready()) {
      std::cerr << "Thumbnail toolbar was not created by Explorer\n";
      controls = nullptr;
      return false;
    }
    if (!messenger.State(true, false, false)) return false;
    for (UINT id = 0x6B00; id < 0x6B04; ++id) {
      SendMessage(window, WM_COMMAND, MAKEWPARAM(id, THBN_CLICKED), 0);
    }
    const std::vector<std::string> expected{"favorite", "previous", "toggle", "next"};
    if (messenger.actions != expected || !IsIconic(window)) return false;
    if (!messenger.State(false, true, true)) return false;
    SendMessage(window, WM_COMMAND, MAKEWPARAM(0x6B03, THBN_CLICKED), 0);
    if (messenger.actions != expected) return false;
    SendMessage(window, WM_THEMECHANGED, 0, 0);
    const DWORD resources = GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS);
    for (int i = 0; i < 50; ++i) {
      if (!messenger.State(true, i % 2 == 0, i % 3 == 0)) return false;
    }
    if (!toolbar.ready() || !IsIconic(window) ||
        GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS) > resources + 2) return false;
    controls = nullptr;
  }
  if (messenger.handler) return false;
  std::cout << "PASS: Explorer toolbar, four actions, disabled state, icon updates, minimized window, cleanup\n";
  return true;
}
}  // namespace

int main() {
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  WNDCLASS window_class{};
  window_class.lpfnWndProc = WindowProc;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.lpszClassName = L"ShikiTaskbarSmoke";
  RegisterClass(&window_class);
  HWND window = CreateWindowEx(WS_EX_APPWINDOW | WS_EX_NOACTIVATE,
      window_class.lpszClassName, L"ShikiMusic taskbar check", WS_OVERLAPPEDWINDOW,
      0, 0, 320, 240, nullptr, nullptr, window_class.hInstance, nullptr);
  const bool success = window && Run(window);
  controls = nullptr;
  if (window) DestroyWindow(window);
  UnregisterClass(window_class.lpszClassName, window_class.hInstance);
  CoUninitialize();
  return success ? 0 : 1;
}
