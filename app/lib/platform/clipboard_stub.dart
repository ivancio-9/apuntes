import 'dart:typed_data';

/// En Android no hay portapapeles de imágenes: se usa la galería.
void listenForPastedImages(void Function(Uint8List bytes)? onImage) {}

Future<Uint8List?> readClipboardImage() async => null;

const bool clipboardImagesSupported = false;
