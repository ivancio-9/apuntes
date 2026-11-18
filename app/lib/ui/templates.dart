import 'package:flutter/material.dart';

import '../ink/ink.dart';

/// Vista previa pequeña de una plantilla de papel.
class TemplatePreview extends StatelessWidget {
  final String template;
  final String paperColor;
  final bool selected;
  const TemplatePreview({super.key, required this.template, this.paperColor = 'white', this.selected = false});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: kPageW / kPageH,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: selected ? const Color(0xFF2F6FED) : Colors.black12, width: selected ? 3 : 1),
          boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 2))],
        ),
        clipBehavior: Clip.antiAlias,
        child: CustomPaint(painter: _TemplatePainter(template, paperColor)),
      ),
    );
  }
}

class _TemplatePainter extends CustomPainter {
  final String template;
  final String paperColor;
  _TemplatePainter(this.template, this.paperColor);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / kPageW);
    paintPaper(canvas, template, paperColor: paperColor);
  }

  @override
  bool shouldRepaint(_TemplatePainter old) => old.template != template || old.paperColor != paperColor;
}

/// Cuadrícula para elegir plantilla. Devuelve la elegida o null.
Future<String?> pickTemplate(BuildContext context, {String? current, String paperColor = 'white', String title = 'Elige una plantilla'}) {
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 520,
        child: GridView.count(
          shrinkWrap: true,
          crossAxisCount: 3,
          mainAxisSpacing: 14,
          crossAxisSpacing: 14,
          childAspectRatio: 0.62,
          children: [
            for (final e in kTemplates.entries)
              InkWell(
                onTap: () => Navigator.pop(c, e.key),
                child: Column(children: [
                  Expanded(child: TemplatePreview(template: e.key, paperColor: paperColor, selected: e.key == current)),
                  const SizedBox(height: 6),
                  Text(e.value, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                ]),
              ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar'))],
    ),
  );
}
