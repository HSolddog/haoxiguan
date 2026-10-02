package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/HSolddog/haoxiguan/server/internal/syncapi"
)

func main() {
	if err := run(); err != nil {
		log.Print(err)
		os.Exit(1)
	}
}
func run() error {
	if len(os.Args) < 2 {
		return fmt.Errorf("usage: haoxiguan-server serve|create-user|invite|freeze-user|unfreeze-user|rotate-vault|rotate-epoch|backup [flags]")
	}
	command := os.Args[1]
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	path := flags.String("db", "./data/haoxiguan.sqlite", "SQLite database on a local persistent volume")
	address := flags.String("listen", "127.0.0.1:8787", "HTTP address, put HTTPS reverse proxy in front")
	name := flags.String("name", "", "account display name")
	certFile := flags.String("tls-cert", "", "optional PEM TLS certificate for direct HTTPS")
	keyFile := flags.String("tls-key", "", "PEM private key paired with --tls-cert")
	user := flags.String("user", "", "operator-known account ID")
	output := flags.String("out", "", "new file to write, must not exist")
	prepared := flags.Bool("prepared", false, "trusted device has completed read-only reconciliation and saved a verified encrypted data backup")
	if err := flags.Parse(os.Args[2:]); err != nil {
		return err
	}
	if (*certFile == "") != (*keyFile == "") {
		return fmt.Errorf("--tls-cert and --tls-key must be supplied together")
	}
	if err := os.MkdirAll(filepath.Dir(*path), 0700); err != nil {
		return err
	}
	// serve and maintenance commands exclude each other across processes. No
	// destructive restore command is exposed; restore an offline consistent file.
	if command == "serve" || command == "rotate-epoch" || command == "backup" || command == "rotate-vault" {
		lock, err := os.OpenFile(*path+".process.lock", os.O_CREATE|os.O_RDWR, 0600)
		if err != nil {
			return err
		}
		defer lock.Close()
		if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
			return fmt.Errorf("server is already running; stop it before maintenance: %w", err)
		}
		defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	}
	store, err := syncapi.Open(*path)
	if err != nil {
		return err
	}
	defer store.Close()
	if err = os.Chmod(*path, 0600); err != nil {
		return err
	}
	ctx := context.Background()
	switch command {
	case "create-user":
		if *output == "" {
			return fmt.Errorf("--out is required; enrollment secrets are not printed")
		}
		// Refuse existing output before changing the database. If writing later fails,
		// the operator can issue a replacement invitation for the created account.
		file, err := os.OpenFile(*output, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			return err
		}
		defer file.Close()
		id, vault, invite, err := store.CreateUser(ctx, *name)
		if err != nil {
			return err
		}
		if err = json.NewEncoder(file).Encode(map[string]string{"userId": id, "vaultId": vault, "invite": invite}); err != nil {
			return err
		}
		return file.Sync()
	case "invite":
		if *output == "" {
			return fmt.Errorf("--out is required")
		}
		file, err := os.OpenFile(*output, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			return err
		}
		defer file.Close()
		invite, err := store.NewInvite(ctx, *user)
		if err != nil {
			return err
		}
		if err = json.NewEncoder(file).Encode(map[string]string{"invite": invite}); err != nil {
			return err
		}
		return file.Sync()
	case "freeze-user", "unfreeze-user":
		return store.SetReadOnly(ctx, *user, command == "freeze-user")
	case "rotate-vault":
		if !*prepared || *output == "" {
			return fmt.Errorf("--prepared and --out are required; complete read-only client reconciliation first")
		}
		file, err := os.OpenFile(*output, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			return err
		}
		defer file.Close()
		vault, invite, err := store.RotateVault(ctx, *user)
		if err != nil {
			return err
		}
		if err = json.NewEncoder(file).Encode(map[string]string{"userId": *user, "vaultId": vault, "invite": invite}); err != nil {
			return err
		}
		return file.Sync()
	case "rotate-epoch":
		return store.RotateEpoch(ctx)
	case "backup":
		if *output == "" {
			return fmt.Errorf("--out is required")
		}
		return store.Backup(ctx, *output)
	case "serve":
		server := &http.Server{Addr: *address, Handler: syncapi.Handler(store), ReadHeaderTimeout: 5 * time.Second,
			ReadTimeout: 30 * time.Second, WriteTimeout: 60 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 * 1024, TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12}}
		stopping, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
		defer stop()
		done := make(chan struct{})
		go func() {
			defer close(done)
			<-stopping.Done()
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			_ = server.Shutdown(ctx)
		}()
		log.Printf("haoxiguan sync protocol %d listening on %s", syncapi.ProtocolVersion, *address)
		var err error
		if *certFile != "" {
			err = server.ListenAndServeTLS(*certFile, *keyFile)
		} else {
			err = server.ListenAndServe()
		}
		stop()
		<-done
		if err == http.ErrServerClosed {
			return nil
		}
		return err
	default:
		return fmt.Errorf("unknown command %q", command)
	}
}
