import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../app_scope.dart';
import '../data/store.dart';
import '../ink/ink.dart';
import '../platform/clipboard_stub.dart' if (dart.library.js_interop) '../platform/clipboard_web.dart';
import 'color_picker.dart';
import 'editor_state.dart';
import 'export.dart';
import 'page_editor.dart';

const kPapers = {
  'blank': 'En blanco',
  'lined': 'Rayado',
  'grid': 'Cuadrícula',
  'dots': 'Puntos',
};

const _shapeNames = {
  ShapeKind.line: 'Línea',
  ShapeKind.arrow: 'Flecha',
  ShapeKind.rect: 'Rectángulo',
  ShapeKind.ellipse: 'Círculo',
  ShapeKind.triangle: 'Triángulo',
};

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

const _kAccent = Color(0xFF2F6FED);
const _kBarBg = Color(0xFFF7F8FA);
const _kPill = Color(0xFFE9ECF1);

class NotebookScreen extends StatefulWidget {
  final AppScope app;
  final String notebookId;
  const NotebookScreen({super.key, required this.app, required this.notebookId});

  @override
  State<NotebookScreen> createState() => _NotebookScreenState();
}

class _NotebookScreenState extends State<NotebookScreen> {
  Store get store => widget.app.store;
  EditorSettings get settings => widget.app.settings;
  late final History history = History(store);
  final _editorKey = GlobalKey<PageEditorState>();
  String? _pageId;

  @override
  void initState() {
    super.initState();
    store.addListener(_changed);
    settings.addListener(_changed);
    history.addListener(_changed);
    final pages = store.pages(widget.notebookId);
    final last = store.recs[widget.notebookId]?.data['lastPage'] as String?;
    _pageId = pages.any((p) => p.id == last) ? last : (pages.isEmpty ? null : pages.first.id);
    // Ctrl+V / Cmd+V con una captura en el portapapeles la inserta en la página.
    listenForPastedImages((bytes) => _insertBytes(bytes));
  }

