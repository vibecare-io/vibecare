package cli

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// A bare "connection refused" tells a user nothing they can act on. The
// three things they actually need are: start it, read why it died, or wait
// for it. Anything less turns a one-command fix into a search.
func TestUnreachableSuggestsWhatToDo(t *testing.T) {
	_, errText, code := capture(t, "plugins", "--addr", deadAddr, "--no-color")

	if code != vc.ExitUnreachable {
		t.Fatalf("exit = %d, want %d", code, vc.ExitUnreachable)
	}
	for _, want := range []string{"just run", "server.log", "--wait"} {
		if !strings.Contains(errText, want) {
			t.Errorf("stderr missing the %q hint\n--- stderr ---\n%s", want, errText)
		}
	}
}

// Hints are for humans. Under --json the error stream is a contract, and a
// consumer that reads stderr must find an envelope there and nothing else.
func TestJSONErrorCarriesNoHints(t *testing.T) {
	_, errText, code := capture(t, "plugins", "--addr", deadAddr, "--json")

	if code != vc.ExitUnreachable {
		t.Fatalf("exit = %d, want %d", code, vc.ExitUnreachable)
	}
	if strings.Contains(errText, "just run") {
		t.Errorf("human hints polluted the --json error stream:\n%s", errText)
	}

	var env struct {
		V   int `json:"v"`
		Err *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(errText)), &env); err != nil {
		t.Fatalf("stderr is not a single JSON envelope: %v\n%s", err, errText)
	}
	if env.V != vc.ContractVersion {
		t.Errorf("envelope v = %d, want %d", env.V, vc.ContractVersion)
	}
	if env.Err == nil || env.Err.Code != vc.ExitUnreachable {
		t.Errorf("envelope error = %+v, want code %d", env.Err, vc.ExitUnreachable)
	}
}

// Telling someone to "wait for it" after they already waited is noise, and
// it implies the fix is something they have not tried.
func TestWaitFlagSuppressesTheWaitHint(t *testing.T) {
	_, errText, _ := capture(t, "plugins", "--addr", deadAddr, "--no-color", "--wait", "150ms")

	if strings.Contains(errText, "--wait") {
		t.Errorf("suggested --wait to a user who already passed it\n--- stderr ---\n%s", errText)
	}
	if !strings.Contains(errText, "just run") {
		t.Errorf("dropped the still-useful hints along with the wait hint\n--- stderr ---\n%s", errText)
	}
}

// Hints belong to unreachability alone. A usage error or a missing schedule
// has nothing to do with core being down, and suggesting `just run` there
// would send the user off to fix a system that is working.
func TestHintsOnlyForUnreachable(t *testing.T) {
	_, errText, code := capture(t, "nonsense-command", "--no-color")

	if code != vc.ExitUsage {
		t.Fatalf("exit = %d, want %d", code, vc.ExitUsage)
	}
	if strings.Contains(errText, "just run") {
		t.Errorf("offered core-is-down hints for a usage error\n--- stderr ---\n%s", errText)
	}
}
