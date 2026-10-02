# 好习惯同步服务（协议验证阶段）

Go + SQLite 单进程原型，只保存不透明对象和授权元数据。当前服务端协议/事务已实现并测试，**移动端 E2EE 同步、恢复材料、密钥轮换与冲突界面尚未接入，不是可正式启用的同步成品**。客户端不能把未加密的 JSON 当作 ciphertext 上传。

使用 MIT，与应用同仓库、同许可证。无 Redis、外部数据库、SMTP 或专有托管依赖。CLI 单次邀请用于初始化账户和增加设备；邀请码是随机 256-bit、24 小时有效、仅可消费一次。短期访问令牌 15 分钟，刷新令牌 30 天并轮换；重放已消费的刷新令牌会撤销该设备族，需要新邀请重新授权。

## 本地构建与隔离验证

```sh
cd server
go test -race ./...
go vet ./...
CGO_ENABLED=0 go build -trimpath -o dist/haoxiguan-server ./cmd/haoxiguan-server
mkdir -p data
./dist/haoxiguan-server create-user --db ./data/haoxiguan.sqlite \
  --name owner --out ./data/invite.json
./dist/haoxiguan-server serve --db ./data/haoxiguan.sqlite --listen 127.0.0.1:8787
```

`invite.json` 权限 0600，含一次性邀请码和账户 ID，不应提交或放公开 Web 目录。命令不会把邀请码/令牌打印到日志。另发邀请：`invite --db ... --user <账户 ID> --out <新文件>`。管理命令在服务器所在机器运行；没有开放远程管理口。

默认只监听回环 HTTP。外部访问必须由 HTTPS 反向代理终结 TLS；不要将此端口直接发布公网。服务不信任用户提交的账号 ID，授权从访问令牌推导。默认 IP 限流不采信 X-Forwarded-For；位于代理后时限制会共享，扩大部署前需评估可信代理配置与负载。

## API 草案

| 接口 | 内容 |
| --- | --- |
| GET /healthz | 健康状态，不返回用户资料 |
| GET /v1/capabilities | protocol/epoch、对象与批次限额 |
| POST /v1/auth/enroll | invite、deviceName → 访问/刷新令牌、设备/空间/epoch |
| POST /v1/auth/refresh | refreshToken → 轮换的令牌对 |
| POST /v1/push | epoch、operations；各含 opId/entityId/baseRevision/ciphertext/deleted |
| GET /v1/pull | epoch、cursor、highWater、limit；按事务提交顺序分页 |
| GET /v1/bootstrap | 分页到固定 highWater，服务端验证连续引导游标 |
| GET /v1/devices | 同账户设备列表 |
| POST /v1/devices/{id}/revoke | 立即撤销该设备未来授权，不远程擦除已下载内容 |
| DELETE /v1/account | 需要 X-Confirm-Delete: delete-remote-account；删除远端密文及日志，不操作手机 |

除 capabilities/health/auth 外均需 `Authorization: Bearer ...`。push 的单个操作结果为 accepted（新 revision）或 conflict（现有密文版本）。同 opId 同内容返回原结果；同 opId 不同内容 409。对象与去重记录、变更序列、配额在同事务提交。未知 JSON 字段拒绝，响应不含内部错误、SQL 或凭据。

ciphertext 当前为规范 Base64 不透明字节，最小 40 字节、最大解码后 256 KiB；**精确 AEAD 编码和客户端测试向量仍待 C 加密实现冻结**。每批最多 100 对象，请求上限 2 MiB，分页最多 200 对象。当前完整历史保留到配额，账户保守存储预算 256 MiB；不擅自压缩日志或删除 tombstone。长于 180 天未同步的设备须完成受控引导后才可写。

引导当前重放固定高水位内的日志。后续内容密钥轮换前需改为可用当前密钥解密的一致对象基线；不能用“服务器看不到密文内容”声称密钥生命周期已经完成。

## 运维与恢复实验

仅一个服务进程；进程锁阻止同时服务或维护。SQLite 位于本机可靠磁盘，WAL/FULL/外键开启。不要放多个实例共享的网络文件系统。

备份步骤：停止 HTTP 服务，执行 `backup --db <原库> --out <不存在的备份路径>`，使用 SQLite VACUUM INTO 一致快照，再同步文件。不能只复制正在使用的主库而忽略 WAL。

从旧服务备份恢复时：保持 HTTP 停止、保留当前整份数据目录、将验证过的备份放到新的数据目录、执行 `rotate-epoch --db <恢复库>`，再启动。客户端必须识别 epoch 改变并保留未上传意图后重新引导。**恢复后授权状态回退、撤销清单与密钥轮换仍在验证中，不可作为已完成的生产恢复流程**。

账户删除会清除在线密文/日志并撤销授权；离线运维备份有独立保存期，维护者必须确定并公布。不能承诺删除已被设备下载的历史。

## 实测边界

2026-10-02，Go 1.27.1、modernc SQLite 1.47.0，Linux amd64。10 项测试与 race detector 通过：CAS 并发冲突、幂等、分页新增、令牌重放/撤销、账户隔离、epoch、过期设备引导、配额回滚、HTTP 边界、一致备份重开/未来 schema 拒绝。真实 Go 进程的邀请消费和授权设备列举通过。Linux ARM64 静态交叉构建通过；这不等于 ARM 实机测试。

尚无 1 vCPU/1 GiB/十万对象负载结果、生产 TLS 部署、客户端端到端加密、完整恢复/轮换验收。不要用于真实用户数据；应用本地与已实现的加密文件/WebDAV 备份继续可用。
