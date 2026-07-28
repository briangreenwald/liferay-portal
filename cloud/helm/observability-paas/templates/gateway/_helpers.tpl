{{- define "observability-paas.gateway.name" -}}
{{- default (printf "%s-gateway" (include "observability-paas.gateway.targetName" .)) .Values.gateway.name -}}
{{- end -}}

{{- define "observability-paas.gateway.className" -}}
{{- if .Values.gateway.gatewayClassName -}}
{{- .Values.gateway.gatewayClassName -}}
{{- else if eq .Values.gateway.provider "envoy" -}}
{{- "envoy-gateway-l4" -}}
{{- else -}}
{{- "gke-l7-global-external-managed" -}}
{{- end -}}
{{- end -}}

{{- define "observability-paas.gateway.targetName" -}}
{{- include "observability-paas.grafana.fullname" . -}}
{{- end -}}

{{- define "observability-paas.gateway.hostname" -}}
{{- first (index .Values "observability" "grafana" "route" "main" "hostnames") -}}
{{- end -}}
