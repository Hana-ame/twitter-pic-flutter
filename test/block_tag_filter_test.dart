// 「屏蔽标签」从**死功能**接通成真过滤的判据。
//
// 背景：标签管理页能存「屏蔽」标签列表（StorageService.setBlockTags），
// 全仓原本**只有一个**读取点 —— 详情页顶部的提示条。任何列表都不消费它，
// 用户配了规则却看不到任何效果。
//
// 本文件钉三件事，每条都**可证伪**：
//  1) 命中屏蔽标签的账号，列表里真的不出现；
//  2) 没命中的照常出现（防「过滤写死成全部隐藏」）；
//  3) 负分标签不算命中（负分在详情页本就不展示，拿它当屏蔽依据会
//     凭空多屏蔽一批人）。
//
// 只测纯函数 StorageService.shouldHideUser / blockTagHits —— 这正是本次
// 把它收成单一权威判定的目的：规则只有一份，测试也就只需一处。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:twitter_pic_flutter/services/storage_service.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

void main() {
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('blocktags');
    PathProviderPlatform.instance = _FakePathProvider(tmpDir.path);
    await StorageService.ensureInitialized();
    await StorageService.clearAll();
    await StorageService.ensureInitialized();
  });

  tearDown(() async {
    await StorageService.clearAll();
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  test('命中屏蔽标签的账号应被隐藏（本次接通的主判据）', () {
    StorageService.setBlockTags(['无关内容']);
    expect(StorageService.shouldHideUser('alice', {'无关内容': 3}), isTrue,
        reason: '带正权重屏蔽标签的账号应当从列表里消失');
  });

  test('没命中屏蔽标签的账号照常显示（防过滤写死成全部隐藏）', () {
    StorageService.setBlockTags(['无关内容']);
    expect(StorageService.shouldHideUser('bob', {'自拍': 3}), isFalse,
        reason: '只有命中屏蔽标签的才隐藏，不能连坐');
  });

  test('负分标签不算命中屏蔽', () {
    StorageService.setBlockTags(['无关内容']);
    expect(StorageService.shouldHideUser('carol', {'无关内容': -1}), isFalse,
        reason: '负分标签在详情页本就不展示，拿它当屏蔽依据会多屏蔽一批人');
  });

  test('blockTagHits 返回具体命中的标签名（详情页提示条要用）', () {
    StorageService.setBlockTags(['无关内容', '广告']);
    final hits = StorageService.blockTagHits({'无关内容': 2, '自拍': 5});
    expect(hits, ['无关内容']);
  });

  test('屏蔽列表为空时不过滤任何人', () {
    StorageService.setBlockTags([]);
    expect(StorageService.shouldHideUser('dave', {'无关内容': 3}), isFalse);
  });

  test('用户名屏蔽仍然生效（既有能力不能因为合并而丢）', () {
    StorageService.setBlockTags(['无关内容']);
    StorageService.toggleBlock('erin');
    expect(StorageService.shouldHideUser('erin', {'自拍': 1}), isTrue,
        reason: '按用户名的屏蔽是既有功能，收成 shouldHideUser 后不能丢');
  });

  test('Gay 模式仍独立生效，且不被屏蔽标签规则压掉', () {
    StorageService.setBlockTags(['男同']);
    expect(StorageService.isGayMode(), isFalse);
    expect(StorageService.shouldHideUser('frank', {'男同': 1}), isTrue);
    // 开启后应放行；此时屏蔽标签不能反过来把它又拦下，
    // 否则开了 Gay 模式反而什么都看不到。
    StorageService.setGayMode(true);
    expect(StorageService.shouldHideUser('frank', {'男同': 1}), isFalse,
        reason: 'Gay 模式下与 Gay 词重叠的屏蔽标签不触发，两条规则不能打架');
  });
}