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
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.edit_note, size: 72, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 8),
                Text('Apuntes', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 32),
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
    );
  }
}
