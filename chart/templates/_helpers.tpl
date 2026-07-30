{{/* Standard name helpers */}}
{{- define "app-back.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app-back.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s" (include "app-back.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "app-back.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels (recommended Kubernetes labels) */}}
{{- define "app-back.labels" -}}
helm.sh/chart: {{ include "app-back.chart" . }}
app.kubernetes.io/name: {{ include "app-back.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: app-back
app-back/env: {{ .Values.env }}
{{- end -}}

{{/* Selector labels — component is appended by each workload template */}}
{{- define "app-back.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app-back.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Fully-qualified image reference — prefer digest pinning when provided */}}
{{- define "app-back.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}
{{- end -}}

{{/* envFrom block shared by app workloads: non-secret ConfigMap + SealedSecret-backed Secret */}}
{{- define "app-back.envFrom" -}}
- configMapRef:
    name: {{ include "app-back.fullname" . }}-config
- secretRef:
    name: {{ .Values.appSecretName }}
{{- end -}}
