-- Frozen schema from 00a55382103de312c7f08fe5d0df4c19a0787e2d; do not regenerate from current schema.
CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE users(id TEXT PRIMARY KEY,name TEXT NOT NULL UNIQUE,vault TEXT NOT NULL UNIQUE,deleted INTEGER NOT NULL DEFAULT 0,created INTEGER NOT NULL,used_bytes INTEGER NOT NULL DEFAULT 0);
CREATE TABLE invites(hash TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),expires INTEGER NOT NULL,used INTEGER NOT NULL DEFAULT 0);
CREATE TABLE devices(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),name TEXT NOT NULL,revoked INTEGER NOT NULL DEFAULT 0,created INTEGER NOT NULL,last_seen INTEGER NOT NULL,bootstrap_high INTEGER,bootstrap_cursor INTEGER,bootstrap_previous INTEGER);
CREATE TABLE sessions(access_hash TEXT PRIMARY KEY,refresh_hash TEXT NOT NULL UNIQUE,device_id TEXT NOT NULL REFERENCES devices(id),access_expires INTEGER NOT NULL,refresh_expires INTEGER NOT NULL,consumed INTEGER NOT NULL DEFAULT 0);
CREATE TABLE objects(vault TEXT NOT NULL,id TEXT NOT NULL,revision INTEGER NOT NULL,epoch TEXT NOT NULL,base_revision INTEGER NOT NULL,ciphertext TEXT NOT NULL,deleted INTEGER NOT NULL,modified INTEGER NOT NULL,PRIMARY KEY(vault,id));
CREATE TABLE changes(sequence INTEGER PRIMARY KEY AUTOINCREMENT,vault TEXT NOT NULL,id TEXT NOT NULL,revision INTEGER NOT NULL,epoch TEXT NOT NULL,base_revision INTEGER NOT NULL,ciphertext TEXT NOT NULL,deleted INTEGER NOT NULL,created INTEGER NOT NULL);
CREATE INDEX changes_vault_sequence ON changes(vault,sequence);
CREATE TABLE operations(vault TEXT NOT NULL,op_id TEXT NOT NULL,digest TEXT NOT NULL,result TEXT NOT NULL,PRIMARY KEY(vault,op_id));
CREATE INDEX sessions_device ON sessions(device_id);
PRAGMA user_version=1;
