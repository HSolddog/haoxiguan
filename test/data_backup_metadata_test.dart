import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/snapshot_codec.dart';
import 'package:haoxiguan/services/backup_codec.dart';
import 'package:haoxiguan/services/backup_preview.dart';

void main() {
  test(
    'authenticated backup creation time survives decryption for restore preview',
    () async {
      const password = 'test-only long random backup phrase';
      final snapshot = SnapshotCodec.empty();
      final before = DateTime.now().toUtc();
      final encrypted = await BackupCodec.encryptHere(snapshot, password);
      final after = DateTime.now().toUtc();
      final contents = await BackupCodec.decryptHereWithMetadata(
        encrypted,
        password,
      );
      expect(contents.snapshot, snapshot);
      expect(contents.createdAtUtc!.isUtc, isTrue);
      expect(contents.createdAtUtc!.isBefore(before), isFalse);
      expect(contents.createdAtUtc!.isAfter(after), isFalse);
      final preview = BackupPreview.fromSnapshot(
        contents.snapshot,
        createdAtUtc: contents.createdAtUtc,
      );
      expect(preview.createdAtUtc, contents.createdAtUtc);
      expect(preview.summary, contains('暂无记录或备注日期'));
      final isolated = await BackupCodec.decryptWithMetadata(
        encrypted,
        password,
      );
      expect(isolated.createdAtUtc, contents.createdAtUtc);
      expect(isolated.snapshot, snapshot);
      await expectLater(
        BackupCodec.decryptHereWithMetadata(encrypted, 'wrong password'),
        throwsFormatException,
      );
    },
  );
}
