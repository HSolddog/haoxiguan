# 逻辑快照与业务备份 JSON Schema

这组 Draft 2020-12 契约落实冻结设计《数据与同步规范》L160 的机器可读格式交付，描述当前逻辑格式 7 与业务备份格式 1；没有改变运行时数据、升级路径或密码学实现。

| Schema | 对应的真实数据 | 实现来源 |
| --- | --- | --- |
| [logical-snapshot-v7](logical-snapshot-v7.schema.json) | `HabitController.exportJson()` 的裸快照；最小空快照为 `{"version":7,"habits":[]}` | [Controller](../../lib/state/habit_controller.dart)、[SnapshotCodec](../../lib/data/snapshot_codec.dart) |
| [backup-encrypted-v1](backup-encrypted-v1.schema.json) | `.hgb` 的七字段加密 JSON 外层 | [BackupCodec](../../lib/services/backup_codec.dart) |
| [backup-plaintext-v1](backup-plaintext-v1.schema.json) | 当前明文导出的五字段 wrapper：`format`、`formatVersion`、`encrypted:false`、`createdAtUtc`、`data` | [DataScreen](../../lib/ui/data_screen.dart) |
| [backup-decrypted-v1](backup-decrypted-v1.schema.json) | 通过认证解密后得到的 `manifest` 与 `data`；不是额外文件格式 | [BackupCodec](../../lib/services/backup_codec.dart) |

`$id` 使用仓库文件的稳定标识，测试把四份文件注册到本地 registry；不会通过 `$ref` 访问网络，也不表示工作分支已经合并或正式发布。

## 兼容边界

这不是全部兼容输入的穷举。旧版 version 1–6 仍由版本分派、领域迁移与原文保护处理，不应用格式 7 Schema 将旧数据判为无法迁移。当前明文导出总有创建时间；旧文件可以没有时间，运行时如实显示未知。解密内容 Schema 保留运行时支持的缺失／null 创建时间及未知 manifest 字段。

根快照、习惯与分类的未知字段作为原层级的扩展保留，使用 `additionalProperties:true`；没有新建嵌套 `extensions` 容器。计划和记录的当前 `toJson()` 只输出已知字段，因此它们的导出契约关闭额外属性；这不等于兼容读取器会拒绝所有未知字段。`completions` 是完成型记录的兼容投影，不能再当独立行为累计。

旧 seed／微秒 ID、旧奖励配置和余额、`legacyInferred`、`unknownLegacy` 以及无时区的历史录入时间均可表达；不要求旧 ID 改成 UUID。新生成的创建时间使用 UTC 文本。`recordedAtUtc`、`legacyTimestamp` 和兼容 `completions` 可能保留旧文本的空格、时区偏移或无时区形式，Schema 只约束字符串结构，真实日期与 UTC 时刻的解析须由运行时复核；不因为字段名含 UTC 就要求旧文本以 `Z` 结尾。

本机保存／完整导出与外部导入采用不同边界。逻辑 Schema 描述现有存储兼容范围，标题上界为 1000，备注不在此截断；不能据此绕过外部导入的 80／2000 限制，也不能用外部输入限额删改旧本机事实。导入是否接受必须再由相应运行时入口判断。

## Schema 不代替的检查

JSON Schema `format` 在默认 Draft 2020-12 方言中主要是注释，`contentEncoding` 也不会自动解码、验证摘要或执行 AEAD。[官方验证规范](https://json-schema.org/draft/2020-12/json-schema-validation)区分这些能力；本测试显式启用日期／日期时间 `FormatChecker`，标准 Base64 的字符、padding 和尾部零位另用 `pattern` 约束。

以下仍须由文件读取器、解密器、迁移器或业务仓储检查：50 MiB 原始文件／36 MiB 明文上限、Base64 解码后的精确长度、SHA-256 与密文匹配、AAD／AEAD／KDF 安全、清单数量与版本相等、全局 ID 唯一、计划时间关系、记录与父习惯关系、完成型量值固定为一／非计数型 scale 为一／周周期上界等跨字段规则、日期／时区语义、提交和恢复保护。密文 `maxLength` 只是编码字符数的粗上界，不保证恰好符合解码字节上限。

JSON Schema `integer` 是数学整数，可接受 `7.0`；Dart 解码后的 `is int` 检查更严格。Schema 字符串 `maxLength` 数 Unicode code points，Dart `String.length` 数 UTF-16 code units，非 BMP 字符时也不完全等价。Calendar `format` 没有启用时不能仅靠正则证明真实日期存在。Schema 校验成功只证明已声明的结构约束，不证明文件可解密或完整业务数据有效。

## 样例与独立验证

[examples](examples) 的四份公开合成样例由 [生成工具](../../tools/generate_schema_examples_test.dart)通过实际 Controller、明文 DataScreen 按钮、BackupCodec 和 libsodium 解密字节生成；文件选择／状态存储使用主机替身，不冒称 SAF 或 Android 系统验证。样例包含旧版迁移、三种记录、分类、计划与备注，没有真实账号、令牌、密码或密钥。加密样例使用工具中明确标注的公开合成口令；随机 UUID、创建时间、salt 和 nonce 使重新生成的字节变化，不是确定性 golden。

在仓库根目录、固定 Flutter 工具链与原生 libsodium 可用时，显式重新生成：

```text
flutter test --no-pub tools/generate_schema_examples_test.dart --reporter expanded
```

普通 `flutter test` 不执行该 `tools/` 入口，不自动重写样例。独立 Python 校验器按 [测试依赖](../../tools/json-schema-test-requirements.txt)安装到任务／CI 虚拟环境；不修改应用依赖。

```text
python -m pip install -r tools/json-schema-test-requirements.txt
python tools/test_json_schemas.py
```

[Python 检查](../../tools/test_json_schemas.py)使用官方 `jsonschema` 的 Draft202012Validator、显式 FormatChecker 与禁止远程读取的 registry，验证 meta-schema、真实导出、现有跨语言公开向量、未知扩展／旧时间的正例及错误结构／类型／版本／KDF／Base64 的反例；另确认格式通过不等于摘要、清单一致性或业务约束通过。已知答案和篡改由 [backup_codec_test](../../test/backup_codec_test.dart)验证，版本迁移由 [schema_upgrade_test](../../test/schema_upgrade_test.dart)验证，领域统计期望见 [domain_rules_test](../../test/domain_rules_test.dart)及 [history_design_test](../../test/history_design_test.dart)。

这次交付只发布上述 A 业务快照／备份契约。`.hgr` 恢复材料、密钥包、同步 AEAD 包装和解密实体尚未在这里发布独立 JSON Schema；它们现有的精确实现说明见[同步实现与验收](../同步实现与验收.md)，服务接口见 [OpenAPI](../../server/openapi.yaml)，跨语言向量见 [sync-v1-vector](../../test/fixtures/sync-v1-vector.json)。不能把这些已有证据或本目录写成全部协议机器 Schema 已完成。
