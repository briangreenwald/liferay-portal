package main

import (
	"context"
	"fmt"
	"os"
	"time"

	env "github.com/caarlos0/env/v11"
	cxv1alpha1 "github.com/liferay/liferay-portal/cloud/operator/api/cx/v1alpha1"
	licensingv1alpha1 "github.com/liferay/liferay-portal/cloud/operator/api/licensing/v1alpha1"
	addon "github.com/liferay/liferay-portal/cloud/operator/internal/addon"
	controller "github.com/liferay/liferay-portal/cloud/operator/internal/controller"
	cx "github.com/liferay/liferay-portal/cloud/operator/internal/controller/cx"
	licensing "github.com/liferay/liferay-portal/cloud/operator/internal/controller/licensing"
	provisioning "github.com/liferay/liferay-portal/cloud/operator/internal/provisioning"
	scope "github.com/liferay/liferay-portal/cloud/operator/internal/scope"
	corev1 "k8s.io/api/core/v1"
	labels "k8s.io/apimachinery/pkg/labels"
	runtime "k8s.io/apimachinery/pkg/runtime"
	schema "k8s.io/apimachinery/pkg/runtime/schema"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	rest "k8s.io/client-go/rest"
	controllerruntime "sigs.k8s.io/controller-runtime"
	cache "sigs.k8s.io/controller-runtime/pkg/cache"
	client "sigs.k8s.io/controller-runtime/pkg/client"
	controllerconfig "sigs.k8s.io/controller-runtime/pkg/config"
	healthz "sigs.k8s.io/controller-runtime/pkg/healthz"
	zap "sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
)

const (
	rbacScopeCluster   = "cluster"
	rbacScopeNamespace = "namespace"
	scopeDebounce      = 5 * time.Second
)

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(cxv1alpha1.AddToScheme(scheme))
	utilruntime.Must(licensingv1alpha1.AddToScheme(scheme))
}

func main() {
	config, configError := env.ParseAs[config]()

	controllerruntime.SetLogger(zap.New(zap.UseDevMode(config.Debug)))

	if configError != nil {
		controller.SetupLog.Error(configError, "Unable to read configuration, falling back to defaults")
	}

	operator := &operator{config: config, restConfig: controllerruntime.GetConfigOrDie()}

	if error := operator.run(controllerruntime.SetupSignalHandler()); error != nil {
		controller.SetupLog.Error(error, "Unexpected error while running the operator")

		os.Exit(1)
	}
}

func newManagerOptions(config config, namespaces []string) (controllerruntime.Options, error) {
	cxConfigMapSelector, error := labels.Parse(cx.LabelMetadataType)

	if error != nil {
		return controllerruntime.Options{}, error
	}

	managerOptions := controllerruntime.Options{
		Cache: cache.Options{
			ByObject: map[client.Object]cache.ByObject{
				&corev1.ConfigMap{}: {Label: cxConfigMapSelector},
				&corev1.Secret{}: {
					Label: labels.SelectorFromSet(labels.Set{licensing.LabelControllerWatched: "yes"}),
				},
			},
		},
		Client: client.Options{
			Cache: &client.CacheOptions{
				DisableFor: []client.Object{&corev1.Namespace{}, &corev1.Secret{}},
			},
		},
		HealthProbeBindAddress: config.ProbeAddress,
		Metrics: metricsserver.Options{
			BindAddress: config.MetricsAddress,
		},
		Scheme: scheme,
	}

	if namespaces == nil {
		return managerOptions, nil
	}

	managerOptions.Cache.DefaultNamespaces = map[string]cache.Config{}

	for _, namespace := range namespaces {
		managerOptions.Cache.DefaultNamespaces[namespace] = cache.Config{}
	}

	for _, object := range []client.Object{&cxv1alpha1.ClientExtension{}, &licensingv1alpha1.LiferayEnvironment{}} {
		managerOptions.Cache.ByObject[object] = cache.ByObject{
			Namespaces: map[string]cache.Config{cache.AllNamespaces: {}},
		}
	}

	skipNameValidation := true

	managerOptions.Controller = controllerconfig.Controller{SkipNameValidation: &skipNameValidation}

	return managerOptions, nil
}

func (operator *operator) newRegistry() (*scope.Registry, error) {
	discoveryCache, error := cache.New(operator.restConfig, cache.Options{Scheme: scheme})

	if error != nil {
		return nil, error
	}

	writer, error := client.New(operator.restConfig, client.Options{Scheme: scheme})

	if error != nil {
		return nil, error
	}

	return scope.NewRegistry(
		operator.config.ClientExtensionsEnabled, discoveryCache,
		requiredGroupResources(operator.config.ClientExtensionsEnabled), writer,
	), nil
}

func requiredGroupResources(clientExtensionsEnabled bool) []schema.GroupResource {
	groupResources := []schema.GroupResource{
		{Group: "", Resource: "secrets"},
		{Group: "apps", Resource: "deployments"},
		{Group: "apps", Resource: "statefulsets"},
		{Group: "autoscaling", Resource: "horizontalpodautoscalers"},
		{Group: "keda.sh", Resource: "scaledobjects"},
	}

	if clientExtensionsEnabled {
		groupResources = append(
			groupResources,
			schema.GroupResource{Group: "", Resource: "configmaps"},
			schema.GroupResource{Group: "batch", Resource: "cronjobs"},
			schema.GroupResource{Group: "batch", Resource: "jobs"},
		)
	}

	return groupResources
}

