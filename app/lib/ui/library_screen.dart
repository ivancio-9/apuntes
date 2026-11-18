import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../data/store.dart';
import '../data/sync.dart';
import '../platform/files_stub.dart' if (dart.library.js_interop) '../platform/files_web.dart';
import 'color_picker.dart';
import 'covers.dart';
import 'export.dart';
import 'notebook_screen.dart';
import 'search_screen.dart';

export 'covers.dart' show kCoverColors, NotebookCover;

const _kInk = Color(0xFF22262C);
const _kSub = Color(0xFF7A818C);
const _kBg = Color(0xFFF6F7F9);

const kFolderColors = [0xFF5B8DEF, 0xFF34C38F, 0xFFF5A623, 0xFFE8505B, 0xFF9B6BDF, 0xFF8D99AE];

String _friendlyDate(int ms) {
  if (ms == 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  String two(int n) => n.toString().padLeft(2, '0');
  if (diff == 0) return 'Hoy, ${two(d.hour)}:${two(d.minute)}';
  if (diff == 1) return 'Ayer';
  if (diff < 7) return 'Hace $diff días';
  const months = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

/// Dibujo de una carpeta.
class _FolderPainter extends CustomPainter {
  final Color color;
  _FolderPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final back = Path()
      ..moveTo(0, h * 0.12)
      ..quadraticBezierTo(0, 0, w * 0.06, 0)
      ..lineTo(w * 0.36, 0)
      ..quadraticBezierTo(w * 0.40, 0, w * 0.43, h * 0.06)
      ..lineTo(w * 0.47, h * 0.12)
      ..lineTo(w * 0.94, h * 0.12)
      ..quadraticBezierTo(w, h * 0.12, w, h * 0.2)
      ..lineTo(w, h * 0.9)
      ..quadraticBezierTo(w, h, w * 0.94, h)
      ..lineTo(w * 0.06, h)
      ..quadraticBezierTo(0, h, 0, h * 0.9)
      ..close();
    final hsl = HSLColor.fromColor(color);
    canvas.drawPath(back, Paint()..color = hsl.withLightness((hsl.lightness - 0.12).clamp(0.0, 1.0)).toColor());
    final front = RRect.fromRectAndRadius(Rect.fromLTWH(0, h * 0.24, w, h * 0.76), Radius.circular(w * 0.06));
    canvas.drawRRect(front.shift(const Offset(0, 2)), Paint()..color = const Color(0x22000000));
    canvas.drawRRect(front, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_FolderPainter old) => old.color != color;
}

class LibraryScreen extends StatefulWidget {
  final AppScope app;
  const LibraryScreen({super.key, required this.app});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  Store get store => widget.app.store;
  SyncService get sync => widget.app.sync;
  String? _folder; // carpeta abierta (null = raíz)

  @override
  void initState() {
    super.initState();
    store.addListener(_changed);
    sync.addListener(_changed);
  }

  @override
  void dispose() {
    store.removeListener(_changed);
    sync.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  void _open(Rec nb, {String? pageId}) {
    store.updateData(nb, {'opened': nowMs()});
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => NotebookScreen(app: widget.app, notebookId: nb.id, initialPageId: pageId),
    ));
  }

  // ---------- Cuadernos ----------

  Future<void> _newNotebook() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (c) => CoverEditor(app: widget.app, initial: null, isNew: true),
    );
    if (result == null) return;
    final nb = await store.createNotebook(result['title'] as String,
        paper: result['paper'] as String, color: result['color'] as int, extra: {...result, 'folder': _folder});
    if (mounted) _open(store.recs[nb.id]!);
  }

  Future<void> _editNotebook(Rec nb) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (c) => CoverEditor(app: widget.app, initial: nb.data, isNew: false),
    );
    if (result != null) await store.updateData(nb, result);
  }

  Future<void> _deleteNotebook(Rec nb) async {
    final ok = await _confirm('¿Eliminar «${nb.data['title']}»?', 'Se borrará el cuaderno con todas sus páginas.');
    if (ok) await store.remove(nb);
  }

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Eliminar')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _moveTo(Rec item) async {
    final all = store.folders(null, true).where((f) => f.id != item.id).toList();
    final target = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Mover a…'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, '__root__'),
            child: const Row(children: [Icon(Icons.home_outlined), SizedBox(width: 12), Text('Documentos (inicio)')]),
          ),
          for (final f in all)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, f.id),
              child: Row(children: [
                Icon(Icons.folder, color: Color(((f.data['color'] ?? kFolderColors[0]) as num).toInt())),
                const SizedBox(width: 12),
                Text((f.data['name'] ?? '') as String),
              ]),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, '__new__'),
            child: const Row(children: [Icon(Icons.create_new_folder_outlined), SizedBox(width: 12), Text('Nueva carpeta…')]),
          ),
        ],
      ),
    );
    if (target == null) return;
    String? dest = target == '__root__' ? null : target;
    if (target == '__new__') {
      final f = await _folderDialog();
      if (f == null) return;
      dest = f.id;
    }
    await store.updateData(item, {'folder': dest});
  }

  // ---------- Carpetas ----------

  Future<Rec?> _folderDialog({Rec? folder}) async {
    final name = TextEditingController(text: (folder?.data['name'] ?? '') as String);
    var color = ((folder?.data['color'] ?? kFolderColors[0]) as num).toInt();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: Text(folder == null ? 'Nueva carpeta' : 'Editar carpeta'),
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Nombre'),
                onSubmitted: (_) => Navigator.pop(c, true),
              ),
              const SizedBox(height: 18),
              Wrap(spacing: 10, runSpacing: 10, children: [
                for (final cc in [...kFolderColors, if (!kFolderColors.contains(color)) color])
                  GestureDetector(
                    onTap: () => setD(() => color = cc),
                    child: SizedBox(
                      width: 46,
                      height: 38,
                      child: Stack(children: [
                        Positioned.fill(child: CustomPaint(painter: _FolderPainter(Color(cc)))),
                        if (cc == color) const Center(child: Icon(Icons.check, color: Colors.white, size: 20)),
                      ]),
                    ),
                  ),
                IconButton(
                  tooltip: 'Otro color',
                  icon: const Icon(Icons.palette_outlined),
                  onPressed: () async {
                    final c2 = await showColorPicker(c, Color(color), title: 'Color de la carpeta');
                    if (c2 != null) setD(() => color = c2.toARGB32());
                  },
                ),
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(folder == null ? 'Crear' : 'Guardar')),
          ],
        ),
      ),
    );
    if (ok != true) return null;
    final n = name.text.trim().isEmpty ? 'Carpeta' : name.text.trim();
    if (folder == null) return store.createFolder(n, parent: _folder, color: color);
    await store.updateData(folder, {'name': n, 'color': color});
    return store.recs[folder.id];
  }

  Future<void> _deleteFolder(Rec f) async {
    final ok = await _confirm('¿Eliminar la carpeta «${f.data['name']}»?',
        'Los cuadernos que contiene no se borran: pasan a la carpeta superior.');
    if (ok) await store.removeFolder(f);
  }

  // ---------- Importar PDF ----------

  Future<void> _importPdf() async {
    if (!pdfImportSupported) {
      _snack('Importar PDF solo está disponible en la versión web (iPad u ordenador).');
      return;
    }
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
      final images = await pdfToImages(picked.$2, onProgress: (i, n) => progress.value = 'Importando página $i de $n…');
      var title = picked.$1;
      if (title.toLowerCase().endsWith('.pdf')) title = title.substring(0, title.length - 4);
      final nb = await store.createNotebook(title,
          paper: 'blank', color: 0xFFE8505B, extra: {'folder': _folder, 'coverStyle': 'gradient'}, firstPage: false);
      for (final img in images) {
        final blob = newId();
        await store.putBlob(blob, img);
        await store.addPageWith(nb.id, {'template': 'blank', 'bg': blob});
      }
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) _open(store.recs[nb.id]!);
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _snack('No se pudo importar el PDF: $e');
      }
    }
  }

  void _newMenu(BuildContext anchor) async {
    final box = anchor.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(Offset.zero);
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy + 40, pos.dx + box.size.width, 0),
      items: [
        const PopupMenuItem(
            value: 'nb', child: Row(children: [Icon(Icons.menu_book_outlined), SizedBox(width: 12), Text('Cuaderno')])),
        const PopupMenuItem(
            value: 'folder',
            child: Row(children: [Icon(Icons.create_new_folder_outlined), SizedBox(width: 12), Text('Carpeta')])),
        if (pdfImportSupported)
          const PopupMenuItem(
              value: 'pdf',
              child: Row(children: [Icon(Icons.picture_as_pdf_outlined), SizedBox(width: 12), Text('Importar PDF')])),
      ],
    );
    if (v == 'nb') _newNotebook();
    if (v == 'folder') _folderDialog();
    if (v == 'pdf') _importPdf();
  }

  // ---------- Interfaz ----------

  Widget _syncChip() {
    final IconData icon;
    final String tip;
    Color color = _kSub;
    switch (sync.state) {
      case SyncState.syncing:
        icon = Icons.sync;
        tip = 'Sincronizando…';
        break;
      case SyncState.offline:
      case SyncState.error:
        icon = Icons.cloud_off_outlined;
        tip = 'Sin conexión con el servidor. Los cambios se guardan en este dispositivo.';
        color = const Color(0xFFE8505B);
        break;
      default:
        icon = store.dirty.isEmpty ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined;
        tip = store.dirty.isEmpty ? 'Todo sincronizado con tu servidor' : 'Cambios pendientes de subir';
    }
    return IconButton(tooltip: tip, icon: Icon(icon, color: color), onPressed: sync.syncNow);
  }

  List<Rec> _breadcrumbs() {
    final list = <Rec>[];
    var id = _folder;
    while (id != null) {
      final f = store.recs[id];
      if (f == null || f.deleted) break;
      list.insert(0, f);
      id = f.data['folder'] as String?;
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    if (_folder != null && (store.recs[_folder!]?.deleted ?? true)) _folder = null;
    final folders = store.folders(_folder);
    final nbs = store.notebooks(_folder);
    final crumbs = _breadcrumbs();
    final title = crumbs.isEmpty ? 'Documentos' : (crumbs.last.data['name'] ?? '') as String;

    return Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        child: CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 18, 16, 4),
              child: Row(children: [
                if (crumbs.isNotEmpty)
                  IconButton(
                    tooltip: 'Atrás',
                    icon: const Icon(Icons.chevron_left, size: 30, color: Color(0xFF2F6FED)),
                    onPressed: () => setState(() => _folder = crumbs.last.data['folder'] as String?),
                  ),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (crumbs.isNotEmpty)
                      Text(['Documentos', ...crumbs.take(crumbs.length - 1).map((f) => f.data['name'] as String? ?? '')].join('  ›  '),
                          style: const TextStyle(color: _kSub, fontSize: 13)),
                    Text(title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: _kInk, letterSpacing: -0.5)),
                  ]),
                ),
                IconButton(
                  tooltip: 'Buscar',
                  icon: const Icon(Icons.search, color: _kInk),
                  onPressed: () async {
                    final r = await Navigator.of(context).push<SearchResult>(
                        MaterialPageRoute(builder: (_) => SearchScreen(app: widget.app)));
                    if (r == null) return;
                    final nb = store.recs[r.notebookId];
                    if (nb != null) _open(nb, pageId: r.pageId);
                  },
                ),
                _syncChip(),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_horiz, color: _kInk),
                  onSelected: (v) async {
                    if (v == 'logout') await sync.logout();
                  },
                  itemBuilder: (c) => const [PopupMenuItem(value: 'logout', child: Text('Cerrar sesión'))],
                ),
              ]),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(28, 16, 28, 60),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                mainAxisSpacing: 28,
                crossAxisSpacing: 26,
                childAspectRatio: 0.56,
              ),
              delegate: SliverChildListDelegate([
                Builder(builder: (bc) => _NewTile(onTap: () => _newMenu(bc))),
                for (final f in folders)
                  _FolderTile(
                    folder: f,
                    count: store.folderCount(f.id),
                    onTap: () => setState(() => _folder = f.id),
                    onMenu: (v) {
                      if (v == 'edit') _folderDialog(folder: f);
                      if (v == 'move') _moveTo(f);
                      if (v == 'delete') _deleteFolder(f);
                    },
                  ),
                for (final nb in nbs)
                  _NotebookTile(
                    app: widget.app,
                    nb: nb,
                    pages: store.pages(nb.id).length,
                    onTap: () => _open(nb),
                    onMenu: (v) {
                      if (v == 'edit') _editNotebook(nb);
                      if (v == 'move') _moveTo(nb);
                      if (v == 'export') showExportDialog(context, widget.app, nb);
                      if (v == 'delete') _deleteNotebook(nb);
                    },
                  ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _NewTile extends StatelessWidget {
  final VoidCallback onTap;
  const _NewTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFCFD5DE), width: 1.5),
            ),
            child: const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: Color(0x1F2F6FED),
                  child: Icon(Icons.add, size: 30, color: Color(0xFF2F6FED)),
                ),
                SizedBox(height: 10),
                Text('Nuevo…', style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF2F6FED))),
              ]),
            ),
          ),
        ),
      ),
      const SizedBox(height: 44),
    ]);
  }
}

