# 贡献指南

感谢你愿意帮助改进「好习惯」。欢迎通过 GitHub Issues 报告问题或提出功能建议，也欢迎提交 Pull Request。

## 开发环境

安装与 `pubspec.yaml` SDK 约束兼容的 Flutter SDK，然后在项目根目录运行：

```sh
flutter pub get
flutter run
```

提交前请运行：

```sh
flutter analyze
flutter test
```

## 提交内容

- 一个 Pull Request 尽量聚焦于一个问题，并说明用户能看到的变化。
- 涉及本地数据格式的改动时，为旧数据保留兼容默认值；不要要求用户卸载应用或清空数据来完成升级。
- 报告问题时，请写明设备或操作系统、Flutter 版本、复现步骤、预期结果和实际结果。请先删除日志中的个人信息。
- 不要提交 `.env`、签名密钥、用户数据、APK 或其他本机生成文件。