func (operator *operator) run(context context.Context) error {
	config := operator.config

	controller.SetupLog.Info(
		"Starting the operator",
		"clientExtensionsEnabled", config.ClientExtensionsEnabled,
		"heartbeatInterval", config.HeartbeatInterval,
		"metricsAddress", config.MetricsAddress,
		"probeAddress", config.ProbeAddress,
		"provisioningBaseURL", config.ProvisioningBaseURL,
		"rbacScope", config.RBACScope,
	)

	switch config.RBACScope {
	case rbacScopeCluster:
		return operator.runManager(context, nil)
	case rbacScopeNamespace:
		registry, error := operator.newRegistry()

		if error != nil {
			return error
		}

		go func() {
			if error := registry.Start(context); error != nil {
				controller.SetupLog.Error(error, "Unable to run the namespace scope")
			}
		}()

		return scope.Supervise(
			[]string{config.OperatorNamespace}, scopeDebounce, registry, operator.runManager, context.Done(),
		)
	}

	return fmt.Errorf(
		"RBAC scope %q is neither %q nor %q", config.RBACScope, rbacScopeCluster, rbacScopeNamespace,
	)
}

func (operator *operator) runManager(context context.Context, snapshot *scope.Snapshot) error {
	config := operator.config

	var namespaces []string

	var namespaceScope scope.Scope

	if snapshot != nil {
		namespaces = snapshot.ActiveNamespaces()

		namespaceScope = snapshot
	}

	managerOptions, error := newManagerOptions(config, namespaces)

	if error != nil {
		return error
	}

	manager, error := controllerruntime.NewManager(operator.restConfig, managerOptions)

	if error != nil {
		return error
	}

	if error := manager.AddHealthzCheck("healthz", healthz.Ping); error != nil {
		return error
	}

	if error := manager.AddReadyzCheck("readyz", healthz.Ping); error != nil {
		return error
	}

	var reconcilers []controller.Reconciler

	if config.ClientExtensionsEnabled {
		reconcilers = append(
			reconcilers,
			&cx.ClientExtensionReconciler{
				APIReader:      manager.GetAPIReader(),
				Client:         manager.GetClient(),
				Recorder:       manager.GetEventRecorderFor("clientextension-controller"),
				Scope:          namespaceScope,
				ServiceAccount: config.OperatorNamespace + "/" + config.OperatorServiceAccount,
			},
		)
	}

	provisioningClient := provisioning.NewHTTPClient(config.ProvisioningBaseURL)

	reconcilers = append(
		reconcilers,
		&licensing.LiferayEnvironmentReconciler{
			Client:                  manager.GetClient(),
			ExpirationGracePeriod:   config.ExpirationGracePeriod,
			HeartbeatInterval:       config.HeartbeatInterval,
			MarketplaceMountPath:    config.MarketplaceMountPath,
			Provisioning:            provisioningClient,
			ProvisioningGracePeriod: config.ProvisioningGracePeriod,
			Recorder:                manager.GetEventRecorderFor("liferayenvironment-controller"),
			RetryInitialDelay:       config.RetryInitialDelay,
			RetryMaxDelay:           config.RetryMaxDelay,
			Scope:                   namespaceScope,
			ServiceAccount:          config.OperatorNamespace + "/" + config.OperatorServiceAccount,
			Syncer: addon.NewSyncer(
				provisioningClient, config.DownloadPollInterval,
				config.RetryInitialDelay, config.RetryMaxDelay, addon.GoRunner{},
			),
		},
	)

	if error := controller.SetupWithManager(manager, reconcilers...); error != nil {
		return error
	}

	return manager.Start(context)
}

type config struct {
	ClientExtensionsEnabled bool          `env:"CLIENT_EXTENSIONS_ENABLED" envDefault:"false"`
	Debug                   bool          `env:"DEBUG" envDefault:"false"`
	DownloadPollInterval    time.Duration `env:"DOWNLOAD_POLL_INTERVAL" envDefault:"15s"`
	ExpirationGracePeriod   time.Duration `env:"EXPIRATION_GRACE_PERIOD" envDefault:"2160h"`
	HeartbeatInterval       time.Duration `env:"HEARTBEAT_INTERVAL" envDefault:"10m"`
	MarketplaceMountPath    string        `env:"MARKETPLACE_MOUNT_PATH" envDefault:"/marketplace"`
	MetricsAddress          string        `env:"METRICS_ADDRESS" envDefault:":8080"`
	OperatorNamespace       string        `env:"OPERATOR_NAMESPACE" envDefault:"dxp-operator-system"`
	OperatorServiceAccount  string        `env:"OPERATOR_SERVICE_ACCOUNT" envDefault:"dxp-operator"`
	ProbeAddress            string        `env:"PROBE_ADDRESS" envDefault:":8081"`
	ProvisioningBaseURL     string        `env:"PROVISIONING_BASE_URL" envDefault:"https://api.one.liferay.com"`
	ProvisioningGracePeriod time.Duration `env:"PROVISIONING_GRACE_PERIOD" envDefault:"168h"`
	RBACScope               string        `env:"RBAC_SCOPE" envDefault:"cluster"`
	RetryInitialDelay       time.Duration `env:"RETRY_INITIAL_DELAY" envDefault:"30s"`
	RetryMaxDelay           time.Duration `env:"RETRY_MAX_DELAY" envDefault:"30m"`
}

type operator struct {
	config     config
	restConfig *rest.Config
}

var scheme = runtime.NewScheme()
