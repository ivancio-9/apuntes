import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../app_scope.dart';
import '../data/store.dart';
import '../ink/ink.dart';
import 'blob_image.dart';
import 'color_picker.dart';
import 'editor_state.dart';
import 'templates.dart';

const kCoverColors = [
  0xFF3F51B5, 0xFF1E88E5, 0xFF00897B, 0xFF43A047, 0xFFFDD835, 0xFFFB8C00, //
  0xFFE53935, 0xFFD81B60, 0xFF8E24AA, 0xFF6D4C41, 0xFF546E7A, 0xFF212121, //
  0xFFF8BBD0, 0xFFB3E5FC, 0xFFC8E6C9, 0xFFFFF9C4, 0xFFD1C4E9, 0xFFFFE0B2,
];

const kCoverStyles = {
  'solid': 'Liso',
  'gradient': 'Degradado',
  'stripes': 'Rayas',
  'dots': 'Lunares',
  'grid': 'Cuadros',
  'waves': 'Ondas',
  'diagonal': 'Diagonal',
  'leather': 'Piel',
};

TextStyle coverFont(String? font, TextStyle base) {
  try {
    return GoogleFonts.getFont(font ?? 'Roboto', textStyle: base);
  } catch (_) {
    return base;
  }
}

class _CoverPatternPainter extends CustomPainter {
  final String style;
  final Color color;
  _CoverPatternPainter(this.style, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final hsl = HSLColor.fromColor(color);
    final lighter = hsl.withLightness((hsl.lightness + 0.18).clamp(0.0, 1.0)).toColor();
    final darker = hsl.withLightness((hsl.lightness - 0.15).clamp(0.0, 1.0)).toColor();
    final over = Paint()..color = Colors.white.withValues(alpha: 0.22);
    final s = size.width / 150;
    switch (style) {
      case 'gradient':
        canvas.drawRect(
            rect, Paint()..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [lighter, darker]).createShader(rect));
        break;
      case 'stripes':
        for (var x = 0.0; x < size.width; x += 22 * s) {
          canvas.drawRect(Rect.fromLTWH(x, 0, 10 * s, size.height), over);
        }
        break;
      case 'dots':
        for (var y = 10 * s; y < size.height; y += 20 * s) {
          for (var x = ((y / (20 * s)).round().isOdd ? 20 * s : 10 * s); x < size.width; x += 20 * s) {
            canvas.drawCircle(Offset(x, y), 3.2 * s, over);
          }
        }
        break;
      case 'grid':
        final p = Paint()
          ..color = Colors.white.withValues(alpha: 0.25)
          ..strokeWidth = 1.2 * s;
        for (var x = 0.0; x < size.width; x += 16 * s) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
        }
        for (var y = 0.0; y < size.height; y += 16 * s) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
        }
        break;
      case 'waves':
        final p = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 * s
          ..color = Colors.white.withValues(alpha: 0.28);
        for (var y = 14 * s; y < size.height + 20; y += 22 * s) {
          final path = Path()..moveTo(0, y);
          for (var x = 0.0; x <= size.width; x += 4) {
            path.lineTo(x, y + math.sin(x / (14 * s)) * 5 * s);
          }
          canvas.drawPath(path, p);
        }
        break;
      case 'diagonal':
        final path = Path()
          ..moveTo(0, size.height * 0.62)
          ..lineTo(size.width, size.height * 0.38)
          ..lineTo(size.width, size.height)
          ..lineTo(0, size.height)
          ..close();
        canvas.drawPath(path, Paint()..color = darker);
        break;
      case 'leather':
        final rnd = math.Random(7);
        final p = Paint()..color = Colors.black.withValues(alpha: 0.06);
        for (var i = 0; i < 700; i++) {
          canvas.drawCircle(Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height), rnd.nextDouble() * 1.6 * s, p);
        }
        final stitch = Paint()
          ..color = Colors.white.withValues(alpha: 0.45)
          ..strokeWidth = 1.4 * s;
        final r = rect.deflate(9 * s);
        for (var x = r.left + 8 * s; x < r.right; x += 9 * s) {
          canvas.drawLine(Offset(x, r.top), Offset(x + 4 * s, r.top), stitch);
          canvas.drawLine(Offset(x, r.bottom), Offset(x + 4 * s, r.bottom), stitch);
        }
        for (var y = r.top + 8 * s; y < r.bottom; y += 9 * s) {
          canvas.drawLine(Offset(r.right, y), Offset(r.right, y + 4 * s), stitch);
        }
        break;
    }
  }

  @override
  bool shouldRepaint(_CoverPatternPainter old) => old.style != style || old.color != color;
}

