package scope

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	cxv1alpha1 "github.com/liferay/liferay-portal/cloud/operator/api/cx/v1alpha1"
	licensingv1alpha1 "github.com/liferay/liferay-portal/cloud/operator/api/licensing/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	runtime "k8s.io/apimachinery/pkg/runtime"
	schema "k8s.io/apimachinery/pkg/runtime/schema"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	cache "sigs.k8s.io/controller-runtime/pkg/cache"
	client "sigs.k8s.io/controller-runtime/pkg/client"
	envtest "sigs.k8s.io/controller-runtime/pkg/envtest"
)

func TestRegistryTracksTheNamespacesTheOperatorIsBoundIn(t *testing.T) {
	assetsDirectory := envtestAssetsDirectory()

	if assetsDirectory == "" {
		t.Skip("Set KUBEBUILDER_ASSETS, or install the envtest binaries with setup-envtest, to run this test")
	}

	testEnvironment := &envtest.Environment{
		BinaryAssetsDirectory: assetsDirectory,
		CRDDirectoryPaths:     []string{"../../../../helm/dxp-operator/crds"},
		ErrorIfCRDPathMissing: true,
	}

	adminConfig, error := testEnvironment.Start()

	if error != nil {
		t.Fatalf("Unable to start the test environment: %v", error)
	}

	t.Cleanup(func() {
		if error := testEnvironment.Stop(); error != nil {
			t.Errorf("Unable to stop the test environment: %v", error)
		}
	})

	scheme := newScheme(t)

	adminClient, error := client.New(adminConfig, client.Options{Scheme: scheme})

	if error != nil {
		t.Fatalf("Unable to build the admin client: %v", error)
	}

	for _, object := range []client.Object{
		&corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: "able"}},
		&corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: "baker"}},
		&rbacv1.ClusterRole{
			ObjectMeta: metav1.ObjectMeta{Name: "discovery"},
			Rules: []rbacv1.PolicyRule{
				{
					APIGroups: []string{"licensing.liferay.com"},
					Resources: []string{"liferayenvironments"},
					Verbs:     []string{"get", "list", "watch"},
				},
			},
		},
		&rbacv1.ClusterRoleBinding{
			ObjectMeta: metav1.ObjectMeta{Name: "discovery"},
			RoleRef:    rbacv1.RoleRef{APIGroup: "rbac.authorization.k8s.io", Kind: "ClusterRole", Name: "discovery"},
			Subjects:   []rbacv1.Subject{{APIGroup: "rbac.authorization.k8s.io", Kind: "User", Name: "operator"}},
		},
		&rbacv1.ClusterRole{
			ObjectMeta: metav1.ObjectMeta{Name: "namespaced"},
			Rules: []rbacv1.PolicyRule{
				{
					APIGroups: []string{""},
					Resources: []string{"secrets"},
					Verbs:     []string{"get", "list", "watch"},
				},
			},
		},
		newRoleBinding("able"),
		newLiferayEnvironment("able"),
		newLiferayEnvironment("baker"),
	} {
		if error := adminClient.Create(context.Background(), object); error != nil {
			t.Fatalf("Unable to create %T %q: %v", object, object.GetName(), error)
		}
	}

	operatorUser, error := testEnvironment.AddUser(envtest.User{Name: "operator"}, adminConfig)

	if error != nil {
		t.Fatalf("Unable to add the operator user: %v", error)
	}

	discoveryCache, error := cache.New(operatorUser.Config(), cache.Options{Scheme: scheme})

	if error != nil {
		t.Fatalf("Unable to build the discovery cache: %v", error)
	}

	writer, error := client.New(operatorUser.Config(), client.Options{Scheme: scheme})

	if error != nil {
		t.Fatalf("Unable to build the operator client: %v", error)
	}

	registry := NewRegistry(false, discoveryCache, []schema.GroupResource{{Group: "", Resource: "secrets"}}, writer)

	startRegistry(registry, t)

	awaitState(registry, "able", StateActive, t)

	awaitState(registry, "baker", StateNotBound, t)

	if namespaces := registry.BoundNamespaces(); !slices.Equal(namespaces, []string{"able"}) {
		t.Errorf("BoundNamespaces() = %v, want [able]", namespaces)
	}

	awaitChange(registry, t)

	if error := adminClient.Create(context.Background(), newRoleBinding("baker")); error != nil {
		t.Fatalf("Unable to bind the operator in baker: %v", error)
	}

	registry.Recheck("baker")

	awaitState(registry, "baker", StateActive, t)

	awaitChange(registry, t)

	if namespaces := registry.BoundNamespaces(); !slices.Equal(namespaces, []string{"able", "baker"}) {
		t.Errorf("BoundNamespaces() = %v, want [able baker]", namespaces)
	}

	if error := adminClient.Delete(context.Background(), newRoleBinding("able")); error != nil {
		t.Fatalf("Unable to unbind the operator in able: %v", error)
	}

	registry.Recheck("able")

	awaitState(registry, "able", StateNotBound, t)

	awaitChange(registry, t)

	if error := adminClient.Delete(context.Background(), newLiferayEnvironment("baker")); error != nil {
		t.Fatalf("Unable to delete the environment in baker: %v", error)
	}

	awaitState(registry, "baker", StateUnknown, t)

	awaitChange(registry, t)

	if namespaces := registry.BoundNamespaces(); len(namespaces) != 0 {
		t.Errorf("BoundNamespaces() = %v, want none once no environment is bound", namespaces)
	}
}

