import 'package:flutter/material.dart';

import 'widgets/markdown_message.dart';

void main() {
  runApp(const JoEnwsApp());
}

class JoEnwsApp extends StatelessWidget {
  const JoEnwsApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6C7BFF),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'JO-ENWSim',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        fontFamily: 'SourceHanSansSC',
        scaffoldBackgroundColor: const Color(0xFF14161C),
      ),
      home: const HomeScreen(),
    );
  }
}

/// 一条展示项：角色标签 + 内容。
class Entry {
  Entry(this.role, this.text);

  final String role;
  final String text;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();

  final List<Entry> _entries = <Entry>[
    Entry('开场', '（这里会显示世界观 / 开场。引擎尚未接入，先占个位。）'),
  ];

  void _submit() {
    final String text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _entries.add(Entry('玩家角色', text));
      _entries.add(
        Entry('系统', '（引擎未接入：这里将来是 A / B₁ / B₂ 跑出来的本回合推演。）'),
      );
    });
    _controller.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        titleSpacing: 16,
        title: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            const Text(
              'JO-ENWSim',
              style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.5),
            ),
            const SizedBox(width: 10),
            Text(
              'Emergent Narrative World Simulator',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            children: <Widget>[
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  itemCount: _entries.length,
                  itemBuilder: (BuildContext context, int index) =>
                      _EntryView(entry: _entries[index]),
                ),
              ),
              const Divider(height: 1),
              _InputBar(controller: _controller, onSubmit: _submit),
            ],
          ),
        ),
      ),
    );
  }
}

class _EntryView extends StatelessWidget {
  const _EntryView({required this.entry});

  final Entry entry;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            entry.role,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 4),
          MarkdownMessage(data: entry.text),
        ],
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({required this.controller, required this.onSubmit});

  final TextEditingController controller;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 6,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSubmit(),
              decoration: const InputDecoration(
                hintText: '你的角色要做什么 / 说什么……',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: onSubmit, child: const Text('发送')),
        ],
      ),
    );
  }
}
