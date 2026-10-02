package syncapi

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// Explicit diagnostic only. Direct Store calls measure SQLite and transaction
// scheduling, not TLS, HTTP rate limits, cryptography or network throughput.
func TestSmallServerCapacity(t *testing.T) {
	output := os.Getenv("HAOXIGUAN_SCALE_OUTPUT")
	if output == "" {
		t.Skip("set HAOXIGUAN_SCALE_OUTPUT to run the synthetic capacity diagnostic")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	const users, devices, records, batchSize = 20, 3, 5000, 100
	directory := t.TempDir()
	path := filepath.Join(directory, "capacity.sqlite")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ids := make([][]Identity, users)
	epoch, err := s.Epoch(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for u := range users {
		user, _, invite, err := s.CreateUser(ctx, fmt.Sprintf("synthetic-%d", u))
		if err != nil {
			t.Fatal(err)
		}
		for d := 0; d < devices; d++ {
			if d > 0 {
				invite, err = s.NewInvite(ctx, user)
				if err != nil {
					t.Fatal(err)
				}
			}
			token, err := s.Enroll(ctx, invite, fmt.Sprintf("device-%d", d))
			if err != nil {
				t.Fatal(err)
			}
			id, err := s.Authenticate(ctx, token.Access)
			if err != nil {
				t.Fatal(err)
			}
			ids[u] = append(ids[u], id)
		}
	}
	cipher := func(u, i int) string {
		b := make([]byte, 1024)
		copy(b, fmt.Sprintf("synthetic:%d:%d", u, i))
		return base64.StdEncoding.EncodeToString(b)
	}
	var mu sync.Mutex
	pushTimes, pullTimes := []float64{}, []float64{}
	var wg sync.WaitGroup
	start := time.Now()
	for u := 0; u < users; u++ {
		wg.Add(1)
		go func(u int) {
			defer wg.Done()
			for offset := 0; offset < records; offset += batchSize {
				ops := make([]Operation, 0, batchSize)
				for i := offset; i < offset+batchSize; i++ {
					ops = append(ops, Operation{ID: fmt.Sprintf("synthetic_operation_%03d_%06d", u, i), Entity: fmt.Sprintf("synthetic_entity_%03d_%06d", u, i), Ciphertext: cipher(u, i)})
				}
				began := time.Now()
				results, err := s.Push(ctx, ids[u][0], epoch, ops)
				elapsed := float64(time.Since(began).Microseconds()) / 1000
				if err != nil {
					t.Error(err)
					cancel()
					return
				}
				for _, r := range results {
					if r.Status != "accepted" || r.Revision != 1 {
						t.Error("unexpected write outcome")
						cancel()
						return
					}
				}
				mu.Lock()
				pushTimes = append(pushTimes, elapsed)
				mu.Unlock()
			}
		}(u)
	}
	wg.Wait()
	if t.Failed() {
		return
	}
	pushDuration := time.Since(start)
	start = time.Now()
	for u := 0; u < users; u++ {
		for d := 0; d < devices; d++ {
			wg.Add(1)
			go func(u, d int) {
				defer wg.Done()
				after, high, count := "", "", 0
				for {
					began := time.Now()
					page, err := s.Pull(ctx, ids[u][d], epoch, after, high, 200, true)
					elapsed := float64(time.Since(began).Microseconds()) / 1000
					if err != nil {
						t.Error(err)
						cancel()
						return
					}
					for _, o := range page.Objects {
						var owner, index int
						if _, err := fmt.Sscanf(o.Entity, "synthetic_entity_%03d_%06d", &owner, &index); err != nil || owner != u || index != count || o.Revision != 1 || o.Ciphertext != cipher(u, index) {
							t.Error("lost, reordered or cross-vault object")
							cancel()
							return
						}
						count++
					}
					mu.Lock()
					pullTimes = append(pullTimes, elapsed)
					mu.Unlock()
					after, high = page.Cursor, page.HighWater
					if !page.More {
						break
					}
				}
				if count != records {
					t.Errorf("expected %d, got %d", records, count)
				}
			}(u, d)
		}
	}
	wg.Wait()
	if t.Failed() {
		return
	}
	pullDuration := time.Since(start)
	backup := filepath.Join(directory, "snapshot.sqlite")
	start = time.Now()
	if err := s.Backup(ctx, backup); err != nil {
		t.Fatal(err)
	}
	backupDuration := time.Since(start)
	restored, err := Open(backup)
	if err != nil {
		t.Fatal(err)
	}
	var restoredCount int
	if err := restored.db.QueryRowContext(ctx, "SELECT count(*) FROM objects").Scan(&restoredCount); err != nil {
		t.Fatal(err)
	}
	var health string
	if err := restored.db.QueryRowContext(ctx, "PRAGMA quick_check").Scan(&health); err != nil || health != "ok" {
		t.Fatal("restored DB integrity", err)
	}
	restored.Close()
	if restoredCount != users*records {
		t.Fatal("backup object count", restoredCount)
	}
	percentile := func(values []float64, p float64) float64 {
		sort.Float64s(values)
		return values[int(float64(len(values)-1)*p)]
	}
	info, err := os.Stat(backup)
	if err != nil {
		t.Fatal(err)
	}
	report := map[string]any{"status": "passed", "mode": "direct Go Store; includes synthetic client CPU; excludes HTTP/TLS/rate limits/crypto", "go": runtime.Version(), "arch": runtime.GOARCH, "users": users, "devicesPerUser": devices, "objectsTotal": users * records, "ciphertextBytesPerObject": 1024, "pushConcurrency": users, "pullConcurrency": users * devices, "pushBatchSize": batchSize, "pushSamples": len(pushTimes), "pushDurationMs": pushDuration.Milliseconds(), "pushBatchP50Ms": percentile(pushTimes, .5), "pushBatchP95Ms": percentile(pushTimes, .95), "pullPageSize": 200, "pullSamples": len(pullTimes), "pullDurationMs": pullDuration.Milliseconds(), "pullPageP95Ms": percentile(pullTimes, .95), "backupMs": backupDuration.Milliseconds(), "snapshotBytes": info.Size(), "fullBootstrapDataVerified": true, "backupQuickCheck": "ok"}
	if status, err := os.ReadFile("/proc/self/status"); err == nil {
		for _, line := range strings.Split(string(status), "\n") {
			if strings.HasPrefix(line, "VmHWM:") {
				fields := strings.Fields(line)
				if len(fields) >= 2 {
					peak, err := strconv.ParseInt(fields[1], 10, 64)
					if err == nil {
						report["processPeakRssKiB"] = peak
					}
				}
			}
		}
	}
	if peak, err := os.ReadFile("/sys/fs/cgroup/memory.peak"); err == nil {
		report["containerPeakMemoryBytesIncludingPageCache"] = string(peak)
	}
	raw, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(output, append(raw, '\n'), 0600); err != nil {
		t.Fatal(err)
	}
	t.Log(string(raw))
}
