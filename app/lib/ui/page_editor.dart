import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/store.dart';
import '../ink/ink.dart';
import 'editor_state.dart';

/// Una página: tinta con el lápiz, cajas de texto con el teclado, zoom y desplazamiento con los dedos.
class PageEditor extends StatefulWidget {
  final Store store;
  final Rec page;
  final String paper;
  final EditorSettings settings;
  final History history;

  const PageEditor({
    super.key,
    required this.store,
    required this.page,
    required this.paper,
    required this.settings,
    required this.history,
  });

  @override
  State<PageEditor> createState() => _PageEditorState();
}

class _PageEditorState extends State<PageEditor> {
  Store get store => widget.store;
  EditorSettings get settings => widget.settings;

  // Vista
  double _scale = 1;
  Offset _pan = Offset.zero;
  bool _fitted = false;
  Size _viewport = Size.zero;

  // Punteros
  final Map<int, Offset> _touches = {};
  final Map<int, Offset> _touchStart = {};
  final Set<int> _ignored = {};
  int? _drawPointer;
  PointerDeviceKind? _drawKind;
  Offset _downPos = Offset.zero;
  Offset _lastDrawPos = Offset.zero;
  Tool? _curTool;
  final List<double> _cur = [];
  Offset? _eraserPos;
  final Set<String> _erasing = {};

