{{/* Étiquettes communes à tous les objets du chart. */}}
{{- define "colis.etiquettes" -}}
app.kubernetes.io/part-of: colis
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/* Image de l'API, du worker et de la purge. */}}
{{- define "colis.imageApi" -}}
{{ .Values.images.registre }}/{{ .Values.images.api.depot }}:{{ .Values.images.api.etiquette | default .Chart.AppVersion }}
{{- end }}

{{/* Variables d'environnement communes à l'API, au worker, à la purge et à la sauvegarde. */}}
{{- define "colis.env" -}}
envFrom:
- configMapRef:
    name: colis-config
env:
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: colis-db
      key: POSTGRES_PASSWORD
- name: COLIS_DB
  value: postgresql://colis:$(POSTGRES_PASSWORD)@postgres:5432/colis
{{- end }}
