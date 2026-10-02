package syncapi

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"regexp"
	"strconv"
	"time"
)

var objectID = regexp.MustCompile(`^[A-Za-z0-9_-]{16,128}$`)

type Operation struct {
	ID         string `json:"opId"`
	Entity     string `json:"entityId"`
	Base       int64  `json:"baseRevision"`
	Ciphertext string `json:"ciphertext"`
	Deleted    bool   `json:"deleted"`
}
type Object struct {
	Entity     string `json:"entityId"`
	Revision   int64  `json:"revision"`
	Epoch      string `json:"encryptionEpoch"`
	Base       int64  `json:"baseRevision"`
	Ciphertext string `json:"ciphertext"`
	Deleted    bool   `json:"deleted"`
}
type PushResult struct {
	ID       string  `json:"opId"`
	Status   string  `json:"status"`
	Revision int64   `json:"revision,omitempty"`
	Current  *Object `json:"current,omitempty"`
}
type PullPage struct {
	Epoch     string   `json:"epoch"`
	Cursor    string   `json:"cursor"`
	HighWater string   `json:"highWater"`
	More      bool     `json:"more"`
	Objects   []Object `json:"objects"`
}

func cursor(n int64) string {
	return base64.RawURLEncoding.EncodeToString([]byte(strconv.FormatInt(n, 10)))
}
func decodeCursor(value string) (int64, error) {
	if value == "" {
		return 0, nil
	}
	raw, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil || len(raw) > 19 {
		return 0, ErrInvalid
	}
	n, err := strconv.ParseInt(string(raw), 10, 64)
	if err != nil || n < 0 || cursor(n) != value {
		return 0, ErrInvalid
	}
	return n, nil
}
func checkEpoch(ctx context.Context, tx *sql.Tx, expected string) error {
	var epoch string
	if err := tx.QueryRowContext(ctx, "SELECT value FROM metadata WHERE key='epoch'").Scan(&epoch); err != nil {
		return err
	}
	if epoch != expected {
		return ErrEpoch
	}
	return nil
}
func currentObject(ctx context.Context, tx *sql.Tx, vault, id string) (*Object, error) {
	o := &Object{Entity: id}
	err := tx.QueryRowContext(ctx, "SELECT revision,epoch,base_revision,ciphertext,deleted FROM objects WHERE vault=? AND id=?", vault, id).Scan(&o.Revision, &o.Epoch, &o.Base, &o.Ciphertext, &o.Deleted)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return o, err
}
func validateOp(op Operation) error {
	if !objectID.MatchString(op.ID) || !objectID.MatchString(op.Entity) || op.Base < 0 || len(op.Ciphertext) > MaxObjectBytes*2 {
		return ErrInvalid
	}
	bytes, err := base64.StdEncoding.DecodeString(op.Ciphertext)
	if err != nil || len(bytes) < 40 || len(bytes) > MaxObjectBytes || base64.StdEncoding.EncodeToString(bytes) != op.Ciphertext {
		return ErrInvalid
	}
	return nil
}
func (s *Store) Push(ctx context.Context, id Identity, epoch string, ops []Operation) ([]PushResult, error) {
	if len(ops) < 1 || len(ops) > MaxBatch {
		return nil, ErrInvalid
	}
	seen := map[string]bool{}
	for _, op := range ops {
		if err := validateOp(op); err != nil {
			return nil, err
		}
		if seen[op.ID] {
			return nil, ErrInvalid
		}
		seen[op.ID] = true
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if err = checkDevice(ctx, tx, id); err != nil {
		return nil, err
	}
	if err = checkEpoch(ctx, tx, epoch); err != nil {
		return nil, err
	}
	var lastSeen int64
	if err = tx.QueryRowContext(ctx, "SELECT last_seen FROM devices WHERE id=?", id.Device).Scan(&lastSeen); err != nil {
		return nil, err
	}
	if s.now().Unix()-lastSeen > int64((180 * 24 * time.Hour).Seconds()) {
		return nil, ErrStale
	}
	results := make([]PushResult, 0, len(ops))
	for _, op := range ops {
		encoded, _ := json.Marshal(op)
		digest := hashToken(string(encoded))
		var oldDigest, oldResult string
		err = tx.QueryRowContext(ctx, "SELECT digest,result FROM operations WHERE vault=? AND op_id=?", id.Vault, op.ID).Scan(&oldDigest, &oldResult)
		if err == nil {
			if digest != oldDigest {
				return nil, ErrConflict
			}
			var result PushResult
			if err = json.Unmarshal([]byte(oldResult), &result); err != nil {
				return nil, err
			}
			results = append(results, result)
			continue
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return nil, err
		}
		current, err := currentObject(ctx, tx, id.Vault, op.Entity)
		if err != nil {
			return nil, err
		}
		revision := int64(0)
		if current != nil {
			revision = current.Revision
		}
		result := PushResult{ID: op.ID, Status: "conflict", Current: current}
		if op.Base == revision {
			next := revision + 1
			if _, err = tx.ExecContext(ctx, `INSERT INTO objects(vault,id,revision,epoch,base_revision,ciphertext,deleted,modified) VALUES(?,?,?,?,?,?,?,?)
    ON CONFLICT(vault,id) DO UPDATE SET revision=excluded.revision,epoch=excluded.epoch,base_revision=excluded.base_revision,ciphertext=excluded.ciphertext,deleted=excluded.deleted,modified=excluded.modified`,
				id.Vault, op.Entity, next, epoch, op.Base, op.Ciphertext, op.Deleted, s.now().Unix()); err != nil {
				return nil, err
			}
			if _, err = tx.ExecContext(ctx, "INSERT INTO changes(vault,id,revision,epoch,base_revision,ciphertext,deleted,created) VALUES(?,?,?,?,?,?,?,?)", id.Vault, op.Entity, next, epoch, op.Base, op.Ciphertext, op.Deleted, s.now().Unix()); err != nil {
				return nil, err
			}
			result = PushResult{ID: op.ID, Status: "accepted", Revision: next}
		}
		value, _ := json.Marshal(result)
		// Charge payloads, retained changes and deduplication results conservatively.
		// Conflicting requests also consume storage and must not bypass the quota.
		cost := int64(len(encoded) + len(value) + 2*len(op.Ciphertext) + 512)
		budget, err := tx.ExecContext(ctx, "UPDATE users SET used_bytes=used_bytes+? WHERE id=? AND used_bytes+?<=?", cost, id.User, cost, MaxVaultBytes)
		if err != nil {
			return nil, err
		}
		charged, _ := budget.RowsAffected()
		if charged != 1 {
			return nil, ErrQuota
		}
		if _, err = tx.ExecContext(ctx, "INSERT INTO operations(vault,op_id,digest,result) VALUES(?,?,?,?)", id.Vault, op.ID, digest, string(value)); err != nil {
			return nil, err
		}
		results = append(results, result)
	}
	if _, err = tx.ExecContext(ctx, "UPDATE devices SET last_seen=? WHERE id=?", s.now().Unix(), id.Device); err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return results, nil
}
func (s *Store) Pull(ctx context.Context, id Identity, epoch, after, until string, limit int, bootstrap bool) (PullPage, error) {
	if limit < 1 || limit > 200 {
		return PullPage{}, ErrInvalid
	}
	from, err := decodeCursor(after)
	if err != nil {
		return PullPage{}, err
	}
	high, err := decodeCursor(until)
	if err != nil {
		return PullPage{}, err
	}
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{})
	if err != nil {
		return PullPage{}, err
	}
	defer tx.Rollback()
	if err = checkDevice(ctx, tx, id); err != nil {
		return PullPage{}, err
	}
	if err = checkEpoch(ctx, tx, epoch); err != nil {
		return PullPage{}, err
	}
	var latest int64
	if err = tx.QueryRowContext(ctx, "SELECT coalesce(max(sequence),0) FROM changes").Scan(&latest); err != nil {
		return PullPage{}, err
	}
	if until == "" {
		high = latest
	}
	if from > high || high > latest {
		return PullPage{}, ErrInvalid
	}
	var lastSeen int64
	var expectedHigh, expectedCursor, previousCursor sql.NullInt64
	if err = tx.QueryRowContext(ctx, "SELECT last_seen,bootstrap_high,bootstrap_cursor,bootstrap_previous FROM devices WHERE id=?", id.Device).Scan(&lastSeen, &expectedHigh, &expectedCursor, &previousCursor); err != nil {
		return PullPage{}, err
	}
	if !bootstrap && s.now().Unix()-lastSeen > int64((180*24*time.Hour).Seconds()) {
		return PullPage{}, ErrStale
	}
	if bootstrap {
		if after == "" && until == "" {
			if _, err = tx.ExecContext(ctx, "UPDATE devices SET bootstrap_high=?,bootstrap_cursor=0,bootstrap_previous=0 WHERE id=?", high, id.Device); err != nil {
				return PullPage{}, err
			}
		} else if !expectedHigh.Valid || expectedHigh.Int64 != high || (!expectedCursor.Valid || expectedCursor.Int64 != from) && (!previousCursor.Valid || previousCursor.Int64 != from) {
			return PullPage{}, ErrInvalid
		}
	}
	// Retain the complete log in v1. Bootstrap replays it up to a stable high-water
	// boundary; subsequent pulls cannot miss changes committed during pagination.
	rows, err := tx.QueryContext(ctx, `SELECT sequence,id,revision,epoch,base_revision,ciphertext,deleted FROM changes
 WHERE vault=? AND sequence>? AND sequence<=? ORDER BY sequence LIMIT ?`, id.Vault, from, high, limit+1)
	if err != nil {
		return PullPage{}, err
	}
	page := PullPage{Epoch: epoch, HighWater: cursor(high), Objects: []Object{}}
	next := from
	for rows.Next() {
		var sequence int64
		var object Object
		if err = rows.Scan(&sequence, &object.Entity, &object.Revision, &object.Epoch, &object.Base, &object.Ciphertext, &object.Deleted); err != nil {
			rows.Close()
			return page, err
		}
		if len(page.Objects) == limit {
			page.More = true
			break
		}
		page.Objects = append(page.Objects, object)
		next = sequence
	}
	if err = rows.Err(); err != nil {
		rows.Close()
		return page, err
	}
	rows.Close()
	if !page.More {
		next = high
	}
	page.Cursor = cursor(next)
	if bootstrap {
		if _, err = tx.ExecContext(ctx, "UPDATE devices SET bootstrap_cursor=?,bootstrap_previous=? WHERE id=?", next, from, id.Device); err != nil {
			return page, err
		}
	}
	if !page.More {
		if _, err = tx.ExecContext(ctx, "UPDATE devices SET last_seen=? WHERE id=?", s.now().Unix(), id.Device); err != nil {
			return page, err
		}
	}
	if err = tx.Commit(); err != nil {
		return page, err
	}
	return page, nil
}
func (s *Store) DeleteAccount(ctx context.Context, id Identity) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err = checkDevice(ctx, tx, id); err != nil {
		return err
	}
	for _, table := range []string{"objects", "changes", "operations"} {
		if _, err = tx.ExecContext(ctx, "DELETE FROM "+table+" WHERE vault=?", id.Vault); err != nil {
			return err
		}
	}
	if _, err = tx.ExecContext(ctx, "UPDATE devices SET revoked=1 WHERE user_id=?", id.User); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM invites WHERE user_id=?", id.User); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "UPDATE users SET deleted=1,name=? WHERE id=?", "deleted-"+id.User, id.User); err != nil {
		return err
	}
	return tx.Commit()
}
