package scope

import (
	"context"
	"slices"
	"sync"
	"time"

	cxv1alpha1 "github.com/liferay/liferay-portal/cloud/operator/api/cx/v1alpha1"
	licensingv1alpha1 "github.com/liferay/liferay-portal/cloud/operator/api/licensing/v1alpha1"
	authorizationv1 "k8s.io/api/authorization/v1"
	schema "k8s.io/apimachinery/pkg/runtime/schema"
	toolscache "k8s.io/client-go/tools/cache"
	workqueue "k8s.io/client-go/util/workqueue"
	cache "sigs.k8s.io/controller-runtime/pkg/cache"
	client "sigs.k8s.io/controller-runtime/pkg/client"
	event "sigs.k8s.io/controller-runtime/pkg/event"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
)

const (
	StateUnknown State = iota
	StateActive
	StateNotBound
)

const (
	activeRecheckInterval   = 5 * time.Minute
	notBoundRecheckInterval = 30 * time.Second
)

func (registry *Registry) ActiveNamespaces() []string {
	registry.mutex.RLock()

	defer registry.mutex.RUnlock()

	var namespaces []string

	for namespace, state := range registry.states {
		if state == StateActive {
			namespaces = append(namespaces, namespace)
		}
	}

	slices.Sort(namespaces)

	return namespaces
}

func (registry *Registry) Changes() <-chan struct{} {
	return registry.changes
}

func (registry *Registry) ClientExtensionEvents() <-chan event.GenericEvent {
	return registry.clientExtensionEvents
}

func (registry *Registry) LiferayEnvironmentEvents() <-chan event.GenericEvent {
	return registry.liferayEnvironmentEvents
}

func NewRegistry(
	clientExtensionsEnabled bool,
	discoveryCache cache.Cache,
	requiredGroupResources []schema.GroupResource,
	writer client.Writer,
) *Registry {
	return &Registry{
		changes:                  make(chan struct{}, 1),
		clientExtensionEvents:    make(chan event.GenericEvent),
		clientExtensionsEnabled:  clientExtensionsEnabled,
		discoveryCache:           discoveryCache,
		liferayEnvironmentEvents: make(chan event.GenericEvent),
		queue: workqueue.NewTypedRateLimitingQueue(
			workqueue.DefaultTypedControllerRateLimiter[string](),
		),
		requiredGroupResources: requiredGroupResources,
		states:                 map[string]State{},
		writer:                 writer,
	}
}

func (registry *Registry) Recheck(namespace string) {
	registry.queue.Add(namespace)
}

func (registry *Registry) Snapshot(namespaces []string) *Snapshot {
	return &Snapshot{namespaces: slices.Clone(namespaces), registry: registry}
}

func (registry *Registry) Start(context context.Context) error {
	go func() {
		if error := registry.discoveryCache.Start(context); error != nil {
			logf.FromContext(context).Error(error, "Unable to run the discovery cache")
		}
	}()

	if error := registry.watch(context, &licensingv1alpha1.LiferayEnvironment{}); error != nil {
		return error
	}

	if registry.clientExtensionsEnabled {
		if error := registry.watch(context, &cxv1alpha1.ClientExtension{}); error != nil {
			return error
		}
	}

	registry.discoveryCache.WaitForCacheSync(context)

	go func() {
		<-context.Done()

		registry.queue.ShutDown()
	}()

	for registry.processNext(context) {
	}

	return nil
}

func (registry *Registry) State(namespace string) State {
	registry.mutex.RLock()

	defer registry.mutex.RUnlock()

	return registry.states[namespace]
}

func dxpNamespace(clientExtension *cxv1alpha1.ClientExtension) string {
	if clientExtension.Spec.DxpNamespace != "" {
		return clientExtension.Spec.DxpNamespace
	}

	return clientExtension.Namespace
}

func (registry *Registry) emit(objects []client.Object) {
	for _, object := range objects {
		events := registry.liferayEnvironmentEvents

		if _, ok := object.(*cxv1alpha1.ClientExtension); ok {
			events = registry.clientExtensionEvents
		}

		go func() {
			events <- event.GenericEvent{Object: object}
		}()
	}
}

func (registry *Registry) enqueue(object any) {
	if tombstone, ok := object.(toolscache.DeletedFinalStateUnknown); ok {
		object = tombstone.Obj
	}

	if clientExtension, ok := object.(*cxv1alpha1.ClientExtension); ok {
		registry.queue.Add(dxpNamespace(clientExtension))
	}

	if clientObject, ok := object.(client.Object); ok {
		registry.queue.Add(clientObject.GetNamespace())
	}
}

func hasRule(groupResource schema.GroupResource, resourceRules []authorizationv1.ResourceRule, verb string) bool {
	for _, resourceRule := range resourceRules {
		if len(resourceRule.ResourceNames) > 0 {
			continue
		}

		if isMatch(resourceRule.APIGroups, groupResource.Group) &&
			isMatch(resourceRule.Resources, groupResource.Resource) &&
			isMatch(resourceRule.Verbs, verb) {

			return true
		}
	}

	return false
}

