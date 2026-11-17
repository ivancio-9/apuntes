import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../data/store.dart';
import '../ink/ink.dart';
import 'editor_state.dart';
import 'page_editor.dart';

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
  }

  @override
  void dispose() {
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

  Future<void> _deletePage(Rec page, List<Rec> pages) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('¿Eliminar esta página?'),
        content: const Text('Se borrará la página y todo lo que contiene.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true) return;
    final i = pages.indexWhere((p) => p.id == page.id);
    await store.remove(page);
    final rest = store.pages(widget.notebookId);
    if (rest.isEmpty) {
      await _addPage(null);
    } else {
      _goTo(rest[(i).clamp(0, rest.length - 1)].id);
    }
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
      appBar: AppBar(
        titleSpacing: 0,
        title: Text((nb.data['title'] ?? '') as String, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Deshacer',
            icon: const Icon(Icons.undo),
            onPressed: history.canUndo ? history.undo : null,
          ),
          IconButton(
            tooltip: 'Rehacer',
            icon: const Icon(Icons.redo),
            onPressed: history.canRedo ? history.redo : null,
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Página anterior',
            icon: const Icon(Icons.chevron_left),
            onPressed: idx > 0 ? () => _goTo(pages[idx - 1].id) : null,
          ),
          TextButton(
            onPressed: () => _showPages(pages),
            child: Text('${idx + 1} / ${pages.length}'),
          ),
          IconButton(
            tooltip: idx == pages.length - 1 ? 'Nueva página' : 'Página siguiente',
            icon: Icon(idx == pages.length - 1 ? Icons.note_add_outlined : Icons.chevron_right),
            onPressed: () => idx == pages.length - 1 ? _addPage(null) : _goTo(pages[idx + 1].id),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'paper':
                  _choosePaper(nb);
                  break;
                case 'finger':
                  settings.set(() => settings.fingerDraws = !settings.fingerDraws);
                  store.setMeta('fingerDraws', settings.fingerDraws);
                  break;
                case 'delete':
                  if (page != null) _deletePage(page, pages);
                  break;
              }
            },
            itemBuilder: (c) => [
              const PopupMenuItem(value: 'paper', child: Text('Tipo de papel…')),
              CheckedPopupMenuItem(
                value: 'finger',
                checked: settings.fingerDraws,
                child: const Text('Dibujar con el dedo'),
              ),
              const PopupMenuItem(value: 'delete', child: Text('Eliminar página')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        _Toolbar(settings: settings),
        const Divider(height: 1),
        Expanded(
          child: page == null
              ? const Center(child: CircularProgressIndicator())
              : PageEditor(
                  key: ValueKey(page.id),
                  store: store,
                  page: page,
                  paper: (nb.data['paper'] ?? 'lined') as String,
                  settings: settings,
                  history: history,
                ),
        ),
      ]),
    );
  }
}

const kPapers = {
  'blank': 'En blanco',
  'lined': 'Rayado',
  'grid': 'Cuadrícula',
  'dots': 'Puntos',
};

class _Toolbar extends StatelessWidget {
  final EditorSettings settings;
  const _Toolbar({required this.settings});

  Widget _tool(BuildContext context, Tool t, IconData icon, String tip) {
    final sel = settings.tool == t;
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tip,
      isSelected: sel,
      style: IconButton.styleFrom(backgroundColor: sel ? cs.primaryContainer : null),
      icon: Icon(icon, color: sel ? cs.onPrimaryContainer : null),
      onPressed: () => settings.set(() => settings.tool = t),
    );
  }

  Widget _colorDot(Color c, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 1),
          shape: BoxShape.circle,
          border: Border.all(color: selected ? Colors.black87 : Colors.black12, width: selected ? 3 : 1),
        ),
      ),
    );
  }

  Widget _sizeDot(double size, bool selected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? Colors.black12 : null,
        ),
        child: Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(color: Colors.black87, shape: BoxShape.circle),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = settings.tool;
    final isHl = t == Tool.highlighter;
    final colors = isHl ? EditorSettings.highlighterColors : EditorSettings.penColors;
    final current = isHl ? settings.highlighterColor : settings.penColor;
    final showColors = t == Tool.pen || t == Tool.highlighter || t == Tool.text;

    final List<Widget> sizes;
    if (t == Tool.pen) {
      sizes = [
        for (var i = 0; i < 3; i++)
          _sizeDot(6.0 + i * 5, settings.penWidth == EditorSettings.penWidths[i],
              () => settings.set(() => settings.penWidth = EditorSettings.penWidths[i])),
      ];
    } else if (isHl) {
      sizes = [
        for (var i = 0; i < 3; i++)
          _sizeDot(8.0 + i * 6, settings.highlighterWidth == EditorSettings.highlighterWidths[i],
              () => settings.set(() => settings.highlighterWidth = EditorSettings.highlighterWidths[i])),
      ];
    } else if (t == Tool.text) {
      sizes = [
        for (var i = 0; i < 3; i++)
          TextButton(
            onPressed: () => settings.set(() => settings.textSize = EditorSettings.textSizes[i]),
            style: TextButton.styleFrom(
              backgroundColor: settings.textSize == EditorSettings.textSizes[i] ? Colors.black12 : null,
              minimumSize: const Size(40, 36),
            ),
            child: Text('A', style: TextStyle(fontSize: 12.0 + i * 5, color: Colors.black87)),
          ),
      ];
    } else {
      sizes = const [];
    }

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(children: [
          _tool(context, Tool.pen, Icons.edit, 'Pluma'),
          _tool(context, Tool.highlighter, Icons.border_color, 'Marcador'),
          _tool(context, Tool.eraser, Icons.cleaning_services_outlined, 'Borrador'),
          _tool(context, Tool.text, Icons.text_fields, 'Texto (teclado)'),
          _tool(context, Tool.hand, Icons.pan_tool_outlined, 'Mover'),
          if (showColors) ...[
            const SizedBox(width: 12),
            const SizedBox(height: 28, child: VerticalDivider()),
            for (final c in colors)
              _colorDot(c, c == current, () {
                settings.set(() {
                  if (isHl) {
                    settings.highlighterColor = c;
                  } else {
                    settings.penColor = c;
                  }
                });
              }),
          ],
          if (sizes.isNotEmpty) ...[
            const SizedBox(width: 8),
            const SizedBox(height: 28, child: VerticalDivider()),
            ...sizes,
          ],
        ]),
      ),
    );
  }
}
