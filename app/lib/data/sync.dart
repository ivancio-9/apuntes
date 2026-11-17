import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'store.dart';

enum SyncState { idle, syncing, ok, offline, error }

class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}

/// Sincroniza el almacén local con tu servidor.
class SyncService extends ChangeNotifier {
  final Store store;
  String serverUrl = '';
  String? token;
  SyncState state = SyncState.idle;
  DateTime? lastOk;
  bool _busy = false;
  bool _again = false;
  Timer? _periodic;
  Timer? _debounce;

  /// Se llama si el servidor rechaza el token (hay que volver a iniciar sesión).
  VoidCallback? onUnauthorized;

  SyncService(this.store) {
    store.onLocalChange = () {
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 2), syncNow);
    };
  }

  bool get loggedIn => token != null && serverUrl.isNotEmpty;

  Future<void> load() async {
    serverUrl = (await store.getMeta('server') as String?) ?? '';
    token = await store.getMeta('token') as String?;
  }

  static String normalizeUrl(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    if (u.isNotEmpty && !u.startsWith('http://') && !u.startsWith('https://')) u = 'https://$u';
    return u;
  }

  Future<void> login(String url, String password) async {
    final base = normalizeUrl(url);
    final http.Response res;
    try {
      res = await http
          .post(Uri.parse('$base/api/login'),
              headers: {'Content-Type': 'application/json'}, body: jsonEncode({'password': password}))
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      throw AuthException('No se puede conectar con el servidor. Revisa la dirección y que Tailscale esté activo.');
    }
    if (res.statusCode == 401) throw AuthException('Contraseña incorrecta.');
    if (res.statusCode != 200) throw AuthException('El servidor respondió con un error (${res.statusCode}).');
    final t = (jsonDecode(res.body) as Map)['token'] as String;
    final previous = await store.getMeta('server') as String?;
    if (previous != null && previous != base) {
      // Otro servidor: empezamos de cero para no mezclar datos.
      await store.clearAll();
    }
    serverUrl = base;
    token = t;
    await store.setMeta('server', base);
    await store.setMeta('token', t);
    start();
    await syncNow();
  }

  Future<void> logout() async {
    stop();
    token = null;
    await store.setMeta('token', null);
    notifyListeners();
  }

  void start() {
    _periodic?.cancel();
    _periodic = Timer.periodic(const Duration(seconds: 20), (_) => syncNow());
  }

  void stop() {
    _periodic?.cancel();
    _debounce?.cancel();
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      };

  void _set(SyncState s) {
    state = s;
    if (s == SyncState.ok) lastOk = DateTime.now();
    notifyListeners();
  }

  Future<void> syncNow() async {
    if (!loggedIn) return;
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    _set(SyncState.syncing);
    try {
      do {
        _again = false;
        await _pushBlobs();
        await _push();
        await _pull();
      } while (_again);
      _set(SyncState.ok);
    } on AuthException {
      _set(SyncState.error);
      await logout();
      onUnauthorized?.call();
    } catch (e) {
      debugPrint('sync: $e');
      _set(SyncState.offline);
    } finally {
      _busy = false;
    }
  }

  void _check(http.Response res) {
    if (res.statusCode == 401) throw AuthException('Sesión caducada');
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  }

  Future<void> _pushBlobs() async {
    for (final id in await store.pendingBlobs()) {
      final bytes = await store.getBlob(id);
      if (bytes == null) {
        await store.blobUploaded(id);
        continue;
      }
      final res = await http
          .put(Uri.parse('$serverUrl/api/blob/$id'),
              headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/octet-stream'}, body: bytes)
          .timeout(const Duration(minutes: 2));
      _check(res);
      await store.blobUploaded(id);
    }
  }

  /// Descarga una imagen que no está en este dispositivo.
  Future<Uint8List?> fetchBlob(String id) async {
    if (!loggedIn) return null;
    try {
      final res = await http
          .get(Uri.parse('$serverUrl/api/blob/$id'), headers: {'Authorization': 'Bearer $token'})
          .timeout(const Duration(minutes: 2));
      if (res.statusCode != 200) return null;
      await store.putBlob(id, res.bodyBytes, pending: false);
      return res.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> _push() async {
    final ids = store.dirty.toList();
    const chunk = 300;
    for (var i = 0; i < ids.length; i += chunk) {
      final part = ids.sublist(i, i + chunk > ids.length ? ids.length : i + chunk);
      final sent = <String, int>{};
      final recs = <Map<String, dynamic>>[];
      for (final id in part) {
        final r = store.recs[id];
        if (r == null) continue;
        sent[id] = r.updatedAt;
        recs.add(r.toJson());
      }
      final res = await http
          .post(Uri.parse('$serverUrl/api/push'), headers: _headers, body: jsonEncode({'records': recs}))
          .timeout(const Duration(seconds: 60));
      _check(res);
      // Solo marcamos como enviados los que no han cambiado mientras tanto.
      await store.markClean(sent.entries.where((e) => store.recs[e.key]?.updatedAt == e.value).map((e) => e.key));
    }
  }

  Future<void> _pull() async {
    var since = ((await store.getMeta('seq')) as num?)?.toInt() ?? 0;
    while (true) {
      final res = await http
          .get(Uri.parse('$serverUrl/api/pull?since=$since&limit=2000'), headers: _headers)
          .timeout(const Duration(seconds: 60));
      _check(res);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final incoming = (body['records'] as List)
          .map((j) => Rec.fromJson(Map<String, dynamic>.from(j as Map)))
          .where((r) {
        final local = store.recs[r.id];
        if (local == null) return true;
        if (store.dirty.contains(r.id) && local.updatedAt >= r.updatedAt) return false;
        return r.updatedAt >= local.updatedAt;
      }).toList();
      await store.putAll(incoming, local: false);
      since = (body['last'] as num).toInt();
      await store.setMeta('seq', since);
      if (body['more'] != true) break;
    }
  }
}
