package syncapi

import (
	"context"
	"errors"
	"os"
	"strings"
)

// Backup produces a consistent SQLite snapshot. The CLI holds the process lock
// with HTTP stopped, and VACUUM INTO includes all committed WAL data.
func (s *Store) Backup(ctx context.Context, path string) error {
	if _, err := os.Stat(path); err == nil {
		return errors.New("backup destination already exists")
	} else if !os.IsNotExist(err) {
		return err
	}
	if strings.ContainsRune(path, 0) {
		return ErrInvalid
	}
	// VACUUM cannot parameterize a database name in all supported SQLite bindings;
	// this is a SQL string literal, never a shell command or SQL identifier.
	quoted := "'" + strings.ReplaceAll(path, "'", "''") + "'"
	if _, err := s.db.ExecContext(ctx, "VACUUM INTO "+quoted); err != nil {
		return err
	}
	if err := os.Chmod(path, 0600); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer file.Close()
	return file.Sync()
}
