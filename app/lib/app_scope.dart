import 'data/store.dart';
import 'data/sync.dart';
import 'ui/editor_state.dart';

/// Agrupa los servicios de la app para pasarlos entre pantallas.
class AppScope {
  final Store store;
  final SyncService sync;
  final EditorSettings settings;
  AppScope(this.store, this.sync, this.settings);
}
