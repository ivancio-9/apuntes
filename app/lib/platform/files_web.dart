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
