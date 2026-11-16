import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

/// 横屏（或够宽的窗口）下切换到「侧边导航 + 多栏布局」；
/// 竖屏保持「底部导航 + 单栏」，和手机一致。
///
/// 用 orientation 而不是纯宽度断点，是因为用户明确要的是
/// "竖屏和横屏"两套行为——手机横过来就该用侧边栏，而不是把单栏拉宽。
/// 桌面端不论窗口是横是竖，一律走侧边导航。
///
/// 用户反馈「点开会话后左侧四项导航消失」：根因是这里原来只看 orientation，
/// 窗口被调成竖长比例时桌面也会退回手机式底栏，点会话再 push 全屏聊天就把
/// 导航盖掉。用 [defaultTargetPlatform] 而不是 `dart:io` 的 Platform，
/// 这样 flutter test 里仍是手机布局，golden 不受宿主系统影响。
bool get isDesktopPlatform =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.linux;

bool isWideLayout(BuildContext context) {
  return isDesktopPlatform ||
      MediaQuery.of(context).orientation == Orientation.landscape;
}

/// 内容最大宽度：超过后在两侧留白居中，避免界面元素在宽屏上被拉伸。
const double kMaxContentWidth = 980;

/// 「会话列表 + 聊天」两栏常驻的最小窗口宽度（逻辑像素）。
///
/// 聊天软件（微信桌面）的操作逻辑是：点会话只换右侧内容，侧边导航和
/// 会话列表**永远不消失**。以前只有 ≥1100 才这样，中等桌面窗口（例如
/// 1000×700）点会话就 push 一个全屏 ChatPage，把整个左侧都盖掉了。
/// 76(侧边导航) + 300(会话栏) + ~520(消息区) ≈ 896，取 900 作下限。
/// 手机横屏只有 844 逻辑宽且高度仅 390，仍走设计稿 04 的单栏 + 返回。
const double kConversationSplitMinWidth = 900;

/// 三栏主场（再常驻 288 宽身份卡栏）的最小窗口宽度。
/// 设计稿 05：1440 = 76 + 296 + 780 + 288；1100 时消息区仍有 ~430，够读。
const double kThreeColumnMinWidth = 1100;

/// 桌面分栏主场：会话列表常驻，聊天内嵌在右侧，不 push 全屏路由。
/// 这是"聊天软件操作逻辑"的基线；[isThreeColumnLayout] 是它的超集。
bool isConversationSplitLayout(BuildContext context) =>
    isWideLayout(context) &&
    (isDesktopPlatform ||
        MediaQuery.sizeOf(context).width >= kConversationSplitMinWidth);

/// 真正的宽桌面窗口：在分栏主场右侧再常驻身份卡栏。
/// 单看 orientation 不够：手机横过来也只有 800 多像素，硬塞
/// 「会话栏 + 消息流 + 身份卡」会把每栏压到看不清，所以按宽度分档。
bool isThreeColumnLayout(BuildContext context) =>
    isConversationSplitLayout(context) &&
    MediaQuery.sizeOf(context).width >= kThreeColumnMinWidth;
