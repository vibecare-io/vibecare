package vc

import (
	"errors"
	"fmt"
)

// Exit codes. These are part of the CLI's contract with scripts and agents,
// so they are defined once here and mapped straight through by the cobra
// root command.
const (
	ExitOK          = 0
	ExitError       = 1
	ExitUnreachable = 2
	ExitNotFound    = 3
	ExitUsage       = 4
)

// Error is a failure that knows which exit code the process should use and
// what to print under --json. Every error crossing the vc package boundary
// should be one of these; anything else is mapped to ExitError.
type Error struct {
	Code int
	Msg  string
	Err  error
}

func (e *Error) Error() string {
	if e.Err == nil {
		return e.Msg
	}
	return e.Msg + ": " + e.Err.Error()
}

func (e *Error) Unwrap() error { return e.Err }

// Body renders the error for --json output.
func (e *Error) Body() ErrorBody {
	return ErrorBody{Code: e.Code, Message: e.Error()}
}

// Unreachable reports that core could not be contacted at addr. This is the
// single most common failure and gets its own constructor so the message is
// identical everywhere it is produced.
func Unreachable(addr string, err error) *Error {
	return &Error{
		Code: ExitUnreachable,
		Msg:  fmt.Sprintf("core unreachable at %s", addr),
		Err:  err,
	}
}

// NotFound reports that a named entity does not exist.
func NotFound(kind, id string) *Error {
	return &Error{Code: ExitNotFound, Msg: fmt.Sprintf("%s %q not found", kind, id)}
}

// Usagef reports invalid arguments.
func Usagef(format string, args ...any) *Error {
	return &Error{Code: ExitUsage, Msg: fmt.Sprintf(format, args...)}
}

// Errorf reports a general failure.
func Errorf(format string, args ...any) *Error {
	return &Error{Code: ExitError, Msg: fmt.Sprintf(format, args...)}
}

// Wrap attaches context to an error while preserving its exit code. A
// wrapped *Error keeps its own code; anything else becomes ExitError.
func Wrap(err error, format string, args ...any) error {
	if err == nil {
		return nil
	}
	code := ExitError
	var e *Error
	if errors.As(err, &e) {
		code = e.Code
	}
	return &Error{Code: code, Msg: fmt.Sprintf(format, args...), Err: err}
}

// ExitCode extracts the exit code an error implies.
func ExitCode(err error) int {
	if err == nil {
		return ExitOK
	}
	var e *Error
	if errors.As(err, &e) {
		return e.Code
	}
	return ExitError
}

// Body renders any error for --json output, defaulting non-vc errors to
// ExitError.
func Body(err error) ErrorBody {
	var e *Error
	if errors.As(err, &e) {
		return e.Body()
	}
	return ErrorBody{Code: ExitError, Message: err.Error()}
}
