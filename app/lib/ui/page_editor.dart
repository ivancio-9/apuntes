import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app_scope.dart';
import '../data/store.dart';
import '../ink/ink.dart';
import 'color_picker.dart';
import 'editor_state.dart';

/// Una página: tinta, figuras, imágenes y cajas de texto; zoom y desplazamiento con los dedos.
class PageEditor extends StatefulWidget {
  final AppScope app;
  final Rec page;
  final String paper;
  final History history;

  const PageEditor({
    super.key,
    required this.app,
    required this.page,
    required this.paper,
    required this.history,
  });

  @override
  State<PageEditor> createState() => PageEditorState();
}

enum _Mode { none, ink, erase, shape, text, lasso, move, scale }

TextStyle textStyleFor(Map<String, dynamic> d, double scale) {
  final base = TextStyle(
    fontSize: ((d['size'] ?? 28) as num).toDouble() * scale,
    color: Color(((d['color'] ?? 0xFF111111) as num).toInt()),
    height: 1.3,
    fontWeight: d['bold'] == true ? FontWeight.w700 : FontWeight.w400,
    fontStyle: d['italic'] == true ? FontStyle.italic : FontStyle.normal,
  );
  final font = (d['font'] ?? 'Roboto') as String;
  try {
    return GoogleFonts.getFont(font, textStyle: base);
  } catch (_) {
    return base;
  }
}

class PageEditorState extends State<PageEditor> {
  Store get store => widget.app.store;
  EditorSettings get settings => widget.app.settings;

  // Vista
  double _scale = 1;
  Offset _pan = Offset.zero;
  bool _fitted = false;
  Size _viewport = Size.zero;

  // Punteros
  final Map<int, Offset> _touches = {};
  final Map<int, Offset> _touchStart = {};
  final Set<int> _ignored = {};
  int? _ptr;
  PointerDeviceKind? _ptrKind;
  Offset _downPos = Offset.zero;
  Offset _lastPos = Offset.zero;
  _Mode _mode = _Mode.none;
  final List<double> _cur = [];
  Offset? _shapeA, _shapeB;
  Offset? _eraserPos;
  final Set<String> _erasing = {};
  final List<Offset> _lasso = [];

  // Selección
  Set<String> _sel = {};
  Rect? _selBounds;
  Offset _selStart = Offset.zero;
  Offset _selDelta = Offset.zero;
  double _selScale = 1;
  bool get _transforming => _mode == _Mode.move || _mode == _Mode.scale;

  // Contenido
  final Map<String, Item> _cache = {};
  List<Item> _items = [];
  List<Item> _inkItems = [];
  List<Rec> _texts = [];
  final Map<String, ui.Image> _images = {};
  final Set<String> _loadingImages = {};
  ui.Picture? _ink;
  bool _inkDirty = true;
  final ValueNotifier<int> _liveTick = ValueNotifier(0);

