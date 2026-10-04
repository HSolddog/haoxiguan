import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/snapshot_codec.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/services/sync_crypto.dart';
import 'package:haoxiguan/services/sync_entities.dart';

void main() {
  const device = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  late String snapshot;
  late EntityMap entities;
  setUp(() {
    final habit = Habit(
      id: 'compat-habit',
      title: '阅读',
      emoji: '📖',
      colorValue: 0xff223344,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
      createdAt: DateTime(2026, 10, 2),
      notes: const {'2026-10-02': '原备注'},
    );
    snapshot = jsonEncode({
      ...SnapshotCodec.decode(SnapshotCodec.empty()),
      'habits': [
        habit.copyWith(plans: [habit.initialPlan]).toJson(),
      ],
    });
    entities = SyncEntities.encode(snapshot);
  });

  test(
    'source annotations stay inside v1 habit extensions and preserve all facts',
    () {
      final before = SyncEntities.encodeFacts(snapshot);
      final notesBefore = {
        for (final e in entities.entries)
          if (e.key.startsWith('n/')) e.key: e.value,
      };
      SyncOrigins.stamp(entities, {}, entities.keys.toList(), device);
      final restored = SyncEntities.assemble(snapshot, entities);
      expect(SyncEntities.encodeFacts(restored), before);
      // Habit.fromJson/toJson's unknown-extension round trip is the legacy v1
      // reader path; neither note/plan payload cardinality nor logical IDs change.
      final encodedAgain = SyncEntities.encode(restored);
      expect(
        encodedAgain['h/compat-habit'][SyncOrigins.field],
        entities['h/compat-habit'][SyncOrigins.field],
      );
      for (final entry in notesBefore.entries) {
        expect(encodedAgain[entry.key], entry.value);
        expect((encodedAgain[entry.key] as Map).length, 3);
        expect(SyncOrigins.sources(encodedAgain, entry.key, entry.value), [
          device,
        ]);
      }
      expect(encodedAgain.keys.toSet(), before.keys.toSet());
    },
  );

  test(
    'legacy content edit retaining extensions cannot inherit stale source label',
    () {
      SyncOrigins.stamp(entities, {}, entities.keys.toList(), device);
      final roundTrip = SnapshotCodec.decode(
        SyncEntities.assemble(snapshot, entities),
      );
      final habit = Habit.fromJson(
        (roundTrip['habits'] as List).single.cast<String, Object?>(),
      );
      final legacyEdited = habit.copyWith(
        notes: const {'2026-10-02': '旧客户端新编辑'},
      );
      final edited = SyncEntities.encode(
        jsonEncode({
          ...roundTrip,
          'habits': [legacyEdited.toJson()],
        }),
      );
      final noteKey = edited.keys.singleWhere((key) => key.startsWith('n/'));
      expect(legacyEdited.extensions[SyncOrigins.field], isNotNull);
      expect(SyncOrigins.sources(edited, noteKey, edited[noteKey]), isEmpty);
    },
  );

  test(
    'strict existing two-field crypto wrapper accepts source-bearing habit',
    () async {
      SyncOrigins.stamp(entities, {}, entities.keys.toList(), device);
      final keys = await SyncKeyring.create('v' * 32);
      try {
        final context = SyncObjectContext(
          vault: keys.vault,
          epoch: 'e' * 32,
          entityId: keys.opaqueId('h/compat-habit'),
          baseRevision: 0,
          deleted: false,
        );
        final encrypted = await SyncCrypto.encrypt(
          keys,
          context,
          'h/compat-habit',
          entities['h/compat-habit'],
        );
        final decoded = await SyncCrypto.decrypt(keys, context, encrypted);
        expect(decoded.payload, entities['h/compat-habit']);
        // Source labels have the same AEAD authentication as the habit; the outer
        // four-field envelope and inner two-field wrapper remain unchanged.
        final envelope =
            jsonDecode(utf8.decode(base64Decode(encrypted)))
                as Map<String, dynamic>;
        expect(envelope.length, 4);
        final ciphertext = base64Decode(envelope['ciphertext'] as String);
        ciphertext[ciphertext.length ~/ 2] ^= 1;
        envelope['ciphertext'] = base64Encode(ciphertext);
        await expectLater(
          SyncCrypto.decrypt(
            keys,
            context,
            base64Encode(utf8.encode(jsonEncode(envelope))),
          ),
          throwsFormatException,
        );
      } finally {
        keys.dispose();
      }
    },
  );

  test(
    'bounded annotations stay within the existing object ceiling and missing labels stay unknown',
    () {
      for (var i = 0; i < 180; i++) {
        final date = DateTime.utc(
          2026,
          1,
          1 + i,
        ).toIso8601String().substring(0, 10);
        final key =
            'n/${base64UrlEncode(utf8.encode(jsonEncode(['compat-habit', date])))}';
        entities[key] = {
          'habitId': 'compat-habit',
          'date': date,
          'text': '合成备注 $i',
        };
      }
      SyncOrigins.stamp(entities, {}, entities.keys.toList(), device);
      final habit = entities['h/compat-habit'] as Map;
      expect(
        (habit[SyncOrigins.field] as List).length,
        SyncOrigins.maxDeclarations,
      );
      expect(
        utf8
            .encode(
              jsonEncode({'logicalId': 'h/compat-habit', 'payload': habit}),
            )
            .length,
        lessThanOrEqualTo(SyncCrypto.maxPlaintextBytes),
      );
      expect(
        SyncEntities.sameFacts(
          'h/compat-habit',
          habit,
          Map<String, dynamic>.from(habit)..remove(SyncOrigins.field),
        ),
        true,
      );
      expect(SyncOrigins.sources({}, 'h/missing', {'id': 'missing'}), isEmpty);
    },
  );
}
