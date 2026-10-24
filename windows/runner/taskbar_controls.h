#ifndef RUNNER_TASKBAR_CONTROLS_H_
#define RUNNER_TASKBAR_CONTROLS_H_

#include <windows.h>
#include <shobjidl.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <array>
#include <memory>
#include <string>

// Windows thumbnail toolbar, independent of window activation/lifecycle.
class TaskbarControls {
 public:
  TaskbarControls(HWND window, flutter::BinaryMessenger* messenger);
  ~TaskbarControls();
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);
  bool ready() const { return added_; }

 private:
  void ConnectTaskbar();
  void UpdateButtons();
  void CreateIcons();
  void DestroyIcons();

  HWND window_;
  UINT created_message_;
  ITaskbarList3* taskbar_ = nullptr;
  bool added_ = false;
  bool has_track_ = false;
  bool playing_ = false;
  bool favorite_ = false;
  ULONG_PTR graphics_token_ = 0;
  std::array<HICON, 6> icons_{};
  std::array<std::wstring, 4> tips_{
      L"Add to favorites", L"Previous track", L"Play", L"Next track"};
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_TASKBAR_CONTROLS_H_