func awaitChange(registry *Registry, t *testing.T) {
	t.Helper()

	select {
	case <-registry.Changes():
	case <-time.After(30 * time.Second):
		t.Fatal("Timed out waiting for the bound namespaces to change")
	}
}

func awaitCondition(condition func() bool, t *testing.T) {
	t.Helper()

	deadline := time.Now().Add(30 * time.Second)

	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal("Timed out waiting for the condition")
		}

		time.Sleep(100 * time.Millisecond)
	}
}

func awaitState(registry *Registry, namespace string, state State, t *testing.T) {
	t.Helper()

	awaitCondition(func() bool { return registry.State(namespace) == state }, t)
}

func envtestAssetsDirectory() string {
	if assetsDirectory := os.Getenv("KUBEBUILDER_ASSETS"); assetsDirectory != "" {
		return assetsDirectory
	}

	assetsDirectory, error := envtest.SetupEnvtestDefaultBinaryAssetsDirectory()

	if error != nil {
		return ""
	}

	matches, error := filepath.Glob(filepath.Join(assetsDirectory, "*"))

	if (error != nil) || (len(matches) == 0) {
		return ""
	}

	return matches[len(matches)-1]
}

func newLiferayEnvironment(namespace string) *licensingv1alpha1.LiferayEnvironment {
	return &licensingv1alpha1.LiferayEnvironment{
		ObjectMeta: metav1.ObjectMeta{Name: "dev", Namespace: namespace},
		Spec: licensingv1alpha1.LiferayEnvironmentSpec{
			ActivationCodeSecretRef: licensingv1alpha1.SecretKeyRef{Key: "activationCode", Name: "activation"},
			WorkloadRef:             licensingv1alpha1.WorkloadRef{Name: "liferay"},
		},
	}
}

func newRoleBinding(namespace string) *rbacv1.RoleBinding {
	return &rbacv1.RoleBinding{
		ObjectMeta: metav1.ObjectMeta{Name: "operator", Namespace: namespace},
		RoleRef:    rbacv1.RoleRef{APIGroup: "rbac.authorization.k8s.io", Kind: "ClusterRole", Name: "namespaced"},
		Subjects:   []rbacv1.Subject{{APIGroup: "rbac.authorization.k8s.io", Kind: "User", Name: "operator"}},
	}
}

func newScheme(t *testing.T) *runtime.Scheme {
	t.Helper()

	scheme := runtime.NewScheme()

	for _, addToScheme := range []func(*runtime.Scheme) error{
		clientgoscheme.AddToScheme, cxv1alpha1.AddToScheme, licensingv1alpha1.AddToScheme,
	} {
		if error := addToScheme(scheme); error != nil {
			t.Fatalf("Unable to build the scheme: %v", error)
		}
	}

	return scheme
}

func startRegistry(registry *Registry, t *testing.T) {
	t.Helper()

	registryContext, cancel := context.WithCancel(context.Background())

	registryErrors := make(chan error, 1)

	go func() {
		registryErrors <- registry.Start(registryContext)
	}()

	t.Cleanup(func() {
		cancel()

		if error := <-registryErrors; error != nil {
			t.Errorf("Unexpected error from the registry: %v", error)
		}
	})
}