  // Texto en edición
  String? _editingId;
  Rec? _editStart;
  final TextEditingController _textCtl = TextEditingController();
  final FocusNode _textFocus = FocusNode();
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    store.addListener(_onStore);
    settings.addListener(_onSettings);
    _reload();
  }

  @override
  void didUpdateWidget(PageEditor old) {
    super.didUpdateWidget(old);
    if (old.paper != widget.paper) _inkDirty = true;
  }

  @override
  void dispose() {
    store.removeListener(_onStore);
    settings.removeListener(_onSettings);
    _disposed = true;
    _finishText();
    _textCtl.dispose();
    _textFocus.dispose();
    _liveTick.dispose();
    super.dispose();
  }

  void _tick() => _liveTick.value++;

  void _onSettings() {
    final id = _editingId;
    if (id != null) {
      if (settings.tool != Tool.text) {
        _finishText();
      } else {
        final cur = store.recs[id];
        if (cur != null) {
          final ch = <String, dynamic>{
            'font': settings.font,
            'size': settings.textSize,
            'bold': settings.bold,
            'italic': settings.italic,
            'color': settings.textColor.toARGB32(),
          };
          if (ch.entries.any((e) => cur.data[e.key] != e.value)) _updateText(id, ch);
        }
      }
    }
    if (settings.tool != Tool.select && _sel.isNotEmpty) {
      _sel = {};
      _selBounds = null;
    }
    if (mounted && !_disposed) setState(() {});
  }

  void _onStore() {
    if (!mounted || _disposed) return;
    setState(_reload);
  }

  void _reload() {
    final els = store.elements(widget.page.id);
    final items = <Item>[];
    final inkItems = <Item>[];
    final texts = <Rec>[];
    for (final r in els) {
      var it = _cache[r.id];
      if (it == null || it.rec.updatedAt != r.updatedAt) {
        it = Item.fromRec(r);
        if (it == null) continue;
        _cache[r.id] = it;
      }
      items.add(it);
      if (it is TextItem) {
        texts.add(r);
      } else {
        inkItems.add(it);
      }
      if (it is ImageItem && !_images.containsKey(it.blob) && !_loadingImages.contains(it.blob)) {
        _loadImage(it.blob);
      }
    }
    var same = inkItems.length == _inkItems.length;
    if (same) {
      for (var i = 0; i < inkItems.length; i++) {
        if (!identical(inkItems[i], _inkItems[i])) {
          same = false;
          break;
        }
      }
    }
    if (!same) _inkDirty = true;
    _items = items;
    _inkItems = inkItems;
    _texts = texts;
    if (_sel.isNotEmpty) {
      final ids = {for (final i in items) i.id};
      _sel = _sel.where(ids.contains).toSet();
      if (_sel.isEmpty) {
        _selBounds = null;
      } else if (!_transforming) {
        _selBounds = _computeSelBounds();
      }
    }
  }

  Future<void> _loadImage(String blob) async {
    _loadingImages.add(blob);
    var bytes = await store.getBlob(blob);
    bytes ??= await widget.app.sync.fetchBlob(blob);
    if (bytes == null) {
      Timer(const Duration(seconds: 20), () => _loadingImages.remove(blob));
      return;
    }
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      _images[blob] = frame.image;
      _inkDirty = true;
      if (mounted && !_disposed) setState(() {});
    } catch (_) {}
  }

  // ---------- Vista ----------

  void _fit(Size size) {
    final s = math.min((size.width - 24) / kPageW, 4.0);
    _scale = s <= 0 ? 0.5 : s;
    _pan = Offset((size.width - kPageW * _scale) / 2, 12);
    _fitted = true;
  }

  Offset _toPage(Offset local) => (local - _pan) / _scale;
  Offset _toScreen(Offset page) => page * _scale + _pan;

  void _clampPan() {
    const margin = 120.0;
    final w = kPageW * _scale, h = kPageH * _scale;
    final minX = margin - w, maxX = _viewport.width - margin;
    final minY = margin - h, maxY = _viewport.height - margin;
    _pan = Offset(_pan.dx.clamp(math.min(minX, maxX), math.max(minX, maxX)),
        _pan.dy.clamp(math.min(minY, maxY), math.max(minY, maxY)));
  }

  void _zoomAt(Offset focal, double newScale) {
    newScale = newScale.clamp(0.25, 8.0);
    final pagePt = _toPage(focal);
    _scale = newScale;
    _pan = focal - pagePt * _scale;
    _clampPan();
  }

  Rect _visibleRect() {
    final r = Rect.fromPoints(_toPage(Offset.zero), _toPage(Offset(_viewport.width, _viewport.height)));
    final v = r.intersect(const Rect.fromLTWH(0, 0, kPageW, kPageH));
    return (v.width <= 10 || v.height <= 10) ? const Rect.fromLTWH(0, 0, kPageW, kPageH) : v;
  }

  // ---------- Selección ----------

  Rect? _computeSelBounds() {
    Rect? r;
    for (final it in _items) {
      if (!_sel.contains(it.id)) continue;
      r = r == null ? it.bounds : r.expandToInclude(it.bounds);
    }
    return r;
  }

  /// Rectángulo de la selección en pantalla (con la transformación en curso).
  Rect? _selScreenRect() {
    final b = _selBounds;
    if (b == null) return null;
    final tl = b.topLeft + _selDelta;
    final pageRect = Rect.fromLTWH(tl.dx, tl.dy, b.width * _selScale, b.height * _selScale);
    return Rect.fromPoints(_toScreen(pageRect.topLeft), _toScreen(pageRect.bottomRight));
  }

  void _finishLasso() {
    if (_lasso.length < 3) return;
    _sel = {for (final it in _items) if (it.inLasso(_lasso)) it.id};
    _selBounds = _sel.isEmpty ? null : _computeSelBounds();
  }

  void _commitTransform() {
    final b = _selBounds;
    if (b == null) return;
    if (_selDelta == Offset.zero && _selScale == 1) {
      _inkDirty = true;
      return;
    }
    final origin = b.topLeft;
    final delta = _selDelta, s = _selScale;
    final changes = <Change>[];
    for (final id in _sel) {
      final rec = store.recs[id];
      if (rec == null || rec.deleted) continue;
      changes.add(Change(rec, rec.copyWith(data: transformData(rec.data, origin, s, delta), updatedAt: store.stamp(rec))));
    }
    _selBounds = Rect.fromLTWH(origin.dx + delta.dx, origin.dy + delta.dy, b.width * s, b.height * s);
    _selDelta = Offset.zero;
    _selScale = 1;
    _mode = _Mode.none;
    _inkDirty = true;
    widget.history.commit(changes);
  }

  void deleteSelection() {
    final changes = <Change>[];
    for (final id in _sel) {
      final rec = store.recs[id];
      if (rec == null || rec.deleted) continue;
      changes.add(Change(rec, rec.copyWith(deleted: true, updatedAt: store.stamp(rec))));
    }
    _sel = {};
    _selBounds = null;
    widget.history.commit(changes);
  }

  void _duplicateSelection() {
    final changes = <Change>[];
    final ids = <String>{};
    final t = nowMs();
    for (final id in _sel) {
      final rec = store.recs[id];
      if (rec == null || rec.deleted) continue;
      final data = transformData(rec.data, Offset.zero, 1, const Offset(30, 30))..['t'] = t;
      final copy = Rec(id: newId(), kind: 'el', parent: widget.page.id, data: data, updatedAt: t);
      ids.add(copy.id);
      changes.add(Change(copy.copyWith(deleted: true), copy));
    }
    widget.history.commit(changes);
    setState(() {
      _sel = ids;
      _selBounds = _computeSelBounds();
    });
  }

  Future<void> _recolorSelection() async {
    final c = await showColorPicker(context, settings.penColor, title: 'Color de la selección');
    if (c == null) return;
    final changes = <Change>[];
    for (final id in _sel) {
      final rec = store.recs[id];
      if (rec == null || rec.deleted) continue;
      final type = rec.data['type'];
      if (type != 'stroke' && type != 'shape' && type != 'text') continue;
      final isHl = type == 'stroke' && rec.data['tool'] == kToolHighlighter;
      final color = isHl ? c.withValues(alpha: 0.38) : c;
      changes.add(Change(
          rec, rec.copyWith(data: {...rec.data, 'color': color.toARGB32()}, updatedAt: store.stamp(rec))));
    }
    widget.history.commit(changes);
  }

  // ---------- Acciones públicas (desde la barra) ----------

  Future<void> insertImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final img = (await codec.getNextFrame()).image;
    final id = newId();
    await store.putBlob(id, bytes);
    _images[id] = img;
    final vis = _visibleRect();
    var w = math.min(img.width.toDouble(), vis.width * 0.8);
    var h = w * img.height / img.width;
    if (h > vis.height * 0.8) {
      h = vis.height * 0.8;
      w = h * img.width / img.height;
    }
    final x = vis.center.dx - w / 2, y = vis.center.dy - h / 2;
    final t = nowMs();
    final rec = Rec(
      id: newId(),
      kind: 'el',
      parent: widget.page.id,
      data: {'type': 'image', 'blob': id, 'x': x, 'y': y, 'w': w, 'h': h, 't': t},
      updatedAt: t,
    );
    await widget.history.commit([Change(rec.copyWith(deleted: true), rec)]);
    settings.set(() => settings.tool = Tool.select);
    if (!mounted) return;
    setState(() {
      _sel = {rec.id};
      _selBounds = Rect.fromLTWH(x, y, w, h);
    });
  }

  void clearPage() {
    final changes = <Change>[];
    for (final it in _items) {
      final rec = store.recs[it.id];
      if (rec == null || rec.deleted) continue;
      changes.add(Change(rec, rec.copyWith(deleted: true, updatedAt: store.stamp(rec))));
    }
    _sel = {};
    _selBounds = null;
    widget.history.commit(changes);
  }

  // ---------- Punteros ----------

  bool _isPen(PointerEvent e) => e.kind == PointerDeviceKind.stylus || e.kind == PointerDeviceKind.invertedStylus;

  double _pressure(PointerEvent e) {
    if (!_isPen(e)) return 0.5;
    final range = e.pressureMax - e.pressureMin;
    if (range <= 0) return 0.5;
    final p = ((e.pressure - e.pressureMin) / range).clamp(0.0, 1.0);
    return p == 0 ? 0.3 : p; // algunos navegadores envían 0 en el primer punto
  }

  void _addPoint(PointerEvent e) {
    final p = _toPage(e.localPosition);
    final n = _cur.length;
    if (n >= 3) {
      final dx = p.dx - _cur[n - 3], dy = p.dy - _cur[n - 2];
      if (dx * dx + dy * dy < 0.25) return;
    }
    _cur
      ..add(p.dx)
      ..add(p.dy)
      ..add(_pressure(e));
  }

  void _down(PointerDownEvent e) {
    final isPen = _isPen(e);
    final isMouse = e.kind == PointerDeviceKind.mouse;
    final isTouch = e.kind == PointerDeviceKind.touch;
    if (isPen) settings.stylusSeen = true;

    if (isMouse && (e.buttons & kPrimaryMouseButton) == 0) {
      _touches[e.pointer] = e.localPosition; // botón secundario/central: mover la página
      return;
    }

    final tool = settings.tool;
    final p = _toPage(e.localPosition);
    final drawer = isPen || isMouse || (isTouch && settings.fingerDraws && _touches.isEmpty && _ptr == null);
    final singleTouch = isTouch && _touches.isEmpty && _ptr == null;

    // Mover o escalar una selección (con cualquier puntero).
    final selRect = _selScreenRect();
    if (tool == Tool.select && selRect != null && (drawer || singleTouch)) {
      final onHandle = (e.localPosition - selRect.bottomRight).distance < 32;
      if (onHandle || selRect.inflate(10).contains(e.localPosition)) {
        if (_ptr != null) _endInteraction(commit: true);
        _ptr = e.pointer;
        _ptrKind = e.kind;
        _downPos = e.localPosition;
        _lastPos = e.localPosition;
        _selStart = p;
        _selDelta = Offset.zero;
        _selScale = 1;
        _mode = onHandle ? _Mode.scale : _Mode.move;
        _inkDirty = true;
        setState(() {});
        return;
      }
    }

    if (drawer) {
      if (isPen) {
        // El lápiz manda: la palma que ya estuviera apoyada se ignora.
        _ignored.addAll(_touches.keys);
        _touches.clear();
        _touchStart.clear();
      }
      // Si quedaba un trazo a medias (p. ej. se perdió el "levantar"), se guarda en vez de perderlo.
      if (_ptr != null) _endInteraction(commit: _ptrKind != PointerDeviceKind.touch);
      if (_editingId != null) _finishText();

      _ptr = e.pointer;
      _ptrKind = e.kind;
      _downPos = e.localPosition;
      _lastPos = e.localPosition;
      if (tool == Tool.eraser || e.kind == PointerDeviceKind.invertedStylus) {
        _mode = _Mode.erase;
        _eraseAt(p);
      } else {
        switch (tool) {
          case Tool.pen:
          case Tool.highlighter:
            _mode = _Mode.ink;
            _cur.clear();
            _addPoint(e);
            break;
          case Tool.shape:
            _mode = _Mode.shape;
            _shapeA = p;
            _shapeB = p;
            break;
          case Tool.text:
            _mode = _Mode.text;
            break;
          case Tool.select:
            _mode = _Mode.lasso;
            _sel = {};
            _selBounds = null;
            _lasso
              ..clear()
              ..add(p);
            setState(() {});
            break;
          case Tool.eraser:
            break;
        }
      }
      _tick();
      return;
    }

    if (isTouch && _ptr != null && _ptrKind != PointerDeviceKind.touch) {
      _ignored.add(e.pointer); // palma mientras escribe el lápiz
      return;
    }
    if (isTouch && _ptr != null && _ptrKind == PointerDeviceKind.touch) {
      // Segundo dedo mientras se dibuja con el dedo: pasa a zoom.
      final first = _ptr!;
      _endInteraction(commit: false);
      _touches[first] = _lastPos;
    }
    _touches[e.pointer] = e.localPosition;
    _touchStart[e.pointer] = e.localPosition;
  }

  void _endInteraction({required bool commit, Offset? upPos}) {
    switch (_mode) {
      case _Mode.ink:
        if (commit) _commitStroke();
        _cur.clear();
        break;
      case _Mode.erase:
        if (commit) {
          _commitErase();
        } else {
          _erasing.clear();
          _inkDirty = true;
        }
        break;
      case _Mode.shape:
        if (commit) _commitShape();
        _shapeA = null;
        _shapeB = null;
        break;
      case _Mode.text:
        if (commit && upPos != null && (upPos - _downPos).distance < 12) _createText(_toPage(upPos));
        break;
      case _Mode.lasso:
        if (commit) _finishLasso();
        _lasso.clear();
        break;
      case _Mode.move:
      case _Mode.scale:
        if (commit) {
          _commitTransform();
        } else {
          _selDelta = Offset.zero;
          _selScale = 1;
          _inkDirty = true;
        }
        break;
      case _Mode.none:
        break;
    }
    _ptr = null;
    _ptrKind = null;
    _mode = _Mode.none;
    _eraserPos = null;
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer == _ptr) {
      final p = _toPage(e.localPosition);
      var rebuild = false;
      switch (_mode) {
        case _Mode.ink:
          _addPoint(e);
          break;
        case _Mode.erase:
          final from = _toPage(_lastPos);
          final r = settings.eraserSize / _scale;
          final steps = math.max(1, ((p - from).distance / (r / 2)).ceil());
          for (var i = 1; i <= steps; i++) {
            _eraseAt(Offset.lerp(from, p, i / steps)!);
          }
          break;
        case _Mode.shape:
          _shapeB = p;
          break;
        case _Mode.lasso:
          if ((p - _lasso.last).distance > 2 / _scale) _lasso.add(p);
          break;
        case _Mode.move:
          _selDelta = p - _selStart;
          rebuild = true;
          break;
        case _Mode.scale:
          final origin = _selBounds!.topLeft;
          final d0 = (_selStart - origin).distance;
          _selScale = d0 < 1 ? 1 : ((p - origin).distance / d0).clamp(0.1, 10.0);
          rebuild = true;
          break;
        default:
          break;
      }
      _lastPos = e.localPosition;
      if (rebuild) {
        setState(() {});
      } else {
        _tick();
      }
      return;
    }
    if (_ignored.contains(e.pointer) || !_touches.containsKey(e.pointer)) return;

    if (_touches.length == 1) {
      _pan += e.localPosition - _touches[e.pointer]!;
      _touches[e.pointer] = e.localPosition;
      _clampPan();
    } else {
      final keys = _touches.keys.take(2).toList();
      if (!keys.contains(e.pointer)) return;
      final a0 = _touches[keys[0]]!, b0 = _touches[keys[1]]!;
      _touches[e.pointer] = e.localPosition;
      final a1 = _touches[keys[0]]!, b1 = _touches[keys[1]]!;
      final f0 = (a0 + b0) / 2, f1 = (a1 + b1) / 2;
      final d0 = (a0 - b0).distance, d1 = (a1 - b1).distance;
      final pagePt = _toPage(f0);
      if (d0 > 10) _scale = (_scale * d1 / d0).clamp(0.25, 8.0);
      _pan = f1 - pagePt * _scale;
      _clampPan();
    }
    setState(() {});
  }

  void _up(PointerUpEvent e) {
    if (e.pointer == _ptr) {
      _endInteraction(commit: true, upPos: e.localPosition);
      setState(() {});
      return;
    }
    final start = _touchStart[e.pointer];
    if (settings.tool == Tool.text &&
        start != null &&
        _touches.length == 1 &&
        _touches.containsKey(e.pointer) &&
        (e.localPosition - start).distance < 12) {
      if (_editingId != null) {
        _finishText();
      } else {
        _createText(_toPage(e.localPosition));
      }
    }
    _touches.remove(e.pointer);
    _touchStart.remove(e.pointer);
    _ignored.remove(e.pointer);
  }

  void _cancel(PointerCancelEvent e) {
    if (e.pointer == _ptr) {
      // El navegador a veces "cancela" el lápiz al final del trazo: lo guardamos igualmente.
      _endInteraction(commit: _ptrKind != PointerDeviceKind.touch);
      setState(() {});
    }
    _touches.remove(e.pointer);
    _touchStart.remove(e.pointer);
    _ignored.remove(e.pointer);
  }

  void _signal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      setState(() {
        if (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed) {
          _zoomAt(e.localPosition, _scale * (e.scrollDelta.dy > 0 ? 0.9 : 1.1));
        } else {
          _pan -= e.scrollDelta;
          _clampPan();
        }
      });
    } else if (e is PointerScaleEvent) {
      setState(() => _zoomAt(e.localPosition, _scale * e.scale));
    }
  }

  // ---------- Tinta, borrador y figuras ----------

  bool get _isHl => settings.tool == Tool.highlighter;
  int get _strokeTool => _isHl ? kToolHighlighter : (settings.penPressure ? kToolPen : kToolBall);
  Color get _strokeColor => _isHl ? settings.highlighterColor : settings.penColor;
  double get _strokeWidth => _isHl ? settings.highlighterWidth : settings.penWidth;

  List<double> _currentPoints() {
    if (_isHl && settings.highlighterStraight && _cur.length > 6) {
      final n = _cur.length;
      return [_cur[0], _cur[1], _cur[2], _cur[n - 3], _cur[n - 2], _cur[n - 1]];
    }
    return _cur;
  }

  void _commitStroke() {
    final raw = _currentPoints();
    if (raw.length < 3) return;
    final pts = smoothPoints(raw);
    final t = nowMs();
    final rec = Rec(
      id: newId(),
      kind: 'el',
      parent: widget.page.id,
      data: Stroke.toData(_strokeTool, _strokeColor, _strokeWidth, pts, t),
      updatedAt: t,
    );
    final item = Item.fromRec(rec);
    if (item != null) _cache[rec.id] = item;
    widget.history.commit([Change(rec.copyWith(deleted: true), rec)]);
  }

  void _commitShape() {
    final a = _shapeA, b = _shapeB;
    if (a == null || b == null || (a - b).distance < 4) return;
    final t = nowMs();
    final rec = Rec(
      id: newId(),
      kind: 'el',
      parent: widget.page.id,
      data: {
        'type': 'shape',
        'shape': settings.shape.name,
        'x1': a.dx,
        'y1': a.dy,
        'x2': b.dx,
        'y2': b.dy,
        'color': settings.shapeColor.toARGB32(),
        'w': settings.shapeWidth,
        'fill': settings.shapeFill,
        't': t,
      },
      updatedAt: t,
    );
    widget.history.commit([Change(rec.copyWith(deleted: true), rec)]);
  }

  void _eraseAt(Offset p) {
    final r = settings.eraserSize / _scale;
    _eraserPos = p;
    for (final it in _inkItems) {
      if (!_erasing.contains(it.id) && it.hit(p, r)) {
        _erasing.add(it.id);
        _inkDirty = true;
      }
    }
    if (_inkDirty && mounted) setState(() {});
  }

  void _commitErase() {
    final changes = <Change>[];
    for (final id in _erasing) {
      final rec = store.recs[id];
      if (rec == null || rec.deleted) continue;
      changes.add(Change(rec, rec.copyWith(deleted: true, updatedAt: store.stamp(rec))));
    }
    _erasing.clear();
    _inkDirty = true;
    widget.history.commit(changes);
  }

  ui.Picture _inkPicture() {
    if (_ink != null && !_inkDirty) return _ink!;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    paintPaper(canvas, widget.paper);
    canvas.save();
    canvas.clipRect(const Rect.fromLTWH(0, 0, kPageW, kPageH));
    bool visible(Item it) => !_erasing.contains(it.id) && !(_transforming && _sel.contains(it.id));
    // Imágenes debajo, luego subrayados y por último tinta y figuras.
    for (final it in _inkItems) {
      if (it is ImageItem && visible(it)) it.paint(canvas, _images);
    }
    for (final it in _inkItems) {
      if (it is StrokeItem && it.stroke.tool == kToolHighlighter && visible(it)) it.paint(canvas, _images);
    }
    for (final it in _inkItems) {
      if (it is ImageItem || (it is StrokeItem && it.stroke.tool == kToolHighlighter)) continue;
      if (visible(it)) it.paint(canvas, _images);
    }
    canvas.restore();
    _ink = recorder.endRecording();
    _inkDirty = false;
    return _ink!;
  }

  /// Capa "en vivo": trazo en curso, figura, lazo, selección y borrador.
  void _paintLive(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(_pan.dx, _pan.dy);
    canvas.scale(_scale);

    if (_mode == _Mode.ink && _cur.length >= 3) {
      canvas.save();
      canvas.clipRect(const Rect.fromLTWH(0, 0, kPageW, kPageH));
      paintStroke(canvas, Stroke(_strokeTool, _strokeColor, _strokeWidth, Float32List.fromList(_currentPoints())));
      canvas.restore();
    }

    final a = _shapeA, b = _shapeB;
    if (_mode == _Mode.shape && a != null && b != null) {
      paintShape(canvas, settings.shape, a, b, settings.shapeColor, settings.shapeWidth, settings.shapeFill);
    }

    if (_mode == _Mode.lasso && _lasso.length > 1) {
      final path = Path()..moveTo(_lasso.first.dx, _lasso.first.dy);
      for (final p in _lasso.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 / _scale
            ..color = const Color(0xFF1E88E5));
      canvas.drawPath(path..close(), Paint()..color = const Color(0x141E88E5));
    }

    final sb = _selBounds;
    if (sb != null && _sel.isNotEmpty) {
      if (_transforming) {
        final origin = sb.topLeft;
        canvas.save();
        canvas.translate(origin.dx + _selDelta.dx, origin.dy + _selDelta.dy);
        canvas.scale(_selScale);
        canvas.translate(-origin.dx, -origin.dy);
        for (final it in _inkItems) {
          if (_sel.contains(it.id)) it.paint(canvas, _images);
        }
        canvas.restore();
      }
      final tl = sb.topLeft + _selDelta;
      final r = Rect.fromLTWH(tl.dx, tl.dy, sb.width * _selScale, sb.height * _selScale);
      canvas.drawRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 / _scale
            ..color = const Color(0xFF1E88E5));
      canvas.drawCircle(r.bottomRight, 9 / _scale, Paint()..color = const Color(0xFF1E88E5));
      canvas.drawCircle(r.bottomRight, 5 / _scale, Paint()..color = const Color(0xFFFFFFFF));
    }

    final ep = _eraserPos;
    if (_mode == _Mode.erase && ep != null) {
      canvas.drawCircle(
          ep,
          settings.eraserSize / _scale,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 / _scale
            ..color = const Color(0xAA555555));
    }
    canvas.restore();
  }

  // ---------- Texto ----------

  void _createText(Offset p) {
    if (p.dx < 0 || p.dy < 0 || p.dx > kPageW || p.dy > kPageH) return;
    final t = nowMs();
    final rec = Rec(
      id: newId(),
      kind: 'el',
      parent: widget.page.id,
      data: {
        'type': 'text',
        'x': p.dx,
        'y': p.dy - settings.textSize * 0.7,
        'w': math.min(560.0, kPageW - p.dx - 20).clamp(120.0, kPageW),
        'text': '',
        'size': settings.textSize,
        'color': settings.textColor.toARGB32(),
        'font': settings.font,
        'bold': settings.bold,
        'italic': settings.italic,
        't': t,
      },
      updatedAt: t,
    );
    store.put(rec);
    _startEdit(rec, isNew: true);
  }

  void _startEdit(Rec r, {bool isNew = false}) {
    if (_editingId != null && _editingId != r.id) _finishText();
    _editingId = r.id;
    _editStart = isNew ? r.copyWith(deleted: true) : r;
    _textCtl.text = (r.data['text'] ?? '') as String;
    final d = r.data;
    settings.set(() {
      settings.font = (d['font'] ?? settings.font) as String;
      settings.textSize = ((d['size'] ?? settings.textSize) as num).toDouble();
      settings.bold = d['bold'] == true;
      settings.italic = d['italic'] == true;
      settings.textColor = Color(((d['color'] ?? settings.textColor.toARGB32()) as num).toInt());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_disposed) _textFocus.requestFocus();
    });
  }

  void _finishText() {
    final id = _editingId;
    if (id == null) return;
    _editingId = null;
    _textFocus.unfocus();
    final cur = store.recs[id];
    final start = _editStart;
    _editStart = null;
    if (cur == null) return;
    final text = ((cur.data['text'] ?? '') as String).trim();
    if (text.isEmpty) {
      if (!cur.deleted) {
        final del = cur.copyWith(deleted: true, updatedAt: store.stamp(cur));
        store.put(del);
        if (start != null && !start.deleted) widget.history.record([Change(start, del)]);
      }
    } else if (start != null) {
      final changed = start.deleted || start.data.entries.any((e) => cur.data[e.key] != e.value);
      if (changed) widget.history.record([Change(start, cur)]);
    }
    if (mounted && !_disposed) setState(() {});
  }

  void _updateText(String id, Map<String, dynamic> changes) {
    final cur = store.recs[id];
    if (cur == null) return;
    store.put(cur.copyWith(data: {...cur.data, ...changes}, updatedAt: store.stamp(cur)));
  }

  Widget _textBox(Rec r) {
    var d = r.data;
    final selected = _sel.contains(r.id);
    if (selected && _transforming && _selBounds != null) {
      d = transformData(d, _selBounds!.topLeft, _selScale, _selDelta);
    }
    final x = (d['x'] as num).toDouble() * _scale + _pan.dx;
    final y = (d['y'] as num).toDouble() * _scale + _pan.dy;
    final w = ((d['w'] ?? 500) as num).toDouble() * _scale;
    final editing = r.id == _editingId;
    final style = textStyleFor(d, _scale);

    if (!editing) {
      return Positioned(
        left: x,
        top: y,
        width: w,
        child: IgnorePointer(
          ignoring: settings.tool != Tool.text,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _startEdit(r),
            child: Container(
              color: selected ? const Color(0x221E88E5) : null,
              child: Text((d['text'] ?? '') as String, style: style),
            ),
          ),
        ),
      );
    }

    return Positioned(
      left: x,
      top: y - 44,
      width: math.max(w, 150.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: const Color(0xFF1E88E5),
            borderRadius: BorderRadius.circular(10),
            elevation: 2,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              GestureDetector(
                onPanUpdate: (g) {
                  final cur = store.recs[r.id];
                  if (cur == null) return;
                  _updateText(r.id, {
                    'x': (cur.data['x'] as num).toDouble() + g.delta.dx / _scale,
                    'y': (cur.data['y'] as num).toDouble() + g.delta.dy / _scale,
                  });
                },
                child: const Padding(
                  padding: EdgeInsets.all(7),
                  child: Icon(Icons.open_with, color: Colors.white, size: 22),
                ),
              ),
              GestureDetector(
                onPanUpdate: (g) {
                  final cur = store.recs[r.id];
                  if (cur == null) return;
                  final nw = ((cur.data['w'] ?? 500) as num).toDouble() + g.delta.dx / _scale;
                  _updateText(r.id, {'w': nw.clamp(60.0, kPageW)});
                },
                child: const Padding(
                  padding: EdgeInsets.all(7),
                  child: Icon(Icons.swap_horiz, color: Colors.white, size: 22),
                ),
              ),
              IconButton(
                tooltip: 'Borrar texto',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline, color: Colors.white, size: 22),
                onPressed: () {
                  _updateText(r.id, {'text': ''});
                  _finishText();
                },
              ),
              IconButton(
                tooltip: 'Listo',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.check, color: Colors.white, size: 22),
                onPressed: _finishText,
              ),
            ]),
          ),
          const SizedBox(height: 4),
          Container(
            width: w,
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0x991E88E5), width: 1.5),
              color: Colors.white.withValues(alpha: 0.85),
            ),
            child: TextField(
              controller: _textCtl,
              focusNode: _textFocus,
              maxLines: null,
              style: style,
              cursorColor: const Color(0xFF1E88E5),
              decoration: const InputDecoration.collapsed(hintText: 'Escribe aquí…'),
              onChanged: (v) => _updateText(r.id, {'text': v}),
            ),
          ),
        ],
      ),
    );
  }

  Widget _selectionBar() {
    final r = _selScreenRect()!;
    final top = r.top > 70 ? r.top - 58 : r.bottom + 12;
    final left = (r.center.dx - 110).clamp(8.0, math.max(8.0, _viewport.width - 228));
    Widget btn(IconData icon, String tip, VoidCallback onTap) => IconButton(
          tooltip: tip,
          icon: Icon(icon, size: 22),
          onPressed: onTap,
        );
    return Positioned(
      left: left,
      top: top,
      child: Material(
        elevation: 6,
        shadowColor: Colors.black26,
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            btn(Icons.palette_outlined, 'Cambiar color', _recolorSelection),
            btn(Icons.copy_outlined, 'Duplicar', _duplicateSelection),
            btn(Icons.delete_outline, 'Eliminar', deleteSelection),
            btn(Icons.close, 'Quitar selección', () => setState(() {
                  _sel = {};
                  _selBounds = null;
                })),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, c.maxHeight);
      if (!_fitted) _fit(size);
      _viewport = size;
      final ink = _inkPicture();
      return ClipRect(
        child: Stack(children: [
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _down,
              onPointerMove: _move,
              onPointerUp: _up,
              onPointerCancel: _cancel,
              onPointerSignal: _signal,
              child: Stack(children: [
                Positioned.fill(
                  child: RepaintBoundary(
                    child: CustomPaint(painter: _InkPainter(ink, _scale, _pan)),
                  ),
                ),
                Positioned.fill(child: CustomPaint(painter: _LivePainter(this))),
              ]),
            ),
          ),
          for (final t in _texts) _textBox(t),
          if (_sel.isNotEmpty && _selBounds != null && _mode == _Mode.none) _selectionBar(),
        ]),
      );
    });
  }
}

class _InkPainter extends CustomPainter {
  final ui.Picture ink;
  final double scale;
  final Offset pan;
  _InkPainter(this.ink, this.scale, this.pan);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFE9EBEF));
    canvas.save();
    canvas.translate(pan.dx, pan.dy);
    canvas.scale(scale);
    canvas.drawPicture(ink);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_InkPainter old) => old.ink != ink || old.scale != scale || old.pan != pan;
}

class _LivePainter extends CustomPainter {
  final PageEditorState s;
  _LivePainter(this.s) : super(repaint: s._liveTick);

  @override
  void paint(Canvas canvas, Size size) => s._paintLive(canvas, size);

  @override
  bool shouldRepaint(_LivePainter old) => true;
}
