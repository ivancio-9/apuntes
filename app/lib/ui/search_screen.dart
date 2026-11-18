import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../data/store.dart';
import 'covers.dart';

class SearchResult {
  final String notebookId;
  final String? pageId;
  SearchResult(this.notebookId, this.pageId);
}

String _norm(String s) {
  const from = 'áàäâãéèëêíìïîóòöôõúùüûñç';
  const to = 'aaaaaeeeeiiiiooooouuuunc';
  final low = s.toLowerCase();
  final b = StringBuffer();
  for (final ch in low.split('')) {
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  return b.toString();
}

class _Hit {
  final Rec notebook;
  final Rec? page;
  final int pageNumber;
  final String snippet;
  _Hit(this.notebook, this.page, this.pageNumber, this.snippet);
}

/// Busca en títulos de cuadernos y carpetas y en el texto escrito con el teclado.
class SearchScreen extends StatefulWidget {
  final AppScope app;
  const SearchScreen({super.key, required this.app});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _q = TextEditingController();
  List<Rec> _notebooks = [];
  List<_Hit> _hits = [];

  void _search(String q) {
    final store = widget.app.store;
    final n = _norm(q.trim());
    if (n.isEmpty) {
      setState(() {
        _notebooks = [];
        _hits = [];
      });
      return;
    }
    final nbs = store.notebooks(null, true);
    final byTitle = nbs
        .where((nb) => _norm('${nb.data['title'] ?? ''} ${nb.data['subtitle'] ?? ''}').contains(n))
        .toList();
    final hits = <_Hit>[];
    for (final nb in nbs) {
      final pages = store.pages(nb.id);
      for (var i = 0; i < pages.length; i++) {
        for (final el in store.elements(pages[i].id)) {
          if (el.data['type'] != 'text') continue;
          final text = (el.data['text'] ?? '') as String;
          final pos = _norm(text).indexOf(n);
          if (pos < 0) continue;
          final start = (pos - 40).clamp(0, text.length);
          final end = (pos + n.length + 60).clamp(0, text.length);
          hits.add(_Hit(nb, pages[i], i + 1,
              '${start > 0 ? '…' : ''}${text.substring(start, end).replaceAll('\n', ' ')}${end < text.length ? '…' : ''}'));
          if (hits.length > 200) break;
        }
      }
    }
    setState(() {
      _notebooks = byTitle;
      _hits = hits;
    });
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.text.trim();
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF6F7F9),
        titleSpacing: 0,
        title: Container(
          margin: const EdgeInsets.only(right: 16),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
          child: TextField(
            controller: _q,
            autofocus: true,
            onChanged: _search,
            decoration: const InputDecoration(
              border: InputBorder.none,
              icon: Icon(Icons.search),
              hintText: 'Buscar en cuadernos y textos',
            ),
          ),
        ),
      ),
      body: q.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Busca por nombre de cuaderno o por el texto que hayas escrito con el teclado.\n'
                  '(La escritura a mano todavía no se puede buscar.)',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.black54),
                ),
              ),
            )
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (_notebooks.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(8, 4, 8, 8),
                  child: Text('CUADERNOS', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.black54, fontSize: 12)),
                ),
                for (final nb in _notebooks)
                  Card(
                    elevation: 0,
                    child: ListTile(
                      leading: SizedBox(width: 34, height: 46, child: NotebookCover(app: widget.app, data: {...nb.data, 'title': ''})),
                      title: Text((nb.data['title'] ?? '') as String),
                      subtitle: (nb.data['subtitle'] ?? '').toString().isEmpty ? null : Text(nb.data['subtitle'] as String),
                      onTap: () => Navigator.pop(context, SearchResult(nb.id, null)),
                    ),
                  ),
                const SizedBox(height: 12),
              ],
              if (_hits.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(8, 4, 8, 8),
                  child: Text('EN EL TEXTO', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.black54, fontSize: 12)),
                ),
                for (final h in _hits)
                  Card(
                    elevation: 0,
                    child: ListTile(
                      leading: const Icon(Icons.notes),
                      title: Text('${h.notebook.data['title'] ?? ''} · página ${h.pageNumber}'),
                      subtitle: Text(h.snippet, maxLines: 2, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.pop(context, SearchResult(h.notebook.id, h.page?.id)),
                    ),
                  ),
              ],
              if (_notebooks.isEmpty && _hits.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('Sin resultados.', style: TextStyle(color: Colors.black54))),
                ),
            ]),
    );
  }
}
