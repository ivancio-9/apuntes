import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app_scope.dart';
import '../data/store.dart';
import '../ink/ink.dart';
import 'notebook_canvas.dart';

const kEmojiStickers = [
  '⭐', '❤️', '✅', '❗', '❓', '💡', '📌', '📚', '✏️', '📅', '🔥', '🎉', //
  '😊', '👍', '☀️', '🌙', '🌸', '🍀', '🎵', '☕', '⚠️', '➡️', '✔️', '✖️', //
  '🏆', '🎯', '📝', '📎', '🔔', '💬', '🌈', '🍎', '🐱', '🌻', '✨', '💪',
];

Map<String, dynamic> _emojiData(String e) => {
      'type': 'text',
      'x': 0.0,
      'y': 0.0,
      'w': 140.0,
      'text': e,
      'size': 96.0,
      'color': 0xFF000000,
      'font': 'Roboto',
      't': 0,
    };

/// Guarda elementos seleccionados como pegatina reutilizable.
Future<void> saveSticker(BuildContext context, AppScope app, Map<String, dynamic> sticker) async {
  final name = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Guardar como pegatina'),
      content: TextField(
        controller: name,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Nombre (opcional)'),
        onSubmitted: (_) => Navigator.pop(c, true),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Guardar')),
      ],
    ),
  );
  if (ok != true) return;
  final t = nowMs();
  await app.store.put(Rec(
    id: newId(),
    kind: 'sticker',
    parent: '',
    data: {...sticker, 'name': name.text.trim(), 'created': t},
    updatedAt: t,
  ));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Guardada en «Mis pegatinas».')));
  }
}

/// Panel de pegatinas: emojis y pegatinas propias.
Future<void> showStickerPanel(BuildContext context, AppScope app, GlobalKey<NotebookCanvasState> canvas) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => SizedBox(
      height: MediaQuery.of(c).size.height * 0.55,
      child: _StickerPanel(app: app, canvas: canvas),
    ),
  );
}

class _StickerPanel extends StatefulWidget {
  final AppScope app;
  final GlobalKey<NotebookCanvasState> canvas;
  const _StickerPanel({required this.app, required this.canvas});

  @override
  State<_StickerPanel> createState() => _StickerPanelState();
}

class _StickerPanelState extends State<_StickerPanel> {
  int tab = 0;

  void _insert(List<Map<String, dynamic>> items, double w, double h) {
    Navigator.pop(context);
    widget.canvas.currentState?.insertElements(items, w, h);
  }

  Future<void> _fromImage() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 800, maxHeight: 800);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final img = (await codec.getNextFrame()).image;
    final blob = newId();
    await widget.app.store.putBlob(blob, bytes);
    final s = 300 / math.max(img.width, img.height);
    final w = img.width * s, h = img.height * s;
    final t = nowMs();
    await widget.app.store.put(Rec(
      id: newId(),
      kind: 'sticker',
      parent: '',
      data: {
        'items': [
          {'type': 'image', 'blob': blob, 'x': 0.0, 'y': 0.0, 'w': w, 'h': h, 't': 0},
        ],
        'w': w,
        'h': h,
        'name': '',
        'created': t,
      },
      updatedAt: t,
    ));
    if (mounted) setState(() => tab = 1);
  }

  @override
  Widget build(BuildContext context) {
    final mine = widget.app.store.stickers();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          const Text('Pegatinas', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const Spacer(),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('Emojis')),
              ButtonSegment(value: 1, label: Text('Mis pegatinas')),
            ],
            selected: {tab},
            onSelectionChanged: (s) => setState(() => tab = s.first),
          ),
        ]),
      ),
      const SizedBox(height: 10),
      Expanded(
        child: tab == 0
            ? GridView.extent(
                maxCrossAxisExtent: 72,
                padding: const EdgeInsets.all(16),
                children: [
                  for (final e in kEmojiStickers)
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _insert([_emojiData(e)], 140, 125),
                      child: Center(child: Text(e, style: const TextStyle(fontSize: 38))),
                    ),
                ],
              )
            : Column(children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(children: [
                    const Expanded(
                      child: Text(
                        'Para crear una: rodea algo con el lazo y pulsa «Pegatina», o añade una imagen.',
                        style: TextStyle(fontSize: 12.5, color: Colors.black54),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _fromImage,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      label: const Text('Desde imagen'),
                    ),
                  ]),
                ),
                Expanded(
                  child: mine.isEmpty
                      ? const Center(child: Text('Aún no tienes pegatinas propias.'))
                      : GridView.extent(
                          maxCrossAxisExtent: 130,
                          padding: const EdgeInsets.all(16),
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          children: [
                            for (final st in mine)
                              _StickerTile(
                                app: widget.app,
                                sticker: st,
                                onTap: () {
                                  final items = [
                                    for (final i in (st.data['items'] as List? ?? const []))
                                      Map<String, dynamic>.from(i as Map),
                                  ];
                                  _insert(items, ((st.data['w'] ?? 100) as num).toDouble(),
                                      ((st.data['h'] ?? 100) as num).toDouble());
                                },
                                onDelete: () async {
                                  await widget.app.store.remove(st);
                                  if (mounted) setState(() {});
                                },
                              ),
                          ],
                        ),
                ),
              ]),
      ),
    ]);
  }
}

