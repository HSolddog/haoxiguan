import 'package:shared_preferences/shared_preferences.dart';

abstract class HabitRepository {
  Future<String?> load();
  Future<String?> loadBackup();
  Future<void> save(String value);
  Future<void> replace(String value);
  Future<Map<String, String>> rawSources();
}

/// Optional fast path: unchanged habits are already validated immutable values.
/// Repositories still check the revision, changed data, IDs and transaction.
abstract interface class IncrementalHabitRepository {
  Future<void> saveDelta(
    String changedSnapshot,
    List<String> habitOrder,
    String Function() completeSnapshot,
  );
}

class LazyHabitRepository
    implements HabitRepository, IncrementalHabitRepository {
  LazyHabitRepository(this.open);
  final Future<HabitRepository> Function() open;
  HabitRepository? _repository;
  Future<HabitRepository> _get() async => _repository ??= await open();
  @override
  Future<String?> load() async => (await _get()).load();
  @override
  Future<String?> loadBackup() async => (await _get()).loadBackup();
  @override
  Future<void> save(String value) async => (await _get()).save(value);
  @override
  Future<void> replace(String value) async => (await _get()).replace(value);
  @override
  Future<Map<String, String>> rawSources() async => (await _get()).rawSources();
  @override
  Future<void> saveDelta(
    String changedSnapshot,
    List<String> habitOrder,
    String Function() completeSnapshot,
  ) async {
    final repository = await _get();
    if (repository is IncrementalHabitRepository) {
      await (repository as IncrementalHabitRepository).saveDelta(
        changedSnapshot,
        habitOrder,
        completeSnapshot,
      );
    } else {
      await repository.save(completeSnapshot());
    }
  }
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
  Future<void> replace(String value) => save(value);

  @override
  Future<Map<String, String>> rawSources() async => {
    if (await load() case final String value) 'primary': value,
    if (await loadBackup() case final String value) 'backup': value,
  };

  @override
  Future<void> save(String value) {
    final operation = _saveQueue.then((_) async {
      final current = await _preferences.getString(_key);
      if (current != null && current.isNotEmpty && current != value) {
        await _preferences.setString(_backupKey, current);
      }
      await _preferences.setString(_key, value);
    });
    // The caller observes this failure, but later writes can still run.
    _saveQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }
}

class MemoryHabitRepository implements HabitRepository {
  MemoryHabitRepository([this.value, this.backupValue]);

  String? value;
  String? backupValue;
  final List<String> protectedSources = [];

  @override
  Future<void> replace(String value) async {
    if (this.value != null) protectedSources.add(this.value!);
    await save(value);
  }

  @override
  Future<Map<String, String>> rawSources() async => {
    'primary': ?value,
    'backup': ?backupValue,
  };

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
