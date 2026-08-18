//go:build windows

package storage

import "os"

// The backend has no Windows build, so the lock is a no-op there rather than an untested
// implementation. LockFileEx is the equivalent when a Windows build appears, and this file
// is the only one that needs to change.
func tryLockFile(*os.File) error { return nil }

func unlockFile(*os.File) error { return nil }
