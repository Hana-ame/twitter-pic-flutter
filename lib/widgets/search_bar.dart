// 搜索栏组件：支持搜索历史、清除历史，以及边打字边给的标签推荐下拉（不需要输入 #）。
import 'package:flutter/material.dart';

import '../models/user.dart';
import '../services/storage_service.dart';
import 'tag_suggestions.dart';

class SearchBarWidget extends StatefulWidget {
  final ValueChanged<String> onChanged;
  final String placeholder;

  /// 全站标签表。**非空即意味着「支持标签推荐」**——为空时不弹下拉，
  /// 搜索栏退回纯历史 + 过滤的原有行为。
  ///
  /// 为什么用「有没有标签表」当开关而不是再传一个 bool：标签表是标签云那
  /// 次请求的副产品，同一份数据；再传一个 flag 就多出一份可能与标签表不一致
  /// 的状态（flag 说有、表却是空的 → 弹一个空下拉）。
  final List<TagCount> tagCloud;

  /// 点了某个推荐标签。回调参数是**不带 `#`** 的标签名。
  ///
  /// 传了就弹推荐下拉并接住点击；不传则即便有标签表也不弹（调用方只想
  /// 要搜索框、不要推荐）。
  final void Function(String tag)? onPickTag;

  const SearchBarWidget({
    super.key,
    required this.onChanged,
    // 不提 `#`：这次改动就是不让用户输入那个符号，占位符再教一遍等于把它请回来。
    this.placeholder = '搜索用户名、昵称或标签…',
    this.tagCloud = const <TagCount>[],
    this.onPickTag,
  });

  @override
  State<SearchBarWidget> createState() => _SearchBarWidgetState();
}

/// 搜索框下方弹的是哪一块。互斥：同一时刻只有一个下拉可见。
///
/// 做成 enum 而不是两个 bool：两个 bool 会允许 `{history: true, suggest: true}`
/// 这种状态，而 build 里必须决定渲染哪一块——把「互斥」这件事交给类型，
/// 比在 build 里写 if/else 判优先级更不容易漏。
enum _Overlay {
  /// 搜索历史。
  history,

  /// 标签推荐。候选项放在 State 的 [_suggests] 里（按枚举带数据会让
  /// 「算出来的列表」和「要显示哪个下拉」两件事搅在一起）。
  suggest,
}

class _SearchBarWidgetState extends State<SearchBarWidget> {
  List<String> _history = [];
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// 当前该显示哪一个下拉：历史，还是标签推荐。
  ///
  /// 二者互斥，且**推荐优先于历史**：一旦有标签命中候选，就说明用户正在找一个
  /// 标签，此时弹一列「你上次搜过什么」是答非所问（这两条数据还常常打架——
  /// 历史里存着「女性」，用户正在打「女」，两个下拉会同时想出现）。
  _Overlay? _overlay;

  /// 输入框当前聚焦着没有。只在聚焦时弹下拉：失焦后下拉必须自己消失，
  /// 否则点完推荐弹层还杵在屏幕上（挡住列表第一行）。
  bool _focused = false;

  /// 本次输入命中的标签推荐（已按匹配质量排好序）。
  ///
  /// 在 [setState] 里算好，不在 build 里算——build 里算意味着**每帧**都要
  /// 扫一遍 178 个标签，而下拉滚动时每帧都会重建。
  List<TagCount> _suggests = const <TagCount>[];

  /// 当前输入里被当作「标签搜索词」的那部分文本。
  ///
  /// ## 为什么不要求用户打 `#`
  ///
  /// 一开始这个功能是「打 # 才弹标签推荐」。实测下来那是**反的**：`#` 对
  /// 绝大多数用户是个需要专门记住的约定符号，忘了打就完全搜不到标签——而
  /// 「我想找女性标签的用户」这件事本身完全说得出口，不需要用户知道平台
  /// 用 `#` 标记标签。所以改成：标签表在手就直接给候选，输入什么都能匹配，
  /// **`#` 仍然接受但不再是前提**（老习惯不用改）。
  ///
  /// 取值：去掉前导 `#` 后的整段文本；不含 `#` 时就是普通输入。
  String get _tagQuery {
    final raw = _ctrl.text.trimLeft();
    return raw.startsWith('#') ? raw.substring(1).trim() : raw.trim();
  }

