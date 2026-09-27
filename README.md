# 好习惯 · Haoxiguan

**一个温和、离线优先的 Flutter 习惯养成应用。** 习惯、打卡和每日备注保存在设备本地，无需账号或云同步。

Haoxiguan is a gentle, offline-first habit tracker built with Flutter. Habits, check-ins, and daily notes stay on your device; no account or cloud sync is required.

## 功能 | Features

- 按天、周或月设置习惯频率，并按分类整理习惯。
- 使用本地通知设置提醒，记录每日打卡和备注。
- 查看连续记录、完成率和历史趋势。
- 可选的努力值奖惩与心愿目标。
- 支持深色模式、主题颜色，以及 JSON 数据导入和导出。
- Local notifications, streaks, completion rates, history, optional point goals, themes, and JSON backup/restore.

## 开发 | Development

需要安装与 `pubspec.yaml` SDK 约束兼容的 Flutter SDK。在项目根目录运行：

```sh
flutter pub get
flutter run
```

运行静态检查和测试：

```sh
flutter analyze
flutter test
```

## Android APK

在已配置 Android SDK、JDK 和更新签名证书的 Windows 环境中，可使用发布脚本构建 APK：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_release_apk.ps1
```

脚本会在构建成功后递增版本号，并将 APK 放入 `dist`。构建产物和签名凭据不会提交到仓库。版本升级与本地数据兼容说明见[版本与数据升级](docs/版本与数据升级.md)。

## 数据与隐私 | Data and privacy

应用数据保存在设备本地；设置页支持导出和导入 JSON。仓库不包含用户的应用数据、签名密钥或构建产物。

## 参与贡献 | Contributing

欢迎提交问题和改进建议。开始前请阅读[贡献指南](CONTRIBUTING.md)。

## 许可证 | License

本项目采用 [MIT License](LICENSE)。第三方依赖仍遵循各自的许可证。
