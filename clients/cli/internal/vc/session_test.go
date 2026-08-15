package vc

import (
	"context"
	"testing"
	"time"
)

func TestDialUnreachableAddressIsExitUnreachable(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	// Port 1 is privileged and never listening; the dial fails fast rather
	// than hanging, which is the behaviour `vibecare status` depends on.
	_, err := Dial(ctx, Options{Addr: "127.0.0.1:1"})
	if err == nil {
		t.Fatal("Dial to a dead port succeeded, want failure")
	}
	if got := ExitCode(err); got != ExitUnreachable {
		t.Errorf("ExitCode = %d, want %d (err: %v)", got, ExitUnreachable, err)
	}
}

func TestOptionsDefaultsAreLocalhost(t *testing.T) {
	o := Options{}.withDefaults()
	if o.Addr != defaultAddr {
		t.Errorf("Addr = %q, want %q", o.Addr, defaultAddr)
	}
	if o.WebAddr != defaultWebAddr {
		t.Errorf("WebAddr = %q, want %q", o.WebAddr, defaultWebAddr)
	}
}

func TestKernelBaseURLComesFromRosterStream(t *testing.T) {
	sess, f := newTestServer(t)

	got, err := sess.KernelBaseURL(testCtx(t))
	if err != nil {
		t.Fatalf("KernelBaseURL: %v", err)
	}
	if got != f.kernel.URL {
		t.Errorf("KernelBaseURL = %q, want %q", got, f.kernel.URL)
	}
	if sess.Addr() != "bufnet" {
		t.Errorf("Addr = %q, want %q", sess.Addr(), "bufnet")
	}
}

func TestKernelBaseURLBlocksUntilRoster(t *testing.T) {
	sess, _ := newTestServer(t, withSilentShell())

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	if _, err := sess.KernelBaseURL(ctx); err == nil {
		t.Fatal("KernelBaseURL returned without a roster, want failure")
	} else if got := ExitCode(err); got != ExitUnreachable {
		t.Errorf("ExitCode = %d, want %d (err: %v)", got, ExitUnreachable, err)
	}
}

func TestCloseClosesWatchers(t *testing.T) {
	sess, _ := newTestServer(t)

	ch, err := sess.WatchRoster(context.Background())
	if err != nil {
		t.Fatalf("WatchRoster: %v", err)
	}
	if err := sess.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	// Drain: the channel must close, otherwise the watcher goroutine outlived
	// the session that owns it.
	deadline := time.After(2 * time.Second)
	for {
		select {
		case _, ok := <-ch:
			if !ok {
				return
			}
		case <-deadline:
			t.Fatal("watcher channel still open 2s after Close")
		}
	}
}

func TestCloseIsIdempotent(t *testing.T) {
	sess, _ := newTestServer(t)
	if err := sess.Close(); err != nil {
		t.Fatalf("first Close: %v", err)
	}
	if err := sess.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}
}

func TestSessionReconnectsAfterStreamFails(t *testing.T) {
	// Shrink the backoff so the reconnect happens inside the test's budget.
	old := streamBackoff
	streamBackoff = 20 * time.Millisecond
	t.Cleanup(func() { streamBackoff = old })

	// Dial against a silent shell so nothing is cached, then drop the stream
	// and fail the next two attempts: the session must keep retrying and
	// recover on its own, the way it has to across a `just run` restart.
	sess, f := newTestServer(t, withSilentShell())
	f.shell.failNext(2)
	f.shell.talk()
	f.shell.dropAll()

	if _, err := sess.KernelBaseURL(testCtx(t)); err != nil {
		t.Fatalf("KernelBaseURL after reconnect: %v", err)
	}
	if got := f.shell.connectCount(); got < 2 {
		t.Errorf("Plugins connect count = %d, want at least 2", got)
	}
}

func TestVersionReadsCoreWebServer(t *testing.T) {
	sess, _ := newTestServer(t)

	got, err := sess.Version(testCtx(t))
	if err != nil {
		t.Fatalf("Version: %v", err)
	}
	if got != "1.2.3" {
		t.Errorf("Version = %q, want %q", got, "1.2.3")
	}
}

func TestVersionWithoutWebServerIsUnreachable(t *testing.T) {
	sess, _ := newTestServer(t, withoutWeb())

	if _, err := sess.Version(testCtx(t)); err == nil {
		t.Fatal("Version succeeded with the web server down")
	} else if got := ExitCode(err); got != ExitUnreachable {
		t.Errorf("ExitCode = %d, want %d (err: %v)", got, ExitUnreachable, err)
	}
}

func TestStatusReportsEveryLayer(t *testing.T) {
	sess, f := newTestServer(t)

	st, err := sess.Status(testCtx(t))
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	if !st.Reachable {
		t.Errorf("Reachable = false, want true (error: %q)", st.Error)
	}
	if st.Version != "1.2.3" {
		t.Errorf("Version = %q, want %q", st.Version, "1.2.3")
	}
	if st.Kernel != f.kernel.URL {
		t.Errorf("Kernel = %q, want %q", st.Kernel, f.kernel.URL)
	}
	if st.Scheduler == nil || !st.Scheduler.Running {
		t.Fatalf("Scheduler = %+v, want running", st.Scheduler)
	}
	if got := st.Scheduler.Raw["total"]; got != float64(3) {
		t.Errorf("Scheduler.Raw[total] = %v, want 3", got)
	}
	if st.Plugins.Total != 1 || st.Plugins.Up != 1 {
		t.Errorf("Plugins tally = %+v, want 1 total / 1 up", st.Plugins)
	}
}

// gRPC up with the kernel and web server down is a real state, and the one
// a human is most likely to be staring at. It must render, not error.
func TestStatusWithoutWebServerStillReportsGRPC(t *testing.T) {
	sess, _ := newTestServer(t, withoutWeb(), withoutKernel())

	st, err := sess.Status(testCtx(t))
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	if !st.Reachable {
		t.Errorf("Reachable = false, want true (error: %q)", st.Error)
	}
	if st.Version != "" {
		t.Errorf("Version = %q, want empty", st.Version)
	}
	if st.Scheduler != nil {
		t.Errorf("Scheduler = %+v, want nil", st.Scheduler)
	}
	// The roster still arrives over gRPC even though the kernel's HTTP
	// surface is gone, so the tally survives.
	if st.Plugins.Total != 1 {
		t.Errorf("Plugins tally = %+v, want 1 total", st.Plugins)
	}
}

func TestStatusWithFailingSchedulerEndpoint(t *testing.T) {
	sess, f := newTestServer(t)
	f.web.setScheduler(nil) // endpoint answers 500

	st, err := sess.Status(testCtx(t))
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	if st.Scheduler != nil {
		t.Errorf("Scheduler = %+v, want nil when the endpoint fails", st.Scheduler)
	}
	if st.Version == "" {
		t.Error("Version empty; a failing scheduler must not take the rest of status down")
	}
}
