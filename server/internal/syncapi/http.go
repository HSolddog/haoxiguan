package syncapi

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

type API struct {
	Store *Store
	mu    sync.Mutex
	rates map[string]*bucket
}
type bucket struct {
	tokens  float64
	updated time.Time
}

func Handler(store *Store) http.Handler {
	api := &API{Store: store, rates: map[string]*bucket{}}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { respond(w, 200, map[string]string{"status": "ok"}) })
	mux.HandleFunc("GET /v1/capabilities", func(w http.ResponseWriter, r *http.Request) {
		epoch, err := store.Epoch(r.Context())
		if err != nil {
			failure(w, err)
			return
		}
		respond(w, 200, map[string]any{"protocol": ProtocolVersion, "epoch": epoch, "maxObjectBytes": MaxObjectBytes, "maxBatch": MaxBatch, "historyRetention": "until-quota", "encryptionSuite": "xchacha20poly1305-v1"})
	})
	mux.HandleFunc("POST /v1/auth/enroll", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Invite string `json:"invite"`
			Name   string `json:"deviceName"`
		}
		if !decode(w, r, &body) {
			return
		}
		tokens, err := store.Enroll(r.Context(), body.Invite, body.Name)
		if err != nil {
			failure(w, err)
			return
		}
		respond(w, 201, tokens)
	})
	mux.HandleFunc("POST /v1/auth/refresh", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Refresh string `json:"refreshToken"`
		}
		if !decode(w, r, &body) {
			return
		}
		tokens, err := store.Refresh(r.Context(), body.Refresh)
		if err != nil {
			failure(w, err)
			return
		}
		respond(w, 200, tokens)
	})
	mux.HandleFunc("POST /v1/push", api.authorized(func(w http.ResponseWriter, r *http.Request, id Identity) {
		var body struct {
			Epoch      string      `json:"epoch"`
			Operations []Operation `json:"operations"`
		}
		if !decode(w, r, &body) {
			return
		}
		results, err := store.Push(r.Context(), id, body.Epoch, body.Operations)
		if err != nil {
			failure(w, err)
			return
		}
		respond(w, 200, map[string]any{"results": results})
	}))
	for _, path := range []string{"/v1/pull", "/v1/bootstrap"} {
		mux.HandleFunc("GET "+path, api.authorized(func(w http.ResponseWriter, r *http.Request, id Identity) {
			limit := 100
			if r.URL.Query().Get("limit") != "" {
				var err error
				limit, err = strconv.Atoi(r.URL.Query().Get("limit"))
				if err != nil {
					failure(w, ErrInvalid)
					return
				}
			}
			q := r.URL.Query()
			page, err := store.Pull(r.Context(), id, q.Get("epoch"), q.Get("cursor"), q.Get("highWater"), limit, r.URL.Path == "/v1/bootstrap")
			if err != nil {
				failure(w, err)
				return
			}
			respond(w, 200, page)
		}))
	}
	mux.HandleFunc("GET /v1/vault", api.authorized(func(w http.ResponseWriter, r *http.Request, id Identity) {
		state, err := store.VaultState(r.Context(), id)
		if err != nil {
			failure(w, err)
			return
		}
		respond(w, 200, state)
	}))
	mux.HandleFunc("GET /v1/devices", api.authorized(func(w http.ResponseWriter, r *http.Request, id Identity) {
		devices, err := store.Devices(r.Context(), id)
		if err != nil {
			failure(w, err)
			return
		}
		respond(w, 200, map[string]any{"devices": devices})
	}))
	mux.HandleFunc("POST /v1/devices/{device}/revoke", api.authorized(func(w http.ResponseWriter, r *http.Request, id Identity) {
		if err := store.Revoke(r.Context(), id, r.PathValue("device")); err != nil {
			failure(w, err)
			return
		}
		respond(w, 200, map[string]bool{"revoked": true})
	}))
	mux.HandleFunc("DELETE /v1/account", api.authorized(func(w http.ResponseWriter, r *http.Request, id Identity) {
		if r.Header.Get("X-Confirm-Delete") != "delete-remote-account" {
			failure(w, ErrInvalid)
			return
		}
		if err := store.DeleteAccount(r.Context(), id); err != nil {
			failure(w, err)
			return
		}
		respond(w, 200, map[string]bool{"deleted": true})
	}))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		// Ignore forwarded IP headers unless a trusted reverse-proxy layer enforces them.
		// Bound the map as well as per-IP bursts; do not log request bodies or headers.
		host, _, _ := net.SplitHostPort(r.RemoteAddr)
		if !api.allow(host, strings.HasPrefix(r.URL.Path, "/v1/auth/")) {
			w.Header().Set("Retry-After", "30")
			respond(w, 429, map[string]string{"error": "rate_limited"})
			return
		}
		mux.ServeHTTP(w, r)
	})
}
func (a *API) allow(ip string, auth bool) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := time.Now()
	key := ip
	rate, burst := 10.0, 200.0
	if auth {
		key = "auth:" + ip
		rate, burst = 0.2, 10
	}
	b := a.rates[key]
	if b == nil {
		if len(a.rates) >= 10000 {
			for k, v := range a.rates {
				if now.Sub(v.updated) > 10*time.Minute {
					delete(a.rates, k)
				}
			}
			if len(a.rates) >= 10000 {
				return false
			}
		}
		b = &bucket{tokens: burst, updated: now}
		a.rates[key] = b
	}
	b.tokens = min(burst, b.tokens+now.Sub(b.updated).Seconds()*rate)
	b.updated = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}
func (a *API) authorized(next func(http.ResponseWriter, *http.Request, Identity)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		if !strings.HasPrefix(header, "Bearer ") {
			failure(w, ErrUnauthorized)
			return
		}
		id, err := a.Store.Authenticate(r.Context(), strings.TrimPrefix(header, "Bearer "))
		if err != nil {
			failure(w, err)
			return
		}
		next(w, r, id)
	}
}
func decode(w http.ResponseWriter, r *http.Request, value any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 2*1024*1024)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		failure(w, ErrInvalid)
		return false
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		failure(w, ErrInvalid)
		return false
	}
	return true
}
func respond(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
func failure(w http.ResponseWriter, err error) {
	code, status := "internal_error", 500
	switch {
	case errors.Is(err, ErrUnauthorized):
		code, status = "unauthorized", 401
	case errors.Is(err, ErrInvalid):
		code, status = "invalid_request", 400
	case errors.Is(err, ErrConflict):
		code, status = "op_id_reused", 409
	case errors.Is(err, ErrEpoch):
		code, status = "epoch_changed", 409
	case errors.Is(err, ErrStale):
		code, status = "device_stale", 409
	case errors.Is(err, ErrReadOnly):
		code, status = "maintenance_read_only", 409
	case errors.Is(err, ErrQuota):
		code, status = "quota_exceeded", 413
	}
	respond(w, status, map[string]string{"error": code})
}
