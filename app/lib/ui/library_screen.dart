import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../data/store.dart';
import '../data/sync.dart';
import 'notebook_screen.dart';

const kCoverColors = [
  0xFF3F51B5,
  0xFF00897B,
  0xFFE53935,
  0xFFFB8C00,
  0xFF8E24AA,
  0xFF546E7A,
  0xFF6D4C41,
  0xFF43A047,
];

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
    final title = TextEditingController(text: (nb?.data['title'] ?? '') as String);
    var paper = (nb?.data['paper'] ?? 'lined') as String;
    var color = ((nb?.data['color'] ?? kCoverColors[0]) as num).toInt();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: Text(nb == null ? 'Nuevo cuaderno' : 'Editar cuaderno'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: title,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Nombre'),
                onSubmitted: (_) => Navigator.pop(c, true),
              ),
              const SizedBox(height: 16),
              const Text('Papel'),
              const SizedBox(height: 6),
              Wrap(spacing: 6, children: [
                for (final e in kPapers.entries)
                  ChoiceChip(
                    label: Text(e.value),
                    selected: paper == e.key,
                    onSelected: (_) => setD(() => paper = e.key),
                  ),
              ]),
              const SizedBox(height: 16),
              const Text('Color de la tapa'),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final cc in kCoverColors)
                  GestureDetector(
                    onTap: () => setD(() => color = cc),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: Color(cc),
                        shape: BoxShape.circle,
                        border: Border.all(color: cc == color ? Colors.black87 : Colors.transparent, width: 3),
                      ),
                    ),
                  ),
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(nb == null ? 'Crear' : 'Guardar')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final name = title.text.trim().isEmpty ? 'Sin título' : title.text.trim();
    if (nb == null) {
      final created = await store.createNotebook(name, paper: paper, color: color);
      if (mounted) _open(created);
    } else {
      await store.updateData(nb, {'title': name, 'paper': paper, 'color': color});
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
      appBar: AppBar(
        title: const Text('Mis apuntes'),
        actions: [
          _syncIcon(),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'logout') {
                await sync.logout();
              }
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
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                mainAxisSpacing: 24,
                crossAxisSpacing: 20,
                childAspectRatio: 0.62,
              ),
              itemCount: nbs.length,
              itemBuilder: (c, i) {
                final nb = nbs[i];
                final pages = store.pages(nb.id).length;
                return _NotebookCard(
                  title: (nb.data['title'] ?? '') as String,
                  subtitle: pages == 1 ? '1 página' : '$pages páginas',
                  color: Color(((nb.data['color'] ?? kCoverColors[0]) as num).toInt()),
                  onTap: () => _open(nb),
                  onEdit: () => _edit(nb: nb),
                  onDelete: () => _delete(nb),
                );
              },
            ),
    );
  }
}

class _NotebookCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _NotebookCard({
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Material(
          color: color,
          elevation: 3,
          borderRadius: const BorderRadius.only(
            topRight: Radius.circular(12),
            bottomRight: Radius.circular(12),
            topLeft: Radius.circular(4),
            bottomLeft: Radius.circular(4),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Stack(children: [
              Positioned(
                left: 10,
                top: 0,
                bottom: 0,
                child: Container(width: 3, color: Colors.black.withValues(alpha: 0.15)),
              ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 12, 12, 12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.black87),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
      Row(children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_horiz),
          onSelected: (v) {
            if (v == 'edit') {
              onEdit();
            } else {
              onDelete();
            }
          },
          itemBuilder: (c) => const [
            PopupMenuItem(value: 'edit', child: Text('Editar')),
            PopupMenuItem(value: 'delete', child: Text('Eliminar')),
          ],
        ),
      ]),
    ]);
  }
}
