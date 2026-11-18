import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

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
  final _blobs = StoreRef<String, String>('blobs');
  final _blobPending = StoreRef<String, int>('blobPending');

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

  // ---------- Archivos (imágenes) ----------

  Future<void> putBlob(String id, Uint8List bytes, {bool pending = true}) async {
    await _db.transaction((txn) async {
      await _blobs.record(id).put(txn, base64Encode(bytes));
      if (pending) await _blobPending.record(id).put(txn, 1);
    });
    if (pending) onLocalChange?.call();
  }

  Future<Uint8List?> getBlob(String id) async {
    final s = await _blobs.record(id).get(_db);
    return s == null ? null : base64Decode(s);
  }

  Future<List<String>> pendingBlobs() => _blobPending.findKeys(_db);

  Future<void> blobUploaded(String id) => _blobPending.record(id).delete(_db);

  Future<void> clearAll() async {
    await _blobs.delete(_db);
    await _blobPending.delete(_db);
    await _recs.delete(_db);
    await _dirty.delete(_db);
    await _meta.record('seq').delete(_db);
    recs.clear();
    _byParent.clear();
    dirty.clear();
    notifyListeners();
  }

  // ---------- Consultas ----------

  List<Rec> notebooks([String? folder, bool all = false]) {
    final l = (_byParent[''] ?? const <String, Rec>{})
        .values
        .where((r) => r.kind == 'notebook' && !r.deleted && (all || r.data['folder'] == folder))
        .toList();
    l.sort((a, b) => ((b.data['opened'] ?? 0) as num).compareTo((a.data['opened'] ?? 0) as num));
    return l;
  }

  List<Rec> folders([String? parent, bool all = false]) {
    final l = (_byParent[''] ?? const <String, Rec>{})
        .values
        .where((r) => r.kind == 'folder' && !r.deleted && (all || r.data['folder'] == parent))
        .toList();
    l.sort((a, b) => ((a.data['name'] ?? '') as String).toLowerCase().compareTo(((b.data['name'] ?? '') as String).toLowerCase()));
    return l;
  }

  List<Rec> stickers() {
    final l = (_byParent[''] ?? const <String, Rec>{}).values.where((r) => r.kind == 'sticker' && !r.deleted).toList();
    l.sort((a, b) => ((b.data['created'] ?? 0) as num).compareTo((a.data['created'] ?? 0) as num));
    return l;
  }

  /// Número de cuadernos y carpetas dentro de una carpeta.
  int folderCount(String id) => notebooks(id).length + folders(id).length;

  Future<Rec> createFolder(String name, {String? parent, int color = 0xFF5B8DEF}) async {
    final t = nowMs();
    final f = Rec(
      id: newId(),
      kind: 'folder',
      parent: '',
      data: {'name': name, 'color': color, 'folder': parent, 'created': t},
      updatedAt: t,
    );
    await put(f);
    return f;
  }

  /// Elimina una carpeta; su contenido pasa a la carpeta superior.
  Future<void> removeFolder(Rec folder) async {
    final up = folder.data['folder'] as String?;
    final changes = <Rec>[];
    for (final r in [...notebooks(folder.id), ...folders(folder.id)]) {
      changes.add(r.copyWith(data: {...r.data, 'folder': up}, updatedAt: stamp(r)));
    }
    changes.add(folder.copyWith(deleted: true, updatedAt: stamp(folder)));
    await putAll(changes);
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

  Future<Rec> createNotebook(String title,
      {String paper = 'lined', int color = 0xFF3F51B5, Map<String, dynamic>? extra, bool firstPage = true}) async {
    final t = nowMs();
    final nb = Rec(
      id: newId(),
      kind: 'notebook',
      parent: '',
      data: {'title': title, 'paper': paper, 'color': color, 'created': t, 'opened': t, ...?extra},
      updatedAt: t,
    );
    await putAll([
      nb,
      if (firstPage) Rec(id: newId(), kind: 'page', parent: nb.id, data: {'order': 1.0}, updatedAt: t),
    ]);
    return nb;
  }

  Future<void> updateData(Rec r, Map<String, dynamic> changes) =>
      put(r.copyWith(data: {...r.data, ...changes}, updatedAt: stamp(r)));

  Future<void> remove(Rec r) => put(r.copyWith(deleted: true, updatedAt: stamp(r)));

  /// Orden para colocar una página justo detrás de [after] (o al final).
  double orderAfter(String notebookId, Rec? after) {
    final ps = pages(notebookId);
    if (ps.isEmpty) return 1.0;
    if (after == null || ps.last.id == after.id) return (ps.last.data['order'] as num).toDouble() + 1;
    final i = ps.indexWhere((p) => p.id == after.id);
    if (i < 0) return (ps.last.data['order'] as num).toDouble() + 1;
    final a = (ps[i].data['order'] as num).toDouble();
    final b = (ps[i + 1].data['order'] as num).toDouble();
    return (a + b) / 2;
  }

  /// Orden para colocar una página justo delante de [before].
  double orderBefore(String notebookId, Rec before) {
    final ps = pages(notebookId);
    final i = ps.indexWhere((p) => p.id == before.id);
    final b = (before.data['order'] as num).toDouble();
    if (i <= 0) return b - 1;
    final a = (ps[i - 1].data['order'] as num).toDouble();
    return (a + b) / 2;
  }

  Future<Rec> addPageWith(String notebookId, Map<String, dynamic> data, {Rec? after}) async {
    final p = Rec(
      id: newId(),
      kind: 'page',
      parent: notebookId,
      data: {...data, 'order': orderAfter(notebookId, after)},
      updatedAt: nowMs(),
    );
    await put(p);
    return p;
  }

  /// Copia una página con todo su contenido y la coloca detrás.
  Future<Rec> duplicatePage(Rec page) async {
    final t = nowMs();
    final copy = Rec(
      id: newId(),
      kind: 'page',
      parent: page.parent,
      data: {...page.data, 'order': orderAfter(page.parent, page), 'bookmark': false},
      updatedAt: t,
    );
    final list = <Rec>[copy];
    for (final e in elements(page.id)) {
      list.add(Rec(id: newId(), kind: 'el', parent: copy.id, data: Map<String, dynamic>.from(e.data), updatedAt: t));
    }
    await putAll(list);
    return copy;
  }

  /// Mueve una página para que quede justo delante de [target].
  Future<void> movePageBefore(Rec page, Rec target) async {
    if (page.id == target.id) return;
    final order = orderBefore(page.parent, target);
    await updateData(page, {'order': order});
  }

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
