package vibecheck

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
	"time"

	pluginv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/plugin/v1"
	"google.golang.org/grpc"
)

// The three assertions below cannot be driven from the live kernel, and it
// is worth being precise about why rather than leaving it as a preference:
//
//   - A CLEAN stream end. rpc.go returns nil from Register in exactly one
//     place — `case e, ok := <-events: if !ok { return nil }`. That channel
//     is closed only by the unsubscribe func Bus.Subscribe hands back, and
//     the only holder of it is the Register handler's own defer, which
//     cannot run until the handler has already returned. Neither Bus nor
//     that func is reachable through Kernel's exported surface, so from
//     outside the kernel package there is no way to make a live core take
//     that branch.
//   - A post-Ready FLAP. The live kernel holds the stream open for as long
//     as the plugin does; nothing short of editing it makes it send Ready
//     and then drop, repeatedly, on demand.
//
// So these use a scripted core: a real gRPC server, on a real unix socket,
// speaking the real plugin.v1 contract to the real Swift binary as a real
// subprocess. Nothing about the plugin is stubbed — only core's script is
// ours, which is the entire point.

// scriptedCore is a PluginHost that answers Register according to a script.
type scriptedCore struct {
	pluginv1.UnimplementedPluginHostServer

	// dropSessions is how many of the first sessions end CLEANLY (a bare
	// `return nil`, byte-for-byte the branch rpc.go:148 takes) shortly after
	// Ready. Later sessions are held open until the plugin goes away.
	// -1 means "every session".
	dropSessions int
	// holdAfterReady is how long a dropped session stays open after Ready,
	// long enough for the SDK to actually observe Ready before the end.
	holdAfterReady time.Duration

	mu        sync.Mutex
	registers []registration

	// conns counts accepted transport connections. It is what separates an
	// inner-ladder reconnect (same gRPC client, same connection, a fresh
	// Register on it) from the outer loop tearing the whole client down and
	// redialling. Both produce a second Register, so a test that counted
	// only Register calls would pass either way.
	conns *countingListener
}

type countingListener struct {
	net.Listener
	mu sync.Mutex
	n  int
}

func (l *countingListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err == nil {
		l.mu.Lock()
		l.n++
		l.mu.Unlock()
	}
	return c, err
}

func (l *countingListener) count() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.n
}

type registration struct {
	at   time.Time
	port uint32
}

func (c *scriptedCore) Register(req *pluginv1.RegisterReq, stream pluginv1.PluginHost_RegisterServer) error {
	c.mu.Lock()
	n := len(c.registers)
	c.registers = append(c.registers, registration{at: time.Now(), port: req.GetHttpPort()})
	c.mu.Unlock()

	if err := stream.Send(&pluginv1.CoreMsg{K: &pluginv1.CoreMsg_Ready{Ready: &pluginv1.Ready{}}}); err != nil {
		return err
	}

	if c.dropSessions < 0 || n < c.dropSessions {
		time.Sleep(c.holdAfterReady)
		return nil // the clean end
	}
	<-stream.Context().Done()
	return nil
}

func (c *scriptedCore) snapshot() []registration {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]registration(nil), c.registers...)
}

// serve binds the scripted core on a short unix socket path and returns it.
func (c *scriptedCore) serve(t *testing.T) string {
	t.Helper()
	sock := filepath.Join(shortSocketDir(t, "vcwire"), "core.sock")
	lis, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatalf("bind %s: %v", sock, err)
	}
	c.conns = &countingListener{Listener: lis}
	srv := grpc.NewServer()
	pluginv1.RegisterPluginHostServer(srv, c)
	go func() { _ = srv.Serve(c.conns) }()
	t.Cleanup(srv.Stop)
	return sock
}

// spawnedPlugin is the plugin binary run directly, the way the supervisor
// runs it, but with this test as the parent so exits can be observed
// precisely.
type spawnedPlugin struct {
	cmd *exec.Cmd
	// done is closed once cmd.Wait has returned and exitErr is set. A
	// channel-of-error would be wrong here: alive() polls it repeatedly and
	// would consume the single value, leaving every later reader — the
	// cleanup func included — blocked forever.
	done    chan struct{}
	exitErr error
}