func (registry *Registry) isAllowed(
	context context.Context,
	groupResource schema.GroupResource,
	namespace string,
	verb string,
) (bool, error) {
	selfSubjectAccessReview := &authorizationv1.SelfSubjectAccessReview{
		Spec: authorizationv1.SelfSubjectAccessReviewSpec{
			ResourceAttributes: &authorizationv1.ResourceAttributes{
				Group:     groupResource.Group,
				Namespace: namespace,
				Resource:  groupResource.Resource,
				Verb:      verb,
			},
		},
	}

	if error := registry.writer.Create(context, selfSubjectAccessReview); error != nil {
		return false, error
	}

	return selfSubjectAccessReview.Status.Allowed, nil
}

func (registry *Registry) isBound(context context.Context, namespace string) (bool, error) {
	selfSubjectRulesReview := &authorizationv1.SelfSubjectRulesReview{
		Spec: authorizationv1.SelfSubjectRulesReviewSpec{Namespace: namespace},
	}

	if error := registry.writer.Create(context, selfSubjectRulesReview); error != nil {
		return false, error
	}

	for _, groupResource := range registry.requiredGroupResources {
		for _, verb := range []string{"list", "watch"} {
			if hasRule(groupResource, selfSubjectRulesReview.Status.ResourceRules, verb) {
				continue
			}

			if !selfSubjectRulesReview.Status.Incomplete {
				return false, nil
			}

			allowed, error := registry.isAllowed(context, groupResource, namespace, verb)

			if error != nil {
				return false, error
			}

			if !allowed {
				return false, nil
			}
		}
	}

	return true, nil
}

func isMatch(values []string, value string) bool {
	return slices.Contains(values, value) || slices.Contains(values, "*")
}

func (registry *Registry) objects(context context.Context, namespace string) ([]client.Object, error) {
	var objects []client.Object

	liferayEnvironmentList := &licensingv1alpha1.LiferayEnvironmentList{}

	if error := registry.discoveryCache.List(
		context, liferayEnvironmentList, client.InNamespace(namespace),
	); error != nil {
		return nil, error
	}

	for index := range liferayEnvironmentList.Items {
		objects = append(objects, &liferayEnvironmentList.Items[index])
	}

	if !registry.clientExtensionsEnabled {
		return objects, nil
	}

	clientExtensionList := &cxv1alpha1.ClientExtensionList{}

	if error := registry.discoveryCache.List(context, clientExtensionList); error != nil {
		return nil, error
	}

	for index := range clientExtensionList.Items {
		clientExtension := &clientExtensionList.Items[index]

		if (clientExtension.Namespace == namespace) || (dxpNamespace(clientExtension) == namespace) {
			objects = append(objects, clientExtension)
		}
	}

	return objects, nil
}

func (registry *Registry) process(context context.Context, namespace string) error {
	objects, error := registry.objects(context, namespace)

	if error != nil {
		return error
	}

	if len(objects) == 0 {
		registry.setState(namespace, StateUnknown)

		return nil
	}

	bound, error := registry.isBound(context, namespace)

	if error != nil {
		return error
	}

	state := StateNotBound

	if bound {
		state = StateActive
	}

	if registry.setState(namespace, state) {
		logf.FromContext(context).Info(
			"Namespace scope changed", "active", state == StateActive, "namespace", namespace,
		)

		registry.emit(objects)
	}

	recheckInterval := notBoundRecheckInterval

	if state == StateActive {
		recheckInterval = activeRecheckInterval
	}

	registry.queue.AddAfter(namespace, recheckInterval)

	return nil
}

func (registry *Registry) processNext(context context.Context) bool {
	namespace, shutdown := registry.queue.Get()

	if shutdown {
		return false
	}

	defer registry.queue.Done(namespace)

	if error := registry.process(context, namespace); error != nil {
		logf.FromContext(context).Error(error, "Unable to evaluate the namespace scope", "namespace", namespace)

		registry.queue.AddRateLimited(namespace)

		return true
	}

	registry.queue.Forget(namespace)

	return true
}

func (registry *Registry) setState(namespace string, state State) bool {
	registry.mutex.Lock()

	defer registry.mutex.Unlock()

	previousState := registry.states[namespace]

	if previousState == state {
		return false
	}

	if state == StateUnknown {
		delete(registry.states, namespace)
	} else {
		registry.states[namespace] = state
	}

	if (previousState == StateActive) || (state == StateActive) {
		select {
		case registry.changes <- struct{}{}:
		default:
		}
	}

	return true
}

func (registry *Registry) watch(context context.Context, object client.Object) error {
	informer, error := registry.discoveryCache.GetInformer(context, object)

	if error != nil {
		return error
	}

	_, error = informer.AddEventHandler(
		toolscache.ResourceEventHandlerFuncs{
			AddFunc:    registry.enqueue,
			DeleteFunc: registry.enqueue,
			UpdateFunc: func(oldObject any, newObject any) {
				registry.enqueue(oldObject)

				registry.enqueue(newObject)
			},
		},
	)

	return error
}

type Registry struct {
	changes                  chan struct{}
	clientExtensionEvents    chan event.GenericEvent
	clientExtensionsEnabled  bool
	discoveryCache           cache.Cache
	liferayEnvironmentEvents chan event.GenericEvent
	mutex                    sync.RWMutex
	queue                    workqueue.TypedRateLimitingInterface[string]
	requiredGroupResources   []schema.GroupResource
	states                   map[string]State
	writer                   client.Writer
}

type Scope interface {
	ActiveNamespaces() []string
	ClientExtensionEvents() <-chan event.GenericEvent
	LiferayEnvironmentEvents() <-chan event.GenericEvent
	State(namespace string) State
}

type State int
