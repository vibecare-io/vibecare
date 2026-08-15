// Package plugbuild runs a plugin's declared build command.
//
// It knows nothing about VibeCare beyond "a directory and a command string".
// Two things it is deliberate about:
//
// No shell. The command is split into argv and exec'd directly, so a
// manifest cannot turn into a pipeline, a redirect, or a `;rm -rf`. Both
// shapes a build command actually takes — `just build-todo-plugin` and
// `go build -tags dev -o todo .` — are plain argv, so a shell buys nothing
// and costs the one property worth having here. A build that genuinely needs
// shell features belongs in a script the manifest names.
//
// Output is captured, not streamed. A build that succeeds has nothing worth
// reading; one that fails has everything, and the caller wants it as a value
// it can put in an error or a JSON field rather than as bytes that already
// went to a terminal.
package plugbuild

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"
	"unicode"
)

// Result is what one build produced.
type Result struct {
	Command  []string
	Output   string
	Duration time.Duration
}

// Run executes command in dir. A non-zero exit is an error whose message
// carries the build output, because "build failed" without the compiler's
// reason is the least useful thing this could report.
func Run(ctx context.Context, dir, command string) (Result, error) {
	argv, err := Split(command)
	if err != nil {
		return Result{}, err
	}
	if len(argv) == 0 {
		return Result{}, fmt.Errorf("no build command declared")
	}

	start := time.Now()
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir = dir

	var buf bytes.Buffer
	cmd.Stdout, cmd.Stderr = &buf, &buf
	runErr := cmd.Run()

	res := Result{Command: argv, Output: buf.String(), Duration: time.Since(start)}
	if runErr != nil {
		return res, fmt.Errorf("%s: %w\n%s", argv[0], runErr, strings.TrimRight(buf.String(), "\n"))
	}
	return res, nil
}

// Split turns a command string into argv, honouring single and double
// quotes so a path with a space survives. It is not a shell: it expands
// nothing, and an unterminated quote is an error rather than a guess.
func Split(s string) ([]string, error) {
	var (
		argv  []string
		cur   strings.Builder
		quote rune
		open  bool
	)
	flush := func() {
		if open || cur.Len() > 0 {
			argv = append(argv, cur.String())
			cur.Reset()
		}
	}

	for _, r := range s {
		switch {
		case quote != 0:
			if r == quote {
				quote = 0
				continue
			}
			cur.WriteRune(r)
		case r == '\'' || r == '"':
			quote = r
			open = true
		case unicode.IsSpace(r):
			flush()
			open = false
		default:
			cur.WriteRune(r)
		}
	}
	if quote != 0 {
		return nil, fmt.Errorf("unterminated %c quote in build command", quote)
	}
	flush()
	return argv, nil
}