class _FolderTile extends StatelessWidget {
  final Rec folder;
  final int count;
  final VoidCallback onTap;
  final ValueChanged<String> onMenu;
  const _FolderTile({required this.folder, required this.count, required this.onTap, required this.onMenu});

  @override
  Widget build(BuildContext context) {
    final color = Color(((folder.data['color'] ?? kFolderColors[0]) as num).toInt());
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: Center(
            child: AspectRatio(
              aspectRatio: 1.2,
              child: Stack(children: [
                Positioned.fill(child: CustomPaint(painter: _FolderPainter(color))),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 14,
                  child: Center(
                    child: Text('$count',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontWeight: FontWeight.w800, fontSize: 18)),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
      _TileFooter(
        title: (folder.data['name'] ?? '') as String,
        subtitle: count == 1 ? '1 elemento' : '$count elementos',
        items: const [
          PopupMenuItem(value: 'edit', child: Text('Cambiar nombre y color')),
          PopupMenuItem(value: 'move', child: Text('Mover a…')),
          PopupMenuItem(value: 'delete', child: Text('Eliminar carpeta')),
        ],
        onMenu: onMenu,
      ),
    ]);
  }
}

class _NotebookTile extends StatelessWidget {
  final AppScope app;
  final Rec nb;
  final int pages;
  final VoidCallback onTap;
  final ValueChanged<String> onMenu;
  const _NotebookTile({required this.app, required this.nb, required this.pages, required this.onTap, required this.onMenu});

  @override
  Widget build(BuildContext context) {
    final date = _friendlyDate(((nb.data['opened'] ?? nb.updatedAt) as num).toInt());
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: GestureDetector(onTap: onTap, child: NotebookCover(app: app, data: nb.data)),
      ),
      _TileFooter(
        title: (nb.data['title'] ?? '') as String,
        subtitle: '$date · ${pages == 1 ? '1 pág.' : '$pages págs.'}',
        items: const [
          PopupMenuItem(value: 'edit', child: Text('Personalizar portada')),
          PopupMenuItem(value: 'move', child: Text('Mover a carpeta…')),
          PopupMenuItem(value: 'export', child: Text('Exportar (PDF, JPG, PNG)')),
          PopupMenuItem(value: 'delete', child: Text('Eliminar')),
        ],
        onMenu: onMenu,
      ),
    ]);
  }
}

class _TileFooter extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<PopupMenuEntry<String>> items;
  final ValueChanged<String> onMenu;
  const _TileFooter({required this.title, required this.subtitle, required this.items, required this.onMenu});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 8, left: 2),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5, color: _kInk)),
              Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: _kSub)),
            ]),
          ),
        ),
        PopupMenuButton<String>(
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.keyboard_arrow_down, color: _kSub),
          onSelected: onMenu,
          itemBuilder: (c) => items,
        ),
      ]),
    );
  }
}
