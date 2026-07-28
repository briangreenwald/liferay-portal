{{- define "observability-paas.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "observability-paas.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "observability-paas.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "observability-paas.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "observability-paas.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "observability-paas.name" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
component: observability-paas
helm.sh/chart: {{ include "observability-paas.chart" . }}
{{- end }}

{{- define "observability-paas.grafana.fullname" -}}
{{- printf "%s-grafana" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "observability-paas.gmp.customMetricsStackdriverAdapter.name" -}}
{{- "custom-metrics-stackdriver-adapter" -}}
{{- end -}}

{{- define "observability-paas.cleanup.fullname" -}}
{{- printf "%s-cleanup" (include "observability-paas.grafana.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}