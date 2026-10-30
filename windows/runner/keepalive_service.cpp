#include "keepalive_service.h"

#include <shellapi.h>
#include <shlobj.h>
#include <tlhelp32.h>
#include <userenv.h>
#include <wtsapi32.h>

#include <string>

#pragma warning(push)
// GDI+ 头文件在 /WX 下的良性数值转换警告，与本项目无关，整体豁免。
#pragma warning(disable : 4244 4310 4838)

namespace {

constexpr wchar_t kServiceName[] = L"WispKeepAlive";

SERVICE_STATUS g_status = {};
SERVICE_STATUS_HANDLE g_status_handle = nullptr;
HANDLE g_stop_event = nullptr;

void ReportState(DWORD state, DWORD wait_hint = 0) {
  if (g_status_handle == nullptr) return;
  g_status.dwCurrentState = state;
  g_status.dwWaitHint = wait_hint;
  SetServiceStatus(g_status_handle, &g_status);
}

std::wstring ExePath() {
  wchar_t path[MAX_PATH] = {};
  GetModuleFileNameW(nullptr, path, MAX_PATH);
  return path;
}

// 可执行文件所在目录，作为被拉起进程的工作目录。
std::wstring ExeDir() {
  std::wstring path = ExePath();
  size_t slash = path.find_last_of(L"\\/");
  return slash == std::wstring::npos ? L"." : path.substr(0, slash);
}

std::wstring FlagPath() {
  wchar_t root[MAX_PATH] = {};
  if (FAILED(SHGetFolderPathW(nullptr, CSIDL_COMMON_APPDATA, nullptr,
                              SHGFP_TYPE_CURRENT, root))) {
    return L"";
  }
  std::wstring dir = std::wstring(root) + L"\\Wisp";
  CreateDirectoryW(dir.c_str(), nullptr);
  return dir + L"\\user_exit.flag";
}

// 任意用户会话里是否已有主程序在跑（不含服务进程自身）。
bool AppRunning() {
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return true;  // 查不到就保守地当它在跑
  PROCESSENTRY32W entry = {};
  entry.dwSize = sizeof(entry);
  bool running = false;
  if (Process32FirstW(snapshot, &entry)) {
    do {
      if (_wcsicmp(entry.szExeFile, L"wisp.exe") == 0 &&
          entry.th32ProcessID != GetCurrentProcessId()) {
        running = true;
        break;
      }
    } while (Process32NextW(snapshot, &entry));
  }
  CloseHandle(snapshot);
  return running;
}

// 在活动控制台会话里拉起主程序。服务跑在 SYSTEM（会话 0），
// 直接 CreateProcess 只会得到一个看不见的会话 0 实例，
// 必须拿到登录用户的 token 再 CreateProcessAsUser。
void LaunchAppInUserSession() {
  DWORD session_id = WTSGetActiveConsoleSessionId();
  if (session_id == 0xFFFFFFFF) return;
  HANDLE token = nullptr;
  if (!WTSQueryUserToken(session_id, &token)) return;  // 锁屏/无人登录

  HANDLE env_block = nullptr;
  CreateEnvironmentBlock(&env_block, token, FALSE);

  const std::wstring exe = ExePath();
  const std::wstring cmd = L"\"" + exe + L"\"";
  const std::wstring dir = ExeDir();
  STARTUPINFOW si = {};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi = {};
  const BOOL ok = CreateProcessAsUserW(
      token, exe.c_str(), const_cast<LPWSTR>(cmd.c_str()), nullptr, nullptr,
      FALSE, CREATE_UNICODE_ENVIRONMENT | CREATE_BREAKAWAY_FROM_JOB,
      env_block, dir.c_str(), &si, &pi);
  if (ok) {
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
  }
  if (env_block != nullptr) DestroyEnvironmentBlock(env_block);
  CloseHandle(token);
}

bool UserExitFlagExists() {
  const std::wstring flag = FlagPath();
  if (flag.empty()) return false;
  return GetFileAttributesW(flag.c_str()) != INVALID_FILE_ATTRIBUTES;
}

// 注意：LPHANDLER_FUNCTION_EX 的签名要求返回 DWORD（NO_ERROR），不是 void。
DWORD WINAPI ServiceCtrlHandlerEx(DWORD control, DWORD event_type,
                                  LPVOID event_data, LPVOID context) {
  UNREFERENCED_PARAMETER(event_data);
  UNREFERENCED_PARAMETER(context);
  switch (control) {
    case SERVICE_CONTROL_STOP:
      ReportState(SERVICE_STOP_PENDING, 3000);
      if (g_stop_event != nullptr) SetEvent(g_stop_event);
      break;
    case SERVICE_CONTROL_SESSIONCHANGE:
      // 用户重新登录视为全新会话：解除「用户主动退出」的抑制，恢复守护。
      if (event_type == WTS_SESSION_LOGON || event_type == WTS_SESSION_LOGOFF) {
        DeleteUserExitFlag();
      }
      break;
    default:
      break;
  }
  return NO_ERROR;
}

void WatchLoop() {
  // 拉起后留几个周期的宽限，给应用启动时间，避免轮询误判。
  int grace = 0;
  for (;;) {
    const DWORD wait =
        WaitForSingleObject(g_stop_event, 4000);
    if (wait != WAIT_TIMEOUT) break;
    if (AppRunning()) {
      grace = 0;
      continue;
    }
    if (grace > 0) {
      grace--;
      continue;
    }
    if (UserExitFlagExists()) continue;  // 用户主动退出：尊重，不拉起
    LaunchAppInUserSession();
    grace = 3;
  }
}

void WINAPI ServiceMain(DWORD argc, LPWSTR* argv) {
  UNREFERENCED_PARAMETER(argc);
  UNREFERENCED_PARAMETER(argv);

  g_status_handle = RegisterServiceCtrlHandlerExW(kServiceName,
                                                  ServiceCtrlHandlerEx,
                                                  nullptr);
  if (g_status_handle == nullptr) return;

  g_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
  g_status.dwControlsAccepted =
      SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SESSIONCHANGE;
  ReportState(SERVICE_START_PENDING, 2000);

  g_stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (g_stop_event == nullptr) {
    ReportState(SERVICE_STOPPED);
    return;
  }

  ReportState(SERVICE_RUNNING);
  WatchLoop();
  ReportState(SERVICE_STOPPED);
  CloseHandle(g_stop_event);
  g_stop_event = nullptr;
}

// 通过 cmd 跑 sc 命令，runas 触发一次 UAC 提权。
bool RunScElevated(const std::wstring& commands) {
  const std::wstring params = L"/c " + commands;
  // 返回值大于 32 表示进程已成功启动（不代表 sc 本身成功，由轮询确认）。
  const INT_PTR result = reinterpret_cast<INT_PTR>(ShellExecuteW(
      nullptr, L"runas", L"cmd.exe", params.c_str(), nullptr, SW_HIDE));
  return result > 32;
}

}  // namespace

