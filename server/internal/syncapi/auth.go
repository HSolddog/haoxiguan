package syncapi

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

var ErrUnauthorized = errors.New("unauthorized")
var ErrConflict = errors.New("conflict")
var ErrEpoch = errors.New("epoch_changed")
var ErrStale = errors.New("device_stale")
var ErrInvalid = errors.New("invalid_request")
var ErrQuota = errors.New("quota_exceeded")

type Tokens struct {
	Access  string `json:"accessToken"`
	Refresh string `json:"refreshToken"`
	Expires int64  `json:"accessExpiresAt"`
	Device  string `json:"deviceId"`
	Vault   string `json:"vaultId"`
	Epoch   string `json:"epoch"`
}
type Identity struct {
	User, Device, Vault string
	LastSeen            int64
}

func (s *Store) issue(ctx context.Context, tx *sql.Tx, device, vault string) (Tokens, error) {
	var epoch string
	if err := tx.QueryRowContext(ctx, "SELECT value FROM metadata WHERE key='epoch'").Scan(&epoch); err != nil {
		return Tokens{}, err
	}
	now := s.now()
	t := Tokens{Access: randomToken(32), Refresh: randomToken(32), Expires: now.Add(15 * time.Minute).Unix(), Device: device, Vault: vault, Epoch: epoch}
	_, err := tx.ExecContext(ctx, "INSERT INTO sessions(access_hash,refresh_hash,device_id,access_expires,refresh_expires) VALUES(?,?,?,?,?)", hashToken(t.Access), hashToken(t.Refresh), device, t.Expires, now.Add(30*24*time.Hour).Unix())
	return t, err
}
func (s *Store) Enroll(ctx context.Context, invite, name string) (Tokens, error) {
	if len(invite) != 43 || len(name) < 1 || len(name) > 80 {
		return Tokens{}, ErrInvalid
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Tokens{}, err
	}
	defer tx.Rollback()
	var user, vault string
	err = tx.QueryRowContext(ctx, `SELECT u.id,u.vault FROM invites i JOIN users u ON u.id=i.user_id
 WHERE i.hash=? AND i.used=0 AND i.expires>? AND u.deleted=0`, hashToken(invite), s.now().Unix()).Scan(&user, &vault)
	if errors.Is(err, sql.ErrNoRows) {
		return Tokens{}, ErrUnauthorized
	}
	if err != nil {
		return Tokens{}, err
	}
	var count int
	if err = tx.QueryRowContext(ctx, "SELECT count(*) FROM devices WHERE user_id=? AND revoked=0", user).Scan(&count); err != nil {
		return Tokens{}, err
	}
	if count >= 10 {
		return Tokens{}, ErrQuota
	}
	device := randomToken(24)
	if _, err = tx.ExecContext(ctx, "INSERT INTO devices(id,user_id,name,created,last_seen) VALUES(?,?,?,?,?)", device, user, name, s.now().Unix(), s.now().Unix()); err != nil {
		return Tokens{}, err
	}
	if _, err = tx.ExecContext(ctx, "UPDATE invites SET used=1 WHERE hash=?", hashToken(invite)); err != nil {
		return Tokens{}, err
	}
	tokens, err := s.issue(ctx, tx, device, vault)
	if err != nil {
		return Tokens{}, err
	}
	if err = tx.Commit(); err != nil {
		return Tokens{}, err
	}
	return tokens, nil
}
func (s *Store) Refresh(ctx context.Context, refresh string) (Tokens, error) {
	if len(refresh) != 43 {
		return Tokens{}, ErrUnauthorized
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Tokens{}, err
	}
	defer tx.Rollback()
	var device, vault string
	var consumed, revoked, deleted int
	var expires int64
	err = tx.QueryRowContext(ctx, `SELECT d.id,u.vault,s.consumed,d.revoked,u.deleted,s.refresh_expires
 FROM sessions s JOIN devices d ON d.id=s.device_id JOIN users u ON u.id=d.user_id WHERE s.refresh_hash=?`, hashToken(refresh)).Scan(&device, &vault, &consumed, &revoked, &deleted, &expires)
	if errors.Is(err, sql.ErrNoRows) {
		return Tokens{}, ErrUnauthorized
	}
	if err != nil {
		return Tokens{}, err
	}
	if consumed != 0 {
		// A replayed refresh invalidates this device family, including its newer token.
		if _, err = tx.ExecContext(ctx, "UPDATE devices SET revoked=1 WHERE id=?", device); err != nil {
			return Tokens{}, err
		}
		if err = tx.Commit(); err != nil {
			return Tokens{}, err
		}
		return Tokens{}, ErrUnauthorized
	}
	if revoked != 0 || deleted != 0 || expires <= s.now().Unix() {
		return Tokens{}, ErrUnauthorized
	}
	if _, err = tx.ExecContext(ctx, "UPDATE sessions SET consumed=1 WHERE refresh_hash=?", hashToken(refresh)); err != nil {
		return Tokens{}, err
	}
	tokens, err := s.issue(ctx, tx, device, vault)
	if err != nil {
		return Tokens{}, err
	}
	if err = tx.Commit(); err != nil {
		return Tokens{}, err
	}
	return tokens, nil
}
func (s *Store) Authenticate(ctx context.Context, token string) (Identity, error) {
	var id Identity
	if len(token) != 43 {
		return id, ErrUnauthorized
	}
	err := s.db.QueryRowContext(ctx, `SELECT u.id,d.id,u.vault,d.last_seen FROM sessions s
 JOIN devices d ON d.id=s.device_id JOIN users u ON u.id=d.user_id
 WHERE s.access_hash=? AND s.access_expires>? AND s.consumed=0 AND d.revoked=0 AND u.deleted=0`, hashToken(token), s.now().Unix()).Scan(&id.User, &id.Device, &id.Vault, &id.LastSeen)
	if errors.Is(err, sql.ErrNoRows) {
		return id, ErrUnauthorized
	}
	return id, err
}

// Check authorization again inside each mutation transaction, preventing a revoke
// between middleware authentication and commit from accepting a later write.
func checkDevice(ctx context.Context, tx *sql.Tx, id Identity) error {
	var count int
	err := tx.QueryRowContext(ctx, `SELECT count(*) FROM devices d JOIN users u ON u.id=d.user_id
 WHERE d.id=? AND d.user_id=? AND d.revoked=0 AND u.deleted=0 AND u.vault=?`, id.Device, id.User, id.Vault).Scan(&count)
	if err != nil {
		return err
	}
	if count != 1 {
		return ErrUnauthorized
	}
	return nil
}
func (s *Store) Revoke(ctx context.Context, id Identity, target string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err = checkDevice(ctx, tx, id); err != nil {
		return err
	}
	result, err := tx.ExecContext(ctx, "UPDATE devices SET revoked=1 WHERE id=? AND user_id=?", target, id.User)
	if err != nil {
		return err
	}
	n, _ := result.RowsAffected()
	if n != 1 {
		return ErrUnauthorized
	}
	return tx.Commit()
}

type Device struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Revoked  bool   `json:"revoked"`
	LastSeen int64  `json:"lastSeen"`
}

func (s *Store) Devices(ctx context.Context, id Identity) ([]Device, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT id,name,revoked,last_seen FROM devices WHERE user_id=? ORDER BY created,id", id.User)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	devices := []Device{}
	for rows.Next() {
		var d Device
		if err = rows.Scan(&d.ID, &d.Name, &d.Revoked, &d.LastSeen); err != nil {
			return nil, err
		}
		devices = append(devices, d)
	}
	return devices, rows.Err()
}
