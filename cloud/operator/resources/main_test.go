package main

import (
	"maps"
	"slices"
	"testing"

	cxv1alpha1 "github.com/liferay/liferay-portal/cloud/operator/api/cx/v1alpha1"
	licensingv1alpha1 "github.com/liferay/liferay-portal/cloud/operator/api/licensing/v1alpha1"
	licensing "github.com/liferay/liferay-portal/cloud/operator/internal/controller/licensing"
	corev1 "k8s.io/api/core/v1"
	labels "k8s.io/apimachinery/pkg/labels"
	cache "sigs.k8s.io/controller-runtime/pkg/cache"
	client "sigs.k8s.io/controller-runtime/pkg/client"
)

func TestNewManagerOptionsScopesTheCache(t *testing.T) {
	testCases := map[string]struct {
		namespaces []string
	}{
		"the cluster RBAC scope caches every namespace": {},
		"the namespace RBAC scope caches the bound namespaces": {
			namespaces: []string{"able", "dxp-operator-system"},
		},
	}

	for name, testCase := range testCases {
		t.Run(name, func(t *testing.T) {
			managerOptions, error := newManagerOptions(config{}, testCase.namespaces)

			if error != nil {
				t.Fatalf("newManagerOptions() error = %v, want nil", error)
			}

			defaultNamespaces := slices.Sorted(maps.Keys(managerOptions.Cache.DefaultNamespaces))

			if !slices.Equal(defaultNamespaces, testCase.namespaces) {
				t.Errorf("DefaultNamespaces = %v, want %v", defaultNamespaces, testCase.namespaces)
			}

			for object, byObject := range managerOptions.Cache.ByObject {
				switch object.(type) {
				case *corev1.ConfigMap:
					if byObject.Label == nil {
						t.Error("ByObject[ConfigMap] has no label filter, want the client extension metadata filter")
					}
				case *corev1.Secret:
					if !byObject.Label.Matches(labels.Set{licensing.LabelControllerWatched: "yes"}) ||
						byObject.Label.Matches(labels.Set{}) {

						t.Errorf("ByObject[Secret] label = %v, want only the operator's own Secrets", byObject.Label)
					}
				case *cxv1alpha1.ClientExtension, *licensingv1alpha1.LiferayEnvironment:
					if testCase.namespaces == nil {
						t.Errorf("ByObject[%T] set in the cluster RBAC scope, want none", object)
					}

					if _, ok := byObject.Namespaces[cache.AllNamespaces]; !ok {
						t.Errorf("ByObject[%T].Namespaces = %v, want every namespace", object, byObject.Namespaces)
					}
				default:
					t.Errorf("ByObject[%T] is unexpected", object)
				}
			}

			wantByObjectCount := 2

			if testCase.namespaces != nil {
				wantByObjectCount = 4
			}

			if len(managerOptions.Cache.ByObject) != wantByObjectCount {
				t.Errorf("ByObject has %d entries, want %d", len(managerOptions.Cache.ByObject), wantByObjectCount)
			}

			if (managerOptions.Client.Cache == nil) || !isDisabledFor(managerOptions.Client.Cache.DisableFor) {
				t.Errorf("Client.Cache = %v, want Namespaces and Secrets read from the API server", managerOptions.Client.Cache)
			}

			skipNameValidation := managerOptions.Controller.SkipNameValidation

			if (skipNameValidation != nil) != (testCase.namespaces != nil) {
				t.Errorf("SkipNameValidation = %v, want it set only when the manager can be rebuilt", skipNameValidation)
			}
		})
	}
}

func isDisabledFor(objects []client.Object) bool {
	namespaceDisabled := false
	secretDisabled := false

	for _, object := range objects {
		switch object.(type) {
		case *corev1.Namespace:
			namespaceDisabled = true
		case *corev1.Secret:
			secretDisabled = true
		}
	}

	return namespaceDisabled && secretDisabled
}
