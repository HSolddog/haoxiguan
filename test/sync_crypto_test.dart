import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/services/sync_crypto.dart';

void main() {
  late SyncKeyring keys;
  const logical = 'records:one-record';
  late SyncObjectContext context;
  setUp(() async {
    keys = await SyncKeyring.create('synthetic-vault');
    context = SyncObjectContext(
      vault: keys.vault,
      epoch: 'epoch-1',
      entityId: keys.opaqueId(logical),
      baseRevision: 0,
      deleted: false,
    );
  });
  tearDown(() => keys.dispose());
  test('独立 Python 向量验证寻址、AAD 编码与解密', () async {
    final v =
        jsonDecode(
              await File('test/fixtures/sync-v1-vector.json').readAsString(),
            )
            as Map<String, dynamic>;
    final vectorKeys = SyncKeyring.fromJson(v['keys'] as Map<String, dynamic>);
    final c = v['context'] as Map<String, dynamic>;
    final ctx = SyncObjectContext(
      vault: c['vault'],
      epoch: c['epoch'],
      entityId: c['entityId'],
      baseRevision: c['baseRevision'],
      deleted: c['deleted'],
    );
    expect(vectorKeys.opaqueId(v['logicalId']), c['entityId']);
    expect(
      ctx.aad(1).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      v['aadHex'],
    );
    final result = await SyncCrypto.decrypt(vectorKeys, ctx, v['ciphertext']);
    expect(result.logicalId, v['logicalId']);
    expect(result.payload, v['payload']);
    vectorKeys.dispose();
  });
  test('同一事实寻址稳定，内容密钥独立且每次加密 nonce 不同', () async {
    final a = await SyncCrypto.encrypt(keys, context, logical, {'value': 1000});
    final b = await SyncCrypto.encrypt(keys, context, logical, {'value': 1000});
    expect(a, isNot(b));
    expect((await SyncCrypto.decrypt(keys, context, a)).payload, {
      'value': 1000,
    });
    final restored = SyncKeyring.fromJson(keys.toJson());
    expect(restored.opaqueId(logical), context.entityId);
    restored.dispose();
    final other = await SyncKeyring.create(keys.vault);
    expect(other.opaqueId(logical), isNot(context.entityId));
    other.dispose();
  });
  test('空间、epoch、对象、基线和删除标记任一被改都拒绝', () async {
    final encrypted = await SyncCrypto.encrypt(keys, context, logical, {
      'value': 1000,
    });
    for (final changed in [
      SyncObjectContext(
        vault: 'other',
        epoch: context.epoch,
        entityId: context.entityId,
        baseRevision: 0,
        deleted: false,
      ),
      SyncObjectContext(
        vault: keys.vault,
        epoch: 'other',
        entityId: context.entityId,
        baseRevision: 0,
        deleted: false,
      ),
      SyncObjectContext(
        vault: keys.vault,
        epoch: context.epoch,
        entityId: keys.opaqueId('other'),
        baseRevision: 0,
        deleted: false,
      ),
      SyncObjectContext(
        vault: keys.vault,
        epoch: context.epoch,
        entityId: context.entityId,
        baseRevision: 1,
        deleted: false,
      ),
      SyncObjectContext(
        vault: keys.vault,
        epoch: context.epoch,
        entityId: context.entityId,
        baseRevision: 0,
        deleted: true,
      ),
    ]) {
      await expectLater(
        SyncCrypto.decrypt(keys, changed, encrypted),
        throwsFormatException,
      );
    }
  });
  test('密文和密钥版本篡改拒绝，缺少轮换密钥显式提示', () async {
    final encrypted = await SyncCrypto.encrypt(keys, context, logical, {
      'note': 'private',
    });
    final envelope =
        jsonDecode(utf8.decode(base64Decode(encrypted)))
            as Map<String, dynamic>;
    envelope['generation'] = 2;
    await expectLater(
      SyncCrypto.decrypt(
        keys,
        context,
        base64Encode(utf8.encode(jsonEncode(envelope))),
      ),
      throwsFormatException,
    );
    envelope['generation'] = 1;
    final cipher = base64Decode(envelope['ciphertext']);
    cipher[0] ^= 1;
    envelope['ciphertext'] = base64Encode(cipher);
    await expectLater(
      SyncCrypto.decrypt(
        keys,
        context,
        base64Encode(utf8.encode(jsonEncode(envelope))),
      ),
      throwsFormatException,
    );
  });
  test('超限和错误逻辑身份在加密前拒绝', () async {
    await expectLater(
      SyncCrypto.encrypt(
        keys,
        context,
        logical,
        'x' * (SyncCrypto.maxPlaintextBytes + 1),
      ),
      throwsFormatException,
    );
    await expectLater(
      SyncCrypto.encrypt(keys, context, 'other', {}),
      throwsFormatException,
    );
  });
}