  /// 要不要弹标签推荐。
  ///
  /// 开关就是「有没有标签表 + 调用方想不想要」——不再看输入里有没有 `#`。
  bool get _wantsTag => widget.onPickTag != null;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _ctrl.addListener(_onTextChanged);
    _focus.addListener(() {
      if (!mounted) return;
      // 聚焦时按当前输入重算下拉；失焦时收掉。
      setState(() {
        _focused = _focus.hasFocus;
        _overlay = _focused ? _computeOverlay() : null;
      });
    });
  }

  @override
  void dispose() {
    // ⚠️ _ctrl 的 listener 必须在 dispose 里摘掉，否则 TextEditingController
    // 在 dispose 之后被 dispose 时，listener 里那一次 setState 会打在
    // 已销毁的 State 上（"setState() called after dispose()"）。
    _ctrl.removeListener(_onTextChanged);
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  /// 标签表是**异步**到货的（标签云那一次请求），用户完全可能在它回来之前
  /// 就已经在输入框里打了 `#`。
  ///
  /// 不在这里重算的话，那种时序下推荐面板会一直不出现——用户看到的是
  /// 「打了 # 什么反应都没有」，而标签表其实早就到了。
  @override
  void didUpdateWidget(covariant SearchBarWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // ⚠️ 只按**长度**判变化，不能用 `identical` 或逐项比较：外层每次 build
    // 都可能传一个新的 List 实例（`setState` 出来的 tagCloud），若因此认定
    // 「标签表变了」，就会在每次 build 后再 setState 一次 —— 直接是
    // 「setState during build」死循环。按长度判既够用（标签表只增不减，
    // 异步到货是一次性从 0 变到 N）又不会自激。
    final cloudChanged = oldWidget.tagCloud.length != widget.tagCloud.length;
    if (cloudChanged && mounted && _focused) {
      setState(() => _overlay = _computeOverlay());
    }
  }

  /// 输入变了：决定这次该弹什么。
  ///
  /// 必须挂在 [TextEditingController] 的 listener 上而不是 `onChanged`：
  /// `onChanged` 只在**用户输入**时触发，而 [_pickTag] 会程序化地
  /// `_ctrl.text = ...`（点推荐后回填标签名），那条路径不经过 onChanged。
  /// 挂在 controller 上两条路径就统一了。
  void _onTextChanged() {
    if (!mounted) return;
    setState(() => _overlay = _focused ? _computeOverlay() : null);
  }

  _Overlay? _computeOverlay() {
    if (_wantsTag) {
      final q = _tagQuery;
      final hits = rankTagSuggestions(widget.tagCloud, q);
      _suggests = hits;
      // 一个都没命中就别弹空框：用户会以为搜索坏了。
      if (hits.isNotEmpty) return _Overlay.suggest;
    }
    _suggests = const <TagCount>[];
    return _history.isEmpty ? null : _Overlay.history;
  }

  void _pickTag(String tag) {
    final picked = tag.trim().replaceFirst(RegExp(r'^#+'), '').trim();
    if (picked.isEmpty) return;
    // 回填**不带 `#`**：这次改动的整个方向就是「不让用户输入 #」，回填时再
    // 塞一个 # 进去等于把约定又塞回用户眼前。回填裸标签名，输出一律是
    // 「标签推荐」，输入框里就是用户刚才点的那个词。
    //
    // 先写 controller 再回调：回调通常会把搜索词写进外层 state，两者需要
    // 看到同一个值。
    _ctrl.text = picked;
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    setState(() => _overlay = null);
    widget.onPickTag!(picked);
    FocusScope.of(context).unfocus();
  }

  void _loadHistory() {
    _history = StorageService.getSearchHistory();
  }

  void _saveToHistory(String query) {
    final q = query.trim();
    if (q.isEmpty) return;

    setState(() {
      // 去重并限制数量
      _history.remove(q);
      _history.insert(0, q);
      if (_history.length > 10) _history = _history.sublist(0, 10);
    });

    StorageService.saveSearchHistory(_history);
  }

  void _onSubmitted(String query) {
    _saveToHistory(query);
    setState(() => _overlay = null);
    FocusScope.of(context).unfocus();
  }

  void _clearHistory() {
    setState(() {
      _history = [];
      _overlay = null;
    });
    StorageService.saveSearchHistory([]);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: TextField(
            controller: _ctrl,
            focusNode: _focus,
            onChanged: widget.onChanged,
            onSubmitted: _onSubmitted,
            // 点输入框时按当前内容重算下拉：可能上次失焦前收掉了。
            onTap: () => setState(
                () => _overlay = _focused ? _computeOverlay() : null),
            decoration: InputDecoration(
              hintText: widget.placeholder,
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _ctrl.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _ctrl.clear();
                        widget.onChanged('');
                        setState(() => _overlay = null);
                      },
                      tooltip: '清除',
                    )
                  : (_history.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.history),
                          onPressed: () => setState(() => _overlay =
                              _overlay == _Overlay.history ? null : _Overlay.history),
                          tooltip: '搜索历史',
                        )
                      : null),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              isDense: true,
            ),
          ),
        ),
        _buildOverlay(),
      ],
    );
  }

  /// 搜索框下方的弹层：要么是标签推荐，要么是搜索历史。
  Widget _buildOverlay() {
    switch (_overlay) {
      case null:
        return const SizedBox.shrink();
      case _Overlay.history:
        return _buildHistoryPanel();
      case _Overlay.suggest:
        return _buildSuggestPanel(_suggests);
    }
  }

  Widget _buildSuggestPanel(List<TagCount> items) {
    final showingHot = _tagQuery.isEmpty;
    // ⚠️ 背景色必须落在 **Material** 上，不能用 Container(decoration:) 包一层。
    // ListTile 把自己的背景与水波纹画在**最近的 Material 祖先**上；夹在中间
    // 的 DecoratedBox 会把那些效果整个盖住 —— 于是按下标签时看不到任何反馈，
    // 表现得像「点不动」。Flutter 会为此抛断言（"ListTile background color or
    // ink splashes may be invisible"），widget 测试直接红。
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Container(
            constraints: const BoxConstraints(maxHeight: 260),
            padding: const EdgeInsets.only(bottom: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('标签推荐',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                      if (showingHot)
                        const Text('热门标签，点一下立即按该标签查找',
                            style: TextStyle(fontSize: 11)),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: items.map((t) => ListTile(
                          dense: true,
                          // 标签推荐与账号搜索是两种不同的事，用不同的前导图标区分，
                          // 免得用户以为点了会跳到某个账号页。
                          leading: const Icon(Icons.sell_outlined, size: 16),
                          title: Text(t.tag,
                              style: const TextStyle(fontSize: 13)),
                          // ⚠️ 显示的是**票数**不是人数（见 TagCount.count 的口径说明），
                          // 所以标签旁边只写「热度」而不是「N 人」。
                          subtitle: Text('热度 ${t.count}',
                              style: const TextStyle(fontSize: 11)),
                          onTap: () => _pickTag(t.tag),
                        )).toList(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 搜索历史面板。逻辑与原实现逐字一致，只是从 build 里搬出来——
  /// 让 [build] 只剩「输入框 + 一个下拉」两件事。
  Widget _buildHistoryPanel() {
    // 同 _buildSuggestPanel：背景色必须在 Material 上，否则 ListTile 的
    // 水波纹被中间的 DecoratedBox 盖住，按下历史项看不到反馈。
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Container(
            constraints: const BoxConstraints(maxHeight: 200),
            padding: const EdgeInsets.only(bottom: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('搜索历史',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                    TextButton(
                      onPressed: _clearHistory,
                      child: const Text('清除', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: _history.map((h) => ListTile(
                          dense: true,
                          leading: const Icon(Icons.history, size: 16),
                          title: Text(h, style: const TextStyle(fontSize: 13)),
                          onTap: () {
                            _ctrl.text = h;
                            widget.onChanged(h);
                            setState(() => _overlay = null);
                            FocusScope.of(context).unfocus();
                          },
                          trailing: IconButton(
                            icon: const Icon(Icons.close, size: 14),
                            onPressed: () {
                              setState(() => _history.remove(h));
                              StorageService.saveSearchHistory(_history);
                            },
                          ),
                        )).toList(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
