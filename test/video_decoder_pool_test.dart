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

VideoDecoderPool _pool({
  int max = 2,
  Duration handoff = Duration.zero,
  Duration hold = Duration.zero,
}) =>
    VideoDecoderPool(
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
      handoffSettle: handoff,
      playerPriorityHold: hold,
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
      // 抢占就发生在 request() 内部的 pump 里（victim 看不见且没在播 →
      // 直接收位），所以 shown 当场拿到槽位。
      expect(p.request(shown), isTrue);
      expect(shown.grantedCount, 1, reason: '可见优先：用户正看着的不用等');
      expect(hidden.revokedCount, 1);
      expect(hidden.grantedCount, 1, reason: '被收走只 revoke，不重复 grant');

      p.nudge();
      expect(shown.grantedCount, 1, reason: 'nudge 幂等，不重复 grant');
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

    test('用户点播（urgent）可挤掉正在播的那张', () {
      final p = _pool(max: 1);
      final playing = _FakeUser(visible: true, playing: true);
      expect(p.request(playing), isTrue);
      final tapped = _FakeUser(visible: true);

      expect(p.request(tapped, urgent: true), isTrue);
      expect(tapped.grantedCount, 1);
      expect(playing.revokedCount, 1, reason: '用户已经在看新的，停旧的可接受');
      expect(p.player, same(tapped), reason: '槽位跟着正在播的这一张走');

      // 正在播的卡片被 revoke 后会重新排队（onSlotRevoked 里 request）；
      // 不许它立刻把刚给用户腾出来的槽位又抢回去。
      p.nudge();
      expect(playing.grantedCount, 1, reason: '再 nudge 也不该二次抢占');
    });

    test('用户点播直接清场：所有持槽者都让位（硬解实例全机唯一）', () {
      final p = _pool(max: 2);
      final noPoster = _FakeUser(visible: false, poster: false);
      final withPoster = _FakeUser(visible: false, poster: true);
      expect(p.request(noPoster), isTrue);
      expect(p.request(withPoster), isTrue);

      final tapped = _FakeUser(visible: true);
      expect(p.request(tapped, urgent: true), isTrue);
      expect(withPoster.revokedCount, 1, reason: '有封面的收回仍有画面');
      expect(noPoster.revokedCount, 1,
          reason: '只要还活着就占着硬解实例，必须一起让位 —— 抢不到就是软解，'
              '不是"慢一点"，这正是"第二个视频变软解"的成因');
      expect(p.liveCount, 1, reason: '全机只剩正在播的这一个解码器');
      expect(p.player, same(tapped));
    });

    test('用户点播即使有空位也清场（不能等到"槽位满了"才让位）', () {
      final p = _pool(max: 3);
      final holder = _FakeUser(poster: true, needsPoster: false, playing: true);
      expect(p.request(holder), isTrue);
      expect(p.liveCount, 1, reason: '只占了一个，上限是 3');

      final tapped = _FakeUser(poster: true, needsPoster: false);
      expect(p.request(tapped, urgent: true), isTrue);
      expect(holder.revokedCount, 1,
          reason: '槽位没满不代表硬解没被占：旧播放器还在播就还是它拿着硬解');
      expect(p.liveCount, 1);
    });
  });

  group('谁在播谁拿硬解', () {
    test('claimPlayback 让其它持槽者退场，并把 player 记到自己名下', () {
      final p = _pool(max: 3);
      final a = _FakeUser(poster: true, needsPoster: false);
      final b = _FakeUser(poster: true, needsPoster: false);
      final playing = _FakeUser(poster: true, needsPoster: false);
      p.request(a);
      p.request(b);
      p.request(playing);
      expect(p.liveCount, 3);

      playing.playing = true;
      p.claimPlayback(playing);
      expect(p.player, same(playing));
      expect(a.revokedCount, 1);
      expect(b.revokedCount, 1);
      expect(p.liveCount, 1);
      expect(playing.grantedCount, 1, reason: '已经在持槽，不该重复 grant');
    });

    test('claimPlayback 幂等：只有自己时什么都不做', () {
      final p = _pool(max: 2);
      final a = _FakeUser();
      p.request(a);
      p.claimPlayback(a);
      expect(p.player, same(a));
      expect(a.revokedCount, 0);
      expect(a.grantedCount, 1);
    });

    test('release 会把 player 标记一起清掉（换人播时不会误判成还在播）', () {
      final p = _pool(max: 2);
      final a = _FakeUser();
      p.request(a);
      p.claimPlayback(a);
      expect(p.player, same(a));
      p.release(a);
      expect(p.player, isNull);
    });

    test('播放者交还槽位后，被清场的卡片重新排队仍能拿到', () {
      final p = _pool(max: 2);
      final playing = _FakeUser(poster: true, needsPoster: false);
      final waiter = _FakeUser();
      p.request(playing);
      p.request(waiter);
      expect(waiter.grantedCount, 1, reason: '上限 2，本来就有空位');

      p.claimPlayback(playing);
      expect(waiter.revokedCount, 1);

      p.release(playing);
      expect(p.request(waiter), isTrue, reason: '播放者交还后立刻补位');
      expect(waiter.grantedCount, 2);
    });
  });

  group('硬解交接（waitForHandoff）', () {
    test('没发生过收走时立即返回，不引入额外延迟', () async {
      final p = _pool(max: 2, handoff: const Duration(milliseconds: 60));
      expect(p.sinceLastRevoke, isNull);
      final sw = Stopwatch()..start();
      await p.waitForHandoff();
      expect(sw.elapsedMilliseconds, lessThan(40));
    });

    test('刚收走槽位时接手方要等硬解真正释放', () async {
      final p = _pool(max: 1, handoff: const Duration(milliseconds: 80));
      final playing = _FakeUser(playing: true);
      p.request(playing);
      final tapped = _FakeUser();
      p.request(tapped, urgent: true);
      expect(p.sinceLastRevoke, isNotNull, reason: '收走必须留痕，接手方据此等待');

      final sw = Stopwatch()..start();
      await p.waitForHandoff(forPlayback: true);
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(40),
          reason: '不等就会在硬解还被占着的时候 prepare → Media3 静默回退软解');
    });

    test('有人正在播时，自动抓封面要让播放者先 prepare', () async {
      final p = _pool(
        max: 3,
        handoff: Duration.zero,
        hold: const Duration(milliseconds: 60),
      );
      final player = _FakeUser(playing: true);
      p.request(player, urgent: true);
      expect(p.player, same(player));

      // 自动抓封面（forPlayback=false）：要让步。
      final poster = Stopwatch()..start();
      await p.waitForHandoff();
      poster.stop();
      expect(poster.elapsedMilliseconds, greaterThanOrEqualTo(30),
          reason: '和播放者同时冲上去，先到 codec server 的会把唯一一路硬解占走');

      // 播放请求（forPlayback=true）：已经清场了，不必再等。
      final play = Stopwatch()..start();
      await p.waitForHandoff(forPlayback: true);
      play.stop();
      expect(play.elapsedMilliseconds, lessThan(30));
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
