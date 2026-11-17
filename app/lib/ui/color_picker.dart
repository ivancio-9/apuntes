import 'package:flutter/material.dart';

const _presets = [
  0xFF000000, 0xFF424242, 0xFF9E9E9E, 0xFFFFFFFF, 0xFF795548, 0xFF3E2723,
  0xFFD32F2F, 0xFFE91E63, 0xFFFF5722, 0xFFFF9800, 0xFFFFC107, 0xFFFFEB3B,
  0xFF8BC34A, 0xFF4CAF50, 0xFF009688, 0xFF00BCD4, 0xFF03A9F4, 0xFF2196F3,
  0xFF3F51B5, 0xFF1A237E, 0xFF673AB7, 0xFF9C27B0, 0xFFF48FB1, 0xFFB39DDB,
];

/// Muestra un selector de color libre. Devuelve el color elegido o null.
Future<Color?> showColorPicker(BuildContext context, Color initial, {String title = 'Elige un color'}) {
  return showDialog<Color>(
    context: context,
    builder: (c) => _ColorPickerDialog(initial: initial, title: title),
  );
}

class _ColorPickerDialog extends StatefulWidget {
  final Color initial;
  final String title;
  const _ColorPickerDialog({required this.initial, required this.title});

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late HSVColor hsv = HSVColor.fromColor(widget.initial.withValues(alpha: 1));
  late final TextEditingController hex = TextEditingController(text: _hex(widget.initial));

  static String _hex(Color c) => (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

  void _setHsv(HSVColor v) {
    setState(() {
      hsv = v;
      hex.text = _hex(v.toColor());
    });
  }

  void _setColor(Color c) => _setHsv(HSVColor.fromColor(c));

  @override
  Widget build(BuildContext context) {
    final color = hsv.toColor();
    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // Saturación / brillo
            LayoutBuilder(builder: (context, c) {
              final w = c.maxWidth;
              const h = 170.0;
              void pick(Offset p) => _setHsv(hsv
                  .withSaturation((p.dx / w).clamp(0.0, 1.0))
                  .withValue(1 - (p.dy / h).clamp(0.0, 1.0)));
              return GestureDetector(
                onPanDown: (d) => pick(d.localPosition),
                onPanUpdate: (d) => pick(d.localPosition),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: w,
                    height: h,
                    child: Stack(children: [
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Colors.white, HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor()],
                            ),
                          ),
                        ),
                      ),
                      const Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Colors.black],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: hsv.saturation * w - 10,
                        top: (1 - hsv.value) * h - 10,
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: color,
                            border: Border.all(color: Colors.white, width: 3),
                            boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4)],
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              );
            }),
            const SizedBox(height: 14),
            // Tono
            LayoutBuilder(builder: (context, c) {
              final w = c.maxWidth;
              void pick(Offset p) => _setHsv(hsv.withHue((p.dx / w).clamp(0.0, 1.0) * 359.9));
              return GestureDetector(
                onPanDown: (d) => pick(d.localPosition),
                onPanUpdate: (d) => pick(d.localPosition),
                child: SizedBox(
                  height: 28,
                  width: w,
                  child: Stack(clipBehavior: Clip.none, children: [
                    Positioned.fill(
                      top: 6,
                      bottom: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          gradient: LinearGradient(colors: [
                            for (var i = 0; i <= 6; i++) HSVColor.fromAHSV(1, i * 60.0 % 360, 1, 1).toColor(),
                          ]),
                        ),
                      ),
                    ),
                    Positioned(
                      left: hsv.hue / 360 * w - 12,
                      top: 2,
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor(),
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4)],
                        ),
                      ),
                    ),
                  ]),
                ),
              );
            }),
            const SizedBox(height: 14),
            Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.black12),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: hex,
                  decoration: const InputDecoration(prefixText: '#  ', isDense: true, border: OutlineInputBorder()),
                  onSubmitted: (v) {
                    final n = int.tryParse(v.replaceAll('#', '').trim(), radix: 16);
                    if (n != null && v.replaceAll('#', '').trim().length == 6) _setColor(Color(0xFF000000 | n));
                  },
                ),
              ),
            ]),
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final p in _presets)
                GestureDetector(
                  onTap: () => _setColor(Color(p)),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: Color(p),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.black12),
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: 8),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(context, hsv.toColor()), child: const Text('Aceptar')),
      ],
    );
  }
}
