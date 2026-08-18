//go:build !windows

package storage

import (
	"errors"
	"os"
	"syscall"
)

// tryLockFile takes an exclusive flock without blocking. flock locks are tied to the open
// file description, so a second os.OpenFile of the same path conflicts even within one
// process - unlike fcntl locks, which would hand the same process a second lock and quietly
// defeat the guard.
func tryLockFile(file *os.File) error {
	err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	switch {
	case err == nil:
		return nil
	case errors.Is(err, syscall.EWOULDBLOCK):
		return errLockHeld
	default:
		return err
	}
}

func unlockFile(file *os.File) error {
	return syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
}
