# 逻辑快照、业务备份与同步 JSON Schema

这组 Draft 2020-12 契约落实冻结设计《数据与同步规范》L160 的机器可读格式交付，描述当前逻辑格式 7、业务备份格式 1 与同步加密／恢复格式 1；没有改变运行时数据、升级路径或密码学实现。

| Schema | 对应的真实数据 | 实现来源 |
| --- | --- | --- |
| [logical-snapshot-v7](logical-snapshot-v7.schema.json) | `HabitController.exportJson()` 的裸快照；最小空快照为 `{"version":7,"habits":[]}` | [Controller](../../lib/state/habit_controller.dart)、[SnapshotCodec](../../lib/data/snapshot_codec.dart) |
| [backup-encrypted-v1](backup-encrypted-v1.schema.json) | `.hgb` 的七字段加密 JSON 外层 | [BackupCodec](../../lib/services/backup_codec.dart) |
| [backup-plaintext-v1](backup-plaintext-v1.schema.json) | 当前明文导出的五字段 wrapper：`format`、`formatVersion`、`encrypted:false`、`createdAtUtc`、`data` | [DataScreen](../../lib/ui/data_screen.dart) |
| [backup-decrypted-v1](backup-decrypted-v1.schema.json) | 通过认证解密后得到的 `manifest` 与 `data`；不是额外文件格式 | [BackupCodec](../../lib/services/backup_codec.dart) |
| [sync-recovery-v1](sync-recovery-v1.schema.json) | `.hgr` 的九字段加密恢复材料外层；与业务备份不同 | [SyncRecoveryCodec](../../lib/services/sync_recovery.dart) |
| [sync-keyring-v1](sync-keyring-v1.schema.json) | `.hgr` 认证解密后的六字段密钥包，含独立 ID 密钥和各代内容密钥 | [SyncKeyring](../../lib/services/sync_crypto.dart) |
| [sync-encrypted-object-v1](sync-encrypted-object-v1.schema.json) | HTTP `ciphertext` 经过 Base64／UTF-8 解码后的 `v`、`generation`、`nonce`、`ciphertext`；`$defs/wireString` 描述外层传输串 | [SyncCrypto](../../lib/services/sync_crypto.dart) |
| [sync-decrypted-object-v1](sync-decrypted-object-v1.schema.json) | AEAD 明文的 `logicalId`／`payload`；`$defs/entity` 描述当前 h/r/p/n 业务实体及 null 删除候选，`$defs/context` 描述 AAD 输入 | [SyncCrypto](../../lib/services/sync_crypto.dart)、[SyncEntities](../../lib/services/sync_entities.dart) |

`$id` 使用仓库文件的稳定标识，测试把八份文件注册到本地 registry；不会通过 `$ref` 访问网络，也不表示工作分支已经合并或正式发布。

HTTP capabilities、认证、设备、push／pull／bootstrap 等请求和响应继续使用 [OpenAPI 3.1](../../server/openapi.yaml) 的机器契约，不复制为另一套定义。同步的客户端密文包装、实体明文和恢复密钥此前未由该 HTTP 契约表达，本目录补齐这些层。

## 兼容边界

这不是全部兼容输入的穷举。旧版 version 1–6 仍由版本分派、领域迁移与原文保护处理，不应用格式 7 Schema 将旧数据判为无法迁移。当前明文导出总有创建时间；旧文件可以没有时间，运行时如实显示未知。解密内容 Schema 保留运行时支持的缺失／null 创建时间及未知 manifest 字段。

根快照、习惯与分类的未知字段作为原层级的扩展保留，使用 `additionalProperties:true`；没有新建嵌套 `extensions` 容器。计划和记录的当前 `toJson()` 只输出已知字段，因此它们的导出契约关闭额外属性；这不等于兼容读取器会拒绝所有未知字段。`completions` 是完成型记录的兼容投影，不能再当独立行为累计。

