import 'dart:typed_data';

/// En Android la exportación aún no está disponible (sí en la versión web / iPad).
const bool exportSupported = false;

void downloadFile(Uint8List bytes, String name, String mime) =>
    throw UnsupportedError('Exportar solo está disponible en la versión web');

Future<Uint8List> pngToJpg(Uint8List png, double quality) async =>
    throw UnsupportedError('Exportar solo está disponible en la versión web');
