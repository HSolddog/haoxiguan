# 好习惯 · Haoxiguan

一个离线优先、MIT 开源的习惯记录应用。无需账号、服务器或备份配置即可使用；记录先在设备本地事务提交，联网能力由用户自行选择。

An MIT-licensed, offline-first habit tracker. Your records commit locally; encrypted backups and a self-hosted sync service are optional.

当前分支为 Android 开发验收版本 1.2.0+6，Flutter 共用领域与数据层；iOS 尚未制作和验收。完整设计与实施证据从 [docs](docs/README.md) 开始，最新范围见[实施进度](docs/实施进度.md)和[逐项设计验收矩阵](docs/设计验收矩阵-2026-10-03.md)。

## 当前能力

- 完成、定点计数、手动时长；明确的快捷增量、安全撤销、补记、更正、每日备注和未保存退出保护。
- 每天、固定星期、每周/每月若干天；计划历史、暂停、休息、归档和回收站。
- 可选历史开始日和影响预览；日/周/月分别回顾已结算周期、实际目标和进行中周期；通知权限和渠道故障分开说明；旧奖励数据保留为只读。
- SQLite/Drift WAL + FULL 事务，提交后确认；旧数据幂等迁移、原文保护、损坏时停止写入而不清空。
- Argon2id + XChaCha20-Poly1305 加密文件备份、读回验证、含时间/备注/日期范围的恢复预览；JSON 与含分类/习惯/计划/记录/备注五表的 CSV ZIP 导出；跟随系统主题。
- 自选 HTTPS WebDAV，不可变加密快照、后台尝试、保留清理和换机恢复。
- 实验性自有同步服务：Go + SQLite、不透明密文、设备邀请、加密恢复文件、手动同步和冲突处理。支持维护式新空间密钥轮换；规模和完整原生联网门禁仍待完成，见[同步实现与验收](docs/同步实现与验收.md)。

## 开发与验证

固定 Flutter 3.44.6（Dart 3.12.2）、JDK 17，提交中包含依赖锁文件。服务端使用 Go 1.27.1。

```sh
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test tools
flutter analyze
flutter test
flutter build apk --debug
```

CI 构建 Debug APK，并在 API 24/35/36 的 KVM 模拟器上验证原生存储、加密、Keystore、强停重开及同签名覆盖升级。[验收记录](docs/验收记录/2026-10-02.md)区分已通过证据与未完成的系统/真机项目。需要真实服务的 WebDAV/Go 集成测试默认跳过，必须按文档显式运行。

服务端构建、邀请和恢复说明见 [server](server/README.md)。单机应用的启动与保存不依赖服务。

## 数据、升级与发布

详见[隐私与数据说明](docs/隐私与数据说明.md)。数据保存于应用私有 SQLite；Android 系统自动备份/设备转移已排除业务数据与密钥，避免不成套复制。应用不含广告或分析 SDK。只有启用 WebDAV 或自有同步后才联系用户选择的服务；对方仍可见连接及密文大小等元数据。文件恢复先保护本地内容并创建新空间，旧同步配置不会自动覆盖远端。

本地数据库依赖操作系统保护，未宣称应用级数据库加密。加密备份密码和同步恢复文件必须由用户保管；账号恢复无法替代内容密钥。

正常升级必须保持 applicationId、签名连续性、递增 versionCode 和兼容迁移。现有真实安装的证书尚需核对；CI 临时调试签名不能替代正式升级链。不得以卸载重装当作无损升级。历史 Windows 内测构建脚本在 `scripts/build_release_apk.ps1`，正式发布条件见[版本与数据升级](docs/版本与数据升级.md)和[执行计划](docs/执行计划.md)。

## 参与与许可证

阅读[贡献指南](CONTRIBUTING.md)后提交问题或改进。应用与服务器均采用 [MIT](LICENSE)；第三方依赖遵循各自许可证。允许自部署、商业衍生和使用同套开源代码提供托管服务。
