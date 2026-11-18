import 'dart:js_interop';
import 'dart:typed_data';

@JS('apuntesDownload')
external void _download(JSUint8Array bytes, JSString name, JSString mime);

@JS('apuntesPngToJpg')
external JSPromise<JSUint8Array> _pngToJpg(JSUint8Array png, JSNumber quality);

const bool exportSupported = true;

void downloadFile(Uint8List bytes, String name, String mime) => _download(bytes.toJS, name.toJS, mime.toJS);

Future<Uint8List> pngToJpg(Uint8List png, double quality) async =>
    (await _pngToJpg(png.toJS, quality.toJS).toDart).toDart;

@JS('apuntesPickFile')
external JSPromise<JSUint8Array?> _pickFile(JSString accept);

@JS('apuntesLastFileName')
external JSString? get _lastFileName;

@JS('apuntesPdfToImages')
external JSPromise<JSArray<JSUint8Array>> _pdfToImages(JSUint8Array bytes, JSNumber maxWidth, JSFunction onProgress);

const bool pdfImportSupported = true;

/// Abre el selector de archivos. Devuelve (nombre, bytes) o null si se cancela.
Future<(String, Uint8List)?> pickFile(String accept) async {
  final r = await _pickFile(accept.toJS).toDart;
  if (r == null) return null;
  return (_lastFileName?.toDart ?? 'archivo', r.toDart);
}

/// Convierte cada página del PDF en una imagen JPG.
Future<List<Uint8List>> pdfToImages(Uint8List pdf, {double maxWidth = 1600, void Function(int done, int total)? onProgress}) async {
  final cb = ((JSNumber i, JSNumber n) {
    onProgress?.call(i.toDartInt, n.toDartInt);
  }).toJS;
  final list = await _pdfToImages(pdf.toJS, maxWidth.toJS, cb).toDart;
  return [for (final x in list.toDart) x.toDart];
}
