import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../data/db_io.dart' if (dart.library.js_interop) '../data/db_web.dart' as dbf;
import '../data/sync.dart';

class LoginScreen extends StatefulWidget {
  final AppScope app;
  const LoginScreen({super.key, required this.app});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _url = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  String? _error;
  late final bool _fixedUrl;

  @override
  void initState() {
    super.initState();
    final def = dbf.defaultServerUrl();
    _fixedUrl = def.isNotEmpty;
    _url.text = widget.app.sync.serverUrl.isNotEmpty ? widget.app.sync.serverUrl : def;
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.app.sync.login(_url.text, _pass.text);
    } on AuthException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = 'Error: $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFE8F0FF), Color(0xFFF6F7F9), Color(0xFFFFF1E6)],
          ),
        ),
        child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420),
            padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: const [BoxShadow(color: Color(0x1A1F2A44), blurRadius: 30, offset: Offset(0, 12))],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      gradient: const LinearGradient(colors: [Color(0xFF4F8BFF), Color(0xFF2F6FED)]),
                    ),
                    child: const Icon(Icons.edit_note, size: 48, color: Colors.white),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Apuntes',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                const Text('Tus cuadernos, en tu propio servidor',
                    textAlign: TextAlign.center, style: TextStyle(color: Colors.black54)),
                const SizedBox(height: 28),
                if (!_fixedUrl) ...[
                  TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Dirección del servidor',
                      hintText: 'https://mi-pc.tu-red.ts.net',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: _pass,
                  obscureText: true,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Contraseña', border: OutlineInputBorder()),
                  onSubmitted: (_) => _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: _busy
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Entrar'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}
