# Security policy

This branch is an Android development/acceptance release. Encrypted sync is
experimental pending independent review and the remaining release gates in
[the implementation status](docs/实施进度.md).

For a suspected vulnerability, use GitHub's private vulnerability reporting when
available. Do not put credentials, recovery keys, private backups, user databases,
or an exploit against a live third-party service in a public issue. Describe the
version, affected component and a minimal reproduction using synthetic data.
No response-time guarantee has been established for this volunteer project.

Local SQLite relies on the OS application sandbox and device storage protection;
it is not application-encrypted. Backups and sync use distinct authenticated
formats. Account access recovery cannot recover content keys. See the
[privacy/data statement](docs/隐私与数据说明.md),
[backup format](docs/加密备份格式.md), and
[sync implementation](docs/同步实现与验收.md) for concrete boundaries.

Contributions must preserve original data on validation, key-access and migration
errors. Never add automatic database deletion, credential logging, disabled TLS
validation, or a debug-signing fallback for releases. A supported update must keep
package/signing identity and test the prior schema, with rollback fault tests.
