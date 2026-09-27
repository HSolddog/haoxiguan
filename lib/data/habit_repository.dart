import 'package:shared_preferences/shared_preferences.dart';

abstract class HabitRepository {
  Future<String?> load();
  Future<String?> loadBackup();
  Future<void> save(String value);
}

class SharedPreferencesHabitRepository implements HabitRepository {
  // Keep this key stable: Android app updates preserve SharedPreferences as
  // long as the applicationId and signing identity stay unchanged.
  static const _key = 'haoxiguan.app_state.v1';
  static const _backupKey = 'haoxiguan.app_state.backup.v1';
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  Future<void> _saveQueue = Future<void>.value();

  @override
  Future<String?> load() => _preferences.getString(_key);

  @override
  Future<String?> loadBackup() => _preferences.getString(_backupKey);

  @override
  Future<void> save(String value) {
    _saveQueue = _saveQueue.then((_) async {
      final current = await _preferences.getString(_key);
      if (current != null && current.isNotEmpty && current != value) {
        await _preferences.setString(_backupKey, current);
      }
      await _preferences.setString(_key, value);
    });
    return _saveQueue;
  }
}

class MemoryHabitRepository implements HabitRepository {
  MemoryHabitRepository([this.value, this.backupValue]);

  String? value;
  String? backupValue;

  @override
  Future<String?> load() async => value;

  @override
  Future<String?> loadBackup() async => backupValue;

  @override
  Future<void> save(String value) async {
    if (this.value != null && this.value!.isNotEmpty && this.value != value) {
      backupValue = this.value;
    }
    this.value = value;
  }
}
