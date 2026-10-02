# 贡献指南

欢迎通过 GitHub Issues 报告可复现的问题，或提交聚焦的 Pull Request。安全问题及私密材料按 [SECURITY.md](SECURITY.md) 处理。

## 固定开发环境

客户端固定 Flutter 3.44.6（commit ee80f08bbf97172ec030b8751ceab557177a34a6）、Dart 3.12.2、JDK 17。首次运行：

```sh
flutter pub get --enforce-lockfile
flutter run
```

提交前：

```sh
dart format --output=none --set-exit-if-changed lib test tools
flutter analyze
flutter test
flutter build apk --debug
```

服务端使用 Go 1.27.1；在 server 目录运行 `go test -race ./...`、`go vet ./...`，构建与隔离运维演练见 [server/README.md](server/README.md)。真实 HTTPS 互操作可从仓库根目录运行 `python3 tools/run_sync_integration.py`，只使用脚本新建的临时服务、证书和合成邀请，不需要生产服务。

CI 锁定第三方 Action 提交，产物仅使用临时 Debug 签名。正式 release 必须显式配置既有发布签名；不得为了安装测试包而指导旧用户卸载应用。

## 数据与协议改动

- 行为以 [产品规格](docs/产品规划.md) 和 [本地完整性](docs/本地数据完整性.md) 为准；协议改变同步更新精确格式、兼容性和测试向量。
- 数据格式改动提供独立旧 schema 夹具、事务失败回滚和重复打开验证；不能依赖“新旧代码都是当前版本”证明升级。
- 记录成功以事务提交为准；副作用失败不能导致记录丢失。不要删除未知字段、初始化示例覆盖坏数据或重解释历史日期。
- 用真实 SQLite/文件验证故障边界；新增测试应覆盖用户可见的不变量，而不只是照抄实现。
- 代码、客户端、服务和自建流程沿用 MIT。新依赖同时核对许可证、原生兼容和维护状态；第三方依赖不因本项目 MIT 而改为 MIT。

请在 PR 说明问题、最终行为和实际检查结果。不得提交 `.env`、签名材料、用户数据、访问令牌、恢复文件或构建产物。
