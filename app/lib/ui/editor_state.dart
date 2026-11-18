import 'dart:async';

import 'package:flutter/material.dart';

import '../data/store.dart';
import '../ink/ink.dart';

const kFonts = [
  'Roboto',
  'Open Sans',
  'Lato',
  'Montserrat',
  'Merriweather',
  'Playfair Display',
  'Roboto Mono',
  'Caveat',
  'Patrick Hand',
  'Indie Flower',
];

/// Opciones de las herramientas. Se guardan en el dispositivo.
class EditorSettings extends ChangeNotifier {
  Tool tool = Tool.pen;

  // Colores (siempre opacos; el subrayador aplica su transparencia al dibujar)
  List<Color> swatches = const [
    Color(0xFF111111),
    Color(0xFF1E56C8),
    Color(0xFFD32F2F),
    Color(0xFF2E7D32),
    Color(0xFF7B1FA2),
    Color(0xFFF57C00),
  ];
  List<Color> highlighterSwatches = const [
    Color(0xFFFFEB3B),
    Color(0xFF76FF03),
    Color(0xFFFF4081),
    Color(0xFF40C4FF),
    Color(0xFFFFAB40),
  ];

  Color penColor = const Color(0xFF111111);
  Color highlighterBase = const Color(0xFFFFEB3B);
  Color shapeColor = const Color(0xFF1E56C8);
  Color textColor = const Color(0xFF111111);
  Color tapeColor = const Color(0xFFF48FB1);
  String tapePattern = 'stripes';
  double tapeWidth = 40;

  /// Regla y ventana de zoom (no se guardan).
  bool ruler = false;
  bool zoomWindow = false;

  Color get highlighterColor => highlighterBase.withValues(alpha: 0.38);

  static const penWidths = [1.5, 2.5, 3.5, 5.0, 8.0];
  static const highlighterWidths = [14.0, 24.0, 36.0];
  static const shapeWidths = [2.0, 3.5, 6.0];
  static const eraserSizes = [8.0, 14.0, 26.0];
  static const tapeWidths = [28.0, 40.0, 56.0];

  double penWidth = 2.5;
  bool penPressure = true; // estilográfica (true) o bolígrafo (false)
  double highlighterWidth = 24;
  bool highlighterStraight = true;
  double eraserSize = 14;
  ShapeKind shape = ShapeKind.rect;
  double shapeWidth = 3.5;
  bool shapeFill = false;

  String font = 'Roboto';
  double textSize = 28;
  bool bold = false;
  bool italic = false;

  /// Dibujar también con el dedo (útil si no tienes lápiz).
  bool fingerDraws = false;

  /// Se activa al detectar un lápiz.
  bool stylusSeen = false;

  Store? _store;
  Timer? _save;

