#include "flutter_window.h"

#include <mmsystem.h>

#include <cstdlib>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr wchar_t kAudioAlias[] = L"joenws_tts";

bool McaSend(const std::wstring& command, std::wstring* out = nullptr) {
  wchar_t buffer[256] = {0};
  const MCIERROR error = mciSendStringW(
      command.c_str(), buffer,
      static_cast<UINT>(sizeof(buffer) / sizeof(buffer[0])), nullptr);
  if (out != nullptr) {
    *out = buffer;
  }
  return error == 0;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Let Dart drive the title bar colors so they always match the app
  // background (and stay opaque: no Mica / Acrylic).
  window_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "joenws/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "setCaption") {
          result->NotImplemented();
          return;
        }
        const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (args == nullptr) {
          result->Error("bad_args", "expected a map");
          return;
        }
        auto read = [args](const char* key, int64_t fallback) -> int64_t {
          auto it = args->find(flutter::EncodableValue(std::string(key)));
          if (it == args->end()) {
            return fallback;
          }
          if (const int64_t* v = std::get_if<int64_t>(&it->second)) {
            return *v;
          }
          if (const int32_t* v = std::get_if<int32_t>(&it->second)) {
            return *v;
          }
          return fallback;
        };
        auto to_colorref = [](int64_t argb) -> COLORREF {
          const BYTE r = static_cast<BYTE>((argb >> 16) & 0xFF);
          const BYTE g = static_cast<BYTE>((argb >> 8) & 0xFF);
          const BYTE b = static_cast<BYTE>(argb & 0xFF);
          return RGB(r, g, b);
        };
        SetCaptionColors(to_colorref(read("caption", 0)),
                         to_colorref(read("text", 0xFFFFFF)),
                         to_colorref(read("border", 0)), read("dark", 0) != 0);
        result->Success();
      });

  // Built-in TTS playback: play a WAV file with winmm (no extra plugin).
  audio_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "joenws/audio",
      &flutter::StandardMethodCodec::GetInstance());
  audio_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const std::string method = call.method_name();
        if (method == "stop") {
          McaSend(L"stop joenws_tts");
          McaSend(L"close joenws_tts");
          result->Success();
          return;
        }
        if (method == "pause") {
          if (!McaSend(L"pause joenws_tts")) {
            result->Error("pause_failed", "MCI pause failed");
            return;
          }
          result->Success();
          return;
        }
        if (method == "resume") {
          if (!McaSend(L"resume joenws_tts")) {
            result->Error("resume_failed", "MCI resume failed");
            return;
          }
          result->Success();
          return;
        }
        if (method == "position") {
          std::wstring pos;
          std::wstring len;
          if (!McaSend(L"status joenws_tts position", &pos) ||
              !McaSend(L"status joenws_tts length", &len)) {
            result->Error("position_failed", "MCI status failed");
            return;
          }
          flutter::EncodableMap out;
          out[flutter::EncodableValue("positionMs")] =
              flutter::EncodableValue(_wtoi(pos.c_str()));
          out[flutter::EncodableValue("durationMs")] =
              flutter::EncodableValue(_wtoi(len.c_str()));
          result->Success(flutter::EncodableValue(out));
          return;
        }
        if (method != "play") {
          result->NotImplemented();
          return;
        }
        const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (args == nullptr) {
          result->Error("bad_args", "expected a map");
          return;
        }
        auto it = args->find(flutter::EncodableValue(std::string("path")));
        if (it == args->end()) {
          result->Error("bad_args", "path is missing");
          return;
        }
        const std::string* path = std::get_if<std::string>(&it->second);
        if (path == nullptr || path->empty()) {
          result->Error("bad_args", "path is empty");
          return;
        }
        const int wide_len =
            MultiByteToWideChar(CP_UTF8, 0, path->c_str(), -1, nullptr, 0);
        if (wide_len <= 1) {
          result->Error("bad_path", "cannot convert path to UTF-16");
          return;
        }
        std::wstring wide_path(static_cast<size_t>(wide_len), L'\0');
        MultiByteToWideChar(CP_UTF8, 0, path->c_str(), -1, &wide_path[0],
                            wide_len);
        wide_path.resize(static_cast<size_t>(wide_len - 1));

        McaSend(L"stop joenws_tts");
        McaSend(L"close joenws_tts");
        const std::wstring open_cmd =
            L"open \"" + wide_path + L"\" type waveaudio alias " +
            std::wstring(kAudioAlias);
        if (!McaSend(open_cmd)) {
          result->Error("open_failed", "MCI open failed");
          return;
        }
        if (!McaSend(L"play joenws_tts")) {
          McaSend(L"close joenws_tts");
          result->Error("play_failed", "MCI play failed");
          return;
        }
        result->Success();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  McaSend(L"stop joenws_tts");
  McaSend(L"close joenws_tts");
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
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
