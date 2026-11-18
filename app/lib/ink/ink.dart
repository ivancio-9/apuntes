import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui';

import '../data/store.dart';

/// Tamaño de una página en unidades internas (proporción A4).
const double kPageW = 1000;
const double kPageH = 1414;

enum Tool { select, pen, highlighter, eraser, shape, tape, text, laser }

enum ShapeKind { line, arrow, rect, ellipse, triangle }

const int kToolPen = 0; // estilográfica (sensible a la presión)
const int kToolHighlighter = 1;
const int kToolBall = 2; // bolígrafo (grosor constante)

// ---------------------------------------------------------------------------
// Utilidades geométricas

double distSqToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len2 = ab.distanceSquared;
  if (len2 == 0) return (p - a).distanceSquared;
  var t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len2;
  t = t.clamp(0.0, 1.0);
  final proj = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
  return (p - proj).distanceSquared;
}

bool pointInPolygon(Offset p, List<Offset> poly) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.dy > p.dy) != (b.dy > p.dy) && p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}

String encodePts(Float32List pts) => base64Encode(pts.buffer.asUint8List(pts.offsetInBytes, pts.lengthInBytes));

Float32List decodePts(String s) {
  final bytes = Uint8List.fromList(base64Decode(s));
  return Float32List.view(bytes.buffer, 0, bytes.lengthInBytes ~/ 4);
}

double _num(Object? v, double def) => v is num ? v.toDouble() : def;

// ---------------------------------------------------------------------------
// Elementos de la página

abstract class Item {
  final Rec rec;
  Item(this.rec);
  String get id => rec.id;
  Rect get bounds;

  /// ¿Lo toca el borrador?
  bool hit(Offset p, double r) => false;

  /// ¿Queda dentro del lazo?
  bool inLasso(List<Offset> poly) => pointInPolygon(bounds.center, poly);

  void paint(Canvas canvas, Map<String, ui.Image> images) {}

  static Item? fromRec(Rec r) {
    try {
      switch (r.data['type']) {
        case 'stroke':
          return StrokeItem(r);
        case 'shape':
          return ShapeItem(r);
        case 'tape':
          return TapeItem(r);
        case 'image':
          return ImageItem(r);
        case 'text':
          return TextItem(r);
      }
    } catch (_) {}
    return null;
  }
}

class StrokeItem extends Item {
  late final Stroke stroke;
  StrokeItem(super.rec) {
    final d = rec.data;
    stroke = Stroke(
      (d['tool'] as num?)?.toInt() ?? kToolPen,
      Color((d['color'] as num).toInt()),
      (d['w'] as num).toDouble(),
      decodePts(d['pts'] as String),
    );
  }

  @override
  Rect get bounds => stroke.bounds;

  @override
  bool hit(Offset p, double r) => stroke.hit(p, r);

  @override
  bool inLasso(List<Offset> poly) {
    final n = stroke.length;
    final step = math.max(1, n ~/ 12);
    var total = 0, inside = 0;
    for (var i = 0; i < n; i += step) {
      total++;
      if (pointInPolygon(Offset(stroke.pts[i * 3], stroke.pts[i * 3 + 1]), poly)) inside++;
    }
    return total > 0 && inside * 2 >= total;
  }

  @override
  void paint(Canvas canvas, Map<String, ui.Image> images) => paintStroke(canvas, stroke);
}

class ShapeItem extends Item {
  late final ShapeKind kind;
  late final Offset a, b;
  late final Color color;
  late final double width;
  late final bool fill;

  ShapeItem(super.rec) {
    final d = rec.data;
    kind = ShapeKind.values.firstWhere((k) => k.name == d['shape'], orElse: () => ShapeKind.rect);
    a = Offset(_num(d['x1'], 0), _num(d['y1'], 0));
    b = Offset(_num(d['x2'], 0), _num(d['y2'], 0));
    color = Color((d['color'] as num).toInt());
    width = _num(d['w'], 3);
    fill = d['fill'] == true;
  }

