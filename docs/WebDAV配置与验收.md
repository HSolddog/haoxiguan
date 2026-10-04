# 自有 WebDAV 备份

## 使用

在数据页打开“自己的 WebDAV 备份”，填写最终 HTTPS WebDAV 目录、用户名、应用密码，以及独立的备份密码。Nextcloud 的示例目录是 `https://你的域名/remote.php/dav/files/用户名/`。应用不跟随重定向发送认证头；遇到跳转应改填最终地址。使用系统信任的证书，不提供关闭 TLS 校验开关。

保存配置会先完成一份加密上传及恢复校验，再启用自动备份。独立备份密码至少 12 个字符，必须另行妥善保管。系统安全存储保存凭据；密钥读取失败会停止操作，不自动清空密钥或业务库。明文习惯内容不发给 WebDAV 服务。

可以随时“立即备份”，或列出服务器各设备/空间下具有完成标记的快照。恢复前重新解密校验并预览数量；确认后事务保护并替换本地数据，创建新的本地空间。旧配置不会自动把这个新空间传回原目录，需重新配置。恢复旧密码文件时，在备份密码框输入当时的密码，不必修改 WebDAV 登录密码。

断开保留本机记录和远端文件，停止后续任务；已经发出的网络请求可能完成。账号凭据、设备身份、自动任务状态不进入业务文件备份。

## 调度和保留

有变化时每天自动尝试一次，默认仅 Wi-Fi。Android WorkManager 每 12 小时提供一次执行机会，前台恢复也补做；系统省电、强制停止和厂商限制可能推迟任务，不承诺准点。通知续排使用独立的离线后台任务，备份服务不可用不影响通知续排或记录保存。

前后台任务使用独立 SQLite 互斥文件协调，不把网络等待放入业务库写事务。备份凭据是先完整写入、再切换有效指针。记录仍始终先在本机事务提交。

每台设备独立路径 `haoxiguan/<vault UUID>/<device UUID>/<snapshot UUID>.hgb`。上传使用 `If-None-Match: *`，读回并解密成功后才发布绑定 SHA-256 的 `.complete.json`，完成标记也读回验证。中断文件不进入恢复候选。

默认保留最近 7 个每日、4 个每周、6 个每月副本的并集，新备份验证成功后才清理。仅清本机成功上传日志中的对象；删除前核对目录归属、标记、文件摘要和强 ETag，使用 `If-Match` 条件删除。没有强 ETag 的服务保留更多文件。用户文件、其他设备和最后有效副本不用于自动腾空间。

请求体积和时间有界；401/403 不重复尝试，429/5xx 最多三次、指数间隔。HTTP 错误文案不显示含凭据的原始响应。成功时间取实际经过读回验证的快照，清理失败单独提示。

## 已运行的检查（2026-10-02）

- 9 项协议/故障自动化：HTTPS 与跳转边界、恶意 href、上传顺序、坏读回、半文件、401、保留、替换文件保护、配置指针中断、空间分叉后停止自动上传。
- WsgiDAV 4.3.3 + Cheroot 11.1.2：在本机隔离目录、TLS 与显式信任测试证书下，真实 MKCOL/PUT/GET/PROPFIND/DELETE、跨设备读取和解密恢复通过。
- Nextcloud 33.0.9 + SQLite + FrankenPHP 1.12.7/PHP 8.5.11：同样通过真实 TLS WebDAV 集成测试。使用官方发布包及校验和安装到隔离目录，不是 mock；Docker Hub 限流未计为产品失败。
- 集成测试源码 `test/webdav_integration_test.dart`，默认不访问网络；只有指定一次性测试目录时执行。例如：

```sh
flutter test test/webdav_integration_test.dart \
  --dart-define=TEST_DAV_ENDPOINT=https://localhost:9443/ \
  --dart-define=TEST_DAV_CERT=/绝对路径/测试证书.pem
```

测试默认账号仅是本地测试夹具的公开合成账号。真实服务用 `TEST_DAV_USER` 和 `TEST_DAV_PASSWORD` 指定专门测试凭据，不能提交真实凭据。测试生成随机空间并只删除自身创建的文件。

## 当前源码的第二种实现补验（2026-10-04，进行中）

上节2026-10-02的Nextcloud记录仅对应旧源码。当前ca85d82已完成官方Nextcloud 33.0.9-apache隔离容器4/4与WsgiDAV TLS 1/1，均实际执行零跳过；版本/镜像摘要、源码146个Git blob哈希、原始日志/归档均核证。恢复元数据、历史超长文本完整保留、删除权限探针及生产保留策略结果见[最终定向证据](验收记录/design-targeted-ci-ca85d82.json)。这份新结果不沿用旧源码的通过结论。

## 未完成的 Android 验收

后台任务、Keystore、Wi-Fi 限制、长期省电后的补做仍需 Android 系统和真机验证。实验室服务测试不等同于所有 Nextcloud/NAS 配置均兼容，也不代表移动端已完成整套 B01–B04。iOS 后台及文件能力后续单独适配。

### 当前条件请求修复的验证范围

首轮官方 Nextcloud 33.0.9-apache 的启用探针及普通/兼容 SQLite 恢复通过，保留夹具的 marker 条件 PUT 返回 412。仅布尔诊断证实压缩 GET 的强 ETag 含 `-gzip` 后缀；这与 [Apache 官方的压缩 ETag 规则](https://httpd.apache.org/docs/2.4/mod/mod_deflate.html#deflatealteretag)一致。客户端请求 identity 表示以取得未压缩表示的 ETag，条件删除和替换保护均保留。原始值不被改写，不通过去掉条件解决冲突。

31项客户端/权限探针和10项隔离运行器回归通过；最终同源码的Nextcloud与WsgiDAV TLS均已实际执行通过。Nextcloud生产prune真实完成两次原If-Match条件DELETE204，旧marker/data404，最新及其他设备副本精确恢复；普通/兼容恢复的11表保护与重开保持一致。首轮和诊断的失败归档见 [摘要](验收记录/design-targeted-first-runs-20261004.json)。此类实验室结果不代表任意 NAS 配置或 Android 长期后台已验收。

最终执行、源码与归档绑定见[定向CI](https://github.com/HSolddog/haoxiguan/actions/runs/37170134852)和[证据摘要](验收记录/design-targeted-ci-ca85d82.json)。首轮412发生在测试时间夹具准备、未进入生产prune；原失败持续保留。当前修复请求identity表示，不改写ETag、不取消条件、不改服务配置。
