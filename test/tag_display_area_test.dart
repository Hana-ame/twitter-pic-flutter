import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/widgets/tag_display_area.dart';

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('TagDisplayArea 高亮标记', () {
    testWidgets('命中高亮集的标签显示星标', (tester) async {
      await tester.pumpWidget(wrap(TagDisplayArea(
        highlights: {'二次元'},
        tags: {'二次元': 1, '自拍': -1},
      )));

      expect(find.byIcon(Icons.star), findsOneWidget);
      expect(find.text('二次元'), findsOneWidget);
      expect(find.text('自拍'), findsOneWidget);
    });

    testWidgets('未命中高亮集则无星标', (tester) async {
      await tester.pumpWidget(wrap(TagDisplayArea(
        highlights: {},
        tags: {'自拍': -1},
      )));

      expect(find.byIcon(Icons.star), findsNothing);
    });

    testWidgets('空标签渲染为空', (tester) async {
      await tester.pumpWidget(wrap(const TagDisplayArea(tags: {})));
      expect(find.text('二次元'), findsNothing);
    });
  });
}
