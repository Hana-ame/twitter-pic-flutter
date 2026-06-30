// 应用入口：初始化 ECH 代理并展示用户列表
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'services/proxy_manager.dart';
import 'screens/user_list_screen.dart';

const _kBuildNum = String.fromEnvironment('BUILD_NUM', defaultValue: 'dev');
const _kDohHost = 'moonchan.xyz';
const _kDohUrl = 'https://moonchan.xyz/doh';

Future<String> _resolveDomainRobustly(String domain) async {
  try {
    final result = await InternetAddress.lookup(domain);
    if (result.isNotEmpty) return result.first.address;
  } catch (e) {
    print('System DNS failed: $e');
  }

  final dohUrls = [
    'http://119.29.29.29/d?dn=$domain',
    'https://223.5.5.5/resolve?name=$domain&type=1',
  ];

  for (final url in dohUrls) {
    try {
      final client = HttpClient();
      client.badCertificateCallback = (cert, host, port) => true;
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('Accept', 'application/dns-json');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close();

      if (response.statusCode == 200 && body.isNotEmpty) {
        if (url.contains('119.29.29.29')) {
          final ips = body.split(';');
          if (ips.isNotEmpty && ips.first.contains('.')) return ips.first;
        }
        if (url.contains('223.5.5.5')) {
          final json = jsonDecode(body);
          if (json['Status'] == 0 && json['Answer'] != null) {
            for (final ans in json['Answer']) {
              if (ans['type'] == 1) return ans['data'].toString();
            }
          }
        }
      }
    } catch (e) {
      print('HTTP DNS failed: $url -> $e');
    }
  }

  throw Exception('failed to resolve $domain');
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final ProxyManager _proxy = ProxyManager();
  bool _proxyReady = false;
  String? _proxyError;
  List<String> _logs = [];
  bool _showLog = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      String? ip;
      for (var i = 0; i < 5; i++) {
        try {
          ip = await _resolveDomainRobustly(_kDohHost);
          break;
        } catch (e) {
          if (i >= 4) rethrow;
          await Future.delayed(const Duration(seconds: 2));
        }
      }

        await _proxy.init(dohUrl: _kDohUrl, dohHost: _kDohHost, dohBootstrapIP: ip);
      await _proxy.waitForInit();
      _logs = _proxy.getLogs();
      if (!mounted) return;
      setState(() => _proxyReady = true);
    } catch (e) {
      _logs = _proxy.getLogs();
      if (!mounted) return;
      setState(() => _proxyError = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Twitter Pic $_kBuildNum',
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: Text('Twitter Pic $_kBuildNum'),
          centerTitle: true,
          actions: [
            IconButton(
              icon: Icon(_showLog ? Icons.close : Icons.list),
              onPressed: () => setState(() => _showLog = !_showLog),
            ),
          ],
        ),
        body: _showLog ? _buildLog() : _buildBody(),
      ),
    );
  }

  Widget _buildLog() {
    if (_logs.isEmpty) return const Center(child: Text('(no logs)'));
    return ListView.builder(
      itemCount: _logs.length,
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(_logs[i], style: const TextStyle(fontSize: 11)),
      ),
    );
  }

  Widget _buildBody() {
    if (_proxyError != null) {
      return Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 8),
              SelectableText('$_proxyError',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red, fontSize: 13)),
              if (_logs.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text('--- Go 日志 ---',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                ...(_logs.map((l) => Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Text(l, style: const TextStyle(fontSize: 10)),
                ))),
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _proxyError = null;
                    _proxyReady = false;
                  });
                  _start();
                },
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (!_proxyReady) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在初始化 ECH ...'),
          ],
        ),
      );
    }
    return UserListScreen(proxy: _proxy);
  }
}
