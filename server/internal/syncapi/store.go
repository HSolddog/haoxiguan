// Package syncapi implements an opaque-object store. It never receives content keys.
package syncapi

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

const ProtocolVersion = 1
const MaxObjectBytes = 256 * 1024
const MaxBatch = 100
const MaxVaultBytes = 256 * 1024 * 1024

type Store struct {
	db  *sql.DB
	now func() time.Time
}

func Open(path string) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	// A single connection defines commit order. WAL readers use separate requests
	// only after each transaction; no preallocated cursor can become visible early.
	db.SetMaxOpenConns(1)
	s := &Store{db: db, now: time.Now}
	if err = s.initialize(); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}
func (s *Store) Close() error { return s.db.Close() }
func (s *Store) initialize() error {
	for _, query := range []string{"PRAGMA journal_mode=WAL", "PRAGMA synchronous=FULL", "PRAGMA foreign_keys=ON", "PRAGMA busy_timeout=5000"} {
		if _, err := s.db.Exec(query); err != nil {
			return err
		}
	}
	var version int
	if err := s.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return err
	}
	if version > 1 {
		return fmt.Errorf("database schema %d is newer than supported; file preserved", version)
	}
	if version == 1 {
		return nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	statements := []string{
		`CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)`,
		`CREATE TABLE users(id TEXT PRIMARY KEY,name TEXT NOT NULL UNIQUE,vault TEXT NOT NULL UNIQUE,deleted INTEGER NOT NULL DEFAULT 0,created INTEGER NOT NULL,used_bytes INTEGER NOT NULL DEFAULT 0)`,
		`CREATE TABLE invites(hash TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),expires INTEGER NOT NULL,used INTEGER NOT NULL DEFAULT 0)`,
		`CREATE TABLE devices(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),name TEXT NOT NULL,revoked INTEGER NOT NULL DEFAULT 0,created INTEGER NOT NULL,last_seen INTEGER NOT NULL,bootstrap_high INTEGER,bootstrap_cursor INTEGER,bootstrap_previous INTEGER)`,
		`CREATE TABLE sessions(access_hash TEXT PRIMARY KEY,refresh_hash TEXT NOT NULL UNIQUE,device_id TEXT NOT NULL REFERENCES devices(id),access_expires INTEGER NOT NULL,refresh_expires INTEGER NOT NULL,consumed INTEGER NOT NULL DEFAULT 0)`,
		`CREATE TABLE objects(vault TEXT NOT NULL,id TEXT NOT NULL,revision INTEGER NOT NULL,epoch TEXT NOT NULL,base_revision INTEGER NOT NULL,ciphertext TEXT NOT NULL,deleted INTEGER NOT NULL,modified INTEGER NOT NULL,PRIMARY KEY(vault,id))`,
		`CREATE TABLE changes(sequence INTEGER PRIMARY KEY AUTOINCREMENT,vault TEXT NOT NULL,id TEXT NOT NULL,revision INTEGER NOT NULL,epoch TEXT NOT NULL,base_revision INTEGER NOT NULL,ciphertext TEXT NOT NULL,deleted INTEGER NOT NULL,created INTEGER NOT NULL)`,
		`CREATE INDEX changes_vault_sequence ON changes(vault,sequence)`,
		`CREATE TABLE operations(vault TEXT NOT NULL,op_id TEXT NOT NULL,digest TEXT NOT NULL,result TEXT NOT NULL,PRIMARY KEY(vault,op_id))`,
		`CREATE INDEX sessions_device ON sessions(device_id)`,
		`PRAGMA user_version=1`,
	}
	for _, q := range statements {
		if _, err = tx.Exec(q); err != nil {
			return err
		}
	}
	if _, err = tx.Exec("INSERT INTO metadata VALUES('epoch',?)", randomToken(24)); err != nil {
		return err
	}
	return tx.Commit()
}
func randomToken(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}
func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}
func (s *Store) Epoch(ctx context.Context) (string, error) {
	var value string
	err := s.db.QueryRowContext(ctx, "SELECT value FROM metadata WHERE key='epoch'").Scan(&value)
	return value, err
}

// CreateUser is an operator-only action. The random enrollment code is single use
// and expires after 24 hours; store only its hash. No SMTP or account password needed.
func (s *Store) CreateUser(ctx context.Context, name string) (userID, vault, invite string, err error) {
	if len(name) < 1 || len(name) > 80 {
		return "", "", "", errors.New("name must be 1–80 bytes")
	}
	userID, vault, invite = randomToken(24), randomToken(24), randomToken(32)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", "", "", err
	}
	defer tx.Rollback()
	now := s.now().Unix()
	if _, err = tx.ExecContext(ctx, "INSERT INTO users(id,name,vault,created) VALUES(?,?,?,?)", userID, name, vault, now); err != nil {
		return "", "", "", err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO invites(hash,user_id,expires) VALUES(?,?,?)", hashToken(invite), userID, now+86400); err != nil {
		return "", "", "", err
	}
	err = tx.Commit()
	return
}
func (s *Store) NewInvite(ctx context.Context, userID string) (string, error) {
	invite := randomToken(32)
	result, err := s.db.ExecContext(ctx, "INSERT INTO invites(hash,user_id,expires) SELECT ?,id,? FROM users WHERE id=? AND deleted=0", hashToken(invite), s.now().Add(24*time.Hour).Unix(), userID)
	if err != nil {
		return "", err
	}
	n, _ := result.RowsAffected()
	if n != 1 {
		return "", errors.New("user not found")
	}
	return invite, nil
}

// RotateEpoch must run with HTTP stopped after restoring a server backup. Existing
// ciphertext retains its original encryption epoch; clients rebootstrap before push.
func (s *Store) RotateEpoch(ctx context.Context) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "UPDATE metadata SET value=? WHERE key='epoch'", randomToken(24)); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM operations"); err != nil {
		return err
	}
	return tx.Commit()
}