  @override
  Rect get bounds => Rect.fromPoints(a, b).inflate(width + (kind == ShapeKind.arrow ? 20 : 0));

  @override
  bool hit(Offset p, double r) {
    final pts = shapeOutline(kind, a, b);
    final rr = r + width / 2;
    for (var i = 0; i < pts.length - 1; i++) {
      if (distSqToSegment(p, pts[i], pts[i + 1]) <= rr * rr) return true;
    }
    return false;
  }

  @override
  void paint(Canvas canvas, Map<String, ui.Image> images) => paintShape(canvas, kind, a, b, color, width, fill);
}

class TapeItem extends Item {
  late final Offset a, b;
  late final Color color;
  late final double width;
  late final String pattern;

  TapeItem(super.rec) {
    final d = rec.data;
    a = Offset(_num(d['x1'], 0), _num(d['y1'], 0));
    b = Offset(_num(d['x2'], 0), _num(d['y2'], 0));
    color = Color((d['color'] as num).toInt());
    width = _num(d['w'], 36);
    pattern = (d['pattern'] ?? 'stripes') as String;
  }

  @override
  Rect get bounds => Rect.fromPoints(a, b).inflate(width);

  @override
  bool hit(Offset p, double r) {
    final rr = r + width / 2;
    return distSqToSegment(p, a, b) <= rr * rr;
  }

  @override
  void paint(Canvas canvas, Map<String, ui.Image> images) => paintTape(canvas, a, b, width, color, pattern);
}

class ImageItem extends Item {
  late final String blob;
  late final Rect rect;
  ImageItem(super.rec) {
    final d = rec.data;
    blob = d['blob'] as String;
    rect = Rect.fromLTWH(_num(d['x'], 0), _num(d['y'], 0), _num(d['w'], 100), _num(d['h'], 100));
  }

  @override
  Rect get bounds => rect;

  @override
  void paint(Canvas canvas, Map<String, ui.Image> images) {
    final img = images[blob];
    if (img == null) {
      canvas.drawRect(rect, Paint()..color = const Color(0xFFEEEEEE));
      canvas.drawRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = const Color(0xFFBBBBBB)
            ..strokeWidth = 2);
      return;
    }
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      rect,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }
}

class TextItem extends Item {
  TextItem(super.rec);

  @override
  Rect get bounds {
    final d = rec.data;
    final size = _num(d['size'], 28);
    final w = _num(d['w'], 500);
    final text = (d['text'] ?? '') as String;
    // Estimación de la altura (el texto real se dibuja como widget).
    var lines = 0;
    for (final l in text.split('\n')) {
      lines += math.max(1, (l.length * size * 0.5 / w).ceil());
    }
    return Rect.fromLTWH(_num(d['x'], 0), _num(d['y'], 0), w, math.max(1, lines) * size * 1.3);
  }
}

