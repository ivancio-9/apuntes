import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../data/store.dart';
import 'export.dart';
import 'templates.dart';

final Map<String, (int, ui.Image)> _thumbCache = {};

int _pageVersion(Store store, Rec page, Rec notebook) {
  var v = page.updatedAt ^ notebook.updatedAt;
  for (final e in store.elements(page.id)) {
    v = v ^ e.updatedAt ^ e.id.hashCode;
  }
  return v;
}

/// Vista de miniaturas: ir a una página, reordenar arrastrando, duplicar, marcadores y plantillas.
class PagesOverview extends StatefulWidget {
  final AppScope app;
  final String notebookId;
  final int current;
  const PagesOverview({super.key, required this.app, required this.notebookId, required this.current});

  @override
  State<PagesOverview> createState() => _PagesOverviewState();
}

class _PagesOverviewState extends State<PagesOverview> {
  Store get store => widget.app.store;
  bool onlyBookmarks = false;

  @override
  void initState() {
    super.initState();
    store.addListener(_changed);
  }

  @override
  void dispose() {
    store.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _menu(String action, Rec page, List<Rec> pages, Rec nb) async {
    switch (action) {
      case 'dup':
        await store.duplicatePage(page);
        break;
      case 'bookmark':
        await store.updateData(page, {'bookmark': page.data['bookmark'] != true});
        break;
      case 'template':
        final t = await pickTemplate(context,
            current: (page.data['template'] ?? nb.data['paper']) as String?,
            paperColor: (nb.data['paperColor'] ?? 'white') as String,
            title: 'Plantilla de esta página');
        if (t != null) await store.updateData(page, {'template': t});
        break;
      case 'after':
        await store.addPageWith(nb.id, {}, after: page);
        break;
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('¿Eliminar esta página?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Eliminar')),
            ],
          ),
        );
        if (ok == true) {
          await store.remove(page);
          if (store.pages(nb.id).isEmpty) await store.addPage(nb.id);
        }
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final nb = store.recs[widget.notebookId];
    if (nb == null) return const SizedBox();
    final all = store.pages(nb.id);
    final shown = [
      for (var i = 0; i < all.length; i++)
        if (!onlyBookmarks || all[i].data['bookmark'] == true) (i, all[i]),
    ];
    return Scaffold(
      backgroundColor: const Color(0xFFF4F5F7),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF4F5F7),
        title: Text((nb.data['title'] ?? 'Páginas') as String, style: const TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Todas')),
              ButtonSegment(value: true, icon: Icon(Icons.bookmark, size: 18), label: Text('Marcadores')),
            ],
            selected: {onlyBookmarks},
            onSelectionChanged: (s) => setState(() => onlyBookmarks = s.first),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Mantén pulsada una página y arrástrala para cambiarla de sitio.',
                style: TextStyle(fontSize: 12.5, color: Colors.black54)),
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? const Center(child: Text('No hay páginas con marcador.'))
              : GridView.builder(
                  padding: const EdgeInsets.all(20),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 190,
                    mainAxisSpacing: 22,
                    crossAxisSpacing: 18,
                    childAspectRatio: 0.6,
                  ),
                  itemCount: shown.length,
                  itemBuilder: (c, k) {
                    final (i, page) = shown[k];
                    final tile = _PageTile(
                      app: widget.app,
                      notebook: nb,
                      page: page,
                      number: i + 1,
                      current: i == widget.current,
                      onTap: () => Navigator.pop(context, i),
                      onMenu: (a) => _menu(a, page, all, nb),
                    );
                    return LongPressDraggable<String>(
                      data: page.id,
                      feedback: Material(
                        color: Colors.transparent,
                        child: SizedBox(width: 130, height: 184, child: Opacity(opacity: 0.85, child: _Thumb(app: widget.app, notebook: nb, page: page))),
                      ),
                      childWhenDragging: Opacity(opacity: 0.3, child: tile),
                      child: DragTarget<String>(
                        onWillAcceptWithDetails: (d) => d.data != page.id,
                        onAcceptWithDetails: (d) {
                          final moving = store.recs[d.data];
                          if (moving != null) store.movePageBefore(moving, page);
                        },
                        builder: (c, cand, rej) => Container(
                          decoration: BoxDecoration(
                            border: Border(
                              left: BorderSide(
                                  color: cand.isNotEmpty ? const Color(0xFF2F6FED) : Colors.transparent, width: 4),
                            ),
                          ),
                          child: tile,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

class _PageTile extends StatelessWidget {
  final AppScope app;
  final Rec notebook;
  final Rec page;
  final int number;
  final bool current;
  final VoidCallback onTap;
  final ValueChanged<String> onMenu;

  const _PageTile({
    required this.app,
    required this.notebook,
    required this.page,
    required this.number,
    required this.current,
    required this.onTap,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final bookmarked = page.data['bookmark'] == true;
    return Column(children: [
      Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: Stack(children: [
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: current ? const Color(0xFF2F6FED) : Colors.black12, width: current ? 3 : 1),
                  boxShadow: const [BoxShadow(color: Color(0x1A000000), blurRadius: 6, offset: Offset(0, 2))],
                ),
                clipBehavior: Clip.antiAlias,
                child: _Thumb(app: app, notebook: notebook, page: page),
              ),
            ),
            if (bookmarked)
              const Positioned(
                top: -2,
                right: 10,
                child: Icon(Icons.bookmark, color: Color(0xFFE53935), size: 28),
              ),
          ]),
        ),
      ),
      Row(children: [
        const SizedBox(width: 6),
        Text('$number', style: const TextStyle(fontWeight: FontWeight.w600)),
        const Spacer(),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_horiz, size: 20),
          onSelected: onMenu,
          itemBuilder: (c) => [
            const PopupMenuItem(value: 'dup', child: Text('Duplicar')),
            PopupMenuItem(value: 'bookmark', child: Text(bookmarked ? 'Quitar marcador' : 'Añadir marcador')),
            const PopupMenuItem(value: 'template', child: Text('Cambiar plantilla…')),
            const PopupMenuItem(value: 'after', child: Text('Insertar página detrás')),
            const PopupMenuItem(value: 'delete', child: Text('Eliminar')),
          ],
        ),
      ]),
    ]);
  }
}

class _Thumb extends StatefulWidget {
  final AppScope app;
  final Rec notebook;
  final Rec page;
  const _Thumb({required this.app, required this.notebook, required this.page});

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  ui.Image? _img;
  int _version = -1;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void didUpdateWidget(_Thumb old) {
    super.didUpdateWidget(old);
    _check();
  }

  void _check() {
    final v = _pageVersion(widget.app.store, widget.page, widget.notebook);
    if (v == _version) return;
    _version = v;
    final cached = _thumbCache[widget.page.id];
    if (cached != null && cached.$1 == v) {
      _img = cached.$2;
      return;
    }
    _render(v);
  }

  Future<void> _render(int v) async {
    try {
      final img = await renderPageImage(widget.app, widget.notebook, widget.page, scale: 0.24);
      _thumbCache[widget.page.id] = (v, img);
      if (mounted && v == _version) setState(() => _img = img);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final img = _img;
    if (img == null) return const ColoredBox(color: Colors.white);
    return RawImage(image: img, fit: BoxFit.cover);
  }
}
