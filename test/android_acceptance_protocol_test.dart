import 'package:flutter_test/flutter_test.dart';

import '../tools/android_acceptance.dart' show controlApiLevel;

void main() {
  int? read(String raw) => controlApiLevel(
    raw,
    runId: 'fresh-run',
    stage: 'awaitingNotificationDeny',
  );

  test('settings acknowledgement belongs to the exact current run and stage', () {
    expect(
      read(
        '{"runId":"fresh-run","stage":"awaitingNotificationDeny","apiLevel":35}',
      ),
      35,
    );
    expect(
      read(
        '{"runId":"old-run","stage":"awaitingNotificationDeny","apiLevel":35}',
      ),
      isNull,
    );
    expect(
      read(
        '{"runId":"fresh-run","stage":"awaitingNotificationGrant","apiLevel":35}',
      ),
      isNull,
    );
  });

  test('Android 24 acknowledgement is explicit; invalid SDK is not completion', () {
    expect(
      read(
        '{"runId":"fresh-run","stage":"awaitingNotificationDeny","apiLevel":24}',
      ),
      24,
    );
    for (final api in ['null', '"35"', 'true', '23', '1000', '35.0']) {
      expect(
        read(
          '{"runId":"fresh-run","stage":"awaitingNotificationDeny","apiLevel":$api}',
        ),
        isNull,
      );
    }
  });

  test(
    'empty, unrelated or partially written controls cannot authorize a stage',
    () {
      for (final raw in ['null', '[]', '{}', '{"status":"passed"}']) {
        expect(read(raw), isNull);
      }
      expect(() => read('{"runId":"fresh-run"'), throwsFormatException);
    },
  );
}