  // Contenido
  final Map<String, MapEntry<int, Stroke>> _cache = {};
  List<Stroke> _strokes = [];
  List<Rec> _texts = [];
  ui.Picture? _ink;
  bool _inkDirty = true;

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
    super.dispose();
  }

  void _onSettings() {
    if (settings.tool != Tool.text && _editingId != null) _finishText();
    setState(() {});
  }

  void _onStore() {
    if (!mounted) return;
    setState(_reload);
  }

  void _reload() {
    final els = store.elements(widget.page.id);
    final strokes = <Stroke>[];
    final texts = <Rec>[];
    for (final r in els) {
      final type = r.data['type'];
      if (type == 'stroke') {
        var c = _cache[r.id];
        if (c == null || c.key != r.updatedAt) {
          try {
            c = MapEntry(r.updatedAt, Stroke.fromData(r.id, r.data));
            _cache[r.id] = c;
          } catch (_) {
            continue;
          }
        }
        strokes.add(c.value);
      } else if (type == 'text') {
        texts.add(r);
      }
    }
    var same = strokes.length == _strokes.length;
    if (same) {
      for (var i = 0; i < strokes.length; i++) {
        if (!identical(strokes[i], _strokes[i])) {
          same = false;
          break;
        }
      }
    }
    if (!same) _inkDirty = true;
    _strokes = strokes;
    _texts = texts;
  }

  // ---------- Vista ----------

  void _fit(Size size) {
    final s = math.min((size.width - 24) / kPageW, 4.0);
    _scale = s <= 0 ? 0.5 : s;
    _pan = Offset((size.width - kPageW * _scale) / 2, 12);
    _fitted = true;
  }

  Offset _toPage(Offset local) => (local - _pan) / _scale;

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

  // ---------- Punteros ----------

  bool _isPen(PointerEvent e) =>
      e.kind == PointerDeviceKind.stylus || e.kind == PointerDeviceKind.invertedStylus;

  double _pressure(PointerEvent e) {
    if (!_isPen(e)) return 0.5;
    final range = e.pressureMax - e.pressureMin;
    if (range <= 0) return 0.5;
    final p = ((e.pressure - e.pressureMin) / range).clamp(0.0, 1.0);
    // Algunos navegadores envían 0 en el primer punto.
    return p == 0 ? 0.3 : p;
  }

  void _addPoint(PointerEvent e) {
    final p = _toPage(e.localPosition);
    final n = _cur.length;
    if (n >= 3) {
      final dx = p.dx - _cur[n - 3], dy = p.dy - _cur[n - 2];
      if (dx * dx + dy * dy < 0.36) return; // puntos casi iguales
    }
    _cur
      ..add(p.dx)
      ..add(p.dy)
      ..add(_pressure(e));
  }

  void _down(PointerDownEvent e) {
    final isPen = _isPen(e);
    if (isPen) settings.stylusSeen = true;
    if (_editingId != null) _finishText();
    final tool = settings.tool;
    final isMouse = e.kind == PointerDeviceKind.mouse;
    final isTouch = e.kind == PointerDeviceKind.touch;

    if (isMouse && (e.buttons & kPrimaryMouseButton) == 0) {
      _touches[e.pointer] = e.localPosition; // botón secundario/central: mover
      return;
    }

    final fingerDraw = isTouch && settings.fingerDraws && _touches.isEmpty && _drawPointer == null;
    final canDraw = (isPen || isMouse || fingerDraw) && tool != Tool.hand;

    if (canDraw && (_drawPointer == null || _drawKind == PointerDeviceKind.touch)) {
      if (isPen) {
        // El lápiz manda: la palma que ya estuviera apoyada se ignora.
        _ignored.addAll(_touches.keys);
        _touches.clear();
        if (_drawPointer != null) _cancelDraw();
      }
      _drawPointer = e.pointer;
      _drawKind = e.kind;
      _downPos = e.localPosition;
      _lastDrawPos = e.localPosition;
      _curTool = (tool == Tool.eraser || e.kind == PointerDeviceKind.invertedStylus) ? Tool.eraser : tool;
      _cur.clear();
      if (_curTool == Tool.pen || _curTool == Tool.highlighter) {
        _addPoint(e);
      } else if (_curTool == Tool.eraser) {
        _eraseAt(_toPage(e.localPosition));
      }
      setState(() {});
      return;
    }

    if (isTouch && _drawPointer != null && _drawKind != PointerDeviceKind.touch) {
      _ignored.add(e.pointer); // palma mientras escribe el lápiz
      return;
    }
    if (isTouch && _drawPointer != null && _drawKind == PointerDeviceKind.touch) {
      // Segundo dedo mientras se dibuja con el dedo: pasa a zoom.
      final first = _drawPointer!;
      _cancelDraw();
      _touches[first] = _lastDrawPos;
    }
    _touches[e.pointer] = e.localPosition;
    _touchStart[e.pointer] = e.localPosition;
  }

  void _cancelDraw() {
    _drawPointer = null;
    _drawKind = null;
    _curTool = null;
    _cur.clear();
    _erasing.clear();
    _eraserPos = null;
    _inkDirty = true;
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer == _drawPointer) {
      if (_curTool == Tool.pen || _curTool == Tool.highlighter) {
        _addPoint(e);
      } else if (_curTool == Tool.eraser) {
        final from = _toPage(_lastDrawPos), to = _toPage(e.localPosition);
        final r = 14 / _scale;
        final steps = math.max(1, ((to - from).distance / (r / 2)).ceil());
        for (var i = 1; i <= steps; i++) {
          _eraseAt(Offset.lerp(from, to, i / steps)!);
        }
      }
      _lastDrawPos = e.localPosition;
      setState(() {});
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
    if (e.pointer == _drawPointer) {
      final moved = (e.localPosition - _downPos).distance;
      switch (_curTool) {
        case Tool.pen:
        case Tool.highlighter:
          _commitStroke();
          break;
        case Tool.eraser:
          _commitErase();
          break;
        case Tool.text:
          if (moved < 12) _createText(_toPage(e.localPosition));
          break;
        default:
          break;
      }
      _drawPointer = null;
      _drawKind = null;
      _curTool = null;
      _eraserPos = null;
      setState(() {});
      return;
    }
    final start = _touchStart[e.pointer];
    if (settings.tool == Tool.text &&
        start != null &&
        _touches.length == 1 &&
        _touches.containsKey(e.pointer) &&
        (e.localPosition - start).distance < 12) {
      _createText(_toPage(e.localPosition));
    }
    _touches.remove(e.pointer);
    _touchStart.remove(e.pointer);
    _ignored.remove(e.pointer);
  }

  void _cancel(PointerCancelEvent e) {
    if (e.pointer == _drawPointer) {
      setState(_cancelDraw);
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

  // ---------- Tinta ----------

  int get _strokeTool => _curTool == Tool.highlighter ? kToolHighlighter : kToolPen;
  Color get _strokeColor => _curTool == Tool.highlighter ? settings.highlighterColor : settings.penColor;
  double get _strokeWidth => _curTool == Tool.highlighter ? settings.highlighterWidth : settings.penWidth;

  void _commitStroke() {
    if (_cur.length < 3) return;
    final pts = smoothPoints(_cur);
    final t = nowMs();
    final tool = _strokeTool;
    final color = _strokeColor;
    final width = _strokeWidth;
    final rec = Rec(
      id: newId(),
      kind: 'el',
      parent: widget.page.id,
      data: Stroke.toData(tool, color, width, pts, t),
      updatedAt: t,
    );
    _cache[rec.id] = MapEntry(t, Stroke(rec.id, tool, color, width, pts));
    _cur.clear();
    widget.history.commit([Change(rec.copyWith(deleted: true), rec)]);
  }

  void _eraseAt(Offset p) {
    final r = 14 / _scale;
    _eraserPos = p;
    for (final s in _strokes) {
      if (!_erasing.contains(s.id) && s.hit(p, r)) {
        _erasing.add(s.id);
        _inkDirty = true;
      }
    }
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
    // Primero los subrayados, para que queden por debajo de la tinta.
    for (final s in _strokes) {
      if (s.tool == kToolHighlighter && !_erasing.contains(s.id)) paintStroke(canvas, s);
    }
    for (final s in _strokes) {
      if (s.tool != kToolHighlighter && !_erasing.contains(s.id)) paintStroke(canvas, s);
    }
    canvas.restore();
    _ink = recorder.endRecording();
    _inkDirty = false;
    return _ink!;
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
        'color': settings.penColor.toARGB32(),
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
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _textFocus.requestFocus();
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
    } else if (start != null && (start.deleted || start.data['text'] != cur.data['text'] ||
        start.data['x'] != cur.data['x'] || start.data['y'] != cur.data['y'])) {
      widget.history.record([Change(start, cur)]);
    }
    if (mounted && !_disposed) setState(() {});
  }

  void _updateText(String id, Map<String, dynamic> changes) {
    final cur = store.recs[id];
    if (cur == null) return;
    store.put(cur.copyWith(data: {...cur.data, ...changes}, updatedAt: store.stamp(cur)));
  }

  Widget _textBox(Rec r) {
    final d = r.data;
    final x = (d['x'] as num).toDouble() * _scale + _pan.dx;
    final y = (d['y'] as num).toDouble() * _scale + _pan.dy;
    final w = ((d['w'] ?? 500) as num).toDouble() * _scale;
    final fs = ((d['size'] ?? 28) as num).toDouble() * _scale;
    final color = Color(((d['color'] ?? 0xFF111111) as num).toInt());
    final editing = r.id == _editingId;
    final style = TextStyle(fontSize: fs, color: color, height: 1.3);

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
            child: Text((d['text'] ?? '') as String, style: style),
          ),
        ),
      );
    }

    return Positioned(
      left: x,
      top: y - 40,
      width: math.max(w, 140.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: Colors.blue.shade600,
            borderRadius: BorderRadius.circular(8),
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
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.open_with, color: Colors.white, size: 22),
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
              border: Border.all(color: Colors.blue.withValues(alpha: 0.6), width: 1.5),
              color: Colors.white.withValues(alpha: 0.85),
            ),
            child: TextField(
              controller: _textCtl,
              focusNode: _textFocus,
              maxLines: null,
              style: style,
              cursorColor: Colors.blue,
              decoration: const InputDecoration.collapsed(hintText: 'Escribe aquí…'),
              onChanged: (v) => _updateText(r.id, {'text': v}),
            ),
          ),
        ],
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
      Stroke? live;
      if ((_curTool == Tool.pen || _curTool == Tool.highlighter) && _cur.length >= 3) {
        live = Stroke('live', _strokeTool, _strokeColor, _strokeWidth, Float32List.fromList(_cur));
      }
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
              child: CustomPaint(
                painter: _PagePainter(
                  ink: ink,
                  scale: _scale,
                  pan: _pan,
                  live: live,
                  eraser: _curTool == Tool.eraser ? _eraserPos : null,
                  eraserRadius: 14 / _scale,
                ),
              ),
            ),
          ),
          for (final t in _texts) _textBox(t),
        ]),
      );
    });
  }
}

class _PagePainter extends CustomPainter {
  final ui.Picture ink;
  final double scale;
  final Offset pan;
  final Stroke? live;
  final Offset? eraser;
  final double eraserRadius;

  _PagePainter({
    required this.ink,
    required this.scale,
    required this.pan,
    required this.live,
    required this.eraser,
    required this.eraserRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFE4E6EA));
    canvas.save();
    canvas.translate(pan.dx, pan.dy);
    canvas.scale(scale);
    canvas.drawPicture(ink);
    final l = live;
    if (l != null) {
      canvas.save();
      canvas.clipRect(const Rect.fromLTWH(0, 0, kPageW, kPageH));
      paintStroke(canvas, l);
      canvas.restore();
    }
    final e = eraser;
    if (e != null) {
      canvas.drawCircle(
          e,
          eraserRadius,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 / scale
            ..color = const Color(0xAA555555));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
