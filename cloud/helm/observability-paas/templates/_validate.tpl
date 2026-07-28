{{- define "observability-paas.validate" -}}
{{- $cloud := index .Values "observability" "cloudProvider" -}}
{{- if ne $cloud "gcp" -}}
{{- fail (printf "observability-paas only supports cloudProvider=gcp today; got %q. AWS PaaS support is not yet implemented." $cloud) -}}
{{- end -}}
{{- end -}}