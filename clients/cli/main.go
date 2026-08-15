// Command vibecare inspects and drives a running VibeCare core, from a
// terminal or from a script. Everything it can do lives in internal/cli.
package main

import (
	"os"

	"github.com/vibecare-io/vibecare/clients/cli/internal/cli"
)

func main() {
	// The exit code is the contract scripts read, so it is produced in one
	// place and returned rather than being scattered through os.Exit calls.
	os.Exit(cli.Execute())
}
