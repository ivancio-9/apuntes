import 'package:sembast/sembast.dart';
import 'package:sembast_web/sembast_web.dart';

Future<Database> openAppDatabase() => databaseFactoryWeb.openDatabase('apuntes');

/// En la web la app la sirve el propio servidor, así que su dirección es la de la página.
String defaultServerUrl() => Uri.base.origin;
