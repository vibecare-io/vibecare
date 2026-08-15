package vc

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"google.golang.org/grpc/connectivity"
)

// rosterProbe bounds how long Status waits for a roster it may never get.
// Status must answer promptly even when core is half up, so it reports what
// it has rather than blocking on the piece that is missing.
const rosterProbe = 750 * time.Millisecond

// Status is the whole-system snapshot. Every section is fetched
// independently and every failure is recorded rather than returned: gRPC
// answering while the kernel never started is a real state, and a status
// command that refuses to print it is useless precisely when it matters.
func (s *Session) Status(ctx context.Context) (Status, error) {
	st := Status{Addr: s.addr}

	// The roster stream keeps the connection busy, so its state is a live
	// answer rather than a stale one from dial time.
	if state := s.conn.GetState(); state == connectivity.Ready {
		st.Reachable = true
	} else {
		st.Error = "grpc connection " + state.String()
	}

	if v, err := s.Version(ctx); err == nil {
		st.Version = v
	}
	st.Scheduler = s.scheduler(ctx)

	rctx, cancel := context.WithTimeout(ctx, rosterProbe)
	defer cancel()
	if r, err := s.Roster(rctx); err == nil {
		st.Kernel = r.BaseURL
		st.Plugins = r.Tally()
	}

	return st, nil
}

// Version reports the running core's build version, which is how a user
// finds out the backend they are debugging is older than they think.
func (s *Session) Version(ctx context.Context) (string, error) {
	var body struct {
		Version string `json:"version"`
	}
	if err := s.webJSON(ctx, "/version", &body); err != nil {
		return "", err
	}
	return body.Version, nil
}

// scheduler reads /api/scheduler/status. It returns nil rather than an error
// because the scheduler is one optional section of Status.
//
// Only the stats object is kept: the endpoint also returns every schedule,
// and this client lists schedules over gRPC where they are typed.
func (s *Session) scheduler(ctx context.Context) *Scheduler {
	var body map[string]any
	if err := s.webJSON(ctx, "/api/scheduler/status", &body); err != nil {
		return nil
	}
	sc := &Scheduler{Running: true}
	if stats, ok := body["stats"].(map[string]any); ok {
		sc.Raw = stats
	} else {
		sc.Raw = body
	}
	return sc
}

func (s *Session) webJSON(ctx context.Context, path string, out any) error {
	url := "http://" + s.webAddr + path
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return Errorf("build request %s: %v", path, err)
	}
	resp, err := s.http.Do(req)
	if err != nil {
		return Unreachable(s.webAddr, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return Errorf("GET %s returned %s", path, resp.Status)
	}
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return Errorf("decode %s: %v", path, err)
	}
	return nil
}
