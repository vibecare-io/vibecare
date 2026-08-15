package vc

import (
	"context"
	"os"
	"path/filepath"
)

// CoreLogID is the source id for core's own log. It is not a plugin id — the
// kernel's id regex rejects nothing of the sort, but no plugin may be called
// this because core reserves it in the same way it reserves /_core/.
const CoreLogID = "core"

// CoreLogSource resolves core's own log without needing a connection. Logs
// are the one thing that must work when core is down, so this is a package
// function rather than a Session method.
func CoreLogSource() LogSource {
	return LogSource{ID: CoreLogID, Path: filepath.Join(vibecareDir(), "logs", "server.log")}
}

// LogSources lists everything tailable: core first, then one source per
// plugin the roster knows about.
//
// A plugin's path comes from the kernel's log_path field. The conventional
// location is only a fallback for a core that predates that field (or whose
// HTTP surface is down), because the whole point of publishing the path is
// that the convention can change without breaking this client.
func (s *Session) LogSources(ctx context.Context) ([]LogSource, error) {
	out := []LogSource{CoreLogSource()}

	r, err := s.Roster(ctx)
	if err != nil {
		// Deliberately not fatal: core's log is exactly what the user came
		// for when core is the thing that is broken.
		return out, nil
	}
	for _, p := range r.Plugins {
		out = append(out, LogSource{ID: p.ID, Path: pluginLogPath(p)})
	}
	return out, nil
}

// LogSource resolves one id, "core" or a plugin's.
func (s *Session) LogSource(ctx context.Context, id string) (LogSource, error) {
	if id == "" {
		return LogSource{}, Usagef("log source id required")
	}
	if id == CoreLogID {
		return CoreLogSource(), nil
	}
	sources, err := s.LogSources(ctx)
	if err != nil {
		return LogSource{}, err
	}
	for _, src := range sources {
		if src.ID == id {
			return src, nil
		}
	}
	return LogSource{}, NotFound("log source", id)
}

func pluginLogPath(p Plugin) string {
	if p.LogPath != "" {
		return p.LogPath
	}
	return filepath.Join(vibecareDir(), "logs", "plugins", p.ID+".log")
}

// vibecareDir is ~/.vibecare. A home directory that cannot be resolved yields
// a relative path, which surfaces as a plain "no such file" from the tailer —
// clearer than an error from a function whose job is to name a file.
func vibecareDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		home = ""
	}
	return filepath.Join(home, ".vibecare")
}
