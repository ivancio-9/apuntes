import 'dart:typed_data';

bool get inkOverlayAvailable => false;

bool inkBegin(String color, double width, bool pressure, bool straight, double l, double t, double r, double b) => false;

Float64List inkPoints() => Float64List(0);

void inkClear() {}

void inkCancel() {}
