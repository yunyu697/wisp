import 'package:flutter/material.dart';

/// 横屏（或够宽的窗口）下切换到「侧边导航 + 多栏布局」；
/// 竖屏保持「底部导航 + 单栏」，和手机一致。
///
/// 用 orientation 而不是纯宽度断点，是因为用户明确要的是
/// "竖屏和横屏"两套行为——手机横过来就该用侧边栏，而不是把单栏拉宽。
bool isWideLayout(BuildContext context) {
  return MediaQuery.of(context).orientation == Orientation.landscape;
}

/// 内容最大宽度：超过后在两侧留白居中，避免界面元素在宽屏上被拉伸。
const double kMaxContentWidth = 980;

/// 三栏聊天主场只在真正的宽桌面窗口启用。
///
/// 单看 orientation 不够：默认测试视口 800×600 也是横屏，手机横过来也只
/// 有 800 多像素，硬塞「会话栏 + 消息流 + 身份卡」会把每栏压到看不清。
/// 用宽度兜一层，同时让窄窗口 / 移动端继续走原来的单栏 + push 会话页。
bool isThreeColumnLayout(BuildContext context) =>
    isWideLayout(context) && MediaQuery.sizeOf(context).width >= 1100;
