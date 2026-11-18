import 'dart:js_interop';
import 'dart:typed_data';

extension type _InkApi(JSObject _) implements JSObject {
  external bool begin(String color, double width, bool pressure, bool straight, double l, double t, double r, double b);
  external JSFloat64Array points();
  external void clear();
  external void cancel();
}

@JS('apuntesInk')
external _InkApi? get _ink;

bool get inkOverlayAvailable => _ink != null;

/// Empieza a dibujar el trazo en la capa rápida del navegador. Devuelve false si no se pudo.
bool inkBegin(String color, double width, bool pressure, bool straight, double l, double t, double r, double b) {
  try {
    return _ink?.begin(color, width, pressure, straight, l, t, r, b) ?? false;
  } catch (_) {
    return false;
  }
}

/// Puntos del trazo (x, y en coordenadas de pantalla, presión), con toda la resolución del lápiz.
Float64List inkPoints() {
  try {
    return _ink?.points().toDart ?? Float64List(0);
  } catch (_) {
    return Float64List(0);
  }
}

void inkClear() {
  try {
    _ink?.clear();
  } catch (_) {}
}

void inkCancel() {
  try {
    _ink?.cancel();
  } catch (_) {}
}
