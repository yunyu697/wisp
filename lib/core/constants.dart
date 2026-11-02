/// 与 LocalSend Protocol v2.2 对齐的常量。
///
/// 保留协议常量意味着 Wisp 能和官方 LocalSend 客户端互相收发——
/// 重构的是体验，不是私有的新协议。
class WispProtocol {
  const WispProtocol._();

  static const String version = '2.2';
  static const int defaultPort = 53317;
  static const String multicastAddress = '224.0.0.167';

  /// 组播端口是协议写死的，**不跟随**用户自定义的 HTTP 端口。
  /// 官方客户端永远只在 224.0.0.167:53317 上收发 announce，
  /// 把这里换成 settings.port 会导致改过端口之后彻底发现不到人。
  static const int multicastPort = defaultPort;

  static const String registerPath = '/api/localsend/v2/register';
  static const String prepareUploadPath = '/api/localsend/v2/prepare-upload';
  static const String uploadPath = '/api/localsend/v2/upload';
  static const String cancelPath = '/api/localsend/v2/cancel';
  static const String infoPath = '/api/localsend/v2/info';

  /// 文本消息端点（Wisp 扩展，官方 LocalSend 没有这个概念）。
  ///
  /// 刻意放在 `wisp` 命名空间而不是 `localsend` 下：这条路径不属于协议
  /// v2.2，塞进别人的命名空间里只会让"兼容 LocalSend"这句话变得含糊。
  /// 对端是官方客户端时会直接 404，发送端据此给出"对方不支持发消息"。
  static const String messagePath = '/api/wisp/v1/message';

  /// 单条消息上限，防止异常报文撑爆内存。
  static const int maxDatagramBytes = 64 * 1024;

  /// 一条文本消息最多多少字符。
  ///
  /// 剪贴板里常见的都是几 KB 的代码片段或地址；给到 32K 字符（UTF-8 下
  /// 最多 ~128 KB 字节）足够覆盖长日志，又不至于让一次 POST 变成文件传输。
  static const int maxMessageChars = 32 * 1024;

  /// 消息请求体的字节上限。字符数够了但字节数可能翻四倍（全中文），
  /// 读取前先按 Content-Length 挡一道，避免把超大 body 全读进内存。
  static const int maxMessageBytes = 256 * 1024;

  /// 文件分块大小：1 MiB 是吞吐与内存占用的折中点。
  static const int chunkSize = 1024 * 1024;
}
