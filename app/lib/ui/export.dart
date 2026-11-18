import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../app_scope.dart';
import '../data/store.dart';
import '../ink/ink.dart';
import '../platform/files_stub.dart' if (dart.library.js_interop) '../platform/files_web.dart';
import 'notebook_canvas.dart';

/// Dibuja una página completa (papel, imágenes, tinta, figuras y textos).
Future<ui.Image> renderPageImage(AppScope app, Rec notebook, Rec page, {double scale = 2}) async {
  final items = <Item>[];
  for (final r in app.store.elements(page.id)) {
    final it = Item.fromRec(r);
    if (it != null) items.add(it);
  }

  final images = <String, ui.Image>{};
  Future<void> load(String blob) async {
    if (images.containsKey(blob)) return;
    var bytes = await app.store.getBlob(blob);
    bytes ??= await app.sync.fetchBlob(blob);
    if (bytes == null) return;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      images[blob] = (await codec.getNextFrame()).image;
    } catch (_) {}
  }

  for (final it in items.whereType<ImageItem>()) {
    await load(it.blob);
  }
  final bg = page.data['bg'] as String?;
  if (bg != null) await load(bg);

  final texts = items.whereType<TextItem>().toList();
  if (texts.isNotEmpty) {
    for (final t in texts) {
      textStyleFor(t.rec.data, 1); // pide la fuente
    }
    try {
      await GoogleFonts.pendingFonts();
    } catch (_) {}
  }

  final template = (page.data['template'] ?? notebook.data['paper'] ?? 'lined') as String;
  final paperColor = (notebook.data['paperColor'] ?? 'white') as String;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(scale);
  canvas.drawRect(const Rect.fromLTWH(0, 0, kPageW, kPageH), Paint()..color = const Color(0xFFFFFFFF));
  paintPaper(canvas, template, paperColor: paperColor, background: bg == null ? null : images[bg]);
  paintPageItems(canvas, items, images);
  for (final t in texts) {
    final d = t.rec.data;
    final tp = TextPainter(
      text: TextSpan(text: (d['text'] ?? '') as String, style: textStyleFor(d, 1)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: ((d['w'] ?? 500) as num).toDouble());
    tp.paint(canvas, Offset((d['x'] as num).toDouble(), (d['y'] as num).toDouble()));
  }
  final pic = recorder.endRecording();
  return pic.toImage((kPageW * scale).round(), (kPageH * scale).round());
}

Future<Uint8List> renderPagePng(AppScope app, Rec notebook, Rec page, {double scale = 2}) async {
  final img = await renderPageImage(app, notebook, page, scale: scale);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

String _safeName(String s) {
  final r = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
  return r.isEmpty ? 'apuntes' : r;
}

enum _Scope { page, notebook }

enum _Format { pdf, jpg, png }

/// Diálogo para exportar la página actual o el cuaderno entero.
Future<void> showExportDialog(BuildContext context, AppScope app, Rec notebook, {Rec? currentPage}) async {
  if (!exportSupported) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Por ahora, exportar solo está disponible en la versión web (iPad u ordenador).'),
    ));
    return;
  }
  var scope = currentPage != null ? _Scope.page : _Scope.notebook;
  var format = _Format.pdf;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setD) => AlertDialog(
        title: const Text('Exportar'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('¿Qué quieres exportar?'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            if (currentPage != null)
              ChoiceChip(
                label: const Text('Esta página'),
                selected: scope == _Scope.page,
                onSelected: (_) => setD(() => scope = _Scope.page),
              ),
            ChoiceChip(
              label: const Text('Cuaderno entero'),
              selected: scope == _Scope.notebook,
              onSelected: (_) => setD(() => scope = _Scope.notebook),
            ),
          ]),
          const SizedBox(height: 18),
          const Text('Formato'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (final f in _Format.values)
              ChoiceChip(
                label: Text(f.name.toUpperCase()),
                selected: format == f,
                onSelected: (_) => setD(() => format = f),
              ),
          ]),
          if (format != _Format.pdf && scope == _Scope.notebook) ...[
            const SizedBox(height: 12),
            const Text('Se descargará un archivo ZIP con una imagen por página.',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(c, true),
            icon: const Icon(Icons.download),
            label: const Text('Exportar'),
          ),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;

  final pages = scope == _Scope.page ? [currentPage!] : app.store.pages(notebook.id);
  final allPages = app.store.pages(notebook.id);
  final title = _safeName((notebook.data['title'] ?? 'apuntes') as String);
  final progress = ValueNotifier<String>('Preparando…');

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      content: Row(children: [
        const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
        const SizedBox(width: 20),
        Expanded(child: ValueListenableBuilder<String>(valueListenable: progress, builder: (_, v, __) => Text(v))),
      ]),
    ),
  );

  try {
    final images = <Uint8List>[];
    for (var i = 0; i < pages.length; i++) {
      progress.value = 'Preparando página ${i + 1} de ${pages.length}…';
      final png = await renderPagePng(app, notebook, pages[i]);
      images.add(format == _Format.png ? png : await pngToJpg(png, 0.9));
    }
    progress.value = 'Generando archivo…';

    if (format == _Format.pdf) {
      final doc = pw.Document(title: title);
      for (final bytes in images) {
        doc.addPage(pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.FullPage(ignoreMargins: true, child: pw.Image(pw.MemoryImage(bytes), fit: pw.BoxFit.fill)),
        ));
      }
      final suffix = scope == _Scope.page ? ' - página ${allPages.indexWhere((p) => p.id == pages.first.id) + 1}' : '';
      downloadFile(await doc.save(), '$title$suffix.pdf', 'application/pdf');
    } else {
      final ext = format == _Format.png ? 'png' : 'jpg';
      final mime = format == _Format.png ? 'image/png' : 'image/jpeg';
      if (images.length == 1) {
        final n = allPages.indexWhere((p) => p.id == pages.first.id) + 1;
        downloadFile(images.first, '$title - página $n.$ext', mime);
      } else {
        final archive = Archive();
        for (var i = 0; i < images.length; i++) {
          archive.addFile(ArchiveFile('pagina-${(i + 1).toString().padLeft(2, '0')}.$ext', images[i].length, images[i]));
        }
        final List<int>? zip = ZipEncoder().encode(archive);
        downloadFile(Uint8List.fromList(zip!), '$title.zip', 'application/zip');
      }
    }
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  } catch (e) {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo exportar: $e')));
    }
  }
}
