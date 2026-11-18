import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app_scope.dart';
import '../data/store.dart';
import '../ink/ink.dart';
import 'color_picker.dart';
import 'editor_state.dart';

const double kGap = 40;
const double kTopPad = 24;
double pageTop(int i) => kTopPad + i * (kPageH + kGap);

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

enum _Mode { none, ink, erase, shape, tape, text, lasso, move, scale, laser, rulerMove, rulerRotate }

enum _View { main, zoom }

class _PageCache {
  List<Item> items = [];
  List<Item> ink = [];
  List<Rec> texts = [];
  ui.Picture? pic;
  bool dirty = true;
  String template = '';
  String paperColor = '';
  String? bg;
}

class _LaserPt {
  final Offset p; // coordenadas globales
  final int t;
  _LaserPt(this.p, this.t);
}

/// Todas las páginas de un cuaderno, una debajo de otra, con scroll vertical y zoom.
class NotebookCanvas extends StatefulWidget {
  final AppScope app;
  final Rec notebook;
  final List<Rec> pages;
  final History history;
  final int initialPage;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<Map<String, dynamic>>? onSaveSticker;

  const NotebookCanvas({
    super.key,
    required this.app,
    required this.notebook,
    required this.pages,
    required this.history,
    required this.initialPage,
    required this.onPageChanged,
    this.onSaveSticker,
  });

  @override
  State<NotebookCanvas> createState() => NotebookCanvasState();
}

class NotebookCanvasState extends State<NotebookCanvas> with SingleTickerProviderStateMixin {
  Store get store => widget.app.store;
  EditorSettings get settings => widget.app.settings;
  List<Rec> get pages => widget.pages;

  // Vista principal
  double _scale = 1;
  Offset _pan = Offset.zero;
  bool _fitted = false;
  Size _viewport = Size.zero;
  int _reportedPage = -1;

  // Ventana de zoom
  int _zoomPage = 0;
  Offset _zoomOrigin = const Offset(60, 150);
  Size _zoomPanelSize = const Size(600, 200);
  static const double _zoomWidth = 320; // ancho de la zona ampliada (unidades de página)
  double get _zs => _zoomPanelSize.width / _zoomWidth;
  Size get _zoomSize => Size(_zoomWidth, _zoomPanelSize.height / _zs);
  bool _zoomInit = false;

  // Regla (coordenadas globales)
  Offset _rulerC = const Offset(500, 500);
  double _rulerA = 0;
  static const double _rulerLen = 900, _rulerW = 100;
  bool _rulerInit = false;
  Offset? _snapA, _snapD;

  // Láser
  final List<_LaserPt> _laser = [];
  late final Ticker _ticker;

  // Punteros
  final Map<int, Offset> _touches = {};
  final Map<int, Offset> _touchStart = {};
  final Set<int> _ignored = {};
  int? _ptr;
  PointerDeviceKind? _ptrKind;
  _View _aView = _View.main;
  int _aPage = 0;
  Offset _downPos = Offset.zero;
  Offset _lastPos = Offset.zero;
  _Mode _mode = _Mode.none;
  final List<double> _cur = [];
  Offset? _shapeA, _shapeB;
  Offset? _eraserPos;
  final Set<String> _erasing = {};
  final List<Offset> _lasso = [];

  // Selección (en una página)
  int _selPage = 0;
  Set<String> _sel = {};
  Rect? _selBounds;
  Offset _selStart = Offset.zero;
  Offset _selDelta = Offset.zero;
  double _selScale = 1;
  bool get _transforming => _mode == _Mode.move || _mode == _Mode.scale;

  // Contenido
  final Map<String, _PageCache> _pc = {};
  final Map<String, Item> _itemCache = {};
  final Map<String, ui.Image> _images = {};
  final Set<String> _loadingImages = {};
  final ValueNotifier<int> _liveTick = ValueNotifier(0);

