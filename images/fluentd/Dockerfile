# syntax=docker/dockerfile:1.7
# Fluentd DaemonSet image with the Loki output plugin.
# The plugin (fluent-plugin-grafana-loki, Apache-2.0) is a single Ruby file whose only runtime
# dependency is Fluentd itself, so it is dropped into /fluentd/plugins (loaded via -p) instead of
# going through bundler. The extract stage runs on the build platform, so multi-arch builds need
# no emulation.
ARG FLUENTD_BASE_IMAGE=fluent/fluentd-kubernetes-daemonset:v1.19.3-debian-forward-1.1

FROM --platform=$BUILDPLATFORM alpine:3.22 AS plugin
ARG FLUENT_PLUGIN_LOKI_VERSION=1.3.0
ARG FLUENT_PLUGIN_LOKI_SHA256=a9fb5177bbe391da4fb1de434659125e5d39010b67340953742d68d9fddbf86c
ADD --checksum=sha256:${FLUENT_PLUGIN_LOKI_SHA256} \
    https://rubygems.org/downloads/fluent-plugin-grafana-loki-${FLUENT_PLUGIN_LOKI_VERSION}.gem /tmp/plugin.gem
RUN mkdir -p /out && cd /tmp \
 && tar -xf plugin.gem data.tar.gz \
 && tar -xzf data.tar.gz lib/fluent/plugin/out_loki.rb LICENSE \
 && cp lib/fluent/plugin/out_loki.rb /out/out_loki.rb \
 && cp LICENSE /out/LICENSE.fluent-plugin-grafana-loki

FROM ${FLUENTD_BASE_IMAGE}
COPY --from=plugin /out/ /fluentd/plugins/
LABEL org.opencontainers.image.source="https://github.com/DverkuOff/kube-gateway-stand" \
      org.opencontainers.image.description="Fluentd DaemonSet image with the Loki output plugin" \
      org.opencontainers.image.licenses="Apache-2.0"
