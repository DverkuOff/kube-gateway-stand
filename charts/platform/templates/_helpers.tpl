{{- define "platform.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: kube-gateway-stand
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "platform.hostSuffix" -}}
{{- required "hostSuffix is required (e.g. --set hostSuffix=192.0.2.10.sslip.io)" .Values.hostSuffix -}}
{{- end -}}