  // Texto en edición
  String? _editingId;
  int _editingPage = 0;
  Rec? _editStart;
  final TextEditingController _textCtl = TextEditingController();
  final FocusNode _textFocus = FocusNode();
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    store.addListener(_onStore);
    settings.addListener(_onSettings);
    _refresh();
  }

  @override
  void didUpdateWidget(NotebookCanvas old) {
    super.didUpdateWidget(old);
    _refresh();
  }

  @override
  void dispose() {
    store.removeListener(_onStore);
    settings.removeListener(_onSettings);
    _disposed = true;
    _finishText();
    _ticker.dispose();
    _textCtl.dispose();
    _textFocus.dispose();
    _liveTick.dispose();
    super.dispose();
  }

  void _tick() => _liveTick.value++;

  void _onTick(Duration _) {
    final now = nowMs();
    _laser.removeWhere((p) => now - p.t > 900);
    if (_laser.isEmpty && _mode != _Mode.laser) _ticker.stop();
    _tick();
  }

  // ---------- Datos ----------

  void _onStore() {
    if (!mounted || _disposed) return;
    setState(_refresh);
  }

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
    if (settings.tool != Tool.select && _sel.isNotEmpty) _clearSelection();
    if (settings.ruler && !_rulerInit) {
      _rulerInit = true;
      _rulerC = _toGlobal(Offset(_viewport.width / 2, _viewport.height / 2));
      _rulerA = 0;
    }
    if (!settings.ruler) _rulerInit = false;
    if (settings.zoomWindow && !_zoomInit) {
      _zoomInit = true;
      _zoomPage = currentPage;
      final top = math.max(100.0, _toGlobal(Offset(0, _viewport.height * 0.25)).dy - pageTop(_zoomPage));
      _zoomOrigin = Offset(60, math.min(top, kPageH - 200));
    }
    if (!settings.zoomWindow) _zoomInit = false;
    if (mounted && !_disposed) setState(() {});
  }

  String _templateOf(Rec page) =>
      (page.data['template'] ?? widget.notebook.data['paper'] ?? 'lined') as String;

  void _refresh() {
    final ids = <String>{};
    final paperColor = (widget.notebook.data['paperColor'] ?? 'white') as String;
    for (final p in pages) {
      ids.add(p.id);
      final pc = _pc.putIfAbsent(p.id, () => _PageCache());
      final items = <Item>[], ink = <Item>[], texts = <Rec>[];
      for (final r in store.elements(p.id)) {
        var it = _itemCache[r.id];
        if (it == null || it.rec.updatedAt != r.updatedAt) {
          it = Item.fromRec(r);
          if (it == null) continue;
          _itemCache[r.id] = it;
        }
        items.add(it);
        if (it is TextItem) {
          texts.add(r);
        } else {
          ink.add(it);
        }
        if (it is ImageItem) _ensureImage(it.blob);
      }
      var same = ink.length == pc.ink.length;
      for (var i = 0; same && i < ink.length; i++) {
        if (!identical(ink[i], pc.ink[i])) same = false;
      }
      if (!same) pc.dirty = true;
      pc.items = items;
      pc.ink = ink;
      pc.texts = texts;
      final tpl = _templateOf(p);
      final bg = p.data['bg'] as String?;
      if (tpl != pc.template || paperColor != pc.paperColor || bg != pc.bg) {
        pc.template = tpl;
        pc.paperColor = paperColor;
        pc.bg = bg;
        pc.dirty = true;
      }
      if (bg != null) _ensureImage(bg);
    }
    _pc.removeWhere((k, _) => !ids.contains(k));
    if (_sel.isNotEmpty) {
      final pc = _selPage < pages.length ? _pc[pages[_selPage].id] : null;
      final present = {for (final i in pc?.items ?? const <Item>[]) i.id};
      _sel = _sel.where(present.contains).toSet();
      if (_sel.isEmpty) {
        _selBounds = null;
      } else if (!_transforming) {
        _selBounds = _computeSelBounds();
      }
    }
  }

  void _ensureImage(String blob) {
    if (_images.containsKey(blob) || _loadingImages.contains(blob)) return;
    _loadImage(blob);
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
      _images[blob] = (await codec.getNextFrame()).image;
      for (final pc in _pc.values) {
        pc.dirty = true;
      }
      if (mounted && !_disposed) setState(() {});
    } catch (_) {}
  }

  void _markDirty(int page) {
    if (page >= 0 && page < pages.length) _pc[pages[page].id]?.dirty = true;
  }

  ui.Picture _pagePicture(int i) {
    final pc = _pc[pages[i].id]!;
    if (pc.pic != null && !pc.dirty) return pc.pic!;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    paintPaper(canvas, pc.template,
        paperColor: pc.paperColor, background: pc.bg == null ? null : _images[pc.bg]);
    canvas.save();
    canvas.clipRect(const Rect.fromLTWH(0, 0, kPageW, kPageH));
    final hideSel = _transforming && i == _selPage;
    paintPageItems(canvas, pc.ink, _images,
        visible: (it) => !_erasing.contains(it.id) && !(hideSel && _sel.contains(it.id)));
    canvas.restore();
    pc.pic = recorder.endRecording();
    pc.dirty = false;
    return pc.pic!;
  }

  // ---------- Vista ----------

  int get pageCount => pages.length;

  Offset _toGlobal(Offset screen) => (screen - _pan) / _scale;
  Offset _toScreen(Offset global) => global * _scale + _pan;

  int _pageAtGlobalY(double gy) =>
      ((gy - kTopPad + kGap / 2) / (kPageH + kGap)).floor().clamp(0, math.max(0, pages.length - 1)).toInt();

  int get currentPage {
    if (pages.isEmpty || _viewport.height == 0) return 0;
    return _pageAtGlobalY(_toGlobal(Offset(0, _viewport.height * 0.4)).dy);
  }

  void _fit(Size size) {
    final s = math.min((size.width - 32) / kPageW, 1.6);
    _scale = s <= 0 ? 0.5 : s;
    final int i = widget.initialPage.clamp(0, math.max(0, pages.length - 1)).toInt();
    _pan = Offset((size.width - kPageW * _scale) / 2, 16 - pageTop(i) * _scale);
    _fitted = true;
  }

  void _clampPan() {
    const margin = 120.0;
    final w = kPageW * _scale;
    final contentH = (pageTop(pages.length) + kTopPad) * _scale;
    final minX = margin - w, maxX = _viewport.width - margin;
    final minY = _viewport.height - margin - contentH, maxY = margin;
    _pan = Offset(_pan.dx.clamp(math.min(minX, maxX), math.max(minX, maxX)),
        _pan.dy.clamp(math.min(minY, maxY), math.max(minY, maxY)));
  }

  void _zoomAt(Offset focal, double newScale) {
    newScale = newScale.clamp(0.2, 6.0);
    final g = _toGlobal(focal);
    _scale = newScale;
    _pan = focal - g * _scale;
    _clampPan();
  }

  void goToPage(int i) {
    if (pages.isEmpty) return;
    i = i.clamp(0, pages.length - 1).toInt();
    setState(() {
      _pan = Offset(_pan.dx, 16 - pageTop(i) * _scale);
      _clampPan();
    });
  }

  /// Zona visible de una página (coordenadas de página).
  Rect _visibleRectOf(int i) {
    final tl = _toGlobal(Offset.zero) - Offset(0, pageTop(i));
    final br = _toGlobal(Offset(_viewport.width, _viewport.height)) - Offset(0, pageTop(i));
    final v = Rect.fromPoints(tl, br).intersect(const Rect.fromLTWH(0, 0, kPageW, kPageH));
    return (v.width <= 20 || v.height <= 20) ? const Rect.fromLTWH(0, 0, kPageW, kPageH) : v;
  }

  // ---------- Selección ----------

  void _clearSelection() {
    if (_sel.isNotEmpty) _markDirty(_selPage);
    _sel = {};
    _selBounds = null;
  }

  Rect? _computeSelBounds() {
    if (_selPage >= pages.length) return null;
    Rect? r;
    for (final it in _pc[pages[_selPage].id]?.items ?? const <Item>[]) {
      if (!_sel.contains(it.id)) continue;
      r = r == null ? it.bounds : r.expandToInclude(it.bounds);
    }
    return r;
  }

  Rect? _selScreenRect() {
    final b = _selBounds;
    if (b == null) return null;
    final tl = b.topLeft + _selDelta + Offset(0, pageTop(_selPage));
    final r = Rect.fromLTWH(tl.dx, tl.dy, b.width * _selScale, b.height * _selScale);
    return Rect.fromPoints(_toScreen(r.topLeft), _toScreen(r.bottomRight));
  }

  void _finishLasso() {
    if (_lasso.length < 3) return;
    _selPage = _aPage;
    final items = _pc[pages[_aPage].id]?.items ?? const <Item>[];
    _sel = {for (final it in items) if (it.inLasso(_lasso)) it.id};
    _selBounds = _sel.isEmpty ? null : _computeSelBounds();
  }

  void _commitTransform() {
    final b = _selBounds;
    if (b == null) return;
    _markDirty(_selPage);
    if (_selDelta == Offset.zero && _selScale == 1) return;
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
    widget.history.commit(changes);
  }

  void deleteSelection() {
    final changes = <Change>[];
    for (final id in _sel) {
      final rec = store.recs[id];
      if (rec == null || rec.deleted) continue;
      changes.add(Change(rec, rec.copyWith(deleted: true, updatedAt: store.stamp(rec))));
    }
    _clearSelection();
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
      final copy = Rec(id: newId(), kind: 'el', parent: rec.parent, data: data, updatedAt: t);
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
      if (type != 'stroke' && type != 'shape' && type != 'text' && type != 'tape') continue;
      final isHl = type == 'stroke' && rec.data['tool'] == kToolHighlighter;
      final color = isHl ? c.withValues(alpha: 0.38) : c;
      changes.add(Change(
          rec, rec.copyWith(data: {...rec.data, 'color': color.toARGB32()}, updatedAt: store.stamp(rec))));
    }
    widget.history.commit(changes);
  }

  void _saveSelectionAsSticker() {
    final b = _selBounds;
    if (b == null || widget.onSaveSticker == null) return;
    final items = <Map<String, dynamic>>[];
    for (final id in _sel) {
      final rec = store.recs[id];
      if (rec == null || rec.deleted) continue;
      items.add(transformData(rec.data, b.topLeft, 1, -b.topLeft));
    }
    widget.onSaveSticker!({'items': items, 'w': b.width, 'h': b.height});
  }

  // ---------- Acciones públicas ----------

  Rec? get _targetPage => pages.isEmpty ? null : pages[currentPage];

  Future<void> insertImage(Uint8List bytes) async {
    final page = _targetPage;
    if (page == null) return;
    final pi = currentPage;
    final codec = await ui.instantiateImageCodec(bytes);
    final img = (await codec.getNextFrame()).image;
    final blob = newId();
    await store.putBlob(blob, bytes);
    _images[blob] = img;
    final vis = _visibleRectOf(pi);
    var w = math.min(img.width.toDouble(), vis.width * 0.8);
    var h = w * img.height / img.width;
    if (h > vis.height * 0.8) {
      h = vis.height * 0.8;
      w = h * img.width / img.height;
    }
    final t = nowMs();
    final rec = Rec(
      id: newId(),
      kind: 'el',
      parent: page.id,
      data: {
        'type': 'image',
        'blob': blob,
        'x': vis.center.dx - w / 2,
        'y': vis.center.dy - h / 2,
        'w': w,
        'h': h,
        't': t,
      },
      updatedAt: t,
    );
    await widget.history.commit([Change(rec.copyWith(deleted: true), rec)]);
    _selectAfterInsert(pi, {rec.id});
  }

  /// Inserta elementos (pegatinas) en el centro de la zona visible de la página actual.
  Future<void> insertElements(List<Map<String, dynamic>> datas, double w, double h) async {
    final page = _targetPage;
    if (page == null || datas.isEmpty) return;
    final pi = currentPage;
    final vis = _visibleRectOf(pi);
    final s = math.min(1.0, math.min(vis.width * 0.5 / math.max(w, 1), vis.height * 0.5 / math.max(h, 1)));
    final off = Offset(vis.center.dx - w * s / 2, vis.center.dy - h * s / 2);
    final t = nowMs();
    final changes = <Change>[];
    final ids = <String>{};
    for (final d in datas) {
      final data = transformData(d, Offset.zero, s, off)..['t'] = t;
      final rec = Rec(id: newId(), kind: 'el', parent: page.id, data: data, updatedAt: t);
      ids.add(rec.id);
      changes.add(Change(rec.copyWith(deleted: true), rec));
    }
    await widget.history.commit(changes);
    _selectAfterInsert(pi, ids);
  }

  void _selectAfterInsert(int pi, Set<String> ids) {
    settings.set(() => settings.tool = Tool.select);
    if (!mounted) return;
    setState(() {
      _selPage = pi;
      _sel = ids;
      _selBounds = _computeSelBounds();
    });
  }

  void clearPage() {
    final page = _targetPage;
    if (page == null) return;
    final changes = <Change>[];
    for (final it in _pc[page.id]?.items ?? const <Item>[]) {
      final rec = store.recs[it.id];
      if (rec == null || rec.deleted) continue;
      changes.add(Change(rec, rec.copyWith(deleted: true, updatedAt: store.stamp(rec))));
    }
    _clearSelection();
    widget.history.commit(changes);
  }

  // ---------- Coordenadas de la interacción activa ----------

  Offset _toLocal(Offset pos) => _aView == _View.zoom
      ? _zoomOrigin + pos / _zs
      : _toGlobal(pos) - Offset(0, pageTop(_aPage));

  double get _aScale => _aView == _View.zoom ? _zs : _scale;

  // ---------- Regla ----------

  Offset _rot(Offset v, double a) => Offset(v.dx * math.cos(a) - v.dy * math.sin(a), v.dx * math.sin(a) + v.dy * math.cos(a));

  Offset get _rulerHandle => _rulerC + _rot(const Offset(_rulerLen / 2 - 70, 0), _rulerA);

  bool _onRuler(Offset g) {
    final d = _rot(g - _rulerC, -_rulerA);
    return d.dx.abs() <= _rulerLen / 2 && d.dy.abs() <= _rulerW / 2;
  }

  /// Si el trazo empieza junto a un borde de la regla, se ajusta a ese borde.
  void _maybeSnapToRuler(Offset g, double strokeWidth) {
    _snapA = null;
    _snapD = null;
    if (!settings.ruler || _aView != _View.main) return;
    final d = _rot(const Offset(1, 0), _rulerA);
    final n = _rot(const Offset(0, 1), _rulerA);
    final along = (g - _rulerC).dx * d.dx + (g - _rulerC).dy * d.dy;
    if (along.abs() > _rulerLen / 2 + 20) return;
    for (final sign in [-1.0, 1.0]) {
      final a = _rulerC + n * (sign * _rulerW / 2);
      final dist = ((g - a).dx * n.dx + (g - a).dy * n.dy).abs();
      if (dist < 30 / _scale) {
        _snapA = a + n * (sign * strokeWidth / 2);
        _snapD = d;
        return;
      }
    }
  }

  Offset _snapLocal(Offset local) {
    final a = _snapA, d = _snapD;
    if (a == null || d == null) return local;
    final g = local + Offset(0, pageTop(_aPage));
    final t = (g - a).dx * d.dx + (g - a).dy * d.dy;
    return a + d * t - Offset(0, pageTop(_aPage));
  }

  void _paintRuler(Canvas canvas) {
    canvas.save();
    canvas.translate(_rulerC.dx, _rulerC.dy);
    canvas.rotate(_rulerA);
    final body = Rect.fromCenter(center: Offset.zero, width: _rulerLen, height: _rulerW);
    canvas.drawRRect(RRect.fromRectAndRadius(body, const Radius.circular(10)), Paint()..color = const Color(0x8CD5DCE6));
    canvas.drawRRect(
        RRect.fromRectAndRadius(body, const Radius.circular(10)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 / _scale
          ..color = const Color(0xAA7B8794));
    final tick = Paint()
      ..color = const Color(0xCC4A5260)
      ..strokeWidth = 1.2 / _scale;
    for (var x = -_rulerLen / 2 + 10; x < _rulerLen / 2; x += 10) {
      final k = ((x + _rulerLen / 2) / 10).round();
      final h = k % 10 == 0 ? 26.0 : (k % 5 == 0 ? 18.0 : 10.0);
      canvas.drawLine(Offset(x, -_rulerW / 2), Offset(x, -_rulerW / 2 + h), tick);
      canvas.drawLine(Offset(x, _rulerW / 2), Offset(x, _rulerW / 2 - h), tick);
    }
    // Asa para girar
    final hx = _rulerLen / 2 - 70;
    canvas.drawCircle(Offset(hx, 0), 22, Paint()..color = const Color(0xFF2F6FED));
    canvas.drawCircle(
        Offset(hx, 0),
        12,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = const Color(0xFFFFFFFF));
    canvas.restore();
    // Ángulo
    var deg = (_rulerA * 180 / math.pi) % 180;
    if (deg < 0) deg += 180;
    final pb = ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 22, textAlign: TextAlign.center))
      ..pushStyle(ui.TextStyle(color: const Color(0xFF2B2F36), fontSize: 22, fontWeight: FontWeight.w700))
      ..addText('${deg.round()}°');
    final para = pb.build()..layout(const ui.ParagraphConstraints(width: 120));
    canvas.drawParagraph(para, _rulerC - const Offset(60, 13));
  }

  // ---------- Punteros ----------

  bool _isPen(PointerEvent e) => e.kind == PointerDeviceKind.stylus || e.kind == PointerDeviceKind.invertedStylus;

  double _pressure(PointerEvent e) {
    if (!_isPen(e)) return 0.5;
    final range = e.pressureMax - e.pressureMin;
    if (range <= 0) return 0.5;
    final p = ((e.pressure - e.pressureMin) / range).clamp(0.0, 1.0);
    return p == 0 ? 0.3 : p;
  }

  void _addPoint(PointerEvent e) {
    final p = _snapLocal(_toLocal(e.localPosition));
    final n = _cur.length;
    if (n >= 3) {
      final dx = p.dx - _cur[n - 3], dy = p.dy - _cur[n - 2];
      if (dx * dx + dy * dy < 0.25 / (_aScale * _aScale)) return;
    }
    _cur
      ..add(p.dx)
      ..add(p.dy)
      ..add(_pressure(e));
  }

  void _downMain(PointerDownEvent e) => _down(e, _View.main);
  void _downZoom(PointerDownEvent e) => _down(e, _View.zoom);
  void _moveMain(PointerMoveEvent e) => _move(e, _View.main);
  void _moveZoom(PointerMoveEvent e) => _move(e, _View.zoom);

  void _down(PointerDownEvent e, _View view) {
    final isPen = _isPen(e);
    final isMouse = e.kind == PointerDeviceKind.mouse;
    final isTouch = e.kind == PointerDeviceKind.touch;
    if (isPen) settings.stylusSeen = true;

    if (view == _View.main && isMouse && (e.buttons & kPrimaryMouseButton) == 0) {
      _touches[e.pointer] = e.localPosition;
      return;
    }

    final tool = settings.tool;
    final drawer = isPen || isMouse || (isTouch && settings.fingerDraws && _touches.isEmpty && _ptr == null);
    final singleTouch = isTouch && _touches.isEmpty && _ptr == null;

    if (view == _View.main) {
      final g = _toGlobal(e.localPosition);

      // Regla: girar con el asa (cualquier puntero) o mover con el dedo / ratón.
      if (settings.ruler && (singleTouch || isMouse || isPen)) {
        final onHandle = (e.localPosition - _toScreen(_rulerHandle)).distance < 36;
        if (onHandle || ((singleTouch || isMouse) && _onRuler(g))) {
          if (_ptr != null) _endInteraction(commit: true);
          _ptr = e.pointer;
          _ptrKind = e.kind;
          _aView = view;
          _lastPos = e.localPosition;
          _mode = onHandle ? _Mode.rulerRotate : _Mode.rulerMove;
          _tick();
          return;
        }
      }

      // Selección: mover o escalar.
      final selRect = _selScreenRect();
      if (tool == Tool.select && selRect != null && (drawer || singleTouch)) {
        final onHandle = (e.localPosition - selRect.bottomRight).distance < 32;
        if (onHandle || selRect.inflate(10).contains(e.localPosition)) {
          if (_ptr != null) _endInteraction(commit: true);
          _ptr = e.pointer;
          _ptrKind = e.kind;
          _aView = view;
          _aPage = _selPage;
          _downPos = e.localPosition;
          _lastPos = e.localPosition;
          _selStart = _toLocal(e.localPosition);
          _selDelta = Offset.zero;
          _selScale = 1;
          _mode = onHandle ? _Mode.scale : _Mode.move;
          _markDirty(_selPage);
          setState(() {});
          return;
        }
      }
    }

    if (drawer || (view == _View.zoom && isTouch && !settings.stylusSeen)) {
      if (isPen) {
        _ignored.addAll(_touches.keys);
        _touches.clear();
        _touchStart.clear();
      }
      if (_ptr != null) _endInteraction(commit: _ptrKind != PointerDeviceKind.touch);
      if (_editingId != null) _finishText();

      _aView = view;
      if (view == _View.zoom) {
        _aPage = _zoomPage;
      } else {
        _aPage = _pageAtGlobalY(_toGlobal(e.localPosition).dy);
      }
      final local = _toLocal(e.localPosition);
      final inside = const Rect.fromLTWH(0, 0, kPageW, kPageH).contains(local);
      if (!inside && tool != Tool.laser) return; // fuera de la página

      _ptr = e.pointer;
      _ptrKind = e.kind;
      _downPos = e.localPosition;
      _lastPos = e.localPosition;
      if (tool == Tool.eraser || e.kind == PointerDeviceKind.invertedStylus) {
        _mode = _Mode.erase;
        _eraseAt(local);
      } else {
        switch (tool) {
          case Tool.pen:
          case Tool.highlighter:
            _mode = _Mode.ink;
            _cur.clear();
            _maybeSnapToRuler(local + Offset(0, pageTop(_aPage)),
                tool == Tool.highlighter ? settings.highlighterWidth : settings.penWidth);
            _addPoint(e);
            break;
          case Tool.shape:
          case Tool.tape:
            _mode = tool == Tool.shape ? _Mode.shape : _Mode.tape;
            _shapeA = local;
            _shapeB = local;
            break;
          case Tool.text:
            _mode = _Mode.text;
            break;
          case Tool.laser:
            _mode = _Mode.laser;
            _laser.add(_LaserPt(_toGlobal(e.localPosition), nowMs()));
            if (!_ticker.isActive) _ticker.start();
            break;
          case Tool.select:
            if (view == _View.zoom) {
              _ptr = null;
              return;
            }
            _mode = _Mode.lasso;
            _clearSelection();
            _lasso
              ..clear()
              ..add(local);
            setState(() {});
            break;
          case Tool.eraser:
            break;
        }
      }
      _tick();
      return;
    }

    if (view == _View.zoom) return;
    if (isTouch && _ptr != null && _ptrKind != PointerDeviceKind.touch) {
      _ignored.add(e.pointer); // palma mientras escribe el lápiz
      return;
    }
    if (isTouch && _ptr != null && _ptrKind == PointerDeviceKind.touch) {
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
        _snapA = null;
        _snapD = null;
        break;
      case _Mode.erase:
        if (commit) {
          _commitErase();
        } else {
          _erasing.clear();
          _markDirty(_aPage);
        }
        break;
      case _Mode.shape:
      case _Mode.tape:
        if (commit) _commitShape(_mode == _Mode.tape);
        _shapeA = null;
        _shapeB = null;
        break;
      case _Mode.text:
        if (commit && upPos != null && (upPos - _downPos).distance < 12) _createText(_aPage, _toLocal(upPos));
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
          _markDirty(_selPage);
        }
        break;
      case _Mode.laser:
      case _Mode.rulerMove:
      case _Mode.rulerRotate:
      case _Mode.none:
        break;
    }
    _ptr = null;
    _ptrKind = null;
    _mode = _Mode.none;
    _eraserPos = null;
  }

  void _move(PointerMoveEvent e, _View view) {
    if (e.pointer == _ptr) {
      var rebuild = false;
      switch (_mode) {
        case _Mode.ink:
          _addPoint(e);
          break;
        case _Mode.erase:
          final from = _toLocal(_lastPos), to = _toLocal(e.localPosition);
          final r = settings.eraserSize / _aScale;
          final steps = math.max(1, ((to - from).distance / (r / 2)).ceil());
          for (var i = 1; i <= steps; i++) {
            _eraseAt(Offset.lerp(from, to, i / steps)!);
          }
          break;
        case _Mode.shape:
        case _Mode.tape:
          _shapeB = _toLocal(e.localPosition);
          break;
        case _Mode.lasso:
          final p = _toLocal(e.localPosition);
          if ((p - _lasso.last).distance > 2 / _scale) _lasso.add(p);
          break;
        case _Mode.move:
          _selDelta = _toLocal(e.localPosition) - _selStart;
          rebuild = true;
          break;
        case _Mode.scale:
          final origin = _selBounds!.topLeft;
          final p = _toLocal(e.localPosition);
          final d0 = (_selStart - origin).distance;
          _selScale = d0 < 1 ? 1 : ((p - origin).distance / d0).clamp(0.1, 10.0);
          rebuild = true;
          break;
        case _Mode.laser:
          _laser.add(_LaserPt(_toGlobal(e.localPosition), nowMs()));
          break;
        case _Mode.rulerMove:
          _rulerC += (e.localPosition - _lastPos) / _scale;
          break;
        case _Mode.rulerRotate:
          final g = _toGlobal(e.localPosition);
          var a = math.atan2(g.dy - _rulerC.dy, g.dx - _rulerC.dx);
          // Ajuste a 0°, 45°, 90°… cuando se acerca.
          final step = math.pi / 4;
          final nearest = (a / step).round() * step;
          if ((a - nearest).abs() < 0.04) a = nearest;
          _rulerA = a;
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
    if (view == _View.zoom) return;
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
      final g = _toGlobal(f0);
      if (d0 > 10) _scale = (_scale * d1 / d0).clamp(0.2, 6.0);
      _pan = f1 - g * _scale;
      _clampPan();
    }
    setState(() {});
  }

  void _up(PointerUpEvent e) {
    if (e.pointer == _ptr) {
      final wasZoom = _aView == _View.zoom && _mode == _Mode.ink;
      _endInteraction(commit: true, upPos: e.localPosition);
      if (wasZoom) _zoomAutoAdvance();
      setState(() {});
      return;
    }
    final start = _touchStart[e.pointer];
    final tap = start != null &&
        _touches.length == 1 &&
        _touches.containsKey(e.pointer) &&
        (e.localPosition - start).distance < 12;
    if (tap) {
      final g = _toGlobal(e.localPosition);
      final pi = _pageAtGlobalY(g.dy);
      final local = g - Offset(0, pageTop(pi));
      if (settings.tool == Tool.text) {
        if (_editingId != null) {
          _finishText();
        } else {
          _createText(pi, local);
        }
      } else if (settings.zoomWindow) {
        // Tocar con el dedo coloca la ventana de zoom en ese punto.
        setState(() {
          _zoomPage = pi;
          _zoomOrigin = Offset(local.dx.clamp(0.0, kPageW - _zoomWidth), local.dy.clamp(0.0, kPageH - 40));
        });
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

  // ---------- Ventana de zoom ----------

  void _zoomAutoAdvance() {
    final pc = pages.isEmpty ? null : _pc[pages[_zoomPage].id];
    if (pc == null || pc.ink.isEmpty) return;
    final last = pc.ink.last.bounds;
    final z = Rect.fromLTWH(_zoomOrigin.dx, _zoomOrigin.dy, _zoomSize.width, _zoomSize.height);
    if (last.right > z.right - z.width * 0.18 && last.overlaps(z)) {
      zoomMove(1, 0);
    }
  }

  /// Mueve la ventana de zoom: dx = ±1 (medio ancho), dy = ±1 (una línea), o salto de línea.
  void zoomMove(int dx, int dy, {bool newLine = false}) {
    setState(() {
      var x = _zoomOrigin.dx, y = _zoomOrigin.dy;
      final zs = _zoomSize;
      if (newLine || x + dx * zs.width * 0.6 > kPageW - zs.width * 0.4) {
        if (newLine || dx > 0) {
          x = 60;
          y += zs.height * 0.75;
        }
      } else {
        x += dx * zs.width * 0.6;
      }
      y += dy * zs.height * 0.75;
      if (y > kPageH - zs.height * 0.5 && _zoomPage < pages.length - 1) {
        _zoomPage++;
        y = 100;
      }
      _zoomOrigin = Offset(x.clamp(0.0, kPageW - zs.width), y.clamp(0.0, kPageH - 40));
      // Que la zona ampliada se vea en la vista principal.
      final top = _toScreen(Offset(0, pageTop(_zoomPage) + _zoomOrigin.dy)).dy;
      if (top < 40 || top > _viewport.height - 260) {
        _pan = Offset(_pan.dx, _pan.dy - (top - _viewport.height * 0.3));
        _clampPan();
      }
    });
  }

  // ---------- Tinta, borrador y figuras ----------

  bool get _isHl => settings.tool == Tool.highlighter;
  int get _strokeTool => _isHl ? kToolHighlighter : (settings.penPressure ? kToolPen : kToolBall);
  Color get _strokeColor => _isHl ? settings.highlighterColor : settings.penColor;
  double get _strokeWidth => _isHl ? settings.highlighterWidth : settings.penWidth;

  List<double> _currentPoints() {
    if (_isHl && settings.highlighterStraight && _cur.length > 6 && _snapA == null) {
      final n = _cur.length;
      return [_cur[0], _cur[1], _cur[2], _cur[n - 3], _cur[n - 2], _cur[n - 1]];
    }
    return _cur;
  }

  /// Puntos tal y como se guardarán (se usan también para dibujar en vivo, así no hay "salto" al soltar).
  Float32List _finalPoints() {
    final raw = _currentPoints();
    return _snapA != null ? Float32List.fromList(raw) : smoothPoints(raw);
  }

  void _commitStroke() {
    if (_currentPoints().length < 3 || _aPage >= pages.length) return;
    final pts = _finalPoints();
    final t = nowMs();
    final rec = Rec(
      id: newId(),
      kind: 'el',
      parent: pages[_aPage].id,
      data: Stroke.toData(_strokeTool, _strokeColor, _strokeWidth, pts, t),
      updatedAt: t,
    );
    final item = Item.fromRec(rec);
    if (item != null) _itemCache[rec.id] = item;
    widget.history.commit([Change(rec.copyWith(deleted: true), rec)]);
  }

  void _commitShape(bool tape) {
    final a = _shapeA, b = _shapeB;
    if (a == null || b == null || (a - b).distance < 4 || _aPage >= pages.length) return;
    final t = nowMs();
    final data = tape
        ? <String, dynamic>{
            'type': 'tape',
            'x1': a.dx,
            'y1': a.dy,
            'x2': b.dx,
            'y2': b.dy,
            'color': settings.tapeColor.toARGB32(),
            'w': settings.tapeWidth,
            'pattern': settings.tapePattern,
            't': t,
          }
        : <String, dynamic>{
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
          };
    final rec = Rec(id: newId(), kind: 'el', parent: pages[_aPage].id, data: data, updatedAt: t);
    widget.history.commit([Change(rec.copyWith(deleted: true), rec)]);
  }

  void _eraseAt(Offset p) {
    if (_aPage >= pages.length) return;
    final r = settings.eraserSize / _aScale;
    _eraserPos = p;
    var changed = false;
    for (final it in _pc[pages[_aPage].id]?.ink ?? const <Item>[]) {
      if (!_erasing.contains(it.id) && it.hit(p, r)) {
        _erasing.add(it.id);
        changed = true;
      }
    }
    if (changed) {
      _markDirty(_aPage);
      if (mounted) setState(() {});
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
    _markDirty(_aPage);
    widget.history.commit(changes);
  }

  /// Dibuja lo que está "en vivo" de la página [page] (en coordenadas de página).
  void _paintLiveOnPage(Canvas canvas, int page, double scale) {
    if (page != _aPage || _ptr == null) return;
    if (_mode == _Mode.ink && _cur.length >= 3) {
      canvas.save();
      canvas.clipRect(const Rect.fromLTWH(0, 0, kPageW, kPageH));
      paintStroke(canvas, Stroke(_strokeTool, _strokeColor, _strokeWidth, _finalPoints()));
      canvas.restore();
    }
    final a = _shapeA, b = _shapeB;
    if (a != null && b != null) {
      if (_mode == _Mode.shape) {
        paintShape(canvas, settings.shape, a, b, settings.shapeColor, settings.shapeWidth, settings.shapeFill);
      } else if (_mode == _Mode.tape) {
        paintTape(canvas, a, b, settings.tapeWidth, settings.tapeColor, settings.tapePattern);
      }
    }
    final ep = _eraserPos;
    if (_mode == _Mode.erase && ep != null) {
      canvas.drawCircle(
          ep,
          settings.eraserSize / scale,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 / scale
            ..color = const Color(0xAA555555));
    }
  }

  void _paintLive(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(_pan.dx, _pan.dy);
    canvas.scale(_scale);

    if (_aView == _View.main) {
      canvas.save();
      canvas.translate(0, pageTop(_aPage));
      _paintLiveOnPage(canvas, _aPage, _scale);
      canvas.restore();
    } else if (_ptr != null) {
      // Lo que se escribe en la ventana de zoom también se ve en la página.
      canvas.save();
      canvas.translate(0, pageTop(_aPage));
      _paintLiveOnPage(canvas, _aPage, _scale);
      canvas.restore();
    }

    // Lazo
    if (_mode == _Mode.lasso && _lasso.length > 1) {
      canvas.save();
      canvas.translate(0, pageTop(_aPage));
      final path = Path()..moveTo(_lasso.first.dx, _lasso.first.dy);
      for (final p in _lasso.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 / _scale
            ..color = const Color(0xFF2F6FED));
      canvas.drawPath(path..close(), Paint()..color = const Color(0x142F6FED));
      canvas.restore();
    }

    // Selección
    final sb = _selBounds;
    if (sb != null && _sel.isNotEmpty && _selPage < pages.length) {
      canvas.save();
      canvas.translate(0, pageTop(_selPage));
      if (_transforming) {
        final origin = sb.topLeft;
        canvas.save();
        canvas.translate(origin.dx + _selDelta.dx, origin.dy + _selDelta.dy);
        canvas.scale(_selScale);
        canvas.translate(-origin.dx, -origin.dy);
        final items = _pc[pages[_selPage].id]?.ink ?? const <Item>[];
        paintPageItems(canvas, items, _images, visible: (it) => _sel.contains(it.id));
        canvas.restore();
      }
      final tl = sb.topLeft + _selDelta;
      final r = Rect.fromLTWH(tl.dx, tl.dy, sb.width * _selScale, sb.height * _selScale);
      canvas.drawRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 / _scale
            ..color = const Color(0xFF2F6FED));
      canvas.drawCircle(r.bottomRight, 9 / _scale, Paint()..color = const Color(0xFF2F6FED));
      canvas.drawCircle(r.bottomRight, 5 / _scale, Paint()..color = const Color(0xFFFFFFFF));
      canvas.restore();
    }

    // Marco de la ventana de zoom
    if (settings.zoomWindow && _zoomPage < pages.length) {
      final z = Rect.fromLTWH(_zoomOrigin.dx, _zoomOrigin.dy + pageTop(_zoomPage), _zoomSize.width, _zoomSize.height);
      canvas.drawRect(z, Paint()..color = const Color(0x142F6FED));
      canvas.drawRect(
          z,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 / _scale
            ..color = const Color(0xFF2F6FED));
    }

    if (settings.ruler) _paintRuler(canvas);

    // Láser
    if (_laser.length > 1) {
      final now = nowMs();
      for (var i = 1; i < _laser.length; i++) {
        final age = (now - _laser[i].t) / 900;
        if (age >= 1) continue;
        final alpha = (1 - age).clamp(0.0, 1.0);
        final glow = Paint()
          ..color = Color.fromRGBO(255, 40, 40, alpha * 0.35)
          ..strokeWidth = 16 / _scale
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
        final core = Paint()
          ..color = Color.fromRGBO(255, 60, 60, alpha)
          ..strokeWidth = 5 / _scale
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(_laser[i - 1].p, _laser[i].p, glow);
        canvas.drawLine(_laser[i - 1].p, _laser[i].p, core);
      }
    }
    canvas.restore();
  }

  // ---------- Texto ----------

  void _createText(int page, Offset p) {
    if (page >= pages.length) return;
    if (p.dx < 0 || p.dy < 0 || p.dx > kPageW || p.dy > kPageH) return;
    final t = nowMs();
    final rec = Rec(
      id: newId(),
      kind: 'el',
      parent: pages[page].id,
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
    _startEdit(rec, page, isNew: true);
  }

  void _startEdit(Rec r, int page, {bool isNew = false}) {
    if (_editingId != null && _editingId != r.id) _finishText();
    _editingId = r.id;
    _editingPage = page;
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

  Widget _textBox(Rec r, int page) {
    var d = r.data;
    final selected = page == _selPage && _sel.contains(r.id);
    if (selected && _transforming && _selBounds != null) {
      d = transformData(d, _selBounds!.topLeft, _selScale, _selDelta);
    }
    final top = pageTop(page);
    final x = (d['x'] as num).toDouble() * _scale + _pan.dx;
    final y = ((d['y'] as num).toDouble() + top) * _scale + _pan.dy;
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
            onTap: () => _startEdit(r, page),
            child: Container(
              color: selected ? const Color(0x222F6FED) : null,
              child: Text((d['text'] ?? '') as String, style: style),
            ),
          ),
        ),
      );
    }

    return Positioned(
      left: x,
      top: y - 46,
      width: math.max(w, 170.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: const Color(0xFF2F6FED),
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
              border: Border.all(color: const Color(0x992F6FED), width: 1.5),
              color: Colors.white.withValues(alpha: 0.85),
            ),
            child: TextField(
              controller: _textCtl,
              focusNode: _textFocus,
              maxLines: null,
              style: style,
              cursorColor: const Color(0xFF2F6FED),
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
    final double left = (r.center.dx - 140).clamp(8.0, math.max(8.0, _viewport.width - 290)).toDouble();
    Widget btn(IconData icon, String label, VoidCallback onTap) => InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 20, color: const Color(0xFF3A3F47)),
              Text(label, style: const TextStyle(fontSize: 10.5, color: Color(0xFF3A3F47))),
            ]),
          ),
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
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            btn(Icons.palette_outlined, 'Color', _recolorSelection),
            btn(Icons.copy_outlined, 'Duplicar', _duplicateSelection),
            if (widget.onSaveSticker != null) btn(Icons.star_outline, 'Pegatina', _saveSelectionAsSticker),
            btn(Icons.delete_outline, 'Borrar', deleteSelection),
            btn(Icons.close, 'Cerrar', () => setState(_clearSelection)),
          ]),
        ),
      ),
    );
  }

  Widget _zoomPanel() {
    Widget b(IconData icon, String tip, VoidCallback onTap) => IconButton(
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          icon: Icon(icon, size: 22, color: const Color(0xFF3A3F47)),
          onPressed: onTap,
        );
    return Material(
      elevation: 10,
      color: const Color(0xFFF7F8FA),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 230,
          child: Row(children: [
            Expanded(
              child: LayoutBuilder(builder: (context, c) {
                _zoomPanelSize = Size(c.maxWidth, c.maxHeight);
                return ClipRect(
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: _downZoom,
                    onPointerMove: _moveZoom,
                    onPointerUp: _up,
                    onPointerCancel: _cancel,
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: _ZoomPainter(this),
                    ),
                  ),
                );
              }),
            ),
            Container(width: 1, color: Colors.black12),
            SizedBox(
              width: 104,
              child: Wrap(alignment: WrapAlignment.center, runAlignment: WrapAlignment.center, children: [
                b(Icons.arrow_upward, 'Subir', () => zoomMove(0, -1)),
                b(Icons.arrow_downward, 'Bajar', () => zoomMove(0, 1)),
                b(Icons.arrow_back, 'Izquierda', () => zoomMove(-1, 0)),
                b(Icons.arrow_forward, 'Derecha', () => zoomMove(1, 0)),
                b(Icons.keyboard_return, 'Siguiente línea', () => zoomMove(0, 0, newLine: true)),
                b(Icons.close, 'Cerrar zoom', () => settings.set(() => settings.zoomWindow = false)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        child: LayoutBuilder(builder: (context, c) {
          final size = Size(c.maxWidth, c.maxHeight);
          if (!_fitted && size.width > 0) _fit(size);
          _viewport = size;
          final cp = currentPage;
          if (cp != _reportedPage) {
            _reportedPage = cp;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) widget.onPageChanged(cp);
            });
          }

          // Páginas visibles
          final pics = <(double, ui.Picture)>[];
          final visibleTexts = <Widget>[];
          if (pages.isNotEmpty) {
            final gTop = _toGlobal(Offset.zero).dy, gBottom = _toGlobal(Offset(0, size.height)).dy;
            final i0 = _pageAtGlobalY(gTop), i1 = _pageAtGlobalY(gBottom);
            for (var i = i0; i <= i1; i++) {
              pics.add((pageTop(i), _pagePicture(i)));
              for (final t in _pc[pages[i].id]?.texts ?? const <Rec>[]) {
                visibleTexts.add(_textBox(t, i));
              }
            }
          }

          return ClipRect(
            child: Stack(children: [
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _downMain,
                  onPointerMove: _moveMain,
                  onPointerUp: _up,
                  onPointerCancel: _cancel,
                  onPointerSignal: _signal,
                  child: Stack(children: [
                    Positioned.fill(
                      child: RepaintBoundary(
                        child: CustomPaint(painter: _InkPainter(pics, _scale, _pan)),
                      ),
                    ),
                    Positioned.fill(child: RepaintBoundary(child: CustomPaint(painter: _LivePainter(this)))),
                  ]),
                ),
              ),
              ...visibleTexts,
              if (_sel.isNotEmpty && _selBounds != null && _mode == _Mode.none) _selectionBar(),
            ]),
          );
        }),
      ),
      if (settings.zoomWindow) _zoomPanel(),
    ]);
  }
}