// spawnPlugin starts the built binary with exactly the three environment
// variables supervisor.go sets and nothing else plugin-specific.
func spawnPlugin(t *testing.T, socketPath string) *spawnedPlugin {
	t.Helper()
	home := t.TempDir()
	dir := filepath.Join(home, "vibecheck")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	execRel := installVibeCheck(t, dir)
	dataDir := filepath.Join(home, "data", "vibecheck")
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		t.Fatal(err)
	}

	// Relative path + cmd.Dir, which is literally what supervisor.go:231-232
	// does. Resolving it to an absolute path here would work but would stop
	// exercising the manifest-relative spawn that core actually performs.
	cmd := exec.Command(execRel)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(),
		"VIBECARE_SOCKET="+socketPath,
		"VIBECARE_PLUGIN_ID=vibecheck",
		"VIBECARE_DATA_DIR="+dataDir,
	)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatalf("spawn plugin: %v", err)
	}

	p := &spawnedPlugin{cmd: cmd, done: make(chan struct{})}
	go func() { p.exitErr = cmd.Wait(); close(p.done) }()
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		<-p.done
	})
	return p
}

func (p *spawnedPlugin) alive() bool {
	select {
	case <-p.done:
		return false
	default:
		return true
	}
}

// waitExit reports the process's exit error, and whether it exited at all
// within budget.
func (p *spawnedPlugin) waitExit(budget time.Duration) (error, bool) {
	select {
	case <-p.done:
		return p.exitErr, true
	case <-time.After(budget):
		return nil, false
	}
}

// Required assertion 2: a stream that ends CLEANLY — no error thrown — must
// bring the plugin all the way back to registered-and-serving.
//
// VCHost handles this structurally (`thrown` is an Error? and the decision
// goes through VCSessionOutcome.classify), and the classifier is unit
// tested, but the wiring from a genuinely finished grpc-swift AsyncSequence
// through to a fresh Register has never been exercised. A loop shaped
// `do { for try await … } catch { retry }` passes every unit test in the
// package and fails this: it falls out of the do-block and silently stops
// receiving events forever.
func TestCleanStreamEndReRegisters(t *testing.T) {
	core := &scriptedCore{dropSessions: 1, holdAfterReady: 150 * time.Millisecond}
	sock := core.serve(t)
	p := spawnPlugin(t, sock)

	// First rung of the ladder is 1 s, so the second Register is due at
	// roughly T+1.15 s. Allow generously for a loaded machine.
	deadline := time.Now().Add(30 * time.Second)
	var got []registration
	for time.Now().Before(deadline) {
		got = core.snapshot()
		if len(got) >= 2 {
			break
		}
		if !p.alive() {
			t.Fatal("plugin process exited; a clean stream end must never terminate it")
		}
		time.Sleep(50 * time.Millisecond)
	}
	if len(got) < 2 {
		t.Fatalf("only %d Register call(s) after a clean stream end; the SDK never reconnected", len(got))
	}
	if got[1].port != got[0].port {
		t.Fatalf("re-registered with port %d, first registration was %d; the HTTP listener was rebuilt",
			got[1].port, got[0].port)
	}

	// The reconnect must come from the INNER ladder — runRegisterLadder
	// looping on the same live gRPC client — not from the outer loop tearing
	// the client down and redialling. Counting Register calls alone cannot
	// tell those apart: a `do { for try await … } catch { retry }` loop falls
	// out of the do-block, returns, and the outer loop still eventually
	// re-registers, so the plugin comes back but Publish/Alert die with it in
	// between and every clean end costs a full transport rebuild. A second
	// accepted connection is the observable difference.
	if n := core.conns.count(); n != 1 {
		t.Fatalf("%d transport connections for %d Register calls; a clean stream end "+
			"must be handled on the live client, not by rebuilding it", n, len(got))
	}

	// "Back up" means serving, not merely re-handshaking: core's proxy
	// targets exactly this port the instant it marks the plugin up.
	url := fmt.Sprintf("http://127.0.0.1:%d/health", got[1].port)
	resp, err := http.Get(url)
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET %s = %d, want 200", url, resp.StatusCode)
	}
}

