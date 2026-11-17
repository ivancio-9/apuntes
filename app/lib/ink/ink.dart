import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui';

import '../data/store.dart';

/// Tamaño de una página en unidades internas (proporción A4).
const double kPageW = 1000;
const double kPageH = 1414;

enum Tool { select, pen, highlighter, eraser, shape, text }

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
  late final Path path = buildStrokePath(pts, width, pressure: tool == kToolPen);

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
// Papel

void paintPaper(Canvas canvas, String paper) {
  const page = Rect.fromLTWH(0, 0, kPageW, kPageH);
  canvas.drawRect(page.shift(const Offset(0, 6)), Paint()..color = const Color(0x22000000));
  canvas.drawRect(page, Paint()..color = const Color(0xFFFFFFFF));
  const gap = 40.0;
  final line = Paint()
    ..color = const Color(0xFFB3CDE8)
    ..strokeWidth = 1.2;
  final grid = Paint()
    ..color = const Color(0xFFDDDDDD)
    ..strokeWidth = 1;
  switch (paper) {
    case 'lined':
      for (var y = 120.0; y < kPageH - 40; y += gap) {
        canvas.drawLine(Offset(0, y), Offset(kPageW, y), line);
      }
      canvas.drawLine(const Offset(110, 0), const Offset(110, kPageH),
          Paint()..color = const Color(0x66E57373)..strokeWidth = 1.5);
      break;
    case 'grid':
      for (var y = gap; y < kPageH; y += gap) {
        canvas.drawLine(Offset(0, y), Offset(kPageW, y), grid);
      }
      for (var x = gap; x < kPageW; x += gap) {
        canvas.drawLine(Offset(x, 0), Offset(x, kPageH), grid);
      }
      break;
    case 'dots':
      final dot = Paint()..color = const Color(0xFFBBBBBB);
      for (var y = gap; y < kPageH; y += gap) {
        for (var x = gap; x < kPageW; x += gap) {
          canvas.drawCircle(Offset(x, y), 1.8, dot);
        }
      }
      break;
  }
}
