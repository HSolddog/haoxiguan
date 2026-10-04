package main

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const lockContendedExitCode = 42

func TestProcessLockExcludesAnotherProcessAndReleases(t *testing.T) {
	path := filepath.Join(t.TempDir(), "data.sqlite")
	lock, err := os.OpenFile(path+".process.lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := lockProcessFile(lock); err != nil {
		t.Fatal(err)
	}
	defer unlockProcessFile(lock)
	runLockChild(t, path, "try", lockContendedExitCode)
	if err := unlockProcessFile(lock); err != nil {
		t.Fatal(err)
	}
	// Keep the original handle open: explicit unlock must admit a new process.
	runLockChild(t, path, "try", 0)
}

func TestProcessLockBlocksProtectedCommandsBeforeOpeningDatabase(t *testing.T) {
	path := filepath.Join(t.TempDir(), "data.sqlite")
	lock, err := os.OpenFile(path+".process.lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := lockProcessFile(lock); err != nil {
		t.Fatal(err)
	}
	defer unlockProcessFile(lock)
	for _, command := range []string{"serve", "backup", "rotate-epoch", "rotate-vault"} {
		t.Run(command, func(t *testing.T) {
			runLockChild(t, path, command, 0)
			if _, err := os.Stat(path); !os.IsNotExist(err) {
				t.Fatalf("blocked %s opened the database: %v", command, err)
			}
		})
	}
}

func TestProcessLockReleasedAfterOwnerProcessIsKilled(t *testing.T) {
	path := filepath.Join(t.TempDir(), "data.sqlite")
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	command := lockChildCommand(ctx, path, "hold")
	output, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	input, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	defer input.Close()
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if command.ProcessState == nil {
			_ = command.Process.Kill()
			_ = command.Wait()
		}
	})
	line, err := bufio.NewReader(output).ReadString('\n')
	if err != nil || strings.TrimSpace(line) != "acquired" {
		t.Fatalf("child failed to acquire lock: %q, %v", line, err)
	}
	runLockChild(t, path, "try", lockContendedExitCode)
	if err := command.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	_ = command.Wait()
	// Reopening the same lock file after a crash must not leave a stale lock.
	runLockChild(t, path, "try", 0)
}

func lockChildCommand(ctx context.Context, path, action string) *exec.Cmd {
	command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestProcessLockChild$")
	command.Env = append(os.Environ(), "HAOXIGUAN_TEST_LOCK_PATH="+path,
		"HAOXIGUAN_TEST_LOCK_ACTION="+action)
	return command
}

func runLockChild(t *testing.T, path, action string, expectedExit int) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	command := lockChildCommand(ctx, path, action)
	output, err := command.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("lock operation blocked instead of returning immediately: %v", ctx.Err())
	}
	if err != nil {
		if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != expectedExit {
			t.Fatalf("child %s: %v; output: %s", action, err, output)
		}
	} else if expectedExit != 0 {
		t.Fatalf("another process acquired an already held lock: %s", output)
	}
}

func TestProcessLockChild(t *testing.T) {
	path := os.Getenv("HAOXIGUAN_TEST_LOCK_PATH")
	if path == "" {
		return
	}
	action := os.Getenv("HAOXIGUAN_TEST_LOCK_ACTION")
	if action != "try" && action != "hold" {
		os.Args = []string{"haoxiguan-server", action, "--db", path, "--listen", "127.0.0.1:0"}
		if err := run(); err == nil || !strings.Contains(err.Error(), "server is already running") {
			t.Fatalf("protected command did not reject held process lock: %v", err)
		}
		return
	}
	lock, err := os.OpenFile(path+".process.lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := lockProcessFile(lock); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(lockContendedExitCode)
	}
	defer unlockProcessFile(lock)
	fmt.Println("acquired")
	if action == "hold" {
		_, _ = os.Stdin.Read(make([]byte, 1))
	}
}