/// Aplica a los datos de un elemento un escalado [s] respecto a [origin] y un desplazamiento [delta].
Map<String, dynamic> transformData(Map<String, dynamic> d, Offset origin, double s, Offset delta) {
  Offset tp(double x, double y) => origin + (Offset(x, y) - origin) * s + delta;
  final out = Map<String, dynamic>.from(d);
  switch (d['type']) {
    case 'stroke':
      final pts = decodePts(d['pts'] as String);
      final res = Float32List(pts.length);
      for (var i = 0; i < pts.length; i += 3) {
        final p = tp(pts[i], pts[i + 1]);
        res[i] = p.dx;
        res[i + 1] = p.dy;
        res[i + 2] = pts[i + 2];
      }
      out['pts'] = encodePts(res);
      out['w'] = _num(d['w'], 3) * s;
      break;
    case 'shape':
    case 'tape':
      final p1 = tp(_num(d['x1'], 0), _num(d['y1'], 0));
      final p2 = tp(_num(d['x2'], 0), _num(d['y2'], 0));
      out['x1'] = p1.dx;
      out['y1'] = p1.dy;
      out['x2'] = p2.dx;
      out['y2'] = p2.dy;
      out['w'] = _num(d['w'], 3) * s;
      break;
    case 'image':
    case 'text':
      final p = tp(_num(d['x'], 0), _num(d['y'], 0));
      out['x'] = p.dx;
      out['y'] = p.dy;
      out['w'] = _num(d['w'], 100) * s;
      if (d['type'] == 'image') out['h'] = _num(d['h'], 100) * s;
      if (d['type'] == 'text') out['size'] = _num(d['size'], 28) * s;
      break;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Trazos

class Stroke {
  final int tool;
  final Color color;
  final double width;
  final Float32List pts; // x, y, presión (0..1), repetido
  late final Rect bounds = _bounds();
  late final Path path = buildStrokePath(densify(pts), width, pressure: tool == kToolPen);

  Stroke(this.tool, this.color, this.width, this.pts);

  int get length => pts.length ~/ 3;

  Rect _bounds() {
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    for (var i = 0; i < pts.length; i += 3) {
      minX = math.min(minX, pts[i]);
      maxX = math.max(maxX, pts[i]);
      minY = math.min(minY, pts[i + 1]);
      maxY = math.max(maxY, pts[i + 1]);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY).inflate(width);
  }

  static Map<String, dynamic> toData(int tool, Color color, double width, Float32List pts, int t) => {
        'type': 'stroke',
        'tool': tool,
        'color': color.toARGB32(),
        'w': width,
        'pts': encodePts(pts),
        't': t,
      };

  bool hit(Offset p, double r) {
    if (!bounds.inflate(r).contains(p)) return false;
    final rr = r + width / 2;
    final rr2 = rr * rr;
    final n = length;
    if (n == 1) return (Offset(pts[0], pts[1]) - p).distanceSquared <= rr2;
    for (var i = 0; i < n - 1; i++) {
      final a = Offset(pts[i * 3], pts[i * 3 + 1]);
      final b = Offset(pts[i * 3 + 3], pts[i * 3 + 4]);
      if (distSqToSegment(p, a, b) <= rr2) return true;
    }
    return false;
  }
}

double _radius(double width, double p, bool pressure) => pressure ? width / 2 * (0.35 + 1.15 * p) : width / 2;

/// Suaviza los puntos al terminar el trazo (media ponderada con los vecinos).
Float32List smoothPoints(List<double> raw) {
  final n = raw.length ~/ 3;
  final out = Float32List(raw.length);
  for (var i = 0; i < n; i++) {
    if (i == 0 || i == n - 1) {
      out[i * 3] = raw[i * 3];
      out[i * 3 + 1] = raw[i * 3 + 1];
      out[i * 3 + 2] = raw[i * 3 + 2];
      continue;
    }
    for (var k = 0; k < 3; k++) {
      out[i * 3 + k] = raw[(i - 1) * 3 + k] * 0.25 + raw[i * 3 + k] * 0.5 + raw[(i + 1) * 3 + k] * 0.25;
    }
  }
  return out;
}

/// Añade puntos intermedios con una curva (Catmull-Rom) para que el trazo sea suave
/// aunque el navegador entregue pocos puntos del lápiz.
List<double> densify(List<double> pts) {
  final n = pts.length ~/ 3;
  if (n < 3) return pts;
  final out = <double>[];
  Offset p(int i) {
    final k = i.clamp(0, n - 1).toInt();
    return Offset(pts[k * 3], pts[k * 3 + 1]);
  }

  for (var i = 0; i < n - 1; i++) {
    final p0 = p(i - 1), p1 = p(i), p2 = p(i + 1), p3 = p(i + 2);
    final pr1 = pts[i * 3 + 2], pr2 = pts[(i + 1) * 3 + 2];
    out
      ..add(p1.dx)
      ..add(p1.dy)
      ..add(pr1);
    final d = (p2 - p1).distance;
    final steps = math.min(10, (d / 2.5).floor());
    for (var k = 1; k < steps; k++) {
      final t = k / steps, t2 = t * t, t3 = t2 * t;
      final x = 0.5 *
          (2 * p1.dx +
              (-p0.dx + p2.dx) * t +
              (2 * p0.dx - 5 * p1.dx + 4 * p2.dx - p3.dx) * t2 +
              (-p0.dx + 3 * p1.dx - 3 * p2.dx + p3.dx) * t3);
      final y = 0.5 *
          (2 * p1.dy +
              (-p0.dy + p2.dy) * t +
              (2 * p0.dy - 5 * p1.dy + 4 * p2.dy - p3.dy) * t2 +
              (-p0.dy + 3 * p1.dy - 3 * p2.dy + p3.dy) * t3);
      out
        ..add(x)
        ..add(y)
        ..add(pr1 + (pr2 - pr1) * t);
    }
  }
  out
    ..add(pts[(n - 1) * 3])
    ..add(pts[(n - 1) * 3 + 1])
    ..add(pts[(n - 1) * 3 + 2]);
  return out;
}

/// Contorno relleno de un trazo con grosor variable según la presión.
Path buildStrokePath(List<double> pts, double width, {bool pressure = true}) {
  final n = pts.length ~/ 3;
  final path = Path();
  if (n == 0) return path;
  if (n == 1) {
    return path..addOval(Rect.fromCircle(center: Offset(pts[0], pts[1]), radius: _radius(width, pts[2], pressure)));
  }
  final left = <Offset>[];
  final right = <Offset>[];
  for (var i = 0; i < n; i++) {
    final prev = i > 0 ? i - 1 : i;
    final next = i < n - 1 ? i + 1 : i;
    var dx = pts[next * 3] - pts[prev * 3];
    var dy = pts[next * 3 + 1] - pts[prev * 3 + 1];
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-6) {
      dx = 1;
      dy = 0;
    } else {
      dx /= len;
      dy /= len;
    }
    final r = _radius(width, pts[i * 3 + 2], pressure);
    final c = Offset(pts[i * 3], pts[i * 3 + 1]);
    left.add(c + Offset(-dy * r, dx * r));
    right.add(c - Offset(-dy * r, dx * r));
  }
  path.moveTo(left[0].dx, left[0].dy);
  for (var i = 1; i < n - 1; i++) {
    final m = (left[i] + left[i + 1]) / 2;
    path.quadraticBezierTo(left[i].dx, left[i].dy, m.dx, m.dy);
  }
  path.lineTo(left[n - 1].dx, left[n - 1].dy);
  path.lineTo(right[n - 1].dx, right[n - 1].dy);
  for (var i = n - 2; i > 0; i--) {
    final m = (right[i] + right[i - 1]) / 2;
    path.quadraticBezierTo(right[i].dx, right[i].dy, m.dx, m.dy);
  }
  path.lineTo(right[0].dx, right[0].dy);
  path.close();
  return path;
}

void paintStroke(Canvas canvas, Stroke s) {
  final paint = Paint()
    ..color = s.color
    ..style = PaintingStyle.fill
    ..isAntiAlias = true;
  canvas.drawPath(s.path, paint);
  if (s.tool != kToolHighlighter && s.length > 1) {
    final p = s.pts;
    final n = s.length;
    final pr = s.tool == kToolPen;
    canvas.drawCircle(Offset(p[0], p[1]), _radius(s.width, p[2], pr), paint);
    canvas.drawCircle(Offset(p[(n - 1) * 3], p[(n - 1) * 3 + 1]), _radius(s.width, p[(n - 1) * 3 + 2], pr), paint);
  }
}

// ---------------------------------------------------------------------------
// Figuras

List<Offset> shapeOutline(ShapeKind k, Offset a, Offset b) {
  final r = Rect.fromPoints(a, b);
  switch (k) {
    case ShapeKind.line:
    case ShapeKind.arrow:
      return [a, b];
    case ShapeKind.rect:
      return [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft, r.topLeft];
    case ShapeKind.triangle:
      return [r.bottomLeft, r.topCenter, r.bottomRight, r.bottomLeft];
    case ShapeKind.ellipse:
      return [
        for (var i = 0; i <= 36; i++)
          Offset(r.center.dx + r.width / 2 * math.cos(i * math.pi / 18),
              r.center.dy + r.height / 2 * math.sin(i * math.pi / 18)),
      ];
  }
}

void paintShape(Canvas canvas, ShapeKind k, Offset a, Offset b, Color color, double w, bool fill) {
  final stroke = Paint()
    ..color = color
    ..strokeWidth = w
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;
  final fillPaint = Paint()..color = color.withValues(alpha: color.a * 0.25);
  final r = Rect.fromPoints(a, b);
  switch (k) {
    case ShapeKind.line:
      canvas.drawLine(a, b, stroke);
      break;
    case ShapeKind.arrow:
      canvas.drawLine(a, b, stroke);
      final ang = math.atan2(b.dy - a.dy, b.dx - a.dx);
      final len = math.max(18.0, w * 4);
      for (final da in [2.6, -2.6]) {
        canvas.drawLine(b, b + Offset(math.cos(ang + da) * len, math.sin(ang + da) * len), stroke);
      }
      break;
    case ShapeKind.rect:
      if (fill) canvas.drawRect(r, fillPaint);
      canvas.drawRect(r, stroke);
      break;
    case ShapeKind.ellipse:
      if (fill) canvas.drawOval(r, fillPaint);
      canvas.drawOval(r, stroke);
      break;
    case ShapeKind.triangle:
      final path = Path()
        ..moveTo(r.left, r.bottom)
        ..lineTo(r.center.dx, r.top)
        ..lineTo(r.right, r.bottom)
        ..close();
      if (fill) canvas.drawPath(path, fillPaint);
      canvas.drawPath(path, stroke);
      break;
  }
}

// ---------------------------------------------------------------------------
// Washi tape

const kTapePatterns = ['solid', 'stripes', 'dots', 'grid', 'zigzag'];

void paintTape(Canvas canvas, Offset a, Offset b, double w, Color color, String pattern) {
  final len = (b - a).distance;
  if (len < 1) return;
  final ang = math.atan2(b.dy - a.dy, b.dx - a.dx);
  canvas.save();
  canvas.translate(a.dx, a.dy);
  canvas.rotate(ang);
  final h = w / 2;
  final n = math.max(4, (w / 5).round());
  final path = Path()..moveTo(0, -h);
  path.lineTo(len, -h);
  for (var i = 1; i <= n; i++) {
    path.lineTo(len + (i.isOdd ? -3.5 : 0), -h + w * i / n);
  }
  path.lineTo(0, h);
  for (var i = 1; i <= n; i++) {
    path.lineTo(i.isOdd ? 3.5 : 0, h - w * i / n);
  }
  path.close();
  canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.78));
  canvas.save();
  canvas.clipPath(path);
  final p = Paint()
    ..color = const Color(0x73FFFFFF)
    ..strokeWidth = 3;
  switch (pattern) {
    case 'stripes':
      for (var x = -w; x < len + w; x += 14) {
        canvas.drawLine(Offset(x, h), Offset(x + w, -h), p);
      }
      break;
    case 'dots':
      for (var x = 6.0; x < len; x += 13) {
        for (var y = -h + 6; y < h; y += 12) {
          canvas.drawCircle(Offset(x + ((y / 12).round().isOdd ? 6 : 0), y), 2.6, p);
        }
      }
      break;
    case 'grid':
      p.strokeWidth = 1.6;
      for (var x = 0.0; x < len; x += 10) {
        canvas.drawLine(Offset(x, -h), Offset(x, h), p);
      }
      for (var y = -h; y < h; y += 10) {
        canvas.drawLine(Offset(0, y), Offset(len, y), p);
      }
      break;
    case 'zigzag':
      p
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5;
      final z = Path()..moveTo(0, 0);
      for (var x = 0.0; x < len; x += 10) {
        z.lineTo(x + 5, (x ~/ 10).isEven ? -h * 0.4 : h * 0.4);
      }
      canvas.drawPath(z, p);
      break;
  }
  canvas.restore();
  canvas.restore();
}

