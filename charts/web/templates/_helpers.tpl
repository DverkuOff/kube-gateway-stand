{{- define "web.labels" -}}
app.kubernetes.io/name: web
app.kubernetes.io/part-of: kube-gateway-stand
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* selector labels of one version: call with (dict "version" "v1") */}}
{{- define "web.selector" -}}
app.kubernetes.io/name: web
app.kubernetes.io/version: {{ .version }}
{{- end -}}

{{- define "web.host" -}}
{{- required "host is required (e.g. --set host=app.192.0.2.10.sslip.io)" .Values.host -}}
{{- end -}}

{{- define "web.weight" -}}
{{- $w := int .Values.canary.weight -}}
{{- if or (lt $w 0) (gt $w 100) -}}
{{- fail (printf "canary.weight must be within 0..100, got %v" .Values.canary.weight) -}}
{{- end -}}
{{- $w -}}
{{- end -}}

{{/* nginx.conf of one version: call with (dict "version" "v1" "root" $) */}}
{{- define "web.nginxConf" -}}
worker_processes {{ .root.Values.nginx.workerProcesses }};
error_log /dev/stderr warn;
pid /tmp/nginx.pid;

events {
  worker_connections 1024;
}

http {
  # Writable paths only under /tmp (read-only root filesystem).
  client_body_temp_path /tmp/client_temp;
  proxy_temp_path /tmp/proxy_temp;
  fastcgi_temp_path /tmp/fastcgi_temp;
  uwsgi_temp_path /tmp/uwsgi_temp;
  scgi_temp_path /tmp/scgi_temp;

  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  server_tokens off;
  sendfile on;
  keepalive_timeout 65;

  # $request_id ignores the incoming header: reuse X-Request-ID from the gateway or client if present.
  map $http_x_request_id $req_id {
    default $http_x_request_id;
    ""      $request_id;
  }

  log_format json escape=json '{"time":"$time_iso8601","request_id":"$req_id",'
    '"remote_addr":"$remote_addr","xff":"$http_x_forwarded_for","method":"$request_method",'
    '"uri":"$request_uri","status":$status,"bytes":$body_bytes_sent,'
    '"request_time":$request_time,"ua":"$http_user_agent","host":"$host","version":"{{ .version }}"}';
  access_log /dev/stdout json;

  server {
    listen 8080;
    server_name _;
    root /usr/share/nginx/html;

    add_header X-Request-Id $req_id always;
    add_header X-App-Version {{ .version }} always;

    location = / {
      default_type text/plain;
      return 200 "Hello World! ({{ .version }})\n";
    }

    location = /healthz {
      access_log off;
      default_type text/plain;
      return 200 "ok\n";
    }

    # Anything else is a static file lookup: unknown paths give 404 and an "open() ... failed" error-log line.
    location / {
    }
  }

  # stub_status for the exporter sidecar, reachable only inside the pod.
  server {
    listen 127.0.0.1:8081;
    access_log off;
    location = /stub_status {
      stub_status;
    }
  }
}
{{- end -}}

{{/* filters shared by every HTTPRoute rule (security headers + rate limit) */}}
{{- define "web.ruleFilters" }}
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            set:
              {{- range $name, $value := .Values.responseHeaders }}
              - name: {{ $name }}
                value: {{ $value | quote }}
              {{- end }}
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: rate-limit
{{- end }}
