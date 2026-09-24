import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class TovoReadCache {
  TovoReadCache(this.scope, {Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance {
    _instances.add(this);
  }

  static final _instances = <TovoReadCache>{};
  static const _prefix = 'tovo.read.v1.';
  static Future<void>? _purging;
  final String scope;
  final Future<SharedPreferences> Function() _preferences;
  final _entries = <String, Map<String, dynamic>>{};
  Future<void>? _hydration;
  Future<void> _writes = Future.value();
  bool _closed = false;

  static String key(String path, Map<String, dynamic>? query) {
    final names = query?.keys.toList() ?? <String>[];
    names.sort();
    return Uri(
      path: path,
      queryParameters: names.isEmpty
          ? null
          : {for (final name in names) name: '${query![name]}'},
    ).toString();
  }

  static bool accepts(String path) =>
      path == '/categories' ||
      path == '/catalog/products' ||
      path == '/conversations' ||
      // Les adresses du client : le panier s'ouvre sur l'adresse habituelle
      // sans attendre le réseau (elles changent rarement, et sont relues).
      path == '/addresses' ||
      path.startsWith('/conversations/') ||
      path.startsWith('/products/') ||
      RegExp(r'^/categories/[^/]+/merchants$').hasMatch(path);

  Future<void> _hydrate() => _hydration ??= () async {
    try {
      await _purging;
      final prefs = await _preferences();
      final raw = prefs.getString('$_prefix$scope');
      if (_closed || raw == null) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in decoded.entries) {
        if (entry.value is Map<String, dynamic>) {
          _entries.putIfAbsent(
            entry.key,
            () => entry.value as Map<String, dynamic>,
          );
        }
      }
    } catch (_) {}
  }();

  Map<String, dynamic>? peek(String key) {
    if (_closed) return null;
    final entry = _entries[key];
    final at = entry?['at'];
    if (at is! int || DateTime.now().millisecondsSinceEpoch - at > 86400000) {
      return null;
    }
    final body = entry?['body'];
    return body is Map<String, dynamic> ? body : null;
  }

  Future<Map<String, dynamic>?> read(String key) async {
    await _hydrate();
    return peek(key);
  }

  Future<void> write(String key, Map<String, dynamic> body) async {
    await _hydrate();
    if (_closed) return;
    _entries.remove(key);
    _entries[key] = {'at': DateTime.now().millisecondsSinceEpoch, 'body': body};
    while (_entries.length > 50 ||
        utf8.encode(jsonEncode(_entries)).length > 2000000) {
      _entries.remove(_entries.keys.first);
    }
    final snapshot = jsonEncode(_entries);
    _writes = _writes
        .then((_) async {
          final prefs = await _preferences();
          if (!_closed) await prefs.setString('$_prefix$scope', snapshot);
        })
        .catchError((_) {});
    await _writes;
  }

  Future<void> clear() async {
    _closed = true;
    _entries.clear();
    await _writes;
    try {
      final prefs = await _preferences();
      await prefs.remove('$_prefix$scope');
    } catch (_) {}
    _instances.remove(this);
  }

  static Future<void> clearPrivateCaches() {
    final previous = _purging;
    final clearing = _instances.toList().map((cache) => cache.clear()).toList();
    final purge = () async {
      await previous;
      await Future.wait(clearing);
      try {
        final prefs = await SharedPreferences.getInstance();
        for (final key in prefs.getKeys().where(
          (key) => key.startsWith(_prefix),
        )) {
          await prefs.remove(key);
        }
      } catch (_) {}
    }();
    _purging = purge;
    return purge.whenComplete(() {
      if (identical(_purging, purge)) _purging = null;
    });
  }
}
