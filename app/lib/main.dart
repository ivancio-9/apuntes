import 'package:flutter/material.dart';

import 'app_scope.dart';
import 'data/store.dart';
import 'data/sync.dart';
import 'ui/editor_state.dart';
import 'ui/library_screen.dart';
import 'ui/login_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = Store();
  await store.init();
  final sync = SyncService(store);
  await sync.load();
  final settings = EditorSettings();
  await settings.load(store);
  if (sync.loggedIn) {
    sync.start();
    sync.syncNow();
  }
  runApp(ApuntesApp(app: AppScope(store, sync, settings)));
}

class ApuntesApp extends StatefulWidget {
  final AppScope app;
  const ApuntesApp({super.key, required this.app});

  @override
  State<ApuntesApp> createState() => _ApuntesAppState();
}

class _ApuntesAppState extends State<ApuntesApp> with WidgetsBindingObserver {
  final _navKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.app.sync.addListener(_changed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.app.sync.removeListener(_changed);
    super.dispose();
  }

  bool _wasLoggedIn = false;
  void _changed() {
    final now = widget.app.sync.loggedIn;
    if (now != _wasLoggedIn) {
      _wasLoggedIn = now;
      // Al entrar o salir, volvemos a la pantalla principal.
      _navKey.currentState?.popUntil((r) => r.isFirst);
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.app.sync.syncNow();
  }

  @override
  Widget build(BuildContext context) {
    _wasLoggedIn = widget.app.sync.loggedIn;
    return MaterialApp(
      title: 'Apuntes',
      navigatorKey: _navKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF3F51B5),
        useMaterial3: true,
      ),
      home: widget.app.sync.loggedIn ? LibraryScreen(app: widget.app) : LoginScreen(app: widget.app),
    );
  }
}
