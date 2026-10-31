/// 版本更新日志。
///
/// 发新版本时做三件事：列表最上面加一条 `ReleaseEntry`、
/// 把 [WispReleaseNotes.currentVersion] 改成新版本号、pubspec.yaml 同步。
/// 设置页「关于 → 更新日志」直接渲染这份列表，badge 高亮靠 [ReleaseEntry.isCurrent]。
library;

class WispReleaseNotes {
  const WispReleaseNotes._();

  /// 当前应用版本（与 pubspec.yaml 的 `version:` 保持一致）。
  static const String currentVersion = '1.0.16';

  /// 新版本在前，设置页按这个顺序展示。
  static const List<WispReleaseEntry> entries = <WispReleaseEntry>[
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
