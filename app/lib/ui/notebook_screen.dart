import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../app_scope.dart';
import '../data/store.dart';
import '../ink/ink.dart';
import '../platform/clipboard_stub.dart' if (dart.library.js_interop) '../platform/clipboard_web.dart';
import '../platform/files_stub.dart' if (dart.library.js_interop) '../platform/files_web.dart';
import 'color_picker.dart';
import 'editor_state.dart';
import 'export.dart';
import 'notebook_canvas.dart';
import 'pages_overview.dart';
import 'stickers.dart';
import 'templates.dart';

/// Nombres antiguos de los papeles (se mantienen por compatibilidad).
const kPapers = kTemplates;

const _shapeNames = {
  ShapeKind.line: 'Línea',
  ShapeKind.arrow: 'Flecha',
  ShapeKind.rect: 'Rectángulo',
  ShapeKind.ellipse: 'Círculo',
  ShapeKind.triangle: 'Triángulo',
};

const _tapeNames = {
  'solid': 'Liso',
  'stripes': 'Rayas',
  'dots': 'Topos',
  'grid': 'Cuadros',
  'zigzag': 'Zigzag',
};

const kAccent = Color(0xFF2F6FED);
const _kInk = Color(0xFF3A3F47);
const _kBarBg = Color(0xFFF7F8FA);
const _kPill = Color(0xFFECEEF2);

/// Dibujo pequeño de cada figura (para los botones).
class ShapeGlyph extends StatelessWidget {
  final ShapeKind kind;
  final Color color;
  final Size size;
  const ShapeGlyph({super.key, required this.kind, required this.color, required this.size});

  @override
  Widget build(BuildContext context) => CustomPaint(size: size, painter: _GlyphPainter(kind, color));
}

class _GlyphPainter extends CustomPainter {
  final ShapeKind kind;
  final Color color;
  _GlyphPainter(this.kind, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final r = Rect.fromLTWH(2, 2, size.width - 4, size.height - 4);
    switch (kind) {
      case ShapeKind.line:
        canvas.drawLine(r.bottomLeft, r.topRight, p);
        break;
      case ShapeKind.arrow:
        final a = Offset(r.left, r.center.dy), b = Offset(r.right, r.center.dy);
        canvas.drawLine(a, b, p);
        canvas.drawLine(b, b + const Offset(-6, -5), p);
        canvas.drawLine(b, b + const Offset(-6, 5), p);
        break;
      case ShapeKind.rect:
        canvas.drawRect(r, p);
        break;
      case ShapeKind.ellipse:
        canvas.drawOval(r, p);
        break;
      case ShapeKind.triangle:
        canvas.drawPath(
            Path()
              ..moveTo(r.left, r.bottom)
              ..lineTo(r.center.dx, r.top)
              ..lineTo(r.right, r.bottom)
              ..close(),
            p);
        break;
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.kind != kind || old.color != color;
}

/// Muestra de cinta (washi tape) para los botones.
class _TapeGlyph extends StatelessWidget {
  final String pattern;
  final Color color;
  const _TapeGlyph({required this.pattern, required this.color});

  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size(34, 18), painter: _TapePainter(pattern, color));
}

class _TapePainter extends CustomPainter {
  final String pattern;
  final Color color;
  _TapePainter(this.pattern, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.height / 30);
    paintTape(canvas, const Offset(2, 15), Offset(size.width * 30 / size.height - 2, 15), 26, color, pattern);
  }

  @override
  bool shouldRepaint(_TapePainter old) => old.pattern != pattern || old.color != color;
}

class NotebookScreen extends StatefulWidget {
  final AppScope app;
  final String notebookId;
  final String? initialPageId;
  const NotebookScreen({super.key, required this.app, required this.notebookId, this.initialPageId});

  @override
  State<NotebookScreen> createState() => _NotebookScreenState();
}

class _NotebookScreenState extends State<NotebookScreen> {
  Store get store => widget.app.store;
  EditorSettings get settings => widget.app.settings;
  late final History history = History(store);
  final _canvasKey = GlobalKey<NotebookCanvasState>();
  int _page = 0;
  late int _initialPage;