  void set(void Function() f) {
    f();
    notifyListeners();
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 800), () => _store?.setMeta('editor', toJson()));
  }

  /// Color "actual" según la herramienta (para los botones de color).
  Color get currentColor {
    switch (tool) {
      case Tool.highlighter:
        return highlighterBase;
      case Tool.shape:
        return shapeColor;
      case Tool.text:
        return textColor;
      case Tool.tape:
        return tapeColor;
      default:
        return penColor;
    }
  }

  void setCurrentColor(Color c) {
    set(() {
      switch (tool) {
        case Tool.highlighter:
          highlighterBase = c;
          break;
        case Tool.shape:
          shapeColor = c;
          break;
        case Tool.text:
          textColor = c;
          break;
        case Tool.tape:
          tapeColor = c;
          break;
        default:
          penColor = c;
      }
    });
  }

  /// Añade un color a la paleta de la herramienta actual (sustituye al más antiguo si hay muchos).
  void addSwatch(Color c) {
    set(() {
      if (tool == Tool.highlighter) {
        if (!highlighterSwatches.contains(c)) {
          highlighterSwatches = [...highlighterSwatches, c];
          if (highlighterSwatches.length > 8) highlighterSwatches = highlighterSwatches.sublist(1);
        }
      } else if (!swatches.contains(c)) {
        swatches = [...swatches, c];
        if (swatches.length > 10) swatches = swatches.sublist(1);
      }
    });
  }

  void replaceSwatch(Color old, Color c) {
    set(() {
      if (tool == Tool.highlighter) {
        highlighterSwatches = [for (final s in highlighterSwatches) s == old ? c : s];
      } else {
        swatches = [for (final s in swatches) s == old ? c : s];
      }
    });
  }

  void removeSwatch(Color c) {
    set(() {
      if (tool == Tool.highlighter) {
        if (highlighterSwatches.length > 1) highlighterSwatches = [...highlighterSwatches]..remove(c);
      } else {
        if (swatches.length > 1) swatches = [...swatches]..remove(c);
      }
    });
  }

  Map<String, Object?> toJson() => {
        'swatches': swatches.map((c) => c.toARGB32()).toList(),
        'hlSwatches': highlighterSwatches.map((c) => c.toARGB32()).toList(),
        'penColor': penColor.toARGB32(),
        'hlColor': highlighterBase.toARGB32(),
        'shapeColor': shapeColor.toARGB32(),
        'textColor': textColor.toARGB32(),
        'tapeColor': tapeColor.toARGB32(),
        'tapePattern': tapePattern,
        'tapeWidth': tapeWidth,
        'penWidth': penWidth,
        'penPressure': penPressure,
        'hlWidth': highlighterWidth,
        'hlStraight': highlighterStraight,
        'eraserSize': eraserSize,
        'shape': shape.name,
        'shapeWidth': shapeWidth,
        'shapeFill': shapeFill,
        'font': font,
        'textSize': textSize,
        'bold': bold,
        'italic': italic,
        'fingerDraws': fingerDraws,
      };

  Future<void> load(Store store) async {
    _store = store;
    final raw = await store.getMeta('editor');
    if (raw is! Map) return;
    final j = Map<String, dynamic>.from(raw);
    List<Color>? colors(Object? v) =>
        v is List && v.isNotEmpty ? [for (final x in v) Color((x as num).toInt())] : null;
    Color? color(Object? v) => v is num ? Color(v.toInt()) : null;
    double? dbl(Object? v) => v is num ? v.toDouble() : null;
    swatches = colors(j['swatches']) ?? swatches;
    highlighterSwatches = colors(j['hlSwatches']) ?? highlighterSwatches;
    penColor = color(j['penColor']) ?? penColor;
    highlighterBase = color(j['hlColor']) ?? highlighterBase;
    shapeColor = color(j['shapeColor']) ?? shapeColor;
    textColor = color(j['textColor']) ?? textColor;
    tapeColor = color(j['tapeColor']) ?? tapeColor;
    tapePattern = kTapePatterns.contains(j['tapePattern']) ? j['tapePattern'] as String : tapePattern;
    tapeWidth = dbl(j['tapeWidth']) ?? tapeWidth;
    penWidth = dbl(j['penWidth']) ?? penWidth;
    penPressure = j['penPressure'] != false;
    highlighterWidth = dbl(j['hlWidth']) ?? highlighterWidth;
    highlighterStraight = j['hlStraight'] != false;
    eraserSize = dbl(j['eraserSize']) ?? eraserSize;
    shape = ShapeKind.values.firstWhere((k) => k.name == j['shape'], orElse: () => shape);
    shapeWidth = dbl(j['shapeWidth']) ?? shapeWidth;
    shapeFill = j['shapeFill'] == true;
    font = kFonts.contains(j['font']) ? j['font'] as String : font;
    textSize = dbl(j['textSize']) ?? textSize;
    bold = j['bold'] == true;
    italic = j['italic'] == true;
    fingerDraws = j['fingerDraws'] == true;
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