// Required assertion 3: a core that sends Ready and THEN drops the stream
// must be backed off against, not hammered.
//
// This is the only place the regression is observable. markReady() used to
// reset the reconnect ladder; with that bug the gaps below are all ~1 s
// forever — one full registration and one announceDemand burst per second,
// indefinitely — and no test that lacks a core sending Ready before dropping
// can tell the difference.
//
// The assertion is on the SHAPE of the gaps (each rung meaningfully longer
// than the last, starting at the bottom rung and reaching the top) rather
// than on exact values, so a loaded CI box cannot make it flake in the
// direction of a false failure. The regression produces flat ~1 s gaps,
// which fails the growth check no matter how loaded the machine is.
func TestPostReadyFlapEscalatesBackoff(t *testing.T) {
	core := &scriptedCore{dropSessions: -1, holdAfterReady: 100 * time.Millisecond}
	sock := core.serve(t)
	p := spawnPlugin(t, sock)

	// Five registrations give four gaps: the 1, 2, 4, 8 rungs.
	const want = 5
	deadline := time.Now().Add(60 * time.Second)
	var got []registration
	for time.Now().Before(deadline) {
		got = core.snapshot()
		if len(got) >= want {
			break
		}
		if !p.alive() {
			t.Fatal("plugin process exited; a flapping core must never terminate it")
		}
		time.Sleep(50 * time.Millisecond)
	}
	if len(got) < want {
		t.Fatalf("only %d Register call(s) in 60s, want %d", len(got), want)
	}

	gaps := make([]time.Duration, 0, want-1)
	for i := 1; i < want; i++ {
		gaps = append(gaps, got[i].at.Sub(got[i-1].at))
	}
	t.Logf("register gaps: %v", gaps)

	// Bottom rung: the first retry is the 1 s one, so the ladder really did
	// start where it should.
	if gaps[0] > 1800*time.Millisecond {
		t.Fatalf("first gap %v; the ladder did not start at the 1s rung", gaps[0])
	}
	// Growth: 1 -> 2 -> 4 -> 8 doubles. Requiring >1.5x leaves room for
	// scheduling jitter while still failing flat ~1s gaps outright.
	for i := 1; i < len(gaps); i++ {
		if gaps[i] < time.Duration(float64(gaps[i-1])*1.5) {
			t.Fatalf("gap %d (%v) is not meaningfully longer than gap %d (%v); "+
				"the ladder is pinned instead of escalating: %v",
				i+1, gaps[i], i, gaps[i-1], gaps)
		}
	}
	// Top rung: 8 s cap actually reached, not merely trending upward.
	if gaps[len(gaps)-1] < 6*time.Second {
		t.Fatalf("last gap %v; the ladder never reached the 8s cap: %v", gaps[len(gaps)-1], gaps)
	}
}

// Required assertion 4: with no core to talk to at all, the process must
// stay up and keep retrying.
//
// Requirement 5 of the SDK — "nothing terminates the process on failure" —
// is what stops supervisor.go charging a failed start on every dial miss and
// parking the plugin in StateFailed after five of them, recoverable only by
// a manual dashboard restart. Exiting here is the single worst thing the SDK
// could do, and until now nothing in the repo checked that it doesn't.
//
// It also covers the SIGTERM path for a plugin that never registered: the
// handler is installed before the first dial precisely so a signal landing
// in that window still ends the process cleanly.
func TestNoCoreRunningDoesNotTerminateTheProcess(t *testing.T) {
	// A path with nothing listening on it, and nothing that ever will.
	sock := filepath.Join(shortSocketDir(t, "vcdead"), "core.sock")
	p := spawnPlugin(t, sock)

	// Long enough to cover several failed dials up the 1/2/4 rungs.
	const observe = 6 * time.Second
	if _, exited := p.waitExit(observe); exited {
		t.Fatalf("plugin exited after %v with no core running (%v); "+
			"core charges that as a failed start", observe, p.exitErr)
	}

	if err := p.cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatalf("SIGTERM: %v", err)
	}
	err, exited := p.waitExit(5 * time.Second)
	if !exited {
		t.Fatal("plugin ignored SIGTERM while unregistered; core would SIGKILL it")
	}
	if err != nil {
		t.Fatalf("exit after SIGTERM = %v, want a clean exit", err)
	}
}
