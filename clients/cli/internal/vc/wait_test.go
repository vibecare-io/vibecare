package vc

import (
	"context"
	"errors"
	"net"
	"testing"
	"time"

	clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
	"google.golang.org/grpc"
)

// serveOn brings a real gRPC server up on addr after a delay, standing in
// for core finishing its startup. It is a real TCP listener rather than the
// bufconn the rest of the suite uses, because what DialWait has to survive
// is precisely "nothing is bound to that port yet" — which bufconn cannot
// express.
func serveOn(t *testing.T, addr string, after time.Duration) (stop func(), done chan struct{}) {
	t.Helper()

	srv := grpc.NewServer()
	clientv1.RegisterShellServer(srv, newFakeShell(true))

	done = make(chan struct{})
	go func() {
		defer close(done)
		time.Sleep(after)
		lis, err := net.Listen("tcp", addr)
		if err != nil {
			return
		}
		_ = srv.Serve(lis)
	}()
	return srv.Stop, done
}

func TestBackoffDelay(t *testing.T) {
	b := Backoff{Base: 250 * time.Millisecond, Max: 8 * time.Second}

	tests := []struct {
		attempt int
		want    time.Duration
	}{
		{0, 250 * time.Millisecond},
		{1, 500 * time.Millisecond},
		{2, time.Second},
		{5, 8 * time.Second},  // 8s exactly, the cap
		{6, 8 * time.Second},  // clamped
		{99, 8 * time.Second}, // clamped, and no overflow
		// A client left running for days must not wrap the shift into a
		// negative duration and start dialling in a tight loop.
		{1000, 8 * time.Second},
		{-1, 250 * time.Millisecond},
	}

	for _, tc := range tests {
		if got := b.Delay(tc.attempt); got != tc.want {
			t.Errorf("Delay(%d) = %s, want %s", tc.attempt, got, tc.want)
		}
	}
}

// The zero Backoff must still be usable: a caller that forgets to configure
// one should get the default schedule, not a zero delay that spins.
func TestZeroBackoffUsesDefaults(t *testing.T) {
	if got := (Backoff{}).Delay(0); got != DefaultBackoff.Base {
		t.Errorf("zero Backoff Delay(0) = %s, want the default base %s", got, DefaultBackoff.Base)
	}
}

func TestDialWaitGivesUpAtDeadline(t *testing.T) {
	start := time.Now()
	_, err := DialWait(context.Background(), Options{Addr: "127.0.0.1:1"}, 600*time.Millisecond)
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("DialWait succeeded against a dead port")
	}
	if code := ExitCode(err); code != ExitUnreachable {
		t.Errorf("exit code = %d, want %d (unreachable)", code, ExitUnreachable)
	}
	// It must actually wait, and it must actually stop. A --wait that
	// returns instantly did not wait; one that overruns badly has ignored
	// the deadline the user set.
	if elapsed < 400*time.Millisecond {
		t.Errorf("returned after %s, want it to keep trying for most of the 600ms budget", elapsed)
	}
	if elapsed > 4*time.Second {
		t.Errorf("returned after %s, far past the 600ms deadline", elapsed)
	}
}

// The point of --wait: core is starting up and is not listening yet.
func TestDialWaitSucceedsWhenCoreArrivesLate(t *testing.T) {
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := lis.Addr().String()
	// Close it so the port is dead, then bring a real server up on the same
	// address shortly after DialWait starts trying.
	_ = lis.Close()

	srv, done := serveOn(t, addr, 300*time.Millisecond)
	defer func() {
		srv()
		<-done
	}()

	s, err := DialWait(context.Background(), Options{Addr: addr}, 5*time.Second)
	if err != nil {
		t.Fatalf("DialWait failed for a core that arrived late: %v", err)
	}
	defer s.Close()
}

func TestDialWaitHonoursCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(150 * time.Millisecond)
		cancel()
	}()

	_, err := DialWait(ctx, Options{Addr: "127.0.0.1:1"}, time.Minute)
	if err == nil {
		t.Fatal("DialWait ignored a cancelled context and kept waiting")
	}
	if !errors.Is(err, context.Canceled) && ExitCode(err) != ExitUnreachable {
		t.Errorf("err = %v, want a cancellation or unreachable error", err)
	}
}
