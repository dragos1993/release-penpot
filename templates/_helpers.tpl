{{- define "penpot.name" -}}
penpot
{{- end -}}

{{- define "penpot.labels" -}}
app.kubernetes.io/name: {{ include "penpot.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* Usage: {{ include "penpot.componentLabels" (dict "root" $ "component" "backend") }} */}}
{{- define "penpot.componentLabels" -}}
{{ include "penpot.labels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "penpot.selectorLabels" -}}
app.kubernetes.io/name: {{ include "penpot.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}
