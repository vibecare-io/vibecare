package logtail

import (
	"context"
	"errors"
	"sync"
)

// Source is one tailable file and the id its lines are labelled with.
type Source struct {
	ID   string
	Path string
}

// Merge fans several Tails into one channel, closing it when every source has
// finished. Lines carry their Source; nothing is reordered.
//
// There is deliberately no global time ordering. Line.At is a receive time,
// not a parsed one, so sorting by it would only re-order lines that arrived
// microseconds apart while implying a precision the data does not have.
// Arrival order is the honest ordering.
//
// A source that cannot be opened is skipped rather than fatal — one plugin
// that has never run must not blank the whole view. An error is returned only
// when no source at all could be opened, since an empty stream with no
// explanation is worse than a failure.
func Merge(ctx context.Context, sources []Source, o Options) (<-chan Line, error) {
	out := make(chan Line, lineBuffer)

	var wg sync.WaitGroup
	var errs []error
	started := 0
	for _, s := range sources {
		ch, err := Tail(ctx, s.ID, s.Path, o)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		started++
		wg.Add(1)
		go func() {
			defer wg.Done()
			for ln := range ch {
				select {
				case out <- ln:
				case <-ctx.Done():
					return
				}
			}
		}()
	}
	if started == 0 && len(sources) > 0 {
		return nil, errors.Join(errs...)
	}

	go func() {
		wg.Wait()
		close(out)
	}()
	return out, nil
}
