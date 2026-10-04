# 固定签名测试包 1.2.1+7

2026-10-04，用户另行批准在 Windows 本机使用现有长期密钥制作并发布测试包。正常产品 `assembleRelease` 已完成（746.1秒、退出码0）；本页记录本地完成状态，GitHub上传尚未执行，等待用户批准本机浏览器授权。没有创建第二套密钥、上传凭据、合并PR或部署服务。

| 项目 | 本轮实际结果 |
| --- | --- |
| 版本 | 1.2.1+7，versionCode 7；旧下载1.1.0+5 |
| 包名 / 最低系统 | com.haoxiguan.haoxiguan / Android 7.0（API24） |
| 构建类型 | 普通产品Release，非debuggable；不是隔离acceptance包 |
| APK字节数 | 68,723,833 |
| APK SHA256 | 1ff80c7d78b50929892a7f2a2082139a7c03421089151dd013d97d2411e0a90b |
| 证书 SHA256 | D675D16E4C0CC72C862DB337E2A6B2D7D92AFDF61135B014B95B44A016FC5ABC |
| 核验 | apksigner v2及唯一4096位RSA签名、包名/版本、ZIP CRC、zipalign -P16、18个ELF全部LOAD对齐至少16KiB通过 |

源码快照 `b8eea8c30b7c1fc25d7a860f0fd374cb3f9d5844`（本地950777d；tree `e57b7313804ec6aa18902f2ee71ff29e499e7280`）基于已验收f58dc14。准确差异为：pubspec从1.2.0+6升至1.2.1+7；`.gitignore`增加p12/pfx/dpapi保护；Gradle禁用OOM堆转储；本机构建脚本固定新证书、复用已选SDK、禁用持久daemon和configuration cache、构建后验证唯一APK签名才导出和更新版本，并保存脱敏失败诊断；新增五项脚本过程边界测试。JVM语言参数正确加引号，测试明确核验这些参数。`lib/`、`android/app/`和锁定依赖与f58dc14一致，未修改产品逻辑。

脚本和版本维护不重绑既有全套CI。此Release包已完成构建与静态核验，尚未安装到真实手机；此前官方16384页运行证明绑定ca85d82的Debug及隔离夹具，不代表本包的真机运行。真机长期提醒/OEM/TalkBack、性能、历史安装兼容及独立安全审阅仍保留外部门禁。可复核的源码和原生库哈希见[本轮核验摘要](验收记录/fixed-release-1.2.1-build7.json)。

首次换装请先在旧应用导出并核对备份。旧临时/debug签名不同，Android可能要求卸载旧版再安装；卸载会删除旧应用本机数据，未确认备份前不要卸载。新应用恢复时先核对预览，再明确确认。以后沿用固定密钥并递增versionCode，继续正常更新。长期密钥只在本机已有保护入口使用；异机备份仍由用户另行保管，本次未完成或验证异机密钥备份。

GitHub将只上传APK、build-info.json和SHA256SUMS到新的prerelease，保留旧release和附件。发布状态及最终链接另行记录，不以本地APK完成代表上传已完成。