/// Tapa de un cuaderno.
class NotebookCover extends StatelessWidget {
  final AppScope app;
  final Map<String, dynamic> data;
  const NotebookCover({super.key, required this.app, required this.data});

  @override
  Widget build(BuildContext context) {
    final color = Color(((data['color'] ?? kCoverColors[0]) as num).toInt());
    final image = data['coverImage'] as String?;
    final style = (data['coverStyle'] ?? 'solid') as String;
    final title = (data['title'] ?? '') as String;
    final subtitle = (data['subtitle'] ?? '') as String;
    final font = data['titleFont'] as String?;

    return Material(
      color: color,
      elevation: 4,
      shadowColor: Colors.black38,
      borderRadius: const BorderRadius.only(
        topRight: Radius.circular(10),
        bottomRight: Radius.circular(10),
        topLeft: Radius.circular(3),
        bottomLeft: Radius.circular(3),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(fit: StackFit.expand, children: [
        if (image == null) CustomPaint(painter: _CoverPatternPainter(style, color)),
        if (image != null) BlobImage(app: app, blobId: image),
        if (image != null)
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0xAA000000)],
                stops: [0.45, 1],
              ),
            ),
          ),
        // Lomo
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 12,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                Colors.black.withValues(alpha: 0.22),
                Colors.black.withValues(alpha: 0.05),
              ]),
            ),
          ),
        ),
        if (image != null)
          Positioned(
            left: 18,
            right: 10,
            bottom: 12,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: coverFont(
                      font,
                      const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          shadows: [Shadow(blurRadius: 4, color: Colors.black54)]))),
              if (subtitle.isNotEmpty)
                Text(subtitle,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 11.5)),
            ]),
          )
        else
          Align(
            alignment: const Alignment(0, -0.35),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 12, 12, 12),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.94),
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 3, offset: Offset(0, 1))],
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(title,
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: coverFont(font, const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, color: Colors.black87))),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(subtitle,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: Colors.black54)),
                  ],
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Editor de portada: nombre, subtítulo, letra, diseño, color, foto, papel y color del papel.
class CoverEditor extends StatefulWidget {
  final AppScope app;
  final Map<String, dynamic>? initial;
  final bool isNew;
  const CoverEditor({super.key, required this.app, required this.initial, required this.isNew});

  @override
  State<CoverEditor> createState() => _CoverEditorState();
}

class _CoverEditorState extends State<CoverEditor> {
  late final TextEditingController title = TextEditingController(text: (widget.initial?['title'] ?? '') as String);
  late final TextEditingController subtitle = TextEditingController(text: (widget.initial?['subtitle'] ?? '') as String);
  late String paper = (widget.initial?['paper'] ?? 'lined') as String;
  late String paperColor = (widget.initial?['paperColor'] ?? 'white') as String;
  late int color = ((widget.initial?['color'] ?? kCoverColors[0]) as num).toInt();
  late String coverStyle = (widget.initial?['coverStyle'] ?? 'solid') as String;
  late String? image = widget.initial?['coverImage'] as String?;
  late String font = (widget.initial?['titleFont'] ?? 'Roboto') as String;
  bool _loadingImage = false;

  Map<String, dynamic> get _data => {
        'title': title.text.trim().isEmpty ? 'Sin título' : title.text.trim(),
        'subtitle': subtitle.text.trim(),
        'paper': paper,
        'paperColor': paperColor,
        'color': color,
        'coverStyle': coverStyle,
        'coverImage': image,
        'titleFont': font,
      };

