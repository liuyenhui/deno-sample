{{- define "deno-service-chart.fullname" -}}
  {{- printf "%s-%s" .Release.Name .Chart.AppVersion | trunc 63 -}}
{{- end -}}
