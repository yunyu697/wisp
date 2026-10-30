#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shlobj.h>
#include <shellapi.h>
#include <windows.h>

#include "flutter_window.h"
#include "keepalive_service.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // 服务模式：作为看护服务运行，不初始化 Flutter、不建窗口。
  // 服务由 SCM 启动，进程里没有消息循环可用，必须最先分流。
  if (command_line != nullptr && wcsstr(command_line, L"--wisp-service") != nullptr) {
    return RunKeepAliveService();
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // 正常启动（手动或被服务拉起）：清除托盘退出留下的标记，
  // 服务守护随即恢复工作。
  DeleteUserExitFlag();

  // 初始化 COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // 给进程一个明确的应用标识，任务栏和托盘才能正确归组、正确显示图标，
  // 否则窗口会挂到宿主程序名下，图标也可能显示成默认的空白块。
  ::SetCurrentProcessExplicitAppUserModelID(L"Wisp.Desktop");

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Wisp", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