旧 seed／微秒 ID、旧奖励配置和余额、`legacyInferred`、`unknownLegacy` 以及无时区的历史录入时间均可表达；不要求旧 ID 改成 UUID。新生成的创建时间使用 UTC 文本。`recordedAtUtc`、`legacyTimestamp` 和兼容 `completions` 可能保留旧文本的空格、时区偏移或无时区形式，Schema 只约束字符串结构，真实日期与 UTC 时刻的解析须由运行时复核；不因为字段名含 UTC 就要求旧文本以 `Z` 结尾。

本机保存／完整导出与外部导入采用不同边界。逻辑 Schema 描述现有存储兼容范围，标题上界为 1000，备注不在此截断；不能据此绕过外部导入的 80／2000 限制，也不能用外部输入限额删改旧本机事实。导入是否接受必须再由相应运行时入口判断。

同步实体 Schema 同样描述现有序列化结构，复用快照的记录／计划／分类及习惯字段，不把可完整导出的旧本机事实截断。普通直接导入由 `decodeImport`／Controller 校验 80／2000，认证后的远端同步输入由 `SyncEngine._receive` 检查相同边界。用户备份恢复入口单独调用 `BackupPreview.forRestore`：完整校验已支持结构后列明超限标题／备注，默认不勾选；用户明确选择完整保留历史文本后，才经 `restoreCompatibleBackup` 使用原保护事务恢复全部原文，今后编辑仍按当前限额。此例外协调原 P44 输入限制与 P9/F08/V76 完整恢复承诺，不放宽版本、结构、日期、ID、文件大小或加密认证。格式版本和 manifest 不证明旧版来源，升级后的新格式导出也可能含历史文本。

`sync-decrypted-object-v1` 的根层是通用加密器真实接受的二字段包装；现有跨语言向量的 `records:synthetic-record` 是通用逻辑 ID，并非生产实体。需要验证当前业务实体时应引用 `sync-decrypted-object-v1.schema.json#/$defs/entity`：习惯 h/ 不含 `entries`／`plans`／`notes`／`completions`，记录 r/、计划 p/ 和备注 n/ 各自独立寻址。h/ 保留未知习惯字段；记录和计划的 canonical `data` 及各子对象 wrapper 关闭额外字段。删除候选的 payload 为 null；其逻辑 ID 和删除上下文仍需运行时一致。

## Schema 不代替的检查

