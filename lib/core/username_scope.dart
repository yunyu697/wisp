/// 「识别用户名」的可见性规则。
///
/// 两台设备**用户名相同**才互相可见。空对空算相同（都没启用这个功能），
/// 空对非空算**不同**——这正是"设了用户名之后不被没设的人看到"的实现方式：
/// 对方即使没填用户名，也会因为"我填了、它没填"而把我过滤掉。
///
/// 比较前统一 trim + 转小写：手输的东西不该因为多一个空格或大小写不同
/// 就互相看不见。
///
/// 这条规则必须在四处同时生效，少一处就等于没设：
/// 1. 组播/扫描收到的设备信息（[DiscoveryService] 的 `_handleDatagram`、
///    `_probe`、`_postRegister`）——不认的设备既不记进列表，也不回 register；
/// 2. 本机服务端收到的 `/register`（[ReceiverService]）——对不上直接 403，
///    否则对方扫一遍就知道我们在；
/// 3. 本机服务端收到的 `/prepare-upload`——对不上 403，防止绕过发现直接推文件；
/// 4. 界面列表（[AppState._upsertDevice]）——兜底，防止别处漏进来的设备被显示。
library;

/// 归一化：去掉首尾空白、统一小写。
String normalizeUsername(String raw) => raw.trim().toLowerCase();

/// 两端是否属于同一个用户名范围（互相可见）。
bool sameUsernameScope(String mine, String theirs) =>
    normalizeUsername(mine) == normalizeUsername(theirs);
