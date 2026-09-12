// video_decoder_pool_test.dart
// 解码器槽位池的分槽/抢占语义。
//
// **发现背景**：这套逻辑原来内联在 twitter_video.dart 的私有 `_PlayerPool` 里，
// 三个线上 bug 全靠真机时序才暴露：①把并发压死后其余卡片变成"点按加载"占位
// （v0.5.3 的错）；②用户点播却抢不到槽位 —— 抢占只允许挤"看不见"的卡片，而
// 屏幕上占位的恰好都是看得见的（v0.5.6 修的"点不动"）；③pump 里被打回的卡片
// 立刻重新 request，抢位白做、来回抖动。v0.5.13 拆封装后（面向 DecoderSlotUser
// 接口）终于能用假对象复现这三类场景，本文件把它们全部锁住。

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/utils/decode_budget.dart';
import 'package:twitter_pic_flutter/video/decoder_policy.dart';
import 'package:twitter_pic_flutter/video/video_decoder_pool.dart';

class _FakeUser implements DecoderSlotUser {
  _FakeUser({
    this.visible = true,
    this.playing = false,
    this.poster = false,
    this.needsPoster = true,
  });

  bool visible;
  bool playing;
  bool poster;
  bool needsPoster;

  int grantedCount = 0;
  int revokedCount = 0;

  @override
  bool get slotMounted => true;
  @override
  bool get slotNeedsPoster => needsPoster;
  @override
  bool get slotVisibleNow => visible;
  @override
  bool get slotIsPlaying => playing;
  @override
  bool get slotHasPoster => poster;
  @override
  void onSlotGranted() => grantedCount++;
  @override
  void onSlotRevoked() => revokedCount++;

  @override
  String toString() =>
      '_FakeUser(v=$visible,p=$playing,poster=$poster,g=$grantedCount,r=$revokedCount)';
}

VideoDecoderPool _pool({int max = 2}) => VideoDecoderPool(
      policy: DecoderPolicy(
        budget: DecodeBudget(
          initial: max,
          floor: 1,
          ceiling: max,
          // 这些用例不测上调；给个大数免得 noteSuccess 副作用干扰。
          successStreakToRaise: 999,
        ),
      ),
      note: (s, m) {},
      saveBudget: (_) {},
    );

void main() {
  group('基本分槽', () {
    test('有空位立即 grant，满了排队', () {
      final p = _pool(max: 2);
      final a = _FakeUser(), b = _FakeUser(), c = _FakeUser();

      expect(p.request(a), isTrue);
      expect(p.request(b), isTrue);
      expect(p.request(c), isFalse);
      expect(p.isWaiting(c), isTrue);
      expect(a.grantedCount, 1);
      expect(c.grantedCount, 0);

      // 交还一个，队首自动补上
      p.release(a);
      expect(c.grantedCount, 1);
      expect(p.isWaiting(c), isFalse);
    });

    test('重复 request 同一个用户不会二次 grant', () {
      final p = _pool(max: 2);
      final a = _FakeUser();
      expect(p.request(a), isTrue);
      expect(p.request(a), isTrue);
      expect(a.grantedCount, 1, reason: '_live.contains 短路，否则双解码器');
    });

    test('已有封面的用户走自动路径不给槽位（不白占解码器）', () {
      final p = _pool(max: 2);
      final a = _FakeUser(poster: true, needsPoster: false);
      // 卡片侧 _requestSlot 会先挡住；池子本身对"已拿到过"的也幂等。
      expect(p.request(a), isTrue);
      expect(p.request(a), isTrue);
      expect(a.grantedCount, 1);
    });
  });

  group('可见优先与抢占', () {
    test('槽位被看不见的卡片占着：排队者里看得见的可以把它收回来', () {
      final p = _pool(max: 1);
      final hidden = _FakeUser(visible: false, poster: true);
      final shown = _FakeUser(visible: true);
      expect(p.request(hidden), isTrue);
      expect(p.request(shown), isFalse);

      p.nudge();
      expect(shown.grantedCount, 1, reason: '可见优先：用户正看着的不用等');
      expect(hidden.revokedCount, 1);
      expect(hidden.grantedCount, 1, reason: '被收走只 revoke，不重复 grant');
    });

    test('自动排队者不许抢占**看得见**的占位卡片（防来回抖动）', () {
      final p = _pool(max: 1);
      final occupant = _FakeUser(visible: true, playing: false);
      final waiter = _FakeUser(visible: true);
      expect(p.request(occupant), isTrue);
      expect(p.request(waiter), isFalse);

      p.nudge();
      expect(waiter.grantedCount, 0, reason: '非 urgent 只挤得掉看不见的');
      expect(occupant.revokedCount, 0);
    });

    test('用户点播（urgent）可挤掉任何非播放卡片，且一轮只抢一次', () {
      final p = _pool(max: 1);
      final playing = _FakeUser(visible: true, playing: true);
      expect(p.request(playing), isTrue);
      final tapped = _FakeUser(visible: true);

      expect(p.request(tapped, urgent: true), isTrue);
      expect(tapped.grantedCount, 1);
      expect(playing.revokedCount, 1, reason: '用户已经在看新的，停旧的可接受');

      // 正在播的卡片被 revoke 后会重新排队（onSlotRevoked 里 request）；
      // 不许它立刻把刚给用户腾出来的槽位又抢回去 —— 一轮只处理一次抢占。
      p.nudge();
      expect(playing.grantedCount, 1, reason: '再 nudge 也不该二次抢占');
    });

    test('牺牲者按"损失最小"排序：先挑已有封面的看不见卡片', () {
      final p = _pool(max: 2);
      final noPoster = _FakeUser(visible: false, poster: false);
      final withPoster = _FakeUser(visible: false, poster: true);
      expect(p.request(noPoster), isTrue);
      expect(p.request(withPoster), isTrue);

      final tapped = _FakeUser(visible: true);
      expect(p.request(tapped, urgent: true), isTrue);
      expect(withPoster.revokedCount, 1, reason: '有封面的收回仍有画面');
      expect(noPoster.revokedCount, 0);
    });
  });

  group('兜底与自适应', () {
    test('抓帧不可用后不再限制并发（退回"每张卡片自己拿播放器"）', () {
      final p = _pool(max: 1);
      final a = _FakeUser(), b = _FakeUser(), c = _FakeUser();
      p.request(a);
      p.request(b);
      p.request(c);
      expect(p.waitingCount, 2);

      p.noteCaptureUnavailable();
      expect(b.grantedCount, 1);
      expect(c.grantedCount, 1, reason: '已在排队的全部放行');
      expect(p.waitingCount, 0);
    });

    test('noteSuccess 连击够数才上调，并存档新值', () {
      final saved = <int>[];
      final p = VideoDecoderPool(
        policy: DecoderPolicy(
          budget: DecodeBudget(initial: 1, ceiling: 3, successStreakToRaise: 2),
        ),
        note: (s, m) {},
        saveBudget: saved.add,
      );
      p.noteSuccess();
      expect(p.max, 1, reason: '第 1 次不算连击');
      p.noteSuccess();
      expect(p.max, 2);
      expect(saved, [2], reason: '学到的值必须落盘，否则冷启动重新试探');
    });
  });
}
