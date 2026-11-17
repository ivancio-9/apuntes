import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_scope.dart';

final Map<String, Uint8List> _memo = {};

/// Muestra una imagen guardada (en el dispositivo o, si no está, en el servidor).
class BlobImage extends StatefulWidget {
  final AppScope app;
  final String blobId;
  final BoxFit fit;
  const BlobImage({super.key, required this.app, required this.blobId, this.fit = BoxFit.cover});

  @override
  State<BlobImage> createState() => _BlobImageState();
}

class _BlobImageState extends State<BlobImage> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(BlobImage old) {
    super.didUpdateWidget(old);
    if (old.blobId != widget.blobId) {
      _bytes = null;
      _load();
    }
  }

  Future<void> _load() async {
    final id = widget.blobId;
    var b = _memo[id] ?? await widget.app.store.getBlob(id);
    b ??= await widget.app.sync.fetchBlob(id);
    if (b != null) _memo[id] = b;
    if (mounted && id == widget.blobId) setState(() => _bytes = b);
  }

  @override
  Widget build(BuildContext context) {
    final b = _bytes;
    if (b == null) return const ColoredBox(color: Color(0x11000000));
    return Image.memory(b, fit: widget.fit, gaplessPlayback: true);
  }
}
