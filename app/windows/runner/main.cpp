#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "app_links/app_links_plugin_c_api.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr const wchar_t kWindowTitle[] = L"Melsi";
constexpr const wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr const wchar_t kSingleInstanceMutex[] =
    L"Local\\app.melsi.Melsi.SingleInstance";

// Default / minimum window size in logical pixels (min size is enforced in
// FlutterWindow::MessageHandler).
constexpr int kDefaultWidth = 1100;
constexpr int kDefaultHeight = 720;

// Brings an already running Melsi window to the front.
bool ActivateExistingWindow() {
  HWND hwnd = ::FindWindowW(kWindowClass, kWindowTitle);
  if (hwnd == nullptr) {
    return false;
  }
  WINDOWPLACEMENT placement = {sizeof(WINDOWPLACEMENT)};
  ::GetWindowPlacement(hwnd, &placement);
  if (placement.showCmd == SW_SHOWMINIMIZED || !::IsWindowVisible(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
  }
  ::SetForegroundWindow(hwnd);
  return true;
}

// Logical origin that centers the default window on the primary work area.
Win32Window::Point CenteredOrigin() {
  RECT work_area = {};
  if (!::SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0)) {
    return Win32Window::Point(10, 10);
  }
  HDC screen = ::GetDC(nullptr);
  const int dpi = screen ? ::GetDeviceCaps(screen, LOGPIXELSX) : 96;
  if (screen) {
    ::ReleaseDC(nullptr, screen);
  }
  const double scale = dpi / 96.0;
  const int work_width = static_cast<int>((work_area.right - work_area.left) / scale);
  const int work_height = static_cast<int>((work_area.bottom - work_area.top) / scale);
  const int left = static_cast<int>(work_area.left / scale);
  const int top = static_cast<int>(work_area.top / scale);
  const int x = left + (work_width > kDefaultWidth ? (work_width - kDefaultWidth) / 2 : 0);
  const int y = top + (work_height > kDefaultHeight ? (work_height - kDefaultHeight) / 2 : 0);
  return Win32Window::Point(static_cast<unsigned int>(x), static_cast<unsigned int>(y));
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Single instance. A second launch (e.g. a melsi:// link opened from the
  // browser) forwards its link to the running instance via app_links and
  // brings that window to the front.
  HANDLE single_instance_mutex =
      ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
  if (single_instance_mutex != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    if (!SendAppLinkToInstance()) {
      ActivateExistingWindow();
    }
    ::CloseHandle(single_instance_mutex);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin = CenteredOrigin();
  Win32Window::Size size(kDefaultWidth, kDefaultHeight);
  if (!window.Create(kWindowTitle, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single_instance_mutex != nullptr) {
    ::ReleaseMutex(single_instance_mutex);
    ::CloseHandle(single_instance_mutex);
  }
  return EXIT_SUCCESS;
}
