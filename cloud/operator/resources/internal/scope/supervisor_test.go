package scope

import (
	"context"
	"slices"
	"testing"
	"time"
)

func TestSnapshotState(t *testing.T) {
	registry := NewRegistry(false, nil, nil, nil)

	registry.setState("able", StateActive)

	registry.setState("baker", StateNotBound)

	registry.setState("charlie", StateActive)

	snapshot := registry.Snapshot([]string{"able", "dxp-operator-system"})

	for namespace, wantState := range map[string]State{
		"able":    StateActive,
		"baker":   StateNotBound,
		"charlie": StateUnknown,
		"delta":   StateUnknown,
	} {
		if state := snapshot.State(namespace); state != wantState {
			t.Errorf("State(%q) = %d, want %d", namespace, state, wantState)
		}
	}
}

func TestSuperviseRebuildsTheManagerWhenTheBoundNamespacesChange(t *testing.T) {
	registry := NewRegistry(false, nil, nil, nil)

	runs := make(chan []string, 4)

	stop := make(chan struct{})

	superviseErrors := make(chan error, 1)

	go func() {
		superviseErrors <- Supervise(
			[]string{"dxp-operator-system"},
			10*time.Millisecond,
			registry,
			func(context context.Context, snapshot *Snapshot) error {
				runs <- snapshot.ActiveNamespaces()

				<-context.Done()

				return nil
			},
			stop,
		)
	}()

	if namespaces := awaitRun(runs, t); !slices.Equal(namespaces, []string{"dxp-operator-system"}) {
		t.Errorf("first run namespaces = %v, want [dxp-operator-system]", namespaces)
	}

	registry.setState("able", StateActive)

	registry.setState("baker", StateActive)

	if namespaces := awaitRun(runs, t); !slices.Equal(namespaces, []string{"able", "baker", "dxp-operator-system"}) {
		t.Errorf("second run namespaces = %v, want [able baker dxp-operator-system]", namespaces)
	}

	registry.setState("charlie", StateNotBound)

	select {
	case namespaces := <-runs:
		t.Errorf("Supervise() rebuilt the manager for %v, want no rebuild when no namespace was bound", namespaces)
	case <-time.After(100 * time.Millisecond):
	}

	close(stop)

	select {
	case error := <-superviseErrors:
		if error != nil {
			t.Errorf("Supervise() error = %v, want nil", error)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Supervise() did not return after stop")
	}
}

func awaitRun(runs <-chan []string, t *testing.T) []string {
	t.Helper()

	select {
	case namespaces := <-runs:
		return namespaces
	case <-time.After(5 * time.Second):
		t.Fatal("Timed out waiting for the manager to run")
	}

	return nil
}