/// Pinta los elementos de una página en el orden correcto (imágenes, subrayados, resto).
void paintPageItems(Canvas canvas, Iterable<Item> items, Map<String, ui.Image> images,
    {bool Function(Item)? visible}) {
  final list = items.where((it) => it is! TextItem && (visible == null || visible(it))).toList();
  for (final it in list) {
    if (it is ImageItem) it.paint(canvas, images);
  }
  for (final it in list) {
    if (it is StrokeItem && it.stroke.tool == kToolHighlighter) it.paint(canvas, images);
  }
  for (final it in list) {
    if (it is ImageItem || (it is StrokeItem && it.stroke.tool == kToolHighlighter)) continue;
    it.paint(canvas, images);
  }
}

// ---------------------------------------------------------------------------
// Papel y plantillas

const kTemplates = {
  'blank': 'En blanco',
  'lined': 'Rayado',
  'narrow': 'Rayado estrecho',
  'grid': 'Cuadrícula',
  'dots': 'Puntos',
  'cornell': 'Cornell',
  'checklist': 'Lista de tareas',
  'weekly': 'Agenda semanal',
  'music': 'Pentagrama',
};

const kPaperColors = {
  'white': 0xFFFFFFFF,
  'cream': 0xFFFFF8E8,
  'gray': 0xFFF1F2F4,
  'dark': 0xFF2A2B2F,
};

