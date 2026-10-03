package main

import (
	"os"

	"golang.org/x/sys/windows"
)

// Lock the same first byte in every process. Windows permits locking beyond EOF,
// so the dedicated empty lock file needs no writes or truncation. FAIL_IMMEDIATELY
// preserves the Unix nonblocking contract, including for overlapped handles.
func lockProcessFile(file *os.File) error {
	return windows.LockFileEx(windows.Handle(file.Fd()),
		windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY,
		0, 1, 0, &windows.Overlapped{})
}

func unlockProcessFile(file *os.File) error {
	return windows.UnlockFileEx(windows.Handle(file.Fd()), 0, 1, 0, &windows.Overlapped{})
}
