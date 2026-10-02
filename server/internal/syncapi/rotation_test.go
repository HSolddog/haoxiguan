package syncapi

import (
	"errors"
	"testing"
)

func TestFrozenVaultRotationPreservesHistoryAndRevokesOldAuthorization(t *testing.T) {
	s, id, tokens, user := fixture(t)
	if _, err := s.Push(ctx, id, tokens.Epoch, []Operation{op(1, 0)}); err != nil {
		t.Fatal(err)
	}
	oldInvite, err := s.NewInvite(ctx, user)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err = s.RotateVault(ctx, user); !errors.Is(err, ErrReadOnly) {
		t.Fatal(err)
	}
	if err = s.SetReadOnly(ctx, user, true); err != nil {
		t.Fatal(err)
	}
	state, err := s.VaultState(ctx, id)
	if err != nil || !state.ReadOnly || state.Objects != 1 {
		t.Fatal(state, err)
	}
	if _, err = s.Push(ctx, id, tokens.Epoch, []Operation{op(2, 1)}); !errors.Is(err, ErrReadOnly) {
		t.Fatal(err)
	}
	page, err := s.Pull(ctx, id, tokens.Epoch, "", "", 100, true)
	if err != nil || len(page.Objects) != 1 {
		t.Fatal(page, err)
	}
	var before int64
	if err = s.db.QueryRow("SELECT used_bytes FROM users WHERE id=?", user).Scan(&before); err != nil {
		t.Fatal(err)
	}
	vault, invite, err := s.RotateVault(ctx, user)
	if err != nil || vault == id.Vault {
		t.Fatal(vault, err)
	}
	if _, err = s.Authenticate(ctx, tokens.Access); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
	if _, err = s.Refresh(ctx, tokens.Refresh); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
	if _, err = s.Enroll(ctx, oldInvite, "stale invitation"); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
	if _, err = s.Pull(ctx, id, tokens.Epoch, "", "", 100, false); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
	fresh, err := s.Enroll(ctx, invite, "trusted device with new keys")
	if err != nil || fresh.Vault != vault {
		t.Fatal(err)
	}
	freshID, err := s.Authenticate(ctx, fresh.Access)
	if err != nil {
		t.Fatal(err)
	}
	page, err = s.Pull(ctx, freshID, fresh.Epoch, "", "", 100, true)
	if err != nil || len(page.Objects) != 0 {
		t.Fatal(page, err)
	}
	var retained, budget int64
	if err = s.db.QueryRow("SELECT count(*) FROM objects WHERE vault=?", id.Vault).Scan(&retained); err != nil || retained != 1 {
		t.Fatal(retained, err)
	}
	if err = s.db.QueryRow("SELECT used_bytes FROM users WHERE id=?", user).Scan(&budget); err != nil || budget != before {
		t.Fatal(budget, err)
	}
	if _, err = s.Push(ctx, freshID, fresh.Epoch, []Operation{op(3, 0)}); err != nil {
		t.Fatal(err)
	}
	if err = s.DeleteAccount(ctx, freshID); err != nil {
		t.Fatal(err)
	}
	for _, table := range []string{"objects", "changes", "operations", "retired_vaults"} {
		var count int
		if err = s.db.QueryRow("SELECT count(*) FROM " + table).Scan(&count); err != nil || count != 0 {
			t.Fatal(table, count, err)
		}
	}
}

func TestUnfreezeKeepsExistingVaultAndPendingAuthorizationUsable(t *testing.T) {
	s, id, tokens, user := fixture(t)
	if err := s.SetReadOnly(ctx, user, true); err != nil {
		t.Fatal(err)
	}
	if err := s.SetReadOnly(ctx, user, false); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Push(ctx, id, tokens.Epoch, []Operation{op(1, 0)}); err != nil {
		t.Fatal(err)
	}
	next, err := s.Authenticate(ctx, tokens.Access)
	if err != nil || next.Vault != id.Vault {
		t.Fatal(next, err)
	}
}