class _StickerTile extends StatefulWidget {
  final AppScope app;
  final Rec sticker;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _StickerTile({required this.app, required this.sticker, required this.onTap, required this.onDelete});

  @override
  State<_StickerTile> createState() => _StickerTileState();
}

class _StickerTileState extends State<_StickerTile> {
  final Map<String, ui.Image> _images = {};
  late final List<Item> _items;

  @override
  void initState() {
    super.initState();
    final list = widget.sticker.data['items'] as List? ?? const [];
    _items = [];
    for (final d in list) {
      final it = Item.fromRec(Rec(id: newId(), kind: 'el', parent: '', data: Map<String, dynamic>.from(d as Map), updatedAt: 0));
      if (it != null) _items.add(it);
    }
    _loadImages();
  }

  Future<void> _loadImages() async {
    for (final it in _items.whereType<ImageItem>()) {
      var b = await widget.app.store.getBlob(it.blob);
      b ??= await widget.app.sync.fetchBlob(it.blob);
      if (b == null) continue;
      try {
        final codec = await ui.instantiateImageCodec(b);
        _images[it.blob] = (await codec.getNextFrame()).image;
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final w = ((widget.sticker.data['w'] ?? 100) as num).toDouble();
    final h = ((widget.sticker.data['h'] ?? 100) as num).toDouble();
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: widget.onTap,
      onLongPress: () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('¿Eliminar esta pegatina?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Eliminar')),
            ],
          ),
        );
        if (ok == true) widget.onDelete();
      },
      child: Container(
        decoration: BoxDecoration(color: const Color(0xFFF4F5F7), borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.all(8),
        child: CustomPaint(painter: _StickerPainter(_items, _images, w, h)),
      ),
    );
  }
}

class _StickerPainter extends CustomPainter {
  final List<Item> items;
  final Map<String, ui.Image> images;
  final double w, h;
  _StickerPainter(this.items, this.images, this.w, this.h);

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width / math.max(w, 1), size.height / math.max(h, 1));
    canvas.translate((size.width - w * s) / 2, (size.height - h * s) / 2);
    canvas.scale(s);
    paintPageItems(canvas, items, images);
    for (final t in items.whereType<TextItem>()) {
      final d = t.rec.data;
      final tp = TextPainter(
        text: TextSpan(text: (d['text'] ?? '') as String, style: textStyleFor(d, 1)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: ((d['w'] ?? 500) as num).toDouble());
      tp.paint(canvas, Offset((d['x'] as num).toDouble(), (d['y'] as num).toDouble()));
    }
  }

  @override
  bool shouldRepaint(_StickerPainter old) => true;
}