const kPaperColorNames = {
  'white': 'Blanco',
  'cream': 'Crema',
  'gray': 'Gris',
  'dark': 'Oscuro',
};

void _label(Canvas canvas, String text, Offset at, Color color, double size, {FontWeight weight = FontWeight.w600}) {
  final pb = ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: size, fontWeight: weight))
    ..pushStyle(ui.TextStyle(color: color, fontSize: size, fontWeight: weight))
    ..addText(text);
  final para = pb.build()..layout(const ui.ParagraphConstraints(width: 600));
  canvas.drawParagraph(para, at);
}

/// Dibuja el papel: color, plantilla y (si hay) la imagen de fondo de un PDF importado.
void paintPaper(Canvas canvas, String template, {String paperColor = 'white', ui.Image? background}) {
  const page = Rect.fromLTWH(0, 0, kPageW, kPageH);
  final dark = paperColor == 'dark';
  canvas.drawRect(page.shift(const Offset(0, 4)), Paint()..color = const Color(0x1F000000));
  canvas.drawRect(page, Paint()..color = Color(kPaperColors[paperColor] ?? 0xFFFFFFFF));
  if (background != null) {
    final iw = background.width.toDouble(), ih = background.height.toDouble();
    final s = math.min(kPageW / iw, kPageH / ih);
    final dst = Rect.fromCenter(center: page.center, width: iw * s, height: ih * s);
    canvas.drawImageRect(background, Rect.fromLTWH(0, 0, iw, ih), dst, Paint()..filterQuality = FilterQuality.medium);
  }
  final line = Paint()
    ..color = dark ? const Color(0x33FFFFFF) : const Color(0xFFB9D0E8)
    ..strokeWidth = 1.2;
  final soft = Paint()
    ..color = dark ? const Color(0x26FFFFFF) : const Color(0xFFDADDE2)
    ..strokeWidth = 1;
  final strong = Paint()
    ..color = dark ? const Color(0x55FFFFFF) : const Color(0xFF9AA3AE)
    ..strokeWidth = 1.6;
  final margin = Paint()
    ..color = const Color(0x66E57373)
    ..strokeWidth = 1.5;
  final labelColor = dark ? const Color(0x99FFFFFF) : const Color(0xFF8A929C);
  const gap = 40.0;

  switch (template) {
    case 'lined':
      for (var y = 120.0; y < kPageH - 40; y += gap) {
        canvas.drawLine(Offset(0, y), Offset(kPageW, y), line);
      }
      canvas.drawLine(const Offset(110, 0), const Offset(110, kPageH), margin);
      break;
    case 'narrow':
      for (var y = 100.0; y < kPageH - 30; y += 30) {
        canvas.drawLine(Offset(0, y), Offset(kPageW, y), line);
      }
      canvas.drawLine(const Offset(90, 0), const Offset(90, kPageH), margin);
      break;
    case 'grid':
      for (var y = gap; y < kPageH; y += gap) {
        canvas.drawLine(Offset(0, y), Offset(kPageW, y), soft);
      }
      for (var x = gap; x < kPageW; x += gap) {
        canvas.drawLine(Offset(x, 0), Offset(x, kPageH), soft);
      }
      break;
    case 'dots':
      final dot = Paint()..color = dark ? const Color(0x44FFFFFF) : const Color(0xFFBBBBBB);
      for (var y = gap; y < kPageH; y += gap) {
        for (var x = gap; x < kPageW; x += gap) {
          canvas.drawCircle(Offset(x, y), 1.8, dot);
        }
      }
      break;
    case 'cornell':
      const top = 150.0, cue = 290.0, bottom = kPageH - 270;
      canvas.drawLine(const Offset(0, top), const Offset(kPageW, top), strong);
      canvas.drawLine(const Offset(cue, top), const Offset(cue, bottom), strong);
      canvas.drawLine(const Offset(0, bottom), const Offset(kPageW, bottom), strong);
      for (var y = top + gap; y < bottom - 4; y += gap) {
        canvas.drawLine(Offset(cue, y), Offset(kPageW, y), line);
      }
      _label(canvas, 'TEMA', const Offset(40, 40), labelColor, 18);
      _label(canvas, 'IDEAS CLAVE', const Offset(40, top + 16), labelColor, 16);
      _label(canvas, 'NOTAS', Offset(cue + 30, top + 16), labelColor, 16);
      _label(canvas, 'RESUMEN', const Offset(40, bottom + 20), labelColor, 16);
      break;
    case 'checklist':
      final box = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = dark ? const Color(0x66FFFFFF) : const Color(0xFFA7B0BB);
      _label(canvas, 'TAREAS', const Offset(60, 50), labelColor, 22);
      for (var y = 150.0; y < kPageH - 60; y += 60) {
        canvas.drawLine(Offset(60, y), Offset(kPageW - 60, y), line);
        canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromLTWH(64, y - 40, 26, 26), const Radius.circular(5)), box);
      }
      break;
    case 'weekly':
      const days = ['LUNES', 'MARTES', 'MIÉRCOLES', 'JUEVES', 'VIERNES', 'SÁBADO', 'DOMINGO', 'NOTAS'];
      _label(canvas, 'SEMANA', const Offset(50, 40), labelColor, 24, weight: FontWeight.w700);
      const top = 110.0, left = 40.0;
      const cw = (kPageW - 2 * left) / 2, ch = (kPageH - top - 40) / 4;
      for (var i = 0; i < 8; i++) {
        final r = Rect.fromLTWH(left + (i % 2) * cw, top + (i ~/ 2) * ch, cw, ch);
        canvas.drawRRect(
            RRect.fromRectAndRadius(r.deflate(8), const Radius.circular(12)),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.6
              ..color = strong.color);
        _label(canvas, days[i], r.topLeft + const Offset(26, 22), labelColor, 15);
        for (var y = r.top + 80; y < r.bottom - 20; y += 38) {
          canvas.drawLine(Offset(r.left + 26, y), Offset(r.right - 26, y), soft);
        }
      }
      break;
    case 'music':
      for (var y = 140.0; y < kPageH - 120; y += 120) {
        for (var k = 0; k < 5; k++) {
          canvas.drawLine(Offset(60, y + k * 14), Offset(kPageW - 60, y + k * 14), strong);
        }
      }
      break;
  }
}
