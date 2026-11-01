/// 版本更新日志。
///
/// 发新版本时做三件事：列表最上面加一条 `ReleaseEntry`、
/// 把 [WispReleaseNotes.currentVersion] 改成新版本号、pubspec.yaml 同步。
/// 设置页「关于 → 更新日志」直接渲染这份列表，badge 高亮靠 [ReleaseEntry.isCurrent]。
library;

class WispReleaseNotes {
  const WispReleaseNotes._();

  /// 当前应用版本（与 pubspec.yaml 的 `version:` 保持一致）。
  static const String currentVersion = '1.0.23';

  /// 新版本在前，设置页按这个顺序展示。
  static const List<WispReleaseEntry> entries = <WispReleaseEntry>[
    WispReleaseEntry(version: '1.0.23', changes: <String>[
      '悬浮球与吸附把手改成同一个形状的连续形变：药丸慢慢变宽、圆角收成正圆，反过来也一样，收尾带一点回弹，不再是两个图形交叉淡入淡出',
      '去掉悬浮球边缘的第二圈边框：阴影不再来自预渲染贴图，改成按当前尺寸实时绘制',
      '吸附到屏幕边缘时把手完全贴边，不再留一条缝',
      '悬浮球常驻置顶；检测到全屏应用（游戏、视频）时自动让位，退出全屏立刻回来',
      '鼠标离开 1 秒后，用 1 秒慢慢淡到 25% 不透明度；移回来 0.1 秒就恢复不透明，不会闪',
      'macOS 菜单栏图标按应用图标自己的构图重画（青绿卡片 + 两条白线 + 珊瑚点），深浅色菜单栏都清晰，有新请求时整体变红',
    ]),
    WispReleaseEntry(version: '1.0.22', changes: <String>[
      '「识别用户名」改成同名才互相可见：设了用户名之后，只显示同名的设备，也只有同名的设备看得到你（以前只有你单方面看不到别人，没设用户名的人照样能看见你）',
      '用户名比对忽略首尾空格与大小写；空对空算同名，设了名字的设备与没设的设备互相隐藏',
      '接收端不再对用户名不一致的设备作出任何响应（此前对方扫一遍网段就知道你在），也拒绝它们直接发起的传输',
      '手动输入 IP 连接时，若对方属于其他用户会明确提示，不再只报"连不上"',
    ]),
    WispReleaseEntry(version: '1.0.21', changes: <String>[
      '修复「出示的证书与它声明的指纹不一致，已忽略」反复弹出、设备列表里看不到对方的问题：Wisp 上报的设备标识是 32 位随机串，不是证书哈希，上一版却拿它去比 64 位证书哈希，于是每台真实设备都被判成冒充。现在只有形状确实是证书哈希的声明才参与比对',
      '同一条证书告警对同一台设备只提示一次，不再每轮扫描刷一条',
      '修正文档里对指纹校验能力的描述：内置证书随安装包分发、所有安装共用一张，它挡得住随手换证书的中间人，但挡不住有心人，也不构成设备认证',
    ]),
    WispReleaseEntry(version: '1.0.20', changes: <String>[
      '修复接收端文件名漏洞：对端可以把文件写到下载目录之外（例如开机启动目录），自动接收时用户毫无察觉；现在文件名只保留纯文件名，并强制校验落点必须在本次接收目录内',
      '「加密传输」真正校验对端身份：证书指纹必须与对端声明的一致，对不上直接断开（此前任何证书都放行，同网段可被中间人劫持）',
      '一键更新下载完会校验 sha256：清单没有校验值就拒绝自动安装，校验不符则删包换源',
      '修复多文件并发上传时，接收端历史里出现两条一模一样记录的问题',
      '发布流程加质量门：构建前先跑静态分析与自动化测试，不通过就不出安装包',
    ]),
    WispReleaseEntry(version: '1.0.19', changes: <String>[
      '修复 macOS 版「无法占用端口：Operation not permitted」：Release 版误开了沙盒又没给网络权限，现已关闭沙盒（本应用不经过 Mac App Store，沙盒只有害处）',
      '补齐 macOS 本地网络权限声明，系统会正常弹出授权询问，不再静默失败',
      '更新弹层改为三个动作：一键更新（下载并自动安装）、仅下载（完成后提示安装）、打开下载页',
      'Windows 一键更新静默完成安装并自动打开新版；macOS 自动挂载镜像写入「应用程序」',
      'macOS 关闭窗口后驻留菜单栏、不再显示 Dock 图标；菜单栏图标可唤回主窗口或退出，有新请求时图标变红提醒',
    ]),
    WispReleaseEntry(version: '1.0.18', changes: <String>[
      '根治通知「要第二次才会出现」：卡片位置固定，入场动画只调透明度，绝不会再停在屏幕外',
      '通知发出后由原生层回报「是否真的画出来了」，没画出来自动重发一次',
      '拿不到窗口状态时照常弹通知，不再静默吞掉第一次的提醒',
      '传输结束时若提示卡已超时收起，会重新弹一张，不会丢失「对方已取消」这类结局提示',
      '修复通知出现后再打开主窗口会变黑：收起桌面浮层与恢复窗口后连续强制重绘',
      '新增端到端自测：通知首次弹出、像素落盘确认、黑屏判定全部纳入回归',
    ]),
    WispReleaseEntry(version: '1.0.17', changes: <String>[
      '修复「发现新版本」后点击下载链接没反应：改用系统 API 唤起默认浏览器',
      '下载列表按当前平台给出对应产物（Windows 安装包 / macOS 镜像 / Linux 包 / APK）',
      '打不开链接时明确提示原因，不再默默无响应',
      '移除已失效的加速镜像 gh.llkk.cc',
    ]),
    WispReleaseEntry(version: '1.0.16', changes: <String>[
      '修复桌面通知「闪一下就没了」：卡片改为先滑入再展示，询问态存活延到 30 秒',
      '发送方取消或连接中断时，通知卡片原地显示提示，3 秒后自动收起并回归原状态',
      '去掉悬浮球内侧多余的高光环，只保留一圈柔和外投影',
      '主窗口重新激活时自动退场桌面卡片与气泡，不再遮挡窗口',
    ]),
    WispReleaseEntry(version: '1.0.15', changes: <String>[
      '修复 Android 启动报「无法占用端口：Operation not permitted」：补齐 INTERNET 等权限声明',
      'Android 组播发现接入 MulticastLock，能稳定收到局域网 announce',
      '放大应用图标图形占比，Android 自适应图标不再显示得很小',
    ]),
    WispReleaseEntry(version: '1.0.14', changes: <String>[
      '设置 → 关于新增「自动检查更新」：每次启动 / 每天 / 每周 / 关闭可选',
      '到点后台静默比对，发现新版本弹一条提示，不自动下载不打扰',
      '手动检查与自动检查共用频率闸门，不会短时间内重复请求',
    ]),
    WispReleaseEntry(version: '1.0.13', changes: <String>[
      '设置 → 关于新增「检查更新」，自动比对最新版本',
      '内置 GitHub 加速镜像列表，下载不动官方源时换个镜像即可',
    ]),
    WispReleaseEntry(version: '1.0.12', changes: <String>[
      '设置 → 关于新增「更新日志」，按版本查看每次发布改了什么',
      '版本号改为随发布自动维护，不再硬编码',
    ]),
    WispReleaseEntry(version: '1.0.11', changes: <String>[
      '拖拽文件或文件夹到窗口，直接加入待发清单',
      '历史记录逐条操作：再次发送 / 打开所在目录 / 单条删除',
      '内置 TLS 自签证书，「加密传输」开关真正可用，设置页显示指纹',
      '修复发送会话号 bug：此前对接真接收端会被 403 拒绝',
    ]),
    WispReleaseEntry(version: '1.0.10', changes: <String>[
      '全站配色迁移到青绿，与图标、通知卡统一色系',
      '深浅两套主题重调：暖白中性色 + 带青的墨色',
      '主按钮禁用态重新设计，不再发灰发糊',
    ]),
    WispReleaseEntry(version: '1.0.9', changes: <String>[
      '内置端到端自测（--wisp-selftest），结果写 JSON 报告',
      '通知分流规则收敛：主窗口 / 气泡 / 通知卡三选一',
      '桌面层（通知卡、悬浮球把手、进度条）统一青绿品牌色',
    ]),
    WispReleaseEntry(version: '1.0.8', changes: <String>[
      '与官方 LocalSend 1.18.2 完成双向发现实测',
      '修复发送端上报错误端口 / 协议导致对端回连失败',
      '扫描兜底支持多端口探测（自定义端口 + 默认端口）',
    ]),
    WispReleaseEntry(version: '1.0.7', changes: <String>[
      '修复「对方搜不到 Wisp」：组播出口钉住物理网卡',
      '设置 → 网络新增「发现状态」诊断面板',
      '修复提示文字字体不一致；设置新增「重启服务」',
      '资源治理：历史内存上限、半截文件清理、日志限容',
    ]),
    WispReleaseEntry(version: '1.0.6', changes: <String>[
      '发现可靠性大修：组播绑定与报文排空、启动突发广播、子网广播兜底',
      '离线设备 60 秒自动移除；网络切换后自动重建发现链路',
      '窗口最小高度调整为 690，内容不再溢出',
    ]),
    WispReleaseEntry(version: '1.0.5', changes: <String>[
      '横竖屏自适应：宽屏侧栏多栏，窄屏底栏单栏',
      '设置页横屏双列；发送页横屏左右分栏',
    ]),
    WispReleaseEntry(version: '1.0.4', changes: <String>[
      '修复首页空态「输入 IP 直接连接」按钮占满整行',
    ]),
    WispReleaseEntry(version: '1.0.3', changes: <String>[
      '修复手动连接按钮过宽',
      '新增 Windows 服务守护：安装后崩溃自动拉起、开机自启',
    ]),
    WispReleaseEntry(version: '1.0.2', changes: <String>[
      '通知互斥分流：同一时刻只走一种提醒，不打扰',
      '悬浮球位置记忆：拖动后重启原位恢复，吸附缩成把手',
    ]),
    WispReleaseEntry(version: '1.0.1', changes: <String>[
      '悬浮球重绘：逐像素抗锯齿、悬停自动展开',
      '修复主窗口从托盘恢复时黑屏',
      '设置新增悬浮球展开延时',
    ]),
    WispReleaseEntry(version: '1.0.0', changes: <String>[
      '首个发布：局域网设备发现与互传，兼容 LocalSend v2.2 协议',
      '文件 / 文件夹发送、接收确认、传输进度与历史',
      '系统托盘、悬浮球气泡、自绘通知卡片',
    ]),
  ];
}

/// 单个版本的改动条目。
class WispReleaseEntry {
  const WispReleaseEntry({required this.version, required this.changes});

  final String version;
  final List<String> changes;

  /// 是否就是当前安装的版本（badge 用品牌色高亮）。
  bool get isCurrent => version == WispReleaseNotes.currentVersion;
}
