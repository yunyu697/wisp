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

  /// 单条消息上限，防止异常报文撑爆内存。
  static const int maxDatagramBytes = 64 * 1024;

  /// 文件分块大小：1 MiB 是吞吐与内存占用的折中点。
  static const int chunkSize = 1024 * 1024;
}
