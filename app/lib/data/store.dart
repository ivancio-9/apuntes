import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sembast/sembast.dart';

import 'db_io.dart' if (dart.library.js_interop) 'db_web.dart' as dbf;

/// Un registro genérico: cuaderno, página o elemento (trazo / texto).
class Rec {
  final String id;
  final String kind; // 'notebook' | 'page' | 'el'
  final String parent; // '' | id del cuaderno | id de la página
  final Map<String, dynamic> data;
  final int updatedAt;
  final bool deleted;

  const Rec({
    required this.id,
    required this.kind,
    required this.parent,
    required this.data,
    required this.updatedAt,
    this.deleted = false,
  });

  Rec copyWith({Map<String, dynamic>? data, bool? deleted, int? updatedAt}) => Rec(
        id: id,
        kind: kind,
        parent: parent,
        data: data ?? this.data,
        updatedAt: updatedAt ?? this.updatedAt,
        deleted: deleted ?? this.deleted,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'parent': parent,
        'data': data,
        'updatedAt': updatedAt,
        'deleted': deleted,
      };

  factory Rec.fromJson(Map<String, dynamic> j) => Rec(
        id: j['id'] as String,
        kind: j['kind'] as String,
        parent: (j['parent'] ?? '') as String,
        data: Map<String, dynamic>.from((j['data'] ?? const <String, dynamic>{}) as Map),
        updatedAt: (j['updatedAt'] as num).toInt(),
        deleted: j['deleted'] == true,
      );
}

final _rand = Random.secure();
String newId() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return List.generate(20, (_) => chars[_rand.nextInt(chars.length)]).join();
}

int nowMs() => DateTime.now().millisecondsSinceEpoch;

/// Almacén local (funciona sin conexión). La sincronización lee [dirty].
class Store extends ChangeNotifier {
  late Database _db;
  final _recs = stringMapStoreFactory.store('recs');
  final _dirty = StoreRef<String, int>('dirty');
  final _meta = StoreRef<String, Object>('meta');

  final Map<String, Rec> recs = {};
  final Map<String, Map<String, Rec>> _byParent = {};
  final Set<String> dirty = {};

  /// Se llama cada vez que hay cambios locales (la sincronización se engancha aquí).
  VoidCallback? onLocalChange;

  Future<void> init() async {
    _db = await dbf.openAppDatabase();
    for (final snap in await _recs.find(_db)) {
      _index(Rec.fromJson(Map<String, dynamic>.from(snap.value)));
    }
    dirty.addAll(await _dirty.findKeys(_db));
  }

  void _index(Rec r) {
    final old = recs[r.id];
    if (old != null) _byParent[old.parent]?.remove(r.id);
    recs[r.id] = r;
    (_byParent[r.parent] ??= {})[r.id] = r;
  }

  Future<Object?> getMeta(String key) => _meta.record(key).get(_db);
  Future<void> setMeta(String key, Object? value) async {
    if (value == null) {
      await _meta.record(key).delete(_db);
    } else {
      await _meta.record(key).put(_db, value);
    }
  }

  /// Hora de modificación siempre creciente para un registro.
  int stamp(Rec? old) {
    final n = nowMs();
    if (old == null) return n;
    return max(n, old.updatedAt + 1);
  }

  Future<void> put(Rec r) => putAll([r]);

  Future<void> putAll(List<Rec> list, {bool local = true}) async {
    if (list.isEmpty) return;
    for (final r in list) {
      _index(r);
      if (local) {
        dirty.add(r.id);
      } else {
        dirty.remove(r.id);
      }
    }
    notifyListeners();
    await _db.transaction((txn) async {
      for (final r in list) {
        await _recs.record(r.id).put(txn, r.toJson());
        if (local) {
          await _dirty.record(r.id).put(txn, 1);
        } else {
          await _dirty.record(r.id).delete(txn);
        }
      }
    });
    if (local) onLocalChange?.call();
  }

  Future<void> markClean(Iterable<String> ids) async {
    final list = ids.toList();
    dirty.removeAll(list);
    await _db.transaction((txn) async {
      for (final id in list) {
        await _dirty.record(id).delete(txn);
      }
    });
  }

  Future<void> clearAll() async {
    await _recs.delete(_db);
    await _dirty.delete(_db);
    await _meta.record('seq').delete(_db);
    recs.clear();
    _byParent.clear();
    dirty.clear();
    notifyListeners();
  }

  // ---------- Consultas ----------

  List<Rec> notebooks() {
    final l = (_byParent[''] ?? const <String, Rec>{}).values.where((r) => r.kind == 'notebook' && !r.deleted).toList();
    l.sort((a, b) => ((b.data['opened'] ?? 0) as num).compareTo((a.data['opened'] ?? 0) as num));
    return l;
  }

  List<Rec> pages(String notebookId) {
    final l = (_byParent[notebookId] ?? const <String, Rec>{}).values.where((r) => r.kind == 'page' && !r.deleted).toList();
    l.sort((a, b) => ((a.data['order'] ?? 0) as num).compareTo((b.data['order'] ?? 0) as num));
    return l;
  }

  List<Rec> elements(String pageId) {
    final l = (_byParent[pageId] ?? const <String, Rec>{}).values.where((r) => r.kind == 'el' && !r.deleted).toList();
    l.sort((a, b) => ((a.data['t'] ?? 0) as num).compareTo((b.data['t'] ?? 0) as num));
    return l;
  }

  // ---------- Acciones de alto nivel ----------

  Future<Rec> createNotebook(String title, {String paper = 'lined', int color = 0xFF3F51B5}) async {
    final t = nowMs();
    final nb = Rec(
      id: newId(),
      kind: 'notebook',
      parent: '',
      data: {'title': title, 'paper': paper, 'color': color, 'created': t, 'opened': t},
      updatedAt: t,
    );
    final page = Rec(id: newId(), kind: 'page', parent: nb.id, data: {'order': 1.0}, updatedAt: t);
    await putAll([nb, page]);
    return nb;
  }

  Future<void> updateData(Rec r, Map<String, dynamic> changes) =>
      put(r.copyWith(data: {...r.data, ...changes}, updatedAt: stamp(r)));

  Future<void> remove(Rec r) => put(r.copyWith(deleted: true, updatedAt: stamp(r)));

  Future<Rec> addPage(String notebookId, {Rec? after}) async {
    final ps = pages(notebookId);
    double order;
    if (after == null || ps.isEmpty || ps.last.id == after.id) {
      order = ps.isEmpty ? 1.0 : ((ps.last.data['order'] as num).toDouble() + 1);
    } else {
      final i = ps.indexWhere((p) => p.id == after.id);
      final a = (ps[i].data['order'] as num).toDouble();
      final b = (ps[i + 1].data['order'] as num).toDouble();
      order = (a + b) / 2;
    }
    final p = Rec(id: newId(), kind: 'page', parent: notebookId, data: {'order': order}, updatedAt: nowMs());
    await put(p);
    return p;
  }
}
