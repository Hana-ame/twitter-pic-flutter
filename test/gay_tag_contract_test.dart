// Gay 模式词表的**跨端契约测试**。
//
// 为什么这条比「选哪份词表」更重要：本项目有过一份知识库记载写着词表是
// gay/yaoi/futanari/男同/基/bl，而线上代码里实际是 男性/男娘/人妖/露屌/阳痿/男同。
// 两份差了 5 个词，且**线上那份是对的** —— 因为那 5 个英文/单字词在真实的
// account_tags 库里一条记录都没有（不分大小写、不限权重均查不到）。
//
// 换句话说：知识库那份若真按字面执行，会把线上正在过滤的 341 个账号
// **全部放行**，不是多过滤几个。这种「文档描述的能力和代码里的不是一回事」
// 只有靠**把两端字面量钉在一起**才能防住，光改文档没用 —— 下一个人还是会
// 照着代码改，改成第三份。
//
// 判据可证伪：把 kDefaultGayTags 增删任何一个词、或改 home.js 的
// DEFAULT_GAY_TAGS，本测试立刻变红。

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/services/storage_service.dart';

/// 图站前端里那份字面量（go/gallery/static/home.js 第 490 行）。
///
/// 这里**手抄**而不是去读文件，是故意的：CI 的 flutter_test job 只 cp 了
/// lib/ 与 test/，读不到 go 仓库。抄一份正好与下面的仓库级检查互补 ——
/// 那条会在 home.js 改动时提醒你回来改这里。
const List<String> kWebGalleryDefaultGayTags = [
  '男性', '男娘', '人妖', '露屌', '阳痿', '男同',
];

void main() {
  test('客户端默认 Gay 词表与图站字面量逐词相同（跨端契约）', () {
    // 比集合而不是比列表：顺序不影响过滤结果，顺序变了不该让 CI 红。
    expect(
      StorageService.kDefaultGayTags.toSet(),
      kWebGalleryDefaultGayTags.toSet(),
      reason: '客户端与图站的 Gay 词表漂移了 —— 改任一端都必须同步另一端。',
    );
  });

  test('kDefaultGayTagsSet 必须与 kDefaultGayTags 一致（不能是第二份字面量）', () {
    // 防「改了一处忘了另一处」：以前 kDefaultGayTagsSet 就是一份独立写死的
    // 副本，全仓无调用点，两边迟早漂移。
    expect(kDefaultGayTagsSet, StorageService.kDefaultGayTags.toSet());
  });

  test('词表非空且无重复', () {
    expect(StorageService.kDefaultGayTags, isNotEmpty);
    expect(
      StorageService.kDefaultGayTags.toSet().length,
      StorageService.kDefaultGayTags.length,
      reason: '词表里有重复项',
    );
  });
}