  @override
  void dispose() {
    listenForPastedImages(null);
    store.removeListener(_changed);
    settings.removeListener(_changed);
    history.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _goTo(String id) {
    if (id == _pageId) return;
    history.clear();
    setState(() => _pageId = id);
    final nb = store.recs[widget.notebookId];
    if (nb != null) store.updateData(nb, {'lastPage': id});
  }

  Future<void> _addPage(Rec? after) async {
    final p = await store.addPage(widget.notebookId, after: after);
    _goTo(p.id);
  }

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

  Future<void> _deletePage(Rec page, List<Rec> pages) async {
    if (!await _confirm('¿Eliminar esta página?', 'Se borrará la página y todo lo que contiene.', 'Eliminar')) return;
    final i = pages.indexWhere((p) => p.id == page.id);
    await store.remove(page);
    final rest = store.pages(widget.notebookId);
    if (rest.isEmpty) {
      await _addPage(null);
    } else {
      _goTo(rest[i.clamp(0, rest.length - 1)].id);
    }
  }

  Future<void> _clearPage() async {
    if (!await _confirm('¿Borrar todo el contenido?', 'Podrás recuperarlo con Deshacer.', 'Borrar')) return;
    _editorKey.currentState?.clearPage();
  }

  Future<void> _choosePaper(Rec nb) async {
    final v = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Tipo de papel'),
        children: [
          for (final e in kPapers.entries)
            SimpleDialogOption(onPressed: () => Navigator.pop(c, e.key), child: Text(e.value)),
        ],
      ),
    );
    if (v != null) await store.updateData(nb, {'paper': v});
  }

  Future<void> _insertBytes(Uint8List bytes) async {
    try {
      await _editorKey.currentState?.insertImage(bytes);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo insertar la imagen: $e')));
      }
    }
  }

  Future<void> _pasteImage() async {
    final bytes = await readClipboardImage();
    if (bytes == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No hay ninguna imagen en el portapapeles. En el ordenador también puedes pulsar Ctrl+V.'),
        ));
      }
      return;
    }
    await _insertBytes(bytes);
  }

  Future<void> _pickImage() async {
    try {
      final x = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 2400,
        maxHeight: 2400,
        imageQuality: 85,
      );
      if (x == null) return;
      final bytes = await x.readAsBytes();
      await _editorKey.currentState?.insertImage(bytes);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo insertar la imagen: $e')));
      }
    }
  }

  void _showPages(List<Rec> pages) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (var i = 0; i < pages.length; i++)
              ListTile(
                selected: pages[i].id == _pageId,
                leading: const Icon(Icons.description_outlined),
                title: Text('Página ${i + 1}'),
                onTap: () {
                  Navigator.pop(c);
                  _goTo(pages[i].id);
                },
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: 'Insertar página detrás',
                    icon: const Icon(Icons.add),
                    onPressed: () {
                      Navigator.pop(c);
                      _addPage(pages[i]);
                    },
                  ),
                  IconButton(
                    tooltip: 'Eliminar página',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      Navigator.pop(c);
                      _deletePage(pages[i], pages);
                    },
                  ),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  // ---------- Barra superior ----------

  Widget _toolButton(Tool t, IconData icon, String tip, {Color? dot, Widget? glyph}) {
    final sel = settings.tool == t;
    return Tooltip(
      message: tip,
      child: GestureDetector(
        onTap: () => settings.set(() => settings.tool = t),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 44,
          height: 40,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: sel ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: sel ? const [BoxShadow(color: Color(0x22000000), blurRadius: 4, offset: Offset(0, 1))] : null,
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            glyph ?? Icon(icon, size: 21, color: sel ? _kAccent : const Color(0xFF4A4F57)),
            if (dot != null)
              Container(
                margin: const EdgeInsets.only(top: 2),
                width: 16,
                height: 3,
                decoration: BoxDecoration(color: dot, borderRadius: BorderRadius.circular(2)),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _tools() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: _kPill, borderRadius: BorderRadius.circular(13)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _toolButton(Tool.select, Icons.gesture, 'Lazo: seleccionar, mover y escalar'),
        _toolButton(Tool.pen, Icons.edit, 'Pluma', dot: settings.penColor),
        _toolButton(Tool.highlighter, Icons.border_color, 'Subrayador', dot: settings.highlighterBase),
        _toolButton(Tool.eraser, Icons.cleaning_services_outlined, 'Borrador'),
        _toolButton(Tool.shape, Icons.category_outlined, 'Figuras (línea, flecha, rectángulo, círculo, triángulo)',
            dot: settings.shapeColor,
            glyph: ShapeGlyph(
                kind: settings.shape,
                color: settings.tool == Tool.shape ? _kAccent : const Color(0xFF4A4F57),
                size: const Size(22, 18))),
        _toolButton(Tool.text, Icons.text_fields, 'Texto con teclado', dot: settings.textColor),
        Container(width: 1, height: 24, margin: const EdgeInsets.symmetric(horizontal: 4), color: Colors.black12),
        PopupMenuButton<String>(
          tooltip: 'Insertar imagen o captura',
          onSelected: (v) => v == 'paste' ? _pasteImage() : _pickImage(),
          itemBuilder: (c) => [
            const PopupMenuItem(
              value: 'pick',
              child: Row(children: [
                Icon(Icons.photo_library_outlined),
                SizedBox(width: 12),
                Text('Desde fotos o archivos'),
              ]),
            ),
            if (clipboardImagesSupported)
              const PopupMenuItem(
                value: 'paste',
                child: Row(children: [
                  Icon(Icons.content_paste),
                  SizedBox(width: 12),
                  Text('Pegar captura (o Ctrl+V)'),
                ]),
              ),
          ],
          child: const SizedBox(
            width: 44,
            height: 40,
            child: Icon(Icons.add_photo_alternate_outlined, size: 22, color: Color(0xFF4A4F57)),
          ),
        ),
      ]),
    );
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback? onTap) => IconButton(
        tooltip: tip,
        onPressed: onTap,
        icon: Icon(icon, size: 22),
        color: const Color(0xFF4A4F57),
        disabledColor: Colors.black26,
      );

  Widget _leftGroup(Rec nb) => Row(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 6),
          child: TextButton.icon(
            onPressed: () => Navigator.pop(context),
            style: TextButton.styleFrom(
              foregroundColor: _kAccent,
              backgroundColor: _kAccent.withValues(alpha: 0.08),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.chevron_left, size: 20),
            label: const Text('Cuadernos', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),
        Flexible(
          child: Text(
            (nb.data['title'] ?? '') as String,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: Color(0xFF2B2F36)),
          ),
        ),
      ]);

  Widget _rightGroup(Rec nb, List<Rec> pages, int idx, Rec? page) {
    final last = idx == pages.length - 1;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _iconBtn(Icons.undo, 'Deshacer', history.canUndo ? history.undo : null),
      _iconBtn(Icons.redo, 'Rehacer', history.canRedo ? history.redo : null),
      Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(color: _kPill, borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: idx > 0 ? () => _goTo(pages[idx - 1].id) : null,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(Icons.chevron_left, size: 20, color: idx > 0 ? const Color(0xFF4A4F57) : Colors.black26),
            ),
          ),
          InkWell(
            onTap: () => _showPages(pages),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Text('${idx + 1} / ${pages.length}',
                  style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF2B2F36))),
            ),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: last ? null : () => _goTo(pages[idx + 1].id),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(Icons.chevron_right, size: 20, color: last ? Colors.black26 : const Color(0xFF4A4F57)),
            ),
          ),
        ]),
      ),
      _iconBtn(Icons.note_add_outlined, 'Añadir página al final', () => _addPage(null)),
      _iconBtn(Icons.ios_share, 'Exportar a PDF, JPG o PNG',
          () => showExportDialog(context, widget.app, nb, currentPage: page)),
      PopupMenuButton<String>(
        tooltip: 'Más opciones',
        icon: const Icon(Icons.more_horiz, color: Color(0xFF4A4F57)),
        onSelected: (v) {
          switch (v) {
            case 'paper':
              _choosePaper(nb);
              break;
            case 'export':
              showExportDialog(context, widget.app, nb, currentPage: page);
              break;
            case 'finger':
              settings.set(() => settings.fingerDraws = !settings.fingerDraws);
              break;
            case 'clear':
              _clearPage();
              break;
            case 'delete':
              if (page != null) _deletePage(page, pages);
              break;
          }
        },
        itemBuilder: (c) => [
          const PopupMenuItem(value: 'export', child: Text('Exportar (PDF, JPG, PNG)…')),
          const PopupMenuItem(value: 'paper', child: Text('Tipo de papel…')),
          CheckedPopupMenuItem(value: 'finger', checked: settings.fingerDraws, child: const Text('Dibujar con el dedo')),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'clear', child: Text('Borrar contenido de la página')),
          const PopupMenuItem(value: 'delete', child: Text('Eliminar página')),
        ],
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final nb = store.recs[widget.notebookId];
    if (nb == null || nb.deleted) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Este cuaderno ya no existe.')));
    }
    final pages = store.pages(nb.id);
    if (pages.isNotEmpty && !pages.any((p) => p.id == _pageId)) _pageId = pages.first.id;
    final idx = pages.indexWhere((p) => p.id == _pageId);
    final page = idx >= 0 ? pages[idx] : null;

    return Scaffold(
      backgroundColor: const Color(0xFFE9EBEF),
      body: Column(children: [
        Material(
          color: _kBarBg,
          child: SafeArea(
            bottom: false,
            child: Container(
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0x14000000)))),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: LayoutBuilder(builder: (context, c) {
                if (c.maxWidth >= 980) {
                  return Row(children: [
                    Expanded(child: Align(alignment: Alignment.centerLeft, child: _leftGroup(nb))),
                    _tools(),
                    Expanded(child: Align(alignment: Alignment.centerRight, child: _rightGroup(nb, pages, idx, page))),
                  ]);
                }
                return Column(mainAxisSize: MainAxisSize.min, children: [
                  Row(children: [
                    Expanded(child: _leftGroup(nb)),
                    _rightGroup(nb, pages, idx, page),
                  ]),
                  const SizedBox(height: 4),
                  SingleChildScrollView(scrollDirection: Axis.horizontal, child: _tools()),
                ]);
              }),
            ),
          ),
        ),
        Expanded(
          child: Stack(children: [
            Positioned.fill(
              child: page == null
                  ? const Center(child: CircularProgressIndicator())
                  : PageEditor(
                      key: _editorKey,
                      app: widget.app,
                      page: page,
                      paper: (nb.data['paper'] ?? 'lined') as String,
                      history: history,
                    ),
            ),
            Positioned(
              top: 10,
              left: 8,
              right: 8,
              child: Center(child: _SubToolbar(settings: settings, onClearPage: _clearPage)),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Subbarra flotante con las opciones de la herramienta activa

class _SubToolbar extends StatelessWidget {
  final EditorSettings settings;
  final VoidCallback onClearPage;
  const _SubToolbar({required this.settings, required this.onClearPage});

  Widget _divider() =>
      Container(width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: 8), color: Colors.black12);

  Widget _toggle(IconData icon, String tip, bool on, VoidCallback onTap, {String? label}) {
    final color = on ? _kAccent : const Color(0xFF4A4F57);
    return Tooltip(
      message: tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(minWidth: label == null ? 36 : 52, minHeight: 34),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          decoration: BoxDecoration(
            color: on ? _kAccent.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 20, color: color),
            if (label != null)
              Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: color)),
          ]),
        ),
      ),
    );
  }

  Widget _shapeButton(ShapeKind k) {
    final on = settings.shape == k;
    final color = on ? _kAccent : const Color(0xFF4A4F57);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => settings.set(() => settings.shape = k),
      child: Container(
        width: 58,
        padding: const EdgeInsets.symmetric(vertical: 3),
        decoration: BoxDecoration(
          color: on ? _kAccent.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ShapeGlyph(kind: k, color: color, size: const Size(26, 18)),
          const SizedBox(height: 2),
          Text(_shapeNames[k]!, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: color)),
        ]),
      ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: on ? _kAccent.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: on ? _kAccent : const Color(0xFF4A4F57))),
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
            color: on ? _kAccent.withValues(alpha: 0.12) : null,
          ),
          child: Container(
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(color: on ? _kAccent : const Color(0xFF4A4F57), shape: BoxShape.circle),
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
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: c == current ? _kAccent : Colors.transparent, width: 2),
            ),
            child: Container(
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.black12),
              ),
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
            width: 30,
            height: 30,
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
            child: const Icon(Icons.add, size: 18, color: Colors.white),
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

  Widget _fontMenu() {
    return PopupMenuButton<String>(
      tooltip: 'Tipo de letra',
      onSelected: (f) => settings.set(() => settings.font = f),
      itemBuilder: (c) => [
        for (final f in kFonts)
          PopupMenuItem(
            value: f,
            child: Text(f, style: _font(f, const TextStyle(fontSize: 17))),
          ),
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

  static TextStyle _font(String f, TextStyle base) {
    try {
      return GoogleFonts.getFont(f, textStyle: base);
    } catch (_) {
      return base;
    }
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
          for (var i = 0; i < EditorSettings.highlighterWidths.length; i++)
            _width(7.0 + i * 5, settings.highlighterWidth == EditorSettings.highlighterWidths[i],
                () => settings.set(() => settings.highlighterWidth = EditorSettings.highlighterWidths[i])),
          _divider(),
          _chip('Recto', settings.highlighterStraight, () => settings.set(() => settings.highlighterStraight = true)),
          _chip('A mano alzada', !settings.highlighterStraight,
              () => settings.set(() => settings.highlighterStraight = false)),
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
          for (final k in ShapeKind.values) _shapeButton(k),
          _divider(),
          _toggle(Icons.format_color_fill, 'Relleno', settings.shapeFill,
              () => settings.set(() => settings.shapeFill = !settings.shapeFill),
              label: 'Relleno'),
          for (var i = 0; i < EditorSettings.shapeWidths.length; i++)
            _width(4.0 + i * 4, settings.shapeWidth == EditorSettings.shapeWidths[i],
                () => settings.set(() => settings.shapeWidth = EditorSettings.shapeWidths[i])),
          _divider(),
          _swatches(context),
        ]);
        break;
      case Tool.text:
        children.addAll([
          _fontMenu(),
          const SizedBox(width: 6),
          _toggle(Icons.remove, 'Más pequeño', false,
              () => settings.set(() => settings.textSize = (settings.textSize - 2).clamp(10.0, 120.0))),
          SizedBox(
            width: 30,
            child: Text(settings.textSize.round().toString(),
                textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          _toggle(Icons.add, 'Más grande', false,
              () => settings.set(() => settings.textSize = (settings.textSize + 2).clamp(10.0, 120.0))),
          _divider(),
          _toggle(Icons.format_bold, 'Negrita', settings.bold, () => settings.set(() => settings.bold = !settings.bold),
              label: 'Negrita'),
          _toggle(Icons.format_italic, 'Cursiva', settings.italic,
              () => settings.set(() => settings.italic = !settings.italic),
              label: 'Cursiva'),
          _divider(),
          _swatches(context),
        ]);
        break;
      case Tool.select:
        children.add(const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Text('Rodea con el lápiz lo que quieras mover, escalar, copiar o borrar',
              style: TextStyle(color: Color(0xFF4A4F57))),
        ));
        break;
    }

    return Material(
      elevation: 4,
      shadowColor: Colors.black26,
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}
