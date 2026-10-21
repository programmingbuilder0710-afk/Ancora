import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'app.dart';
import 'main_web.dart' if (dart.library.js_interop) 'main_web.dart';

void main() {
  if (kIsWeb) {
    runWebApp();
  } else {
    runApp(const DoerApp());
  }
}
