package syncapi

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

var ctx = context.Background()

func fixture(t *testing.T) (*Store, Identity, Tokens, string) {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "store.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	user, _, invite, err := s.CreateUser(ctx, "test")
	if err != nil {
		t.Fatal(err)
	}
	tokens, err := s.Enroll(ctx, invite, "phone")
	if err != nil {
		t.Fatal(err)
	}
	id, err := s.Authenticate(ctx, tokens.Access)
	if err != nil {
		t.Fatal(err)
	}
	return s, id, tokens, user
}
func op(index int, base int64) Operation {
	return Operation{ID: fmt.Sprintf("operation_%024d", index), Entity: "entity_111111111111111111111111", Base: base, Ciphertext: base64.StdEncoding.EncodeToString([]byte(fmt.Sprintf("synthetic authenticated ciphertext fixture %040d", index)))}
}
func TestCommitAndIdempotency(t *testing.T) {
	s, id, tokens, _ := fixture(t)
	first := op(1, 0)
	result, err := s.Push(ctx, id, tokens.Epoch, []Operation{first})
	if err != nil || result[0].Revision != 1 {
		t.Fatal(result, err)
	}
	result, err = s.Push(ctx, id, tokens.Epoch, []Operation{first})
	if err != nil || result[0].Revision != 1 {
		t.Fatal(result, err)
	}
	reused := first
	reused.Deleted = true
	if _, err = s.Push(ctx, id, tokens.Epoch, []Operation{reused}); !errors.Is(err, ErrConflict) {
		t.Fatal(err)
	}
	page, err := s.Pull(ctx, id, tokens.Epoch, "", "", 100, false)
	if err != nil || len(page.Objects) != 1 {
		t.Fatal(page, err)
	}
}
func TestConcurrentCASRetainsConflict(t *testing.T) {
	s, id, tokens, _ := fixture(t)
	var wg sync.WaitGroup
	results := make(chan PushResult, 2)
	for i := 1; i <= 2; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			r, e := s.Push(ctx, id, tokens.Epoch, []Operation{op(n, 0)})
			if e != nil {
				t.Error(e)
				return
			}
			results <- r[0]
		}(i)
	}
	wg.Wait()
	close(results)
	accepted, conflicts := 0, 0
	for r := range results {
		if r.Status == "accepted" {
			accepted++
		} else if r.Current != nil && r.Current.Revision == 1 {
			conflicts++
		}
	}
	if accepted != 1 || conflicts != 1 {
		t.Fatal(accepted, conflicts)
	}
}
func TestPaginationDoesNotSkipConcurrentCommit(t *testing.T) {
	s, id, tokens, _ := fixture(t)
	for i := 1; i <= 3; i++ {
		v := op(i, 0)
		v.Entity = fmt.Sprintf("entity_%025d", i)
		if _, err := s.Push(ctx, id, tokens.Epoch, []Operation{v}); err != nil {
			t.Fatal(err)
		}
	}
	p1, err := s.Pull(ctx, id, tokens.Epoch, "", "", 1, true)
	if err != nil {
		t.Fatal(err)
	}
	v := op(4, 0)
	v.Entity = "entity_after_snapshot_1111111111"
	if _, err = s.Push(ctx, id, tokens.Epoch, []Operation{v}); err != nil {
		t.Fatal(err)
	}
	p2, err := s.Pull(ctx, id, tokens.Epoch, p1.Cursor, p1.HighWater, 100, true)
	if err != nil || len(p2.Objects) != 2 || p2.More {
		t.Fatal(p2, err)
	}
	// Retry a lost final response is accepted at the same cursor/high-water.
	retry, err := s.Pull(ctx, id, tokens.Epoch, p1.Cursor, p1.HighWater, 100, true)
	if err != nil || retry.Cursor != p2.Cursor {
		t.Fatal(retry, err)
	}
	p3, err := s.Pull(ctx, id, tokens.Epoch, p2.Cursor, "", 100, false)
	if err != nil || len(p3.Objects) != 1 || p3.Objects[0].Entity != v.Entity {
		t.Fatal(p3, err)
	}
}
func TestRefreshReplayAndRevocation(t *testing.T) {
	s, id, tokens, user := fixture(t)
	next, err := s.Refresh(ctx, tokens.Refresh)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Authenticate(ctx, tokens.Access); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
	if _, err = s.Refresh(ctx, tokens.Refresh); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
	if _, err = s.Authenticate(ctx, next.Access); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
	if _, err = s.Push(ctx, id, tokens.Epoch, []Operation{op(1, 0)}); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
	invite, err := s.NewInvite(ctx, user)
	if err != nil {
		t.Fatal(err)
	}
	enrolled, err := s.Enroll(ctx, invite, "replacement")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Enroll(ctx, invite, "replay"); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
	replacement, err := s.Authenticate(ctx, enrolled.Access)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.Revoke(ctx, replacement, replacement.Device); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Refresh(ctx, enrolled.Refresh); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
}
func TestAccountIsolationEpochAndDelete(t *testing.T) {
	s, id, tokens, _ := fixture(t)
	if _, err := s.Push(ctx, id, tokens.Epoch, []Operation{op(1, 0)}); err != nil {
		t.Fatal(err)
	}
	_, _, invite, err := s.CreateUser(ctx, "second")
	if err != nil {
		t.Fatal(err)
	}
	otherTokens, err := s.Enroll(ctx, invite, "second phone")
	if err != nil {
		t.Fatal(err)
	}
	other, err := s.Authenticate(ctx, otherTokens.Access)
	if err != nil {
		t.Fatal(err)
	}
	page, err := s.Pull(ctx, other, tokens.Epoch, "", "", 100, false)
	if err != nil || len(page.Objects) != 0 {
		t.Fatal(page, err)
	}
	if err = s.Revoke(ctx, other, id.Device); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
	if err = s.RotateEpoch(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Push(ctx, id, tokens.Epoch, []Operation{op(2, 1)}); !errors.Is(err, ErrEpoch) {
		t.Fatal(err)
	}
	epoch, err := s.Epoch(ctx)
	if err != nil {
		t.Fatal(err)
	}
	page, err = s.Pull(ctx, id, epoch, "", "", 100, true)
	if err != nil || len(page.Objects) != 1 || page.Objects[0].Epoch != tokens.Epoch {
		t.Fatal(page, err)
	}
	if err = s.DeleteAccount(ctx, id); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Authenticate(ctx, tokens.Access); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
}
func TestStaleRequiresCompleteBootstrap(t *testing.T) {
	s, id, tokens, _ := fixture(t)
	if _, err := s.Push(ctx, id, tokens.Epoch, []Operation{op(1, 0)}); err != nil {
		t.Fatal(err)
	}
	now := time.Now().Add(181 * 24 * time.Hour)
	s.now = func() time.Time { return now }
	if _, err := s.Push(ctx, id, tokens.Epoch, []Operation{op(2, 1)}); !errors.Is(err, ErrStale) {
		t.Fatal(err)
	}
	if _, err := s.Pull(ctx, id, tokens.Epoch, cursor(1), cursor(1), 1, true); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
	p, err := s.Pull(ctx, id, tokens.Epoch, "", "", 1, true)
	if err != nil || p.More || len(p.Objects) != 1 {
		t.Fatal(p, err)
	}
	if _, err = s.Push(ctx, id, tokens.Epoch, []Operation{op(2, 1)}); err != nil {
		t.Fatal(err)
	}
}
func TestQuotaRollsBackWholeBatch(t *testing.T) {
	s, id, tokens, user := fixture(t)
	if _, err := s.db.Exec("UPDATE users SET used_bytes=? WHERE id=?", MaxVaultBytes-1, user); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Push(ctx, id, tokens.Epoch, []Operation{op(1, 0)}); !errors.Is(err, ErrQuota) {
		t.Fatal(err)
	}
	p, err := s.Pull(ctx, id, tokens.Epoch, "", "", 100, false)
	if err != nil || len(p.Objects) != 0 {
		t.Fatal(p, err)
	}
	var n int
	if err = s.db.QueryRow("SELECT count(*) FROM operations").Scan(&n); err != nil || n != 0 {
		t.Fatal(n, err)
	}
}
