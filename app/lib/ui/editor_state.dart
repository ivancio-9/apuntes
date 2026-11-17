import 'package:flutter/material.dart';

import '../data/store.dart';
import '../ink/ink.dart';

/// Opciones de las herramientas (compartidas entre páginas).
class EditorSettings extends ChangeNotifier {
  Tool tool = Tool.pen;

  static const penColors = [
    Color(0xFF111111),
    Color(0xFF1E56C8),
    Color(0xFFD32F2F),
    Color(0xFF2E7D32),
    Color(0xFF7B1FA2),
  ];
  static const highlighterColors = [
    Color(0x66FFEB3B),
    Color(0x5576FF03),
    Color(0x55FF4081),
    Color(0x5540C4FF),
  ];
  static const penWidths = [2.0, 3.5, 6.0];
  static const highlighterWidths = [16.0, 26.0, 38.0];
  static const textSizes = [20.0, 28.0, 40.0];

  Color penColor = penColors[0];
  double penWidth = penWidths[1];
  Color highlighterColor = highlighterColors[0];
  double highlighterWidth = highlighterWidths[1];
  double textSize = textSizes[1];

  /// Dibujar también con el dedo (útil si no tienes lápiz).
  bool fingerDraws = false;

  /// Se activa al detectar un lápiz: a partir de ahí los dedos solo mueven la página.
  bool stylusSeen = false;

  void set(void Function() f) {
    f();
    notifyListeners();
  }
}

class Change {
  final Rec before;
  final Rec after;
  Change(this.before, this.after);
}

/// Deshacer / rehacer dentro de la página abierta.
class History extends ChangeNotifier {
  final Store store;
  History(this.store);

  final _undo = <List<Change>>[];
  final _redo = <List<Change>>[];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Guarda los cambios y los apunta en el historial.
  Future<void> commit(List<Change> cs) async {
    if (cs.isEmpty) return;
    record(cs);
    await store.putAll(cs.map((c) => c.after).toList());
  }

  /// Solo apunta en el historial (los datos ya están guardados).
  void record(List<Change> cs) {
    if (cs.isEmpty) return;
    _undo.add(cs);
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
    notifyListeners();
  }

  Future<void> undo() async {
    if (_undo.isEmpty) return;
    final cs = _undo.removeLast();
    _redo.add(cs);
    notifyListeners();
    await store.putAll(cs.map((c) => c.before.copyWith(updatedAt: store.stamp(store.recs[c.before.id]))).toList());
  }

  Future<void> redo() async {
    if (_redo.isEmpty) return;
    final cs = _redo.removeLast();
    _undo.add(cs);
    notifyListeners();
    await store.putAll(cs.map((c) => c.after.copyWith(updatedAt: store.stamp(store.recs[c.after.id]))).toList());
  }

  void clear() {
    _undo.clear();
    _redo.clear();
    notifyListeners();
  }
}
