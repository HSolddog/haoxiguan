package syncapi

import (
	"context"
	"database/sql"
	"errors"
)

// Rotation deliberately uses a new vault and independent client-generated keys.
// It is operator-driven maintenance, not an in-place partial re-encryption that
// could expose a mixture of key generations or silently lose concurrent writes.
type VaultState struct {
	Vault     string `json:"vaultId"`
	ReadOnly  bool   `json:"readOnly"`
	Objects   int64  `json:"objects"`
	HighWater string `json:"highWater"`
}

func (s *Store) VaultState(ctx context.Context, id Identity) (VaultState, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return VaultState{}, err
	}
	defer tx.Rollback()
	if err = checkDevice(ctx, tx, id); err != nil {
		return VaultState{}, err
	}
	state := VaultState{Vault: id.Vault}
	if err = tx.QueryRowContext(ctx, "SELECT read_only FROM users WHERE id=?", id.User).Scan(&state.ReadOnly); err != nil {
		return state, err
	}
	if err = tx.QueryRowContext(ctx, "SELECT count(*) FROM objects WHERE vault=?", id.Vault).Scan(&state.Objects); err != nil {
		return state, err
	}
	var high int64
	if err = tx.QueryRowContext(ctx, "SELECT coalesce(max(sequence),0) FROM changes WHERE vault=?", id.Vault).Scan(&high); err != nil {
		return state, err
	}
	state.HighWater = cursor(high)
	return state, tx.Commit()
}

// SetReadOnly is local operator administration; not a remotely accessible API.
// Once true, all subsequent user Push transactions fail, while Pull still works.
func (s *Store) SetReadOnly(ctx context.Context, user string, value bool) error {
	result, err := s.db.ExecContext(ctx, "UPDATE users SET read_only=? WHERE id=? AND deleted=0", value, user)
	if err != nil {
		return err
	}
	n, _ := result.RowsAffected()
	if n != 1 {
		return ErrInvalid
	}
	return nil
}

// RotateVault requires a frozen account and a trusted device with a verified
// complete local snapshot. The CLI holds the process lock with HTTP stopped.
// Old ciphertext is retained, inaccessible to active account tokens. It remains
// charged to this user's quota and is included in explicit account deletion.
func (s *Store) RotateVault(ctx context.Context, user string) (vault, invite string, err error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", "", err
	}
	defer tx.Rollback()
	var previous string
	var frozen bool
	err = tx.QueryRowContext(ctx, "SELECT vault,read_only FROM users WHERE id=? AND deleted=0", user).Scan(&previous, &frozen)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", ErrInvalid
	}
	if err != nil {
		return "", "", err
	}
	if !frozen {
		return "", "", ErrReadOnly
	}
	vault, invite = randomToken(24), randomToken(32)
	if _, err = tx.ExecContext(ctx, "INSERT INTO retired_vaults(vault,user_id,retired_at) VALUES(?,?,?)", previous, user, s.now().Unix()); err != nil {
		return "", "", err
	}
	if _, err = tx.ExecContext(ctx, "UPDATE users SET vault=?,read_only=0 WHERE id=?", vault, user); err != nil {
		return "", "", err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM sessions WHERE device_id IN (SELECT id FROM devices WHERE user_id=?)", user); err != nil {
		return "", "", err
	}
	if _, err = tx.ExecContext(ctx, "UPDATE devices SET revoked=1 WHERE user_id=?", user); err != nil {
		return "", "", err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM invites WHERE user_id=?", user); err != nil {
		return "", "", err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO invites(hash,user_id,expires) VALUES(?,?,?)", hashToken(invite), user, s.now().Unix()+86400); err != nil {
		return "", "", err
	}
	err = tx.Commit()
	return
}
