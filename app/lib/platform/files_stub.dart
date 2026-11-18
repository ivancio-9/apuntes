import 'dart:typed_data';

/// En Android la exportación aún no está disponible (sí en la versión web / iPad).
const bool exportSupported = false;

void downloadFile(Uint8List bytes, String name, String mime) =>
    throw UnsupportedError('Exportar solo está disponible en la versión web');

Future<Uint8List> pngToJpg(Uint8List png, double quality) async =>
    throw UnsupportedError('Exportar solo está disponible en la versión web');

const bool pdfImportSupported = false;

Future<(String, Uint8List)?> pickFile(String accept) async => null;

Future<List<Uint8List>> pdfToImages(Uint8List pdf, {double maxWidth = 1600, void Function(int done, int total)? onProgress}) async =>
    throw UnsupportedError('Importar PDF solo está disponible en la versión web');
