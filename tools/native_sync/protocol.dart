import 'dart:convert';

const syncAcceptanceSchema = 3;
const syncAcceptanceFlags = <String>[
  'realSyncScreen',
  'realTlsTransport',
  'productionStorage',
  'recoverySafVerified',
  'initialPreviewCancelled',
  'initialPreviewConfirmed',
  'fullFactsTransferred',
  'independentSameDayEntries',
  'manualConflictMerged',
  'protectionIntegrity',
  'sqliteReopened',
  'keystoreProcessReopened',
  'disconnectedOfflineBackup',
];

const syncAcceptanceSource = <String, String>{
  'repository': 'SqliteHabitRepository',
  'secretStore': 'DeviceSecretStore',
  'screen': 'SyncScreen',
  'conflictDialog': 'SyncConflictDialog',
  'transport': 'HttpSyncTransport',
  'platform': 'android',
};

/// Fixed identifiers deliberately contain no UI text, credentials or server data.
class SyncAcceptanceFailure implements Exception {
  const SyncAcceptanceFailure(this.code);
  final String code;
  @override
  String toString() => code;
}

void syncAcceptanceCheck(bool condition, String code) {
  if (!condition) throw SyncAcceptanceFailure(code);
}

class SyncAcceptanceConfig {
  const SyncAcceptanceConfig({
    required this.runId,
    required this.sdkInt,
    required this.packageName,
    required this.role,
    required this.endpoint,
    required this.publicCertificatePem,
    required this.invite,
  });

  final String runId, packageName, role, endpoint, publicCertificatePem, invite;
  final int sdkInt;

  static SyncAcceptanceConfig parse(
    String raw, {
    required String compiledPackage,
    required String compiledBuild,
    bool publicOnly = false,
  }) {
    final value = jsonDecode(raw);
    syncAcceptanceCheck(value is Map<String, dynamic>, 'invalid_config');
    final v = value as Map<String, dynamic>;
    final role = v['role'];
    final package = v['packageName'];
    final run = v['runId'];
    final sdk = v['sdkInt'];
    final invite = v['invite'];
    final certificate = v['publicCertificatePem'];
    final endpoint = v['endpoint'];
    syncAcceptanceCheck(
      v['schemaVersion'] is int &&
          v['schemaVersion'] == syncAcceptanceSchema &&
          (role == 'A' || role == 'B') &&
          run is String &&
          RegExp(r'^[a-f0-9]{32}$').hasMatch(run) &&
          sdk is int &&
          sdk >= 24 &&
          sdk < 1000 &&
          package == compiledPackage &&
          package ==
              'com.haoxiguan.haoxiguan.syncacceptance.${(role as String).toLowerCase()}' &&
          compiledBuild == (role == 'A' ? '11001' : '11002') &&
          (publicOnly
              ? invite == null
              : invite is String &&
                    RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(invite)) &&
          certificate is String &&
          certificate.length <= 128 * 1024 &&
          RegExp(
            r'^-----BEGIN CERTIFICATE-----\r?\n[A-Za-z0-9+/=\r\n]+-----END CERTIFICATE-----\r?\n?$',
          ).hasMatch(certificate) &&
          endpoint is String,
      'invalid_config',
    );
    final uri = Uri.tryParse(endpoint as String);
    syncAcceptanceCheck(
      uri != null &&
          uri.scheme == 'https' &&
          uri.host == 'localhost' &&
          uri.hasPort &&
          uri.port >= 1024 &&
          uri.port <= 65535 &&
          uri.userInfo.isEmpty &&
          !uri.hasQuery &&
          !uri.hasFragment &&
          (uri.path.isEmpty || uri.path == '/'),
      'invalid_loopback_endpoint',
    );
    return SyncAcceptanceConfig(
      runId: run as String,
      sdkInt: sdk as int,
      packageName: package as String,
      role: role as String,
      endpoint: endpoint,
      publicCertificatePem: certificate as String,
      invite: publicOnly ? '' : invite as String,
    );
  }

  Map<String, Object?> get publicCheckpoint => {
    'schemaVersion': syncAcceptanceSchema,
    'runId': runId,
    'sdkInt': sdkInt,
    'packageName': packageName,
    'role': role,
    'endpoint': endpoint,
    'publicCertificatePem': publicCertificatePem,
  };
}

/// A prior run, stage, package or SDK can never release a current barrier.
bool syncAcceptanceControl(
  String raw, {
  required SyncAcceptanceConfig config,
  required String stage,
  required String launchId,
  required int reportSequence,
}) {
  final v = jsonDecode(raw);
  return v is Map &&
      v['schemaVersion'] is int &&
      v['schemaVersion'] == syncAcceptanceSchema &&
      v['runId'] == config.runId &&
      v['packageName'] == config.packageName &&
      v['sdkInt'] is int &&
      v['sdkInt'] == config.sdkInt &&
      v['stage'] == stage &&
      v['launchId'] == launchId &&
      v['reportSequence'] is int &&
      v['reportSequence'] == reportSequence;
}

/// Go cursor(n) is raw base64url of canonical ASCII strconv.FormatInt(n, 10).
/// Preserve that wire contract before converting a watermark to report JSON.
/// Alternate encodings, signs, whitespace, decimal points and overflow fail.
int syncAcceptanceHighWater(Object? wire) {
  syncAcceptanceCheck(
    wire is String && RegExp(r'^[A-Za-z0-9_-]{2,26}$').hasMatch(wire),
    'invalid_remote_watermark',
  );
  try {
    final bytes = base64Url.decode(base64Url.normalize(wire as String));
    syncAcceptanceCheck(
      base64Url.encode(bytes).replaceAll('=', '') == wire,
      'invalid_remote_watermark',
    );
    final decimal = ascii.decode(bytes);
    final parsed = int.tryParse(decimal);
    syncAcceptanceCheck(
      RegExp(r'^(0|[1-9][0-9]{0,18})$').hasMatch(decimal) &&
          parsed != null &&
          parsed >= 0 &&
          parsed <= 9223372036854775807,
      'invalid_remote_watermark',
    );
    return parsed!;
  } on FormatException {
    throw const SyncAcceptanceFailure('invalid_remote_watermark');
  }
}

String syncAcceptanceCanonical(Object? value) {
  Object? order(Object? v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: order(v[key])};
    }
    if (v is List) return v.map(order).toList();
    return v;
  }

  return jsonEncode(order(value));
}
