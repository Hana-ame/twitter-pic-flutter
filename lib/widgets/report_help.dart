// report_help.dart
// 反馈相关的共用弹窗：异常退出提示 / 加群说明 / 复制日志包。
//
// 主界面（启动时发现上次没正常结束）与设置页（用户主动反馈）都用这里，
// 保证两处文案与行为一致 —— 反馈渠道只有一处定义（LogService 里的常量）。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/log_service.dart';

/// 复制完整反馈包（日志 + 运行时上下文 + 加群方式）到剪贴板。
Future<void> copyLogDump(
  BuildContext context, {
  Map<String, String> extra = const <String, String>{},
}) async {
  // await 之前先取 messenger，之后再取会用到可能已失效的 context。
  final messenger = ScaffoldMessenger.of(context);
  final dump = await LogService.buildDump(extra: extra);
  await Clipboard.setData(ClipboardData(text: dump));
  messenger.showSnackBar(const SnackBar(
    content: Text('日志已复制，粘贴到群里即可'),
    duration: Duration(seconds: 3),
  ));
}

/// 反馈渠道的说明块（加群 + 申请 + 房间名），可复制。
///
/// 这里刻意**不给整个 Column 加 const**：`SelectableText` 的构造函数在
/// 各版本里是否 const 不一致（本项目被 `Container` / `Icon` 的同类问题炸过），
/// 少一个 const 只是少一点优化，写错 const 是编译错误。
Widget _groupInfo() {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('加群即可反馈（把日志发到群里）：',
          style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      SelectableText(LogService.kGroupUrl),
      const SizedBox(height: 4),
      SelectableText('注册不了：${LogService.kGroupApplyUrl}'),
      const SizedBox(height: 4),
      Text('群内房间：${LogService.kGroupRoom}',
          style: const TextStyle(fontSize: 12, color: Colors.grey)),
    ],
  );
}

/// 上次没有正常结束时，启动后弹这个。
///
/// 措辞刻意不说「闪退」：被系统回收后台进程、用户从任务管理器强杀，也会
/// 落到同一个判定里（见 LogService.takeUncleanExit 的注释）。
Future<void> showExitReportDialog(
  BuildContext context, {
  required Incident incident,
  Map<String, String> extra = const <String, String>{},
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('上次运行没有正常结束'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(incident.describe, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 10),
            const Text('可能是闪退，也可能是后台进程被系统回收了。\n'
                '如果你刚才确实遇到了闪退、卡死或黑屏，请反馈一下：'),
            const SizedBox(height: 12),
            _groupInfo(),
            const SizedBox(height: 12),
            const Text('点「复制日志」会把本机日志打包成一段文字，直接粘贴到群里即可。',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await copyLogDump(ctx, extra: extra);
          },
          child: const Text('复制日志'),
        ),
        TextButton(
          onPressed: () async {
            await LogService.suppressPrompt();
            if (ctx.mounted) Navigator.pop(ctx);
          },
          child: const Text('不再提示'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

/// 设置页里的「加群反馈」说明。
Future<void> showGroupHelpDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('反馈'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _groupInfo(),
            const SizedBox(height: 12),
            const Text('遇到闪退、播放失败、图片空白等问题，请附上「复制日志」的内容。',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
      ],
    ),
  );
}
