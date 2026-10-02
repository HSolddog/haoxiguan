package syncapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func call(h http.Handler, method, path, token, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}
func TestHTTPAuthorizationAndValidation(t *testing.T) {
	s, _, tokens, _ := fixture(t)
	h := Handler(s)
	if w := call(h, "GET", "/v1/devices", "", ""); w.Code != 401 {
		t.Fatal(w.Code)
	}
	if w := call(h, "POST", "/v1/push", tokens.Access, `{"epoch":"x","operations":[],"userId":"forged"}`); w.Code != 400 {
		t.Fatal(w.Code)
	}
	if w := call(h, "POST", "/v1/push", tokens.Access, strings.Repeat("x", 2*1024*1024+1)); w.Code != 400 {
		t.Fatal(w.Code)
	}
	if w := call(h, "GET", "/v1/pull?epoch="+tokens.Epoch+"&limit=9999999", tokens.Access, ""); w.Code != 400 {
		t.Fatal(w.Code)
	}
	if w := call(h, "DELETE", "/v1/account", tokens.Access, ""); w.Code != 400 {
		t.Fatal(w.Code)
	}
	body, _ := json.Marshal(map[string]any{"epoch": tokens.Epoch, "operations": []Operation{op(1, 0)}})
	w := call(h, "POST", "/v1/push", tokens.Access, string(body))
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	if strings.Contains(w.Body.String(), op(1, 0).Ciphertext) {
		t.Fatal("accepted reply leaks extra payload")
	}
	if w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal(w.Header())
	}
}
func TestHTTPAuthRateLimit(t *testing.T) {
	s, _, _, _ := fixture(t)
	h := Handler(s)
	for i := 0; i < 10; i++ {
		w := call(h, "POST", "/v1/auth/enroll", "", `{"invite":"invalid","deviceName":"phone"}`)
		if w.Code == 429 {
			t.Fatal("early limit")
		}
	}
	w := call(h, "POST", "/v1/auth/enroll", "", `{}`)
	if w.Code != 429 {
		t.Fatal(w.Code)
	}
	if bytes.Contains(w.Body.Bytes(), []byte("invalid")) {
		t.Fatal("response included input")
	}
}
func TestBackupReopenAndFutureSchema(t *testing.T) {
	s, id, tokens, _ := fixture(t)
	if _, err := s.Push(ctx, id, tokens.Epoch, []Operation{op(1, 0)}); err != nil {
		t.Fatal(err)
	}
	path := t.TempDir() + "/backup.sqlite"
	if err := s.Backup(ctx, path); err != nil {
		t.Fatal(err)
	}
	copy, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	page, err := copy.Pull(ctx, id, tokens.Epoch, "", "", 100, false)
	if err != nil || len(page.Objects) != 1 {
		t.Fatal(page, err)
	}
	if _, err = copy.db.Exec("PRAGMA user_version=999"); err != nil {
		t.Fatal(err)
	}
	copy.Close()
	if _, err = Open(path); err == nil {
		t.Fatal("future schema opened")
	}
}
