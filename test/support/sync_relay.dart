import 'dart:convert';
import 'package:haoxiguan/services/backup_settings.dart';
import 'package:haoxiguan/services/sync_client.dart';

class MemorySecrets implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

/// Deliberately dumb opaque relay. Protocol/auth/SQLite are independently tested
/// against the real Go server; this injects deterministic client crash windows.
class TestSyncRelay implements SyncTransport {
  static final epoch = 'e' * 32, vault = 'v' * 32;
  final objects = <String, Map<String, dynamic>>{};
  final operations = <String, Map<String, dynamic>>{};
  final requests = <String, String>{};
  final changes = <Map<String, dynamic>>[];
  bool loseNextPushResponse = false;
  Future<void> Function()? afterNextPull;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? token,
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse(path);
    if (uri.path == '/v1/capabilities') return {'protocol': 1, 'epoch': epoch};
    if (uri.path == '/v1/push') {
      final results = <dynamic>[];
      for (final op in body!['operations']! as List) {
        final id = op['opId'] as String, entity = op['entityId'] as String;
        final prior = operations[id];
        if (prior != null) {
          if (requests[id] != jsonEncode(op)) {
            throw StateError('opId reused with different payload');
          }
          results.add(prior);
          continue;
        }
        final current = objects[entity],
            revision = objects[entity]?['revision'] as int? ?? 0;
        Map<String, dynamic> result;
        if (op['baseRevision'] == revision) {
          final value = <String, dynamic>{
            'entityId': entity,
            'revision': revision + 1,
            'baseRevision': revision,
            'encryptionEpoch': body['epoch'],
            'ciphertext': op['ciphertext'],
            'deleted': op['deleted'],
          };
          objects[entity] = value;
          changes.add(value);
          result = {'opId': id, 'status': 'accepted', 'revision': revision + 1};
        } else {
          result = {'opId': id, 'status': 'conflict', 'current': current};
        }
        operations[id] = result;
        requests[id] = jsonEncode(op);
        results.add(result);
      }
      if (loseNextPushResponse) {
        loseNextPushResponse = false;
        throw const SyncApiException('lost_response');
      }
      return {'results': results};
    }
    if (uri.path == '/v1/pull' || uri.path == '/v1/bootstrap') {
      final q = uri.queryParameters;
      final from = int.tryParse(q['cursor'] ?? '') ?? 0;
      final high = int.tryParse(q['highWater'] ?? '') ?? changes.length;
      final page = changes
          .sublist(from, high)
          .take(int.parse(q['limit']!))
          .toList();
      final next = from + page.length;
      final callback = afterNextPull;
      afterNextPull = null;
      await callback?.call();
      return {
        'epoch': epoch,
        'cursor': '$next',
        'highWater': '$high',
        'more': next < high,
        'objects': page,
      };
    }
    throw StateError('unsupported fixture route $path');
  }

  @override
  void close() {}
}
