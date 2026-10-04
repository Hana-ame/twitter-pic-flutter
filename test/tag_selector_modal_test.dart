// tag_selector_modal 的「至少选一个标签」约束（v0.6.3）。
//
// 背景：服务端首次添加用户的分支要求必须带标签（空 map → 400
// 「你没加tag，这是不行的」，实测生产无 body 直接 POST → 400 EOF）。
// 所以添加用户时确认按钮必须在未选标签时禁用，避免白跑一次往返再报错。
//
// 改已有账号的标签时保持默认 false——那时允许全不选（等于撤掉全部标签）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/widgets/tag_selector_modal.dart';

Widget _wrap({
  required bool requireAtLeastOneTag,
  required void Function(Map<String, int>) onConfirm,
}) {
  return MaterialApp(
    home: Scaffold(
      body: TagSelectorModal(
        isOpen: true,
        requireAtLeastOneTag: requireAtLeastOneTag,
        username: 'alice',
        onClose: () {},
        onConfirm: onConfirm,
      ),
    ),
  );
}

/// 找到「确认保存」那个按钮（改标签时文案会变，这里按类型找）。
ElevatedButton _confirmButton(WidgetTester tester) {
  return tester.widget<ElevatedButton>(
    find.widgetWithText(ElevatedButton, '确认保存').evaluate().isNotEmpty
        ? find.widgetWithText(ElevatedButton, '确认保存')
        : find.widgetWithText(ElevatedButton, '确认保存（至少选一个标签）'),
  );
}

void main() {
  testWidgets('requireAtLeastOneTag=true：没选标签时确认按钮禁用', (tester) async {
    Map<String, int>? confirmed;
    await tester.pumpWidget(_wrap(
      requireAtLeastOneTag: true,
      onConfirm: (t) => confirmed = t,
    ));
    await tester.pumpAndSettle();

    final btn = _confirmButton(tester);
    expect(btn.onPressed, isNull,
        reason: '添加用户时空标签必然被服务端拒，不该允许提交');
    expect(confirmed, isNull);
  });

  testWidgets('requireAtLeastOneTag=false：没选标签也能提交（允许清空标签）',
      (tester) async {
    Map<String, int>? confirmed;
    await tester.pumpWidget(_wrap(
      requireAtLeastOneTag: false,
      onConfirm: (t) => confirmed = t,
    ));
    await tester.pumpAndSettle();

    final btn = _confirmButton(tester);
    expect(btn.onPressed, isNotNull,
        reason: '改已有账号的标签时允许全不选（= 撤掉全部标签）');

    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();
    expect(confirmed, isNotNull);
    expect(confirmed, isEmpty);
  });

  testWidgets('requireAtLeastOneTag=true：提示文案说明为什么要选标签',
      (tester) async {
    await tester.pumpWidget(_wrap(
      requireAtLeastOneTag: true,
      onConfirm: (_) {},
    ));
    await tester.pumpAndSettle();
    expect(find.text('确认保存（至少选一个标签）'), findsOneWidget);
  });
}