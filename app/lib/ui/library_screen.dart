import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../app_scope.dart';
import '../data/store.dart';
import '../data/sync.dart';
import 'blob_image.dart';
import 'color_picker.dart';
import 'editor_state.dart';
import 'export.dart';
import 'notebook_screen.dart';

const kCoverColors = [
  0xFF3F51B5,
  0xFF1E88E5,
  0xFF00897B,
  0xFF43A047,
  0xFFFDD835,
  0xFFFB8C00,
  0xFFE53935,
  0xFFD81B60,
  0xFF8E24AA,
  0xFF6D4C41,
  0xFF546E7A,
  0xFF212121,
];

TextStyle _fontStyle(String? font, TextStyle base) {
  try {
    return GoogleFonts.getFont(font ?? 'Roboto', textStyle: base);
  } catch (_) {
    return base;
  }
}

/// Tapa de un cuaderno (se usa en la biblioteca y en la vista previa del editor).
class NotebookCover extends StatelessWidget {
  final AppScope app;
  final Map<String, dynamic> data;
  const NotebookCover({super.key, required this.app, required this.data});

  @override
  Widget build(BuildContext context) {
    final color = Color(((data['color'] ?? kCoverColors[0]) as num).toInt());
    final image = data['coverImage'] as String?;
    final title = (data['title'] ?? '') as String;
    final subtitle = (data['subtitle'] ?? '') as String;
    final font = data['titleFont'] as String?;
    final dark = color.computeLuminance() < 0.5;

    return Material(
      color: color,
      elevation: 3,
      borderRadius: const BorderRadius.only(
        topRight: Radius.circular(12),
        bottomRight: Radius.circular(12),
        topLeft: Radius.circular(4),
        bottomLeft: Radius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(fit: StackFit.expand, children: [
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
        Positioned(
          left: 9,
          top: 0,
          bottom: 0,
          child: Container(width: 3, color: Colors.black.withValues(alpha: 0.18)),
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
                  style: _fontStyle(
                      font,
                      const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          shadows: [Shadow(blurRadius: 4, color: Colors.black54)]))),
              if (subtitle.isNotEmpty)
                Text(subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 11.5)),
            ]),
          )
        else
          Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 12, 12, 12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                decoration: BoxDecoration(
                  color: dark ? Colors.white.withValues(alpha: 0.92) : Colors.white.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(title,
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: _fontStyle(
                          font, const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: Colors.black87))),
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

class LibraryScreen extends StatefulWidget {
  final AppScope app;
  const LibraryScreen({super.key, required this.app});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  Store get store => widget.app.store;
  SyncService get sync => widget.app.sync;

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

  void _open(Rec nb) {
    store.updateData(nb, {'opened': nowMs()});
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => NotebookScreen(app: widget.app, notebookId: nb.id),
    ));
  }

  Future<void> _edit({Rec? nb}) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (c) => _CoverEditor(app: widget.app, initial: nb?.data, isNew: nb == null),
    );
    if (result == null) return;
    if (nb == null) {
      final created = await store.createNotebook(result['title'] as String,
          paper: result['paper'] as String, color: result['color'] as int);
      final fresh = store.recs[created.id]!;
      await store.updateData(fresh, result);
      if (mounted) _open(store.recs[created.id]!);
    } else {
      await store.updateData(nb, result);
    }
  }

  Future<void> _delete(Rec nb) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('¿Eliminar «${nb.data['title']}»?'),
        content: const Text('Se borrará el cuaderno con todas sus páginas.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok == true) await store.remove(nb);
  }

  Widget _syncIcon() {
    final IconData icon;
    final String tip;
    switch (sync.state) {
      case SyncState.syncing:
        icon = Icons.cloud_sync_outlined;
        tip = 'Sincronizando…';
        break;
      case SyncState.offline:
      case SyncState.error:
        icon = Icons.cloud_off_outlined;
        tip = 'Sin conexión con el servidor. Los cambios se guardan en este dispositivo.';
        break;
      default:
        icon = store.dirty.isEmpty ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined;
        tip = store.dirty.isEmpty ? 'Todo sincronizado' : 'Cambios pendientes de subir';
    }
    return IconButton(tooltip: tip, icon: Icon(icon), onPressed: sync.syncNow);
  }

  @override
  Widget build(BuildContext context) {
    final nbs = store.notebooks();
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF7F8FA),
        title: const Text('Mis cuadernos', style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          _syncIcon(),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'logout') await sync.logout();
            },
            itemBuilder: (c) => const [
              PopupMenuItem(value: 'logout', child: Text('Cerrar sesión')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Nuevo cuaderno'),
      ),
      body: nbs.isEmpty
          ? const Center(child: Text('Crea tu primer cuaderno con el botón de abajo.'))
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 100),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 190,
                mainAxisSpacing: 26,
                crossAxisSpacing: 22,
                childAspectRatio: 0.6,
              ),
              itemCount: nbs.length,
              itemBuilder: (c, i) {
                final nb = nbs[i];
                final pages = store.pages(nb.id).length;
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => _open(nb),
                      child: NotebookCover(app: widget.app, data: nb.data),
                    ),
                  ),
                  Row(children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Text(pages == 1 ? '1 página' : '$pages páginas',
                            style: Theme.of(context).textTheme.bodySmall),
                      ),
                    ),
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_horiz),
                      onSelected: (v) {
                        if (v == 'edit') {
                          _edit(nb: nb);
                        } else if (v == 'export') {
                          showExportDialog(context, widget.app, nb);
                        } else {
                          _delete(nb);
                        }
                      },
                      itemBuilder: (c) => const [
                        PopupMenuItem(value: 'edit', child: Text('Personalizar portada')),
                        PopupMenuItem(value: 'export', child: Text('Exportar (PDF, JPG, PNG)')),
                        PopupMenuItem(value: 'delete', child: Text('Eliminar')),
                      ],
                    ),
                  ]),
                ]);
              },
            ),
    );
  }
}

