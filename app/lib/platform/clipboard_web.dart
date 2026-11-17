import 'dart:js_interop';
import 'dart:typed_data';

@JS('apuntesOnImagePaste')
external set _onImagePaste(JSFunction? f);

@JS('apuntesReadClipboardImage')
external JSPromise<JSUint8Array?> _readClipboardImage();

/// Escucha Ctrl+V / Cmd+V con una imagen en el portapapeles. Pasa null para dejar de escuchar.
void listenForPastedImages(void Function(Uint8List bytes)? onImage) {
  if (onImage == null) {
    _onImagePaste = null;
    return;
  }
  _onImagePaste = ((JSUint8Array data) {
    onImage(data.toDart);
  }).toJS;
}

/// Lee una imagen del portapapeles (el navegador puede pedir permiso).
Future<Uint8List?> readClipboardImage() async {
  try {
    final r = await _readClipboardImage().toDart;
    return r?.toDart;
  } catch (_) {
    return null;
  }
}

const bool clipboardImagesSupported = true;
