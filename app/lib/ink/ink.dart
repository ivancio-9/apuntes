import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// Tamaño de una página en unidades internas (proporción A4).
const double kPageW = 1000;
const double kPageH = 1414;

enum Tool { pen, highlighter, eraser, text, hand }

const int kToolPen = 0;
const int kToolHighlighter = 1;

/// Trazo ya decodificado, con su contorno precalculado.
class Stroke {
  final String id;
  final int tool;
  final Color color;
  final double width;
  final Float32List pts; // x, y, presión (0..1), repetido
  late final Rect bounds = _bounds();
  late final Path path = buildStrokePath(pts, width, pressure: tool == kToolPen);

  Stroke(this.id, this.tool, this.color, this.width, this.pts);

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

  static Stroke fromData(String id, Map<String, dynamic> d) {
    final bytes = Uint8List.fromList(base64Decode(d['pts'] as String));
    return Stroke(
      id,
      (d['tool'] as num?)?.toInt() ?? kToolPen,
      Color((d['color'] as num).toInt()),
      (d['w'] as num).toDouble(),
      Float32List.view(bytes.buffer, 0, bytes.lengthInBytes ~/ 4),
    );
  }

  static Map<String, dynamic> toData(int tool, Color color, double width, Float32List pts, int t) => {
        'type': 'stroke',
        'tool': tool,
        'color': color.toARGB32(),
        'w': width,
        'pts': base64Encode(pts.buffer.asUint8List(pts.offsetInBytes, pts.lengthInBytes)),
        't': t,
      };

  /// ¿Toca el borrador (círculo en [p] de radio [r]) este trazo?
  bool hit(Offset p, double r) {
    if (!bounds.inflate(r).contains(p)) return false;
    final rr = r + width / 2;
    final rr2 = rr * rr;
    final n = length;
    if (n == 1) return (Offset(pts[0], pts[1]) - p).distanceSquared <= rr2;
    for (var i = 0; i < n - 1; i++) {
      final a = Offset(pts[i * 3], pts[i * 3 + 1]);
      final b = Offset(pts[i * 3 + 3], pts[i * 3 + 4]);
      if (_distSqToSegment(p, a, b) <= rr2) return true;
    }
    return false;
  }
}

double _distSqToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len2 = ab.distanceSquared;
  if (len2 == 0) return (p - a).distanceSquared;
  var t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len2;
  t = t.clamp(0.0, 1.0);
  final proj = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
  return (p - proj).distanceSquared;
}

double _radius(double width, double p, bool pressure) =>
    pressure ? width / 2 * (0.35 + 1.15 * p) : width / 2;

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

/// Construye el contorno relleno de un trazo con grosor variable según la presión.
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
  if (s.tool == kToolPen && s.length > 1) {
    // Extremos redondeados (se dibujan aparte para que nunca dejen huecos).
    final p = s.pts;
    final n = s.length;
    canvas.drawCircle(Offset(p[0], p[1]), _radius(s.width, p[2], true), paint);
    canvas.drawCircle(Offset(p[(n - 1) * 3], p[(n - 1) * 3 + 1]), _radius(s.width, p[(n - 1) * 3 + 2], true), paint);
  }
}

/// Dibuja el fondo de la página (blanco, rayado, cuadrícula o puntos).
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