/// Editor de portada: nombre, subtítulo, letra, color, foto y papel, con vista previa.
class _CoverEditor extends StatefulWidget {
  final AppScope app;
  final Map<String, dynamic>? initial;
  final bool isNew;
  const _CoverEditor({required this.app, required this.initial, required this.isNew});

  @override
  State<_CoverEditor> createState() => _CoverEditorState();
}

class _CoverEditorState extends State<_CoverEditor> {
  late final TextEditingController title =
      TextEditingController(text: (widget.initial?['title'] ?? '') as String);
  late final TextEditingController subtitle =
      TextEditingController(text: (widget.initial?['subtitle'] ?? '') as String);
  late String paper = (widget.initial?['paper'] ?? 'lined') as String;
  late int color = ((widget.initial?['color'] ?? kCoverColors[0]) as num).toInt();
  late String? image = widget.initial?['coverImage'] as String?;
  late String font = (widget.initial?['titleFont'] ?? 'Roboto') as String;
  bool _loadingImage = false;

  Map<String, dynamic> get _data => {
        'title': title.text.trim().isEmpty ? 'Sin título' : title.text.trim(),
        'subtitle': subtitle.text.trim(),
        'paper': paper,
        'color': color,
        'coverImage': image,
        'titleFont': font,
      };

  Future<void> _pickImage() async {
    setState(() => _loadingImage = true);
    try {
      final x = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 900,
        maxHeight: 1400,
        imageQuality: 85,
      );
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
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      );

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width > 640;
    final preview = SizedBox(
      width: 150,
      height: 230,
      child: NotebookCover(app: widget.app, data: _data),
    );
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
      _section('Letra del título'),
      DropdownButton<String>(
        value: font,
        isExpanded: true,
        items: [
          for (final f in kFonts)
            DropdownMenuItem(value: f, child: Text(f, style: _fontStyle(f, const TextStyle(fontSize: 16)))),
        ],
        onChanged: (v) => setState(() => font = v ?? font),
      ),
      _section('Color'),
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
      _section('Foto de portada'),
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
      _section('Papel de las páginas'),
      Wrap(spacing: 6, children: [
        for (final e in kPapers.entries)
          ChoiceChip(
            label: Text(e.value),
            selected: paper == e.key,
            onSelected: (_) => setState(() => paper = e.key),
          ),
      ]),
    ]);

    return AlertDialog(
      title: Text(widget.isNew ? 'Nuevo cuaderno' : 'Personalizar cuaderno'),
      content: SizedBox(
        width: wide ? 560 : 360,
        child: SingleChildScrollView(
          child: wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  preview,
                  const SizedBox(width: 24),
                  Expanded(child: form),
                ])
              : Column(children: [Center(child: preview), const SizedBox(height: 12), form]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _data),
          child: Text(widget.isNew ? 'Crear' : 'Guardar'),
        ),
      ],
    );
  }
}