  Future<void> _pickImage() async {
    setState(() => _loadingImage = true);
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 900, maxHeight: 1400, imageQuality: 85);
      if (x != null) {
        final bytes = await x.readAsBytes();
        final id = newId();
        await widget.app.store.putBlob(id, bytes);
        image = id;
      }
    } catch (_) {}
    if (mounted) setState(() => _loadingImage = false);
  }

  Widget _section(String label) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF555B66))),
      );

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width > 700;
    final preview = SizedBox(width: 160, height: 240, child: NotebookCover(app: widget.app, data: _data));
    final form = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: title,
        autofocus: widget.isNew,
        decoration: const InputDecoration(labelText: 'Nombre'),
        onChanged: (_) => setState(() {}),
      ),
      TextField(
        controller: subtitle,
        decoration: const InputDecoration(labelText: 'Subtítulo o descripción (opcional)'),
        onChanged: (_) => setState(() {}),
      ),
      _section('LETRA DEL TÍTULO'),
      DropdownButton<String>(
        value: kFonts.contains(font) ? font : 'Roboto',
        isExpanded: true,
        items: [
          for (final f in kFonts) DropdownMenuItem(value: f, child: Text(f, style: coverFont(f, const TextStyle(fontSize: 16)))),
        ],
        onChanged: (v) => setState(() => font = v ?? font),
      ),
      _section('DISEÑO DE LA PORTADA'),
      Wrap(spacing: 10, runSpacing: 10, children: [
        for (final e in kCoverStyles.entries)
          GestureDetector(
            onTap: () => setState(() {
              coverStyle = e.key;
              image = null;
            }),
            child: Column(children: [
              Container(
                width: 46,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                      color: coverStyle == e.key && image == null ? const Color(0xFF2F6FED) : Colors.black12,
                      width: coverStyle == e.key && image == null ? 3 : 1),
                ),
                clipBehavior: Clip.antiAlias,
                child: ColoredBox(
                  color: Color(color),
                  child: CustomPaint(painter: _CoverPatternPainter(e.key, Color(color))),
                ),
              ),
              const SizedBox(height: 3),
              Text(e.value, style: const TextStyle(fontSize: 10.5)),
            ]),
          ),
      ]),
      _section('COLOR'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final cc in [...kCoverColors, if (!kCoverColors.contains(color)) color])
          GestureDetector(
            onTap: () => setState(() => color = cc),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: Color(cc),
                shape: BoxShape.circle,
                border: Border.all(color: cc == color ? Colors.black87 : Colors.black12, width: cc == color ? 3 : 1),
              ),
            ),
          ),
        Tooltip(
          message: 'Otro color',
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () async {
              final c = await showColorPicker(context, Color(color), title: 'Color de la portada');
              if (c != null) setState(() => color = c.toARGB32());
            },
            child: Container(
              width: 30,
              height: 30,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(colors: [
                  Color(0xFFFF0000),
                  Color(0xFFFFFF00),
                  Color(0xFF00FF00),
                  Color(0xFF00FFFF),
                  Color(0xFF0000FF),
                  Color(0xFFFF00FF),
                  Color(0xFFFF0000),
                ]),
              ),
              child: const Icon(Icons.add, size: 18, color: Colors.white),
            ),
          ),
        ),
      ]),
      _section('FOTO DE PORTADA'),
      Wrap(spacing: 8, children: [
        OutlinedButton.icon(
          onPressed: _loadingImage ? null : _pickImage,
          icon: _loadingImage
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.photo_outlined),
          label: Text(image == null ? 'Elegir foto' : 'Cambiar foto'),
        ),
        if (image != null)
          TextButton.icon(
            onPressed: () => setState(() => image = null),
            icon: const Icon(Icons.close),
            label: const Text('Quitar foto'),
          ),
      ]),
      _section('PAPEL'),
      SizedBox(
        height: 150,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final e in kTemplates.entries)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: InkWell(
                onTap: () => setState(() => paper = e.key),
                child: SizedBox(
                  width: 82,
                  child: Column(children: [
                    Expanded(child: TemplatePreview(template: e.key, paperColor: paperColor, selected: paper == e.key)),
                    const SizedBox(height: 4),
                    Text(e.value, style: const TextStyle(fontSize: 10.5), textAlign: TextAlign.center, maxLines: 1),
                  ]),
                ),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 10),
      Wrap(spacing: 8, children: [
        for (final e in kPaperColors.entries)
          ChoiceChip(
            avatar: CircleAvatar(backgroundColor: Color(e.value), radius: 9),
            label: Text(kPaperColorNames[e.key] ?? e.key),
            selected: paperColor == e.key,
            onSelected: (_) => setState(() => paperColor = e.key),
          ),
      ]),
    ]);

    return AlertDialog(
      title: Text(widget.isNew ? 'Nuevo cuaderno' : 'Personalizar cuaderno'),
      content: SizedBox(
        width: wide ? 640 : 360,
        child: SingleChildScrollView(
          child: wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  preview,
                  const SizedBox(width: 28),
                  Expanded(child: form),
                ])
              : Column(children: [Center(child: preview), const SizedBox(height: 12), form]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(context, _data), child: Text(widget.isNew ? 'Crear' : 'Guardar')),
      ],
    );
  }
}
