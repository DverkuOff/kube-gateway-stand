# shellcheck shell=bash
# Printed at the end of a full ./deploy.sh run (sourced; prints only, no side effects).
# Uses APP_HOST, GRAFANA_HOST, NODE_IP and OUT_DIR from load_config (scripts/lib.sh).

step "access"
info "Application:     https://${APP_HOST:-app.<NODE_IP>.sslip.io}/"
info "Grafana:         https://${GRAFANA_HOST:-grafana.<NODE_IP>.sslip.io}/   (login and password: make creds)"
info "CA certificate:  ${OUT_DIR:-out}/ca.crt   (import it into the browser to trust both sites)"
printf '\n'
info "Quick test:      curl --cacert ${OUT_DIR:-out}/ca.crt https://${APP_HOST:-app.<NODE_IP>.sslip.io}/"
info "                 (without DNS for sslip.io add: --resolve ${APP_HOST:-app.<NODE_IP>.sslip.io}:443:${NODE_IP:-<NODE_IP>})"
printf '\n'
info "Next steps (as a regular user, no sudo):"
info "  make check         end-to-end check of the cluster, Gateway API, TLS, routing, metrics and logs"
info "  make creds         URLs and the Grafana login"
info "  make demo-logs     send a request with X-Request-ID and find it in Loki"
info "  make demo-metrics  generate traffic and print the key PromQL results"
info "  make canary W=50   change the share of traffic for v2"