  @override
  void initState() {
    super.initState();
    store.addListener(_changed);
    settings.addListener(_changed);
    history.addListener(_changed);
    final pages = store.pages(widget.notebookId);
    final want = widget.initialPageId ?? store.recs[widget.notebookId]?.data['lastPage'] as String?;
    _initialPage = want == null ? 0 : pages.indexWhere((p) => p.id == want).clamp(0, 1 << 30);
    if (_initialPage >= pages.length) _initialPage = 0;
    _page = _initialPage;
    listenForPastedImages((bytes) => _insertBytes(bytes));
  }

  @override
  void dispose() {
    listenForPastedImages(null);
    store.removeListener(_changed);
    settings.removeListener(_changed);
    history.removeListener(_changed);
    settings.ruler = false;
    settings.zoomWindow = false;
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Rec? get _nb => store.recs[widget.notebookId];
  List<Rec> get _pages => store.pages(widget.notebookId);
  Rec? get _currentPage {
    final ps = _pages;
    return ps.isEmpty ? null : ps[_page.clamp(0, ps.length - 1)];
  }

  void _onPageChanged(int i) {
    if (i == _page) return;
    setState(() => _page = i);
    final nb = _nb;
    final ps = _pages;
    if (nb != null && i < ps.length && nb.data['lastPage'] != ps[i].id) {
      store.updateData(nb, {'lastPage': ps[i].id});
    }
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<bool> _confirm(String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
        ],
      ),
    );
    return ok == true;
  }

  // ---------- Páginas ----------

  Future<void> _addPageWithTemplate(String? template) async {
    final cur = _currentPage;
    final p = await store.addPageWith(widget.notebookId, template == null ? {} : {'template': template}, after: cur);
    final i = _pages.indexWhere((x) => x.id == p.id);
    WidgetsBinding.instance.addPostFrameCallback((_) => _canvasKey.currentState?.goToPage(i));
  }

  Future<void> _addPageSheet() async {
    final nb = _nb;
    if (nb == null) return;
    final paperColor = (nb.data['paperColor'] ?? 'white') as String;
    final cur = _currentPage;
    final curTpl = (cur?.data['template'] ?? nb.data['paper'] ?? 'lined') as String;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Añadir página', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('Se añade detrás de la página actual.', style: TextStyle(color: Colors.black54)),
            const SizedBox(height: 14),
            SizedBox(
              height: 190,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final e in kTemplates.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 14),
                    child: InkWell(
                      onTap: () {
                        Navigator.pop(c);
                        _addPageWithTemplate(e.key);
                      },
                      child: SizedBox(
                        width: 110,
                        child: Column(children: [
                          Expanded(
                              child: TemplatePreview(
                                  template: e.key, paperColor: paperColor, selected: e.key == curTpl)),
                          const SizedBox(height: 6),
                          Text(e.value,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        ]),
                      ),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 10, runSpacing: 8, children: [
              FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.pop(c);
                  if (cur != null) store.duplicatePage(cur);
                },
                icon: const Icon(Icons.copy_outlined),
                label: const Text('Duplicar esta página'),
              ),
              if (pdfImportSupported)
                FilledButton.tonalIcon(
                  onPressed: () {
                    Navigator.pop(c);
                    _importPdf();
                  },
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('Importar PDF aquí'),
                ),
            ]),
          ]),
        ),
      ),
    );
  }

  Future<void> _importPdf() async {
    final picked = await pickFile('application/pdf');
    if (picked == null || !mounted) return;
    final progress = ValueNotifier<String>('Abriendo PDF…');
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
      final images = await pdfToImages(picked.$2,
          onProgress: (i, n) => progress.value = 'Importando página $i de $n…');
      Rec? after = _currentPage;
      for (final img in images) {
        final blob = newId();
        await store.putBlob(blob, img);
        after = await store.addPageWith(widget.notebookId, {'template': 'blank', 'bg': blob}, after: after);
      }
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) _snack('PDF importado: ${images.length} páginas.');
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _snack('No se pudo importar el PDF: $e');
      }
    }
  }

  Future<void> _openOverview() async {
    final i = await Navigator.of(context).push<int>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => PagesOverview(app: widget.app, notebookId: widget.notebookId, current: _page),
    ));
    if (i != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _canvasKey.currentState?.goToPage(i));
    }
  }

  Future<void> _toggleBookmark() async {
    final p = _currentPage;
    if (p == null) return;
    final on = p.data['bookmark'] != true;
    await store.updateData(p, {'bookmark': on});
    _snack(on ? 'Marcador añadido a la página ${_page + 1}.' : 'Marcador quitado.');
  }

  Future<void> _paperSettings() async {
    final nb = _nb;
    final page = _currentPage;
    if (nb == null || page == null) return;
    var color = (nb.data['paperColor'] ?? 'white') as String;
    var template = (page.data['template'] ?? nb.data['paper'] ?? 'lined') as String;
    var allPages = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: const Text('Papel'),
          content: SizedBox(
            width: 520,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Plantilla', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              SizedBox(
                height: 170,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (final e in kTemplates.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: InkWell(
                        onTap: () => setD(() => template = e.key),
                        child: SizedBox(
                          width: 96,
                          child: Column(children: [
                            Expanded(
                                child: TemplatePreview(
                                    template: e.key, paperColor: color, selected: e.key == template)),
                            const SizedBox(height: 4),
                            Text(e.value, style: const TextStyle(fontSize: 11.5), textAlign: TextAlign.center),
                          ]),
                        ),
                      ),
                    ),
                ]),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: allPages,
                onChanged: (v) => setD(() => allPages = v == true),
                title: const Text('Aplicar a todas las páginas del cuaderno'),
              ),
              const SizedBox(height: 4),
              const Text('Color del papel', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                for (final e in kPaperColors.entries)
                  ChoiceChip(
                    avatar: CircleAvatar(backgroundColor: Color(e.value), radius: 9),
                    label: Text(kPaperColorNames[e.key] ?? e.key),
                    selected: color == e.key,
                    onSelected: (_) => setD(() => color = e.key),
                  ),
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Aplicar')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (allPages) {
      final changes = <Rec>[
        for (final p in _pages)
          if (p.data['bg'] == null) p.copyWith(data: {...p.data}..remove('template'), updatedAt: store.stamp(p)),
      ];
      await store.putAll(changes);
      await store.updateData(store.recs[nb.id]!, {'paper': template, 'paperColor': color});
    } else {
      await store.updateData(page, {'template': template});
      await store.updateData(store.recs[nb.id]!, {'paperColor': color});
    }
  }

  // ---------- Imágenes ----------

  Future<void> _insertBytes(Uint8List bytes) async {
    try {
      await _canvasKey.currentState?.insertImage(bytes);
    } catch (e) {
      if (mounted) _snack('No se pudo insertar la imagen: $e');
    }
  }

  Future<void> _pasteImage() async {
    final bytes = await readClipboardImage();
    if (bytes == null) {
      if (mounted) _snack('No hay ninguna imagen en el portapapeles. En el ordenador también puedes pulsar Ctrl+V.');
      return;
    }
    await _insertBytes(bytes);
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final x = await ImagePicker().pickImage(source: source, maxWidth: 2400, maxHeight: 2400, imageQuality: 85);
      if (x == null) return;
      await _insertBytes(await x.readAsBytes());
    } catch (e) {
      if (mounted) _snack('No se pudo insertar la imagen: $e');
    }
  }

  // ---------- Barras ----------

  Widget _navButton(IconData icon, String tip, VoidCallback? onTap, {bool active = false}) => IconButton(
        tooltip: tip,
        onPressed: onTap,
        icon: Icon(icon, size: 22),
        color: active ? kAccent : _kInk,
        disabledColor: Colors.black26,
      );

  Widget _topBar(Rec nb, List<Rec> pages) {
    final page = _currentPage;
    final bookmarked = page?.data['bookmark'] == true;
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(children: [
        TextButton.icon(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(
            foregroundColor: kAccent,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
          icon: const Icon(Icons.chevron_left, size: 24),
          label: const Text('Cuadernos', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            (nb.data['title'] ?? '') as String,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5, color: Color(0xFF22262C)),
          ),
        ),
        _navButton(Icons.undo, 'Deshacer', history.canUndo ? history.undo : null),
        _navButton(Icons.redo, 'Rehacer', history.canRedo ? history.redo : null),
        Container(width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: 4), color: Colors.black12),
        _navButton(Icons.grid_view_rounded, 'Ver todas las páginas', _openOverview),
        _navButton(bookmarked ? Icons.bookmark : Icons.bookmark_border, 'Marcador en esta página', _toggleBookmark,
            active: bookmarked),
        _navButton(Icons.note_add_outlined, 'Añadir página', _addPageSheet),
        _navButton(Icons.ios_share, 'Exportar (PDF, JPG, PNG)',
            () => showExportDialog(context, widget.app, nb, currentPage: page)),
        PopupMenuButton<String>(
          tooltip: 'Más opciones',
          icon: const Icon(Icons.more_horiz, color: _kInk),
          onSelected: (v) async {
            switch (v) {
              case 'paper':
                _paperSettings();
                break;
              case 'finger':
                settings.set(() => settings.fingerDraws = !settings.fingerDraws);
                break;
              case 'dup':
                if (page != null) await store.duplicatePage(page);
                break;
              case 'pdf':
                _importPdf();
                break;
              case 'clear':
                if (await _confirm('¿Borrar todo el contenido de esta página?', 'Podrás recuperarlo con Deshacer.',
                    'Borrar')) {
                  _canvasKey.currentState?.clearPage();
                }
                break;
              case 'delete':
                if (page == null) return;
                if (await _confirm('¿Eliminar esta página?', 'Se borrará la página y todo lo que contiene.', 'Eliminar')) {
                  await store.remove(page);
                  if (_pages.isEmpty) await store.addPage(widget.notebookId);
                }
                break;
            }
          },
          itemBuilder: (c) => [
            const PopupMenuItem(value: 'paper', child: Text('Papel y plantilla…')),
            CheckedPopupMenuItem(value: 'finger', checked: settings.fingerDraws, child: const Text('Dibujar con el dedo')),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'dup', child: Text('Duplicar página')),
            if (pdfImportSupported) const PopupMenuItem(value: 'pdf', child: Text('Importar PDF…')),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'clear', child: Text('Borrar contenido de la página')),
            const PopupMenuItem(value: 'delete', child: Text('Eliminar página')),
          ],
        ),
      ]),
    );
  }

  Widget _tool(Tool t, IconData icon, String tip, {Color? dot, Widget? glyph}) {
    final sel = settings.tool == t;
    return Tooltip(
      message: tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => settings.set(() => settings.tool = t),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: sel ? kAccent.withValues(alpha: 0.12) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            glyph ?? Icon(icon, size: 22, color: sel ? kAccent : _kInk),
            if (dot != null)
              Container(
                margin: const EdgeInsets.only(top: 3),
                width: 18,
                height: 3.5,
                decoration: BoxDecoration(color: dot, borderRadius: BorderRadius.circular(2)),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _toggleButton(IconData icon, String tip, bool on, VoidCallback onTap) => Tooltip(
        message: tip,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: on ? kAccent.withValues(alpha: 0.12) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 22, color: on ? kAccent : _kInk),
          ),
        ),
      );

  Widget _sep() => Container(width: 1, height: 26, margin: const EdgeInsets.symmetric(horizontal: 6), color: Colors.black12);

  Widget _toolsBar() {
    return Container(
      height: 56,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0x14000000)), top: BorderSide(color: Color(0x0A000000))),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(children: [
          _tool(Tool.select, Icons.gesture, 'Lazo: seleccionar, mover, escalar'),
          _tool(Tool.pen, Icons.edit, 'Pluma', dot: settings.penColor),
          _tool(Tool.highlighter, Icons.border_color, 'Subrayador', dot: settings.highlighterBase),
          _tool(Tool.eraser, Icons.cleaning_services_outlined, 'Borrador'),
          _tool(Tool.shape, Icons.category_outlined, 'Figuras',
              dot: settings.shapeColor,
              glyph: ShapeGlyph(
                  kind: settings.shape,
                  color: settings.tool == Tool.shape ? kAccent : _kInk,
                  size: const Size(22, 18))),
          _tool(Tool.tape, Icons.straighten, 'Washi tape (cinta)',
              glyph: _TapeGlyph(pattern: settings.tapePattern, color: settings.tapeColor)),
          _tool(Tool.text, Icons.text_fields, 'Texto con teclado', dot: settings.textColor),
          _tool(Tool.laser, Icons.flare, 'Puntero láser'),
          _sep(),
          _toggleButton(Icons.emoji_emotions_outlined, 'Pegatinas',
              false, () => showStickerPanel(context, widget.app, _canvasKey).then((_) => setState(() {}))),
          PopupMenuButton<String>(
            tooltip: 'Insertar imagen o captura',
            onSelected: (v) {
              if (v == 'paste') {
                _pasteImage();
              } else if (v == 'camera') {
                _pickImage(ImageSource.camera);
              } else {
                _pickImage(ImageSource.gallery);
              }
            },
            itemBuilder: (c) => [
              const PopupMenuItem(
                value: 'pick',
                child: Row(children: [Icon(Icons.photo_library_outlined), SizedBox(width: 12), Text('Fotos o archivos')]),
              ),
              const PopupMenuItem(
                value: 'camera',
                child: Row(children: [Icon(Icons.photo_camera_outlined), SizedBox(width: 12), Text('Hacer una foto')]),
              ),
              if (clipboardImagesSupported)
                const PopupMenuItem(
                  value: 'paste',
                  child: Row(children: [Icon(Icons.content_paste), SizedBox(width: 12), Text('Pegar captura (Ctrl+V)')]),
                ),
            ],
            child: const SizedBox(
              width: 42,
              height: 42,
              child: Icon(Icons.add_photo_alternate_outlined, size: 22, color: _kInk),
            ),
          ),
          _sep(),
          _toggleButton(Icons.straighten, 'Regla', settings.ruler, () => settings.set(() => settings.ruler = !settings.ruler)),
          _toggleButton(Icons.zoom_in, 'Ventana de zoom', settings.zoomWindow,
              () => settings.set(() => settings.zoomWindow = !settings.zoomWindow)),
          _sep(),
          _ToolOptions(settings: settings, onClearPage: () async {
            if (await _confirm('¿Borrar todo el contenido de esta página?', 'Podrás recuperarlo con Deshacer.', 'Borrar')) {
              _canvasKey.currentState?.clearPage();
            }
          }),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final nb = _nb;
    if (nb == null || nb.deleted) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Este cuaderno ya no existe.')));
    }
    final pages = _pages;
    return Scaffold(
      backgroundColor: const Color(0xFFE9EBEF),
      body: Column(children: [
        Material(
          color: _kBarBg,
          child: SafeArea(
            bottom: false,
            child: Column(children: [_topBar(nb, pages), _toolsBar()]),
          ),
        ),
        Expanded(
          child: Stack(children: [
            Positioned.fill(
              child: pages.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : NotebookCanvas(
                      key: _canvasKey,
                      app: widget.app,
                      notebook: nb,
                      pages: pages,
                      history: history,
                      initialPage: _initialPage,
                      onPageChanged: _onPageChanged,
                      onSaveSticker: (s) => saveSticker(context, widget.app, s),
                    ),
            ),
            if (!settings.zoomWindow)
              Positioned(
                right: 16,
                bottom: 16,
                child: Material(
                  color: Colors.white,
                  elevation: 3,
                  shadowColor: Colors.black26,
                  borderRadius: BorderRadius.circular(20),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: _openOverview,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (_currentPage?.data['bookmark'] == true)
                          const Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: Icon(Icons.bookmark, size: 16, color: Color(0xFFE53935)),
                          ),
                        Text('${(_page + 1).clamp(1, pages.length)} / ${pages.length}',
                            style: const TextStyle(fontWeight: FontWeight.w700, color: _kInk)),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Opciones de la herramienta activa (en la misma barra, como en Goodnotes)

class _ToolOptions extends StatelessWidget {
  final EditorSettings settings;
  final VoidCallback onClearPage;
  const _ToolOptions({required this.settings, required this.onClearPage});

  Widget _divider() =>
      Container(width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: 8), color: Colors.black12);

  Widget _labeled(Widget icon, String label, bool on, VoidCallback onTap, {String? tip}) {
    final color = on ? kAccent : _kInk;
    return Tooltip(
      message: tip ?? label,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 48),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
          decoration: BoxDecoration(
            color: on ? kAccent.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            IconTheme(data: IconThemeData(color: color, size: 19), child: icon),
            Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
          ]),
        ),
      ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: on ? kAccent.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(label,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: on ? kAccent : _kInk)),
        ),
      );

  Widget _width(double dotSize, bool on, VoidCallback onTap) => InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? kAccent.withValues(alpha: 0.12) : null,
          ),
          child: Container(
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(color: on ? kAccent : _kInk, shape: BoxShape.circle),
          ),
        ),
      );

  Widget _swatches(BuildContext context) {
    final hl = settings.tool == Tool.highlighter;
    final list = hl ? settings.highlighterSwatches : settings.swatches;
    final current = settings.currentColor;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final c in list)
        GestureDetector(
          onTap: () => settings.setCurrentColor(c),
          onLongPress: () => _editSwatch(context, c),
          child: Container(
            width: 30,
            height: 30,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: c == current ? kAccent : Colors.transparent, width: 2),
            ),
            child: Container(
              decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: Colors.black12)),
            ),
          ),
        ),
      Tooltip(
        message: 'Otro color',
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () async {
            final c = await showColorPicker(context, current);
            if (c == null) return;
            settings.addSwatch(c);
            settings.setCurrentColor(c);
          },
          child: Container(
            width: 28,
            height: 28,
            margin: const EdgeInsets.only(left: 3),
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
            child: const Icon(Icons.add, size: 17, color: Colors.white),
          ),
        ),
      ),
    ]);
  }

  void _editSwatch(BuildContext context, Color c) {
    showModalBottomSheet(
      context: context,
      builder: (s) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.colorize),
            title: const Text('Cambiar este color'),
            onTap: () async {
              Navigator.pop(s);
              final n = await showColorPicker(context, c);
              if (n != null) {
                settings.replaceSwatch(c, n);
                settings.setCurrentColor(n);
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Quitar de la paleta'),
            onTap: () {
              Navigator.pop(s);
              settings.removeSwatch(c);
            },
          ),
        ]),
      ),
    );
  }

  static TextStyle _font(String f, TextStyle base) {
    try {
      return GoogleFonts.getFont(f, textStyle: base);
    } catch (_) {
      return base;
    }
  }

  Widget _fontMenu() {
    return PopupMenuButton<String>(
      tooltip: 'Tipo de letra',
      onSelected: (f) => settings.set(() => settings.font = f),
      itemBuilder: (c) => [
        for (final f in kFonts) PopupMenuItem(value: f, child: Text(f, style: _font(f, const TextStyle(fontSize: 17)))),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: _kPill, borderRadius: BorderRadius.circular(8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(settings.font, style: _font(settings.font, const TextStyle(fontSize: 14, color: Color(0xFF2B2F36)))),
          const Icon(Icons.arrow_drop_down, size: 20),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = settings.tool;
    final children = <Widget>[];
    switch (t) {
      case Tool.pen:
        children.addAll([
          _chip('Pluma', settings.penPressure, () => settings.set(() => settings.penPressure = true)),
          _chip('Bolígrafo', !settings.penPressure, () => settings.set(() => settings.penPressure = false)),
          _divider(),
          for (var i = 0; i < EditorSettings.penWidths.length; i++)
            _width(4.0 + i * 3, settings.penWidth == EditorSettings.penWidths[i],
                () => settings.set(() => settings.penWidth = EditorSettings.penWidths[i])),
          _divider(),
          _swatches(context),
        ]);
        break;
      case Tool.highlighter:
        children.addAll([
          _chip('Recto', settings.highlighterStraight, () => settings.set(() => settings.highlighterStraight = true)),
          _chip('A mano alzada', !settings.highlighterStraight,
              () => settings.set(() => settings.highlighterStraight = false)),
          _divider(),
          for (var i = 0; i < EditorSettings.highlighterWidths.length; i++)
            _width(7.0 + i * 5, settings.highlighterWidth == EditorSettings.highlighterWidths[i],
                () => settings.set(() => settings.highlighterWidth = EditorSettings.highlighterWidths[i])),
          _divider(),
          _swatches(context),
        ]);
        break;
      case Tool.eraser:
        children.addAll([
          for (var i = 0; i < EditorSettings.eraserSizes.length; i++)
            _width(6.0 + i * 6, settings.eraserSize == EditorSettings.eraserSizes[i],
                () => settings.set(() => settings.eraserSize = EditorSettings.eraserSizes[i])),
          _divider(),
          TextButton.icon(
            onPressed: onClearPage,
            icon: const Icon(Icons.delete_sweep_outlined, size: 20),
            label: const Text('Borrar página'),
          ),
        ]);
        break;
      case Tool.shape:
        children.addAll([
          for (final k in ShapeKind.values)
            _labeled(ShapeGlyph(kind: k, color: settings.shape == k ? kAccent : _kInk, size: const Size(24, 17)),
                _shapeNames[k]!, settings.shape == k, () => settings.set(() => settings.shape = k)),
          _divider(),
          _labeled(const Icon(Icons.format_color_fill), 'Relleno', settings.shapeFill,
              () => settings.set(() => settings.shapeFill = !settings.shapeFill)),
          for (var i = 0; i < EditorSettings.shapeWidths.length; i++)
            _width(4.0 + i * 4, settings.shapeWidth == EditorSettings.shapeWidths[i],
                () => settings.set(() => settings.shapeWidth = EditorSettings.shapeWidths[i])),
          _divider(),
          _swatches(context),
        ]);
        break;
      case Tool.tape:
        children.addAll([
          for (final p in kTapePatterns)
            _labeled(_TapeGlyph(pattern: p, color: settings.tapeColor), _tapeNames[p] ?? p, settings.tapePattern == p,
                () => settings.set(() => settings.tapePattern = p)),
          _divider(),
          for (var i = 0; i < EditorSettings.tapeWidths.length; i++)
            _width(8.0 + i * 5, settings.tapeWidth == EditorSettings.tapeWidths[i],
                () => settings.set(() => settings.tapeWidth = EditorSettings.tapeWidths[i])),
          _divider(),
          _swatches(context),
        ]);
        break;
      case Tool.text:
        children.addAll([
          _fontMenu(),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Más pequeño',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.remove, size: 20),
            onPressed: () => settings.set(() => settings.textSize = (settings.textSize - 2).clamp(10.0, 120.0)),
          ),
          SizedBox(
            width: 28,
            child: Text(settings.textSize.round().toString(),
                textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          IconButton(
            tooltip: 'Más grande',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add, size: 20),
            onPressed: () => settings.set(() => settings.textSize = (settings.textSize + 2).clamp(10.0, 120.0)),
          ),
          _divider(),
          _labeled(const Icon(Icons.format_bold), 'Negrita', settings.bold,
              () => settings.set(() => settings.bold = !settings.bold)),
          _labeled(const Icon(Icons.format_italic), 'Cursiva', settings.italic,
              () => settings.set(() => settings.italic = !settings.italic)),
          _divider(),
          _swatches(context),
        ]);
        break;
      case Tool.select:
        children.add(const Text('Rodea con el lápiz lo que quieras mover, escalar, copiar o guardar como pegatina',
            style: TextStyle(color: Colors.black54, fontSize: 13)));
        break;
      case Tool.laser:
        children.add(const Text('Puntero láser: lo que dibujes desaparece al momento (ideal para presentar)',
            style: TextStyle(color: Colors.black54, fontSize: 13)));
        break;
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}
