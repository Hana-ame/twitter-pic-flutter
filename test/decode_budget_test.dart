// decode_budget_test.dart
// 解码器并发上限的自适应策略。
//
// 这层必须测：它决定"设备能吃几个并发解码器"，调错了要么拖慢封面铺满
// （上限压太低），要么在低端机上反复撞硬解上限（上限放太高）。
// 线上报错 `MediaCodecVideoRenderer error ... format_supported=YES` 就是后者。

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/utils/decode_budget.dart';

void main() {
  test('默认从 2 起步，不会超过上下限', () {
    final b = DecodeBudget();
    expect(b.value, 2);

    // 初始值越界也要夹住
    expect(DecodeBudget(initial: 99).value, 4);
    expect(DecodeBudget(initial: 0).value, 1);
    expect(DecodeBudget(initial: 0, floor: 1).value, 1);
  });

  test('连续成功 3 次上调 1，之后重新计数', () {
    final b = DecodeBudget(initial: 2);
    expect(b.onSuccess(), isFalse);
    expect(b.onSuccess(), isFalse);
    expect(b.onSuccess(), isTrue, reason: '第 3 次连续成功应上调');
    expect(b.value, 3);
    // 连击清零，不会立刻再涨
    expect(b.onSuccess(), isFalse);
    expect(b.value, 3);
  });

  test('连续成功也不会超过 ceiling', () {
    final b = DecodeBudget(initial: 2, ceiling: 3);
    for (var i = 0; i < 30; i++) {
      b.onSuccess();
    }
    expect(b.value, 3);
  });

  test('Codec 失败立即下调，且清掉连击', () {
    final b = DecodeBudget(initial: 3);
    b.onSuccess();
    b.onSuccess(); // 连击 2
    expect(b.onCodecFailure(), isTrue);
    expect(b.value, 2);
    expect(b.streak, 0, reason: '失败必须清掉连击，否则残次连击会误判成有余量');
    // 再来两次成功不该立刻上调（连击从 0 重新数）
    expect(b.onSuccess(), isFalse);
    expect(b.onSuccess(), isFalse);
    expect(b.value, 2);
  });

  test('下调到 floor 就停住，永远不会到 0', () {
    final b = DecodeBudget(initial: 2, floor: 1);
    expect(b.onCodecFailure(), isTrue);
    expect(b.value, 1);
    expect(b.onCodecFailure(), isFalse);
    expect(b.value, 1, reason: '下限保证永远有一路能推进，不会卡死');
  });

  test('失败后再成功可以重新涨回去（设备情况会变：别的 App 放开了解码器）', () {
    final b = DecodeBudget(initial: 3);
    b.onCodecFailure();
    expect(b.value, 2);
    b.onSuccess();
    b.onSuccess();
    expect(b.onSuccess(), isTrue);
    expect(b.value, 3);
  });
}
