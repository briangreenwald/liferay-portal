# observability-paas

PaaS-only overlay for the `observability` chart. It consumes `observability` as
a subchart and adds the Liferay-PaaS pieces the cloud-agnostic base omits:

- the `builds`, `secrets`, and `custom-domains` dashboards, plus a
    PaaS-flavored `central-hub` that replaces the base one (tiles for Builds,
    Secrets, and Custom Domains, and PROJECT/LOCATION header badges)
- the `googlecloud-logging-datasource` for the `builds` dashboard and the
    kubernetes-workload log panels
- kube-state-metrics tuning: a `customResourceState` config exporting the
    `LiferayBackup`, `HTTPRoute`, and `Certificate` metrics that back the
    backups and custom-domains dashboards, and a customer-namespace-scoped
    `PodMonitoring` (`exported_namespace ~ ^liferay-.*-.*$`, 5m) that replaces
    the base chart's unfiltered scrape
- Gateway API exposure for Grafana (`Gateway` + Envoy or GKE traffic
    policies); the HTTPRoutes are rendered by the grafana subchart and attach
    to this Gateway
- Grafana Okta SSO (an `ExternalSecret` for the OIDC credentials plus the
    `auth.okta` login block), off by default
- Grafana alerting email over SMTP (an `ExternalSecret` for the SMTP
    credentials plus the `grafana.ini` `[smtp]` block), off by default. Without
    it the alert rules still fire but the email contact point cannot send
- optional GCP add-ons, off by default: the `custom-metrics-stackdriver-adapter`
    (HPA on Cloud Monitoring metrics) and the GMP collector RBAC
- an optional CronJob that deletes manually-provisioned Grafana resources
    (off by default)

## GMP querying

Grafana queries Google Managed Prometheus through the **base chart's in-cluster
frontend proxy** (`observability` renders a `prometheus-engine/frontend`
Deployment that runs as the `grafana` ServiceAccount and authenticates to GMP
via Workload Identity). There is **no** OAuth-token datasource-syncer CronJob;
the frontend proxy replaces it. The frontend needs the GCP project id
(`observability.gcp.projectId`).

## Supported clouds

Today: **GCP only.** Helm template fails with a clear message if
`observability.cloudProvider` is set to anything other than `gcp` (see
`templates/_validate.tpl`). AWS PaaS support is planned but out of scope for
this iteration.

## Deploy-time contract

Defaults in `values.yaml` are placeholders. The ArgoCD ApplicationSet's
`templatePatch` (in `charts/deploy/internal/argocd-resources/{nonprd,prd}/applications.yaml`)
injects these per-cluster from cluster metadata:

| Value | Source |
| --- | --- |
| `observability.gcp.projectId` | `GcpProjectId` label |
| `observability.grafana.route.main.hostnames[]` / `route.redirect.hostnames[]` | `monitoring.<DnsZones>` |
| `observability.grafana.grafana\.ini.auth\.okta.*` + `sso.enabled` | `CustomerOidcProperties` / `EnabledSso` |
| `smtp.enabled` + `observability.grafana.grafana\.ini.smtp.ehlo_identity` | alerting email toggle / `monitoring.<DnsZones>` |
| `observability.alloy.iam.gcpServiceAccount` | PaaS infrastructure |
| `centralHub.*` | cluster metadata (`DnsZones`, project/location labels) |

`gateway.name` must stay in sync with
`observability.grafana.route.main/redirect.parentRefs[].name`.