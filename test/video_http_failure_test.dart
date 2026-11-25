// video_http_failure_test.dart
// HTTP 层失败分类的回归测试。
//
// 背景：用户报「有些视频放不出」，App 里只能看到
//   PlatformException(VideoError, Video player had error v.j: Source error, null, null)
// —— 403、404、超时、连接重置长得**一模一样**，因为 media3 的
// `PlaybackException.toString()` 只有「混淆类名: 一句概括」，errorCode 与 HTTP
// 状态码全被丢掉。
//
// fork `video_player_android` 2.12.2-fallback.3 起把状态码塞进了错误原文
// （见该仓库 `PlaybackErrorReport.java`），这里的用例锁住两件事：
//   1. 能正确取出 403 / 404 / 5xx / 超时；
//   2. 取不到时**不许**瞎猜 —— 旧版插件发来的消息必须退回原来的判定路径。

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/utils/video_failure.dart';
import 'package:twitter_pic_flutter/video/decoder_policy.dart';

/// 用户实测报错 + fork 新增的结构化字段（403 场景，**字段顺序与真实输出一致**）。
const String kReal403 = 'PlatformException(VideoError, Video player had error '
    'v.j: Source error [code=2004 name=ERROR_CODE_IO_BAD_HTTP_STATUS http=403 '
    'httpMessage="Forbidden" uri=http://127.0.0.1:8123/media/abc.mp4 '
    'decoder=c2.android.avc.decoder decoderMode=auto '
    'cause=InvalidResponseCodeException: Invalid response code: 403], null, null)';

const String kReal404 = 'PlatformException(VideoError, Video player had error '
    'v.j: Source error [code=2004 name=ERROR_CODE_IO_BAD_HTTP_STATUS http=404 '
    'httpMessage="Not Found" uri=http://127.0.0.1:8123/amplify_video/vid.mp4 '
    'decoder=c2.android.avc.decoder decoderMode=prefer_software '
    'cause=InvalidResponseCodeException: Invalid response code: 404], null, null)';

const String kReal503 = 'PlatformException(VideoError, Video player had error '
    'v.j: Source error [code=2004 name=ERROR_CODE_IO_BAD_HTTP_STATUS http=503 '
    'httpMessage="Service Unavailable" uri=http://127.0.0.1:8123/media/x.mp4 '
    'cause=InvalidResponseCodeException: Invalid response code: 503], null, null)';

const String kRealTimeout = 'PlatformException(VideoError, Video player had '
    'error v.j: Source error [code=2001 '
    'name=ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT '
    'uri=http://127.0.0.1:8123/media/slow.mp4 '
    'cause=SocketTimeoutException: failed to connect: Connection timed out], '
    'null, null)';

/// 旧版插件（未打 fork 补丁）发来的消息：没有任何结构化字段。
const String kLegacySourceError = 'PlatformException(VideoError, Video player '
    'had error v.j: Source error, null, null)';

void main() {
  test('从错误原文里取出 HTTP 状态码与 media3 errorCode', () {
    expect(VideoFailure.httpStatusOf(kReal403), 403);
    expect(VideoFailure.httpStatusOf(kReal404), 404);
    expect(VideoFailure.httpStatusOf(kReal503), 503);
    expect(VideoFailure.errorCodeOf(kReal403), 2004);
    expect(VideoFailure.errorCodeOf(kRealTimeout), 2001);

    // 连接层失败没有状态码；`uri=http://...` 里的 "http=" 不许被误当成状态码
    expect(VideoFailure.httpStatusOf(kRealTimeout), isNull);
    expect(VideoFailure.httpStatusOf(kLegacySourceError), isNull);
    expect(VideoFailure.errorCodeOf(kLegacySourceError), isNull);
  });

  test('403 判为上游拒绝，且不再归到"链路抖动"', () {
    expect(VideoFailure.isHttpForbidden(kReal403), isTrue);
    expect(VideoFailure.isClientHttpError(kReal403), isTrue);
    // 关键：403 的原文里也带 `Source error`，如果 isNetworkError 不排掉 4xx，
    // 文案会退化成"取不到视频数据 → 点重试"，把终局失败说成一次性抖动。
    expect(VideoFailure.isNetworkError(kReal403), isFalse);

    final msg = VideoFailure.humanize(kReal403);
    expect(msg, contains('HTTP 403'));
    expect(msg, isNot(contains('取不到视频数据')));
    // 要给出可执行的下一步：带着 uri 与状态码反馈
    expect(msg, contains('反馈'));
    expect(msg, contains('uri'));
  });

  test('404 判为永久失效，文案明确说重试没用', () {
    expect(VideoFailure.isHttpMissing(kReal404), isTrue);
    expect(VideoFailure.isNetworkError(kReal404), isFalse);
    final msg = VideoFailure.humanize(kReal404);
    expect(msg, contains('HTTP 404'));
    expect(msg, contains('重试不会成功'));
  });

  test('5xx 判为临时故障，引导用户重试', () {
    expect(VideoFailure.isHttpServerError(kReal503), isTrue);
    expect(VideoFailure.isClientHttpError(kReal503), isFalse);
    final msg = VideoFailure.humanize(kReal503);
    expect(msg, contains('HTTP 503'));
    expect(msg, contains('点重试'));
  });

  test('超时单独成类，不与"取不到数据"混在一起', () {
    expect(VideoFailure.isTimeout(kRealTimeout), isTrue);
    expect(VideoFailure.isClientHttpError(kRealTimeout), isFalse);
    expect(VideoFailure.humanize(kRealTimeout), contains('超时'));
  });

  test('旧版插件消息没有结构化字段时退回原判定（不瞎猜）', () {
    expect(VideoFailure.isClientHttpError(kLegacySourceError), isFalse);
    expect(VideoFailure.isHttpForbidden(kLegacySourceError), isFalse);
    expect(VideoFailure.isNetworkError(kLegacySourceError), isTrue);
    expect(
      VideoFailure.humanize(kLegacySourceError),
      contains('取不到视频数据'),
    );
  });

  test('4xx 不自动重试（同 URL 重试必得同一状态码）', () {
    final policy = DecoderPolicy();
    expect(policy.classify(kReal403), DecodeFailureAction.failFast);
    expect(policy.classify(kReal404), DecodeFailureAction.failFast);
    // 5xx / 超时还是一次性抖动，值得自动重试一次
    expect(policy.classify(kReal503), DecodeFailureAction.retryOnce);
    expect(policy.classify(kRealTimeout), DecodeFailureAction.retryOnce);
    // 400~499 整段都算终局，不只是 403/404
    expect(
      policy.classify('PlatformException(VideoError, ... http=429 ...)'),
      DecodeFailureAction.failFast,
    );
  });

  test('`http=` 只认三位状态码，不会被 httpMessage / uri 带偏', () {
    // httpMessage 是引号包起来的字符串，uri 是 http:// 开头，都不该命中
    expect(
      VideoFailure.httpStatusOf(
        '... [code=2004 name=ERROR_CODE_IO_BAD_HTTP_STATUS '
        'httpMessage="Forbidden" uri=http://127.0.0.1:8123/a.mp4]',
      ),
      isNull,
    );
  });
}