JSON Schema `format` 在默认 Draft 2020-12 方言中主要是注释，`contentEncoding` 也不会自动解码、验证摘要或执行 AEAD。[官方验证规范](https://json-schema.org/draft/2020-12/json-schema-validation)区分这些能力；本测试显式启用日期／日期时间 `FormatChecker`，标准 Base64 的字符、padding 和尾部零位另用 `pattern` 约束。

以下仍须由文件读取器、解密器、迁移器或业务仓储检查：50 MiB 原始备份／36 MiB 明文、128 KiB 原始恢复材料／64 KiB 恢复明文、128 KiB 同步明文等字节上限、Base64 解码、SHA-256 与密文匹配、AAD／AEAD／KDF 安全、清单数量与版本相等、全局 ID 唯一、计划时间关系、记录与父习惯关系、完成型量值固定为一／非计数型 scale 为一／周周期上界等跨字段规则、日期／时区语义、提交和恢复保护。

备份 `.hgb` 密文 `maxLength` 只是编码字符数的粗上界，不保证恰好符合解码字节上限。`.hgr` 的 canonical Base64 通过最大长度处的 padding 条件表达 16–65552 密文字节范围；同步密文上界 131088 可被 3 整除，编码最大长度 174784 可精确表达。即使这两个结构界限精确，文件总字节、解密明文长度和认证结果仍须另验。

同步 `wireString` 的 `contentSchema`／`contentEncoding` 仅描述 Base64 包含哪种 JSON，不自动执行解码或递归校验。工具显式解码真实 wire 样例及公开向量再验证 envelope。密钥包的 `currentGeneration` 必须存在于 `contentKeys`、加密代次必须有相应内容密钥、opaque ID 必须符合 HMAC 派生、逻辑 ID 与 payload／父对象必须一致、备注地址必须由习惯和日期规范派生；这些动态关系和 AAD 精确 JSON 数组字节编码保留给运行时与加密向量。

JSON Schema `integer` 是数学整数，可接受 `7.0`；Dart 解码后的 `is int` 检查更严格。Schema 字符串 `maxLength` 数 Unicode code points，Dart `String.length` 数 UTF-16 code units，非 BMP 字符时也不完全等价。Calendar `format` 没有启用时不能仅靠正则证明真实日期存在。Schema 校验成功只证明已声明的结构约束，不证明文件可解密或完整业务数据有效。

## 样例与独立验证

[examples](examples) 的四份业务备份公开合成样例由 [备份生成工具](../../tools/generate_schema_examples_test.dart)通过实际 Controller、明文 DataScreen 按钮、BackupCodec 和 libsodium 解密字节生成；文件选择／状态存储使用主机替身，不冒称 SAF 或 Android 系统验证。样例包含旧版迁移、三种记录、分类、计划与备注，没有真实账号、令牌、密码或密钥。加密样例使用工具中明确标注的公开合成口令；随机 UUID、创建时间、salt 和 nonce 使重新生成的字节变化，不是确定性 golden。

[同步生成工具](../../tools/generate_sync_schema_examples_test.dart)只读取既有合成快照和公开加密向量，调用真实 SyncEntities、SyncCrypto、SyncRecoveryCodec 生成四份同步主样例，另保存全部业务实体及四类 null 删除候选、AAD context 和实际 HTTP wire 串。密钥来自公开固定测试字节，并包含原有格式的第二代内容密钥；从未读取用户安全存储或认证材料。工具验证真实加解密并捕获 libsodium 认证后的原始明文结构，不重写四份备份样例。

在仓库根目录、固定 Flutter 工具链与原生 libsodium 可用时，显式重新生成：

```text
flutter test --no-pub tools/generate_schema_examples_test.dart --reporter expanded
flutter test --no-pub tools/generate_sync_schema_examples_test.dart --reporter expanded
```

普通 `flutter test` 不执行该 `tools/` 入口，不自动重写样例。独立 Python 校验器按 [测试依赖](../../tools/json-schema-test-requirements.txt)安装到任务／CI 虚拟环境；不修改应用依赖。

```text
python -m pip install -r tools/json-schema-test-requirements.txt
python tools/test_json_schemas.py
```

[Python 检查](../../tools/test_json_schemas.py)使用官方 `jsonschema` 的 Draft202012Validator、显式 FormatChecker 与禁止远程读取的 registry，验证八份 meta-schema、真实导出／恢复／同步样例、现有跨语言公开向量、未知扩展／旧时间的正例及错误结构／类型／版本／KDF／Base64 的反例；覆盖 h/r/p/n 分离、删除候选、代次名称与 byte/padding 边界。另确认格式通过不等于摘要、清单一致性、密钥代次存在或业务身份关系通过。已知答案和篡改由 [backup_codec_test](../../test/backup_codec_test.dart)、[sync_crypto_test](../../test/sync_crypto_test.dart)及 [sync_recovery_test](../../test/sync_recovery_test.dart)验证，版本迁移由 [schema_upgrade_test](../../test/schema_upgrade_test.dart)验证，领域统计期望见 [domain_rules_test](../../test/domain_rules_test.dart)及 [history_design_test](../../test/history_design_test.dart)。

上述八份 Schema 与既有 OpenAPI 组成当前逻辑备份及 C 同步协议各 JSON 层的结构交付；确切实现说明见[同步实现与验收](../同步实现与验收.md)，跨语言向量见 [sync-v1-vector](../../test/fixtures/sync-v1-vector.json)。它们不新增 SQLite 内部表、设备私有设置或其他版本的文件格式，也不能据 Schema 通过宣称全部协议行为、密码学、Android 原生流程或正式发布门禁通过。