class _InkPainter extends CustomPainter {
  final List<(double, ui.Picture)> pics;
  final double scale;
  final Offset pan;
  _InkPainter(this.pics, this.scale, this.pan);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFE9EBEF));
    canvas.save();
    canvas.translate(pan.dx, pan.dy);
    canvas.scale(scale);
    for (final (top, pic) in pics) {
      canvas.save();
      canvas.translate(0, top);
      canvas.drawPicture(pic);
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_InkPainter old) {
    if (old.scale != scale || old.pan != pan || old.pics.length != pics.length) return true;
    for (var i = 0; i < pics.length; i++) {
      if (!identical(old.pics[i].$2, pics[i].$2) || old.pics[i].$1 != pics[i].$1) return true;
    }
    return false;
  }
}

class _LivePainter extends CustomPainter {
  final NotebookCanvasState s;
  _LivePainter(this.s) : super(repaint: s._liveTick);

  @override
  void paint(Canvas canvas, Size size) => s._paintLive(canvas, size);

  @override
  bool shouldRepaint(_LivePainter old) => true;
}

class _ZoomPainter extends CustomPainter {
  final NotebookCanvasState s;
  _ZoomPainter(this.s) : super(repaint: s._liveTick);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
    if (s.pages.isEmpty || s._zoomPage >= s.pages.length) return;
    final zs = s._zs;
    canvas.save();
    canvas.scale(zs);
    canvas.translate(-s._zoomOrigin.dx, -s._zoomOrigin.dy);
    canvas.drawPicture(s._pagePicture(s._zoomPage));
    s._paintLiveOnPage(canvas, s._zoomPage, zs);
    canvas.restore();
    // Línea guía
    final y = size.height * 0.72;
    canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..color = const Color(0x332F6FED)
          ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(_ZoomPainter old) => true;
}
