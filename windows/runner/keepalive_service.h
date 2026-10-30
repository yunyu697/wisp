#ifndef RUNNER_KEEPALIVE_SERVICE_H_
#define RUNNER_KEEPALIVE_SERVICE_H_

#include <windows.h>

// 桌面守护服务：wisp.exe 以 `--wisp-service` 参数运行时进入本模块，
// 作为 Windows 服务在后台看护主程序——应用被误关或崩溃时自动拉起，
// 用户重新登录后也会自动恢复。托盘「退出」会写入标记文件，
// 服务尊重用户的主动退出，不会阴魂不散。

// 进入服务模式（阻塞至服务停止）。返回值即进程退出码。
int RunKeepAliveService();

// 服务管理。状态：0=未安装 1=已安装未运行 2=运行中。
int KeepAliveServiceStatus();
// 安装并启动服务（触发一次 UAC 提权）。成功返回 true。
bool InstallKeepAliveService();
// 停止并卸载服务（触发一次 UAC 提权）。成功返回 true。
bool UninstallKeepAliveService();
// 重启服务（触发一次 UAC 提权）。服务卡在停止中、或守护逻辑失效时用它。
// 未安装时返回 false，调用方应先安装。
bool RestartKeepAliveService();

// 用户主动退出标记：托盘退出时写入，服务看到它就不再拉起；
// 主程序正常启动（手动或开机自启）时清除。
void WriteUserExitFlag();
void DeleteUserExitFlag();

#endif  // RUNNER_KEEPALIVE_SERVICE_H_
