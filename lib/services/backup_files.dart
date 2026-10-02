import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'backup_codec.dart';

abstract interface class BackupFiles {
  Future<bool> save(Uint8List bytes, String name);
  Future<Uint8List?> open();
}

class PlatformBackupFiles implements BackupFiles {
  static const _channel = MethodChannel('com.haoxiguan.haoxiguan/documents');

  @override
  Future<bool> save(Uint8List bytes, String name) async {
    if (bytes.length > BackupCodec.maxFileBytes) {
      throw const FormatException('文件超过 50 MiB');
    }
    if (Platform.isAndroid) {
      final directory = await getTemporaryDirectory();
      final source = File('${directory.path}/export-${const Uuid().v4()}.tmp');
      try {
        await source.writeAsBytes(bytes, flush: true);
        return await _channel.invokeMethod<bool>('save', {
              'sourcePath': source.path,
              'name': name,
              'sha256': sha256.convert(bytes).toString(),
            }) ??
            false;
      } finally {
        if (await source.exists()) await source.delete();
      }
    }
    // The platform port is shared; iOS document export is a later release gate.
    if (Platform.isIOS) throw UnsupportedError('iOS 文件导出尚未发布');
    final destination = await getSaveLocation(suggestedName: name);
    if (destination == null) return false;
    final file = File(destination.path);
    await file.writeAsBytes(bytes, flush: true);
    if (sha256.convert(await file.readAsBytes()).toString() !=
        sha256.convert(bytes).toString()) {
      throw const FileSystemException('文件读回校验失败');
    }
    return true;
  }

  @override
  Future<Uint8List?> open() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '好习惯备份',
          extensions: ['hgb', 'json'],
          uniformTypeIdentifiers: ['public.data'],
        ),
      ],
    );
    if (file == null) return null;
    if (await file.length() > BackupCodec.maxFileBytes) {
      throw const FormatException('文件超过 50 MiB');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > BackupCodec.maxFileBytes) {
      throw const FormatException('文件超过 50 MiB');
    }
    return bytes;
  }
}
