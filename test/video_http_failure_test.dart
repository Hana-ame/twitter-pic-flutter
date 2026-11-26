// video_http_failure_test.dart
// HTTP 层失败分类的回归测试。
//
// 背景：用户报「有些视频放不出」，App 里只能看到
//   PlatformException(VideoError, Video player had error v.j: Source error, null, null)
// —— 403、404、超时、连接重置长得**一模一样**，因为 media3 的
// `PlaybackException.toString()` 只有「混淆类名: 一句概括」，errorCode 与 HTTP
// 状态码全被丢掉。
//
// fork `video_player_android` 2.12.2-fallback.4 起把这几个字段拼进错误原文
// （`ExoPlayerEventListener.formatPlaybackError`），这里的用例锁住两件事：
//   1. 能从 `[ERROR_CODE_*, HTTP xxx]` 里取出状态码，且 403/404/410 判终局；
//   2. 取不到时**不许**瞎猜 —— 旧版插件发来的消息必须退回原来的判定路径。

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/utils/video_failure.dart';
import 'package:twitter_pic_flutter/video/decoder_policy.dart';

/// fork 版真实输出形状（403，字段顺序与 formatPlaybackError 一致）。
const String kReal403 = 'PlatformException(VideoError, Video player had error '
    'v.j: Source error [ERROR_CODE_IO_BAD_HTTP_STATUS, HTTP 403] '
    'uri=http://127.0.0.1:8443/media/abc.mp4 '
    'decoder=c2.android.avc.decoder decoderMode=auto '
    '(InvalidResponseCodeException: Response code: 403), null, null)';

const String kReal404 = 'PlatformException(VideoError, Video player had error '
    'v.j: Source error [ERROR_CODE_IO_BAD_HTTP_STATUS, HTTP 404] '
    'uri=http://127.0.0.1:8443/amplify_video/vid.mp4 '
    'decoder=c2.android.avc.decoder decoderMode=prefer_software '
    '(InvalidResponseCodeException: Response code: 404), null, null)';

const String kReal502 = 'PlatformException(VideoError, Video player had error '
    'v.j: Source error [ERROR_CODE_IO_BAD_HTTP_STATUS, HTTP 502] '
    'uri=http://127.0.0.1:8443/media/x.mp4 '
    '(InvalidResponseCodeException: Response code: 502), null, null)';

const String kRealTimeout = 'PlatformException(VideoError, Video player had '
    'error v.j: Source error [ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT] '
    'uri=http://127.0.0.1:8443/media/slow.mp4 '
    '(SocketTimeoutException: failed to connect: Connection timed out), null, null)';

/// 旧版插件（未打 fork 补丁）发来的消息：没有任何结构化字段。
const String kLegacySourceError = 'PlatformException(VideoError, Video player '
    'had error v.j: Source error, null, null)';

void main() {
  test('从错误原文里取出 HTTP 状态码', () {
    expect(VideoFailure.httpStatusCode(kReal403), 403);
    expect(VideoFailure.httpStatusCode(kReal404), 404);
    expect(VideoFailure.httpStatusCode(kReal502), 502);
    // 连接层失败没有状态码；uri 里的 `127.0.0.1:8443` 不许被当成状态码
    expect(VideoFailure.httpStatusCode(kRealTimeout), isNull);
    expect(VideoFailure.httpStatusCode(kLegacySourceError), isNull);
  });

  test('403/404/410 判为终局，不再归到"链路抖动"', () {
    for (final msg in <String>[kReal403, kReal404]) {
      expect(VideoFailure.isHttpGoneOrForbidden(msg), isTrue, reason: msg);
      // 关键：403 的原文里也带 `Source error`，如果 isNetworkError 不排掉
      // 403/404，文案会退化成"取不到视频数据 → 点重试"，把终局失败说成
      // 一次性抖动，用户只会反复点一个必然失败的动作。
      expect(VideoFailure.isNetworkError(msg), isFalse, reason: msg);
    }
    expect(
      VideoFailure.isHttpGoneOrForbidden('... [ERROR_CODE_IO_BAD_HTTP_STATUS, HTTP 410] ...'),
      isTrue,
    );
  });

  test('5xx 不判终局，仍走可重试的网络路径', () {
    expect(VideoFailure.isHttpGoneOrForbidden(kReal502), isFalse);
    expect(VideoFailure.isNetworkError(kReal502), isTrue);
  });

  test('旧版插件消息没有结构化字段时退回原判定（不瞎猜）', () {
    expect(VideoFailure.httpStatusCode(kLegacySourceError), isNull);
    expect(VideoFailure.isHttpGoneOrForbidden(kLegacySourceError), isFalse);
    expect(VideoFailure.isNetworkError(kLegacySourceError), isTrue);
    expect(
      VideoFailure.humanize(kLegacySourceError),
      contains('取不到视频数据'),
    );
  });

  test('403/404 不自动重试，5xx 与超时仍重试一次', () {
    final policy = DecoderPolicy();
    expect(policy.classify(kReal403), DecodeFailureAction.failFast);
    expect(policy.classify(kReal404), DecodeFailureAction.failFast);
    expect(policy.classify(kReal502), DecodeFailureAction.retryOnce);
    expect(policy.classify(kRealTimeout), DecodeFailureAction.retryOnce);
  });

  test('文案里要带上可执行的信息', () {
    // 403 的文案必须让用户能照着反馈（带上状态码），不是只说"加载失败"
    final forbidden = VideoFailure.humanize(kReal403);
    expect(forbidden, contains('403'));
    // 404 必须说清重试没用
    final missing = VideoFailure.humanize(kReal404);
    expect(missing, contains('404'));
  });

  test('状态码只认三位，不会被 uri / decoder 带偏', () {
    expect(
      VideoFailure.httpStatusCode(
        '... [ERROR_CODE_IO_BAD_HTTP_STATUS] uri=http://127.0.0.1:8443/a.mp4 '
        'decoder=c2.android.avc.decoder',
      ),
      isNull,
    );
  });
}
