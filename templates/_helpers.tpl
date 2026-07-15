{{/* Chart name */}}
{{- define "temporal-stack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified app name */}}
{{- define "temporal-stack.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "temporal-stack.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels */}}
{{- define "temporal-stack.labels" -}}
helm.sh/chart: {{ include "temporal-stack.chart" . }}
{{ include "temporal-stack.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: temporal
{{- end -}}

{{/* Selector labels */}}
{{- define "temporal-stack.selectorLabels" -}}
app.kubernetes.io/name: {{ include "temporal-stack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* True when the username-allowlist gate sidecar should be deployed */}}
{{- define "temporal-stack.uiGateEnabled" -}}
{{- and .Values.ui.auth.enabled (gt (len .Values.ui.auth.allowedUsers) 0) -}}
{{- end -}}

{{/* Frontend service name that clients/UI connect to */}}
{{- define "temporal-stack.frontendService" -}}
{{- printf "%s-frontend" (include "temporal-stack.fullname" .) -}}
{{- end -}}

{{/* Resolved database host: bundled postgres service unless overridden */}}
{{- define "temporal-stack.dbHost" -}}
{{- if .Values.database.host -}}
{{- .Values.database.host -}}
{{- else -}}
{{- .Values.postgresql.fullnameOverride | default "temporal-postgresql" -}}
{{- end -}}
{{- end -}}

{{/* Resolved secret holding the DB password */}}
{{- define "temporal-stack.dbSecret" -}}
{{- if .Values.database.existingSecret -}}
{{- .Values.database.existingSecret -}}
{{- else -}}
{{- .Values.postgresql.fullnameOverride | default "temporal-postgresql" -}}
{{- end -}}
{{- end -}}

{{/*
Shared environment block for Temporal server pods and the schema job.
The auto-setup/admin-tools entrypoints read these to render config & wire the DB.
*/}}
{{- define "temporal-stack.dbEnv" -}}
- name: DB
  value: {{ .Values.database.driver | quote }}
- name: DB_PORT
  value: {{ .Values.database.port | quote }}
- name: POSTGRES_SEEDS
  value: {{ include "temporal-stack.dbHost" . | quote }}
- name: POSTGRES_USER
  value: {{ .Values.database.user | quote }}
- name: POSTGRES_PWD
  valueFrom:
    secretKeyRef:
      name: {{ include "temporal-stack.dbSecret" . }}
      key: {{ .Values.database.secretKey }}
- name: DBNAME
  value: {{ .Values.database.temporalDb | quote }}
- name: VISIBILITY_DBNAME
  value: {{ .Values.database.visibilityDb | quote }}
{{- end -}}
