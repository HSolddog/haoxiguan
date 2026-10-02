package syncapi

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"
)

func schemaOneFixture(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "schema1.sqlite")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ddl, err := os.ReadFile("testdata/schema1.sql")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(string(ddl)); err != nil {
		t.Fatal(err)
	}
	statements := []string{
		"INSERT INTO metadata VALUES('epoch','original-encryption-epoch')",
		"INSERT INTO users(id,name,vault,created,used_bytes) VALUES('user','synthetic legacy','vault',100,1234)",
		"INSERT INTO devices(id,user_id,name,created,last_seen) VALUES('device','user','legacy phone',100,100)",
		"INSERT INTO objects VALUES('vault','entity_legacy_0001',7,'original-encryption-epoch',6,'original opaque bytes',0,100)",
		"INSERT INTO changes(vault,id,revision,epoch,base_revision,ciphertext,deleted,created) VALUES('vault','entity_legacy_0001',7,'original-encryption-epoch',6,'original opaque bytes',0,100)",
	}
	for _, statement := range statements {
		if _, err = db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	return path
}

func TestFrozenSchemaOneUpgradeKeepsObjectsAndEpoch(t *testing.T) {
	path := schemaOneFixture(t)
	for range 2 {
		s, err := Open(path)
		if err != nil {
			t.Fatal(err)
		}
		var version, readOnly, used, revision int
		var epoch, cipher string
		if err = s.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 2 {
			t.Fatal(version, err)
		}
		if err = s.db.QueryRow("SELECT read_only,used_bytes FROM users WHERE id='user'").Scan(&readOnly, &used); err != nil || readOnly != 0 || used != 1234 {
			t.Fatal(readOnly, used, err)
		}
		if err = s.db.QueryRow("SELECT revision,ciphertext FROM objects WHERE vault='vault'").Scan(&revision, &cipher); err != nil || revision != 7 || cipher != "original opaque bytes" {
			t.Fatal(revision, cipher, err)
		}
		if err = s.db.QueryRow("SELECT value FROM metadata WHERE key='epoch'").Scan(&epoch); err != nil || epoch != "original-encryption-epoch" {
			t.Fatal(epoch, err)
		}
		s.Close()
	}
}

func TestSchemaOneFailureRollsBackEarlierDDL(t *testing.T) {
	path := schemaOneFixture(t)
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	// The second migration statement will fail after ALTER TABLE has executed.
	if _, err = db.Exec("CREATE TABLE retired_vaults(collision TEXT)"); err != nil {
		t.Fatal(err)
	}
	db.Close()
	if s, err := Open(path); err == nil {
		s.Close()
		t.Fatal("expected migration to stop")
	}
	db, err = sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	var version, columns, objects int
	if err = db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 1 {
		t.Fatal(version, err)
	}
	if err = db.QueryRow("SELECT count(*) FROM pragma_table_info('users') WHERE name='read_only'").Scan(&columns); err != nil || columns != 0 {
		t.Fatal(columns, err)
	}
	if err = db.QueryRow("SELECT count(*) FROM objects WHERE ciphertext='original opaque bytes'").Scan(&objects); err != nil || objects != 1 {
		t.Fatal(objects, err)
	}
	// Remove only the test-injected collision, then retry the preserved database.
	if _, err = db.Exec("DROP TABLE retired_vaults"); err != nil {
		t.Fatal(err)
	}
	db.Close()
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
}
