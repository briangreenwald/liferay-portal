package scope

import (
	"context"
	"slices"
	"time"

	event "sigs.k8s.io/controller-runtime/pkg/event"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
)

func (snapshot *Snapshot) ActiveNamespaces() []string {
	return slices.Clone(snapshot.namespaces)
}

func (snapshot *Snapshot) ClientExtensionEvents() <-chan event.GenericEvent {
	return snapshot.registry.ClientExtensionEvents()
}

func (snapshot *Snapshot) LiferayEnvironmentEvents() <-chan event.GenericEvent {
	return snapshot.registry.LiferayEnvironmentEvents()
}

func (snapshot *Snapshot) State(namespace string) State {
	if slices.Contains(snapshot.namespaces, namespace) {
		return StateActive
	}

	if snapshot.registry.State(namespace) == StateNotBound {
		return StateNotBound
	}

	return StateUnknown
}

func Supervise(
	baseNamespaces []string,
	debounce time.Duration,
	registry *Registry,
	run func(context context.Context, snapshot *Snapshot) error,
	stop <-chan struct{},
) error {
	for {
		namespaces := slices.Concat(baseNamespaces, registry.ActiveNamespaces())

		slices.Sort(namespaces)

		namespaces = slices.Compact(namespaces)

		runContext, cancel := context.WithCancel(context.Background())

		runErrors := make(chan error, 1)

		go func() {
			runErrors <- run(runContext, registry.Snapshot(namespaces))
		}()

		logf.Log.WithName("scope").Info("Running the manager", "namespaces", namespaces)

		select {
		case <-registry.Changes():
		case runError := <-runErrors:
			cancel()

			return runError
		case <-stop:
			cancel()

			return <-runErrors
		}

		select {
		case <-stop:
			cancel()

			return <-runErrors
		case <-time.After(debounce):
		}

		select {
		case <-registry.Changes():
		default:
		}

		cancel()

		if runError := <-runErrors; runError != nil {
			return runError
		}
	}
}

type Snapshot struct {
	namespaces []string
	registry   *Registry
}

var _ Scope = &Snapshot{}