int RunKeepAliveService() {
  SERVICE_TABLE_ENTRYW table[] = {
      {const_cast<LPWSTR>(kServiceName), ServiceMain},
      {nullptr, nullptr},
  };
  if (!StartServiceCtrlDispatcherW(table)) {
    // 不是由 SCM 启动（比如手动带参调试）：直接进看护循环。
    g_stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (g_stop_event == nullptr) return EXIT_FAILURE;
    WatchLoop();
    CloseHandle(g_stop_event);
  }
  return EXIT_SUCCESS;
}

int KeepAliveServiceStatus() {
  SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (scm == nullptr) return 0;
  SC_HANDLE svc = OpenServiceW(scm, kServiceName, SERVICE_QUERY_STATUS);
  if (svc == nullptr) {
    CloseServiceHandle(scm);
    return 0;
  }
  SERVICE_STATUS status = {};
  int result = 0;
  if (QueryServiceStatus(svc, &status)) {
    result = status.dwCurrentState == SERVICE_RUNNING ? 2 : 1;
  }
  CloseServiceHandle(svc);
  CloseServiceHandle(scm);
  return result;
}

bool InstallKeepAliveService() {
  // binPath 带参数需要内层引号：sc 会按 CRT 规则解析 \" 为字面引号。
  const std::wstring commands =
      L"sc create WispKeepAlive binPath= \"\\\"" + ExePath() +
      L"\\\" --wisp-service\" start= auto DisplayName= \"Wisp 桌面守护服务\""
      L" && sc start WispKeepAlive";
  if (!RunScElevated(commands)) return false;
  for (int i = 0; i < 20; i++) {
    Sleep(200);
    if (KeepAliveServiceStatus() != 0) return true;
  }
  return false;
}

bool UninstallKeepAliveService() {
  // stop 在服务未运行时会失败，用 & 串联保证 delete 一定执行。
  const std::wstring commands =
      L"sc stop WispKeepAlive & sc delete WispKeepAlive";
  if (!RunScElevated(commands)) return false;
  for (int i = 0; i < 20; i++) {
    Sleep(200);
    if (KeepAliveServiceStatus() == 0) return true;
  }
  return false;
}

bool RestartKeepAliveService() {
  if (KeepAliveServiceStatus() == 0) return false;  // 没装就没什么可重启的
  // sc stop 之后服务进入 STOP_PENDING，紧接着 start 会被 SCM 拒绝，
  // 中间必须等它真的停下来。ping 是等 3 秒最省事的写法：
  // 无控制台时 timeout 命令会直接报错，ping 不会。
  const std::wstring commands =
      L"sc stop WispKeepAlive & ping -n 4 127.0.0.1 >nul & "
      L"sc start WispKeepAlive";
  if (!RunScElevated(commands)) return false;
  // 停 + 等 + 起大约 3 秒，给到 10 秒的观察窗口。
  for (int i = 0; i < 40; i++) {
    Sleep(250);
    if (KeepAliveServiceStatus() == 2) return true;
  }
  return false;
}

void WriteUserExitFlag() {
  const std::wstring flag = FlagPath();
  if (flag.empty()) return;
  HANDLE file =
      CreateFileW(flag.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                  FILE_ATTRIBUTE_HIDDEN, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  const char body[] = "user quit";
  DWORD written = 0;
  WriteFile(file, body, sizeof(body) - 1, &written, nullptr);
  CloseHandle(file);
}

void DeleteUserExitFlag() {
  const std::wstring flag = FlagPath();
  if (flag.empty()) return;
  DeleteFileW(flag.c_str());
}

#pragma warning(pop)
