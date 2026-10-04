#!/usr/bin/env bash
# Stage 00-preflight — OS, resources, ports, networks, registry access
# Owner: track A. Sourced by deploy.sh; can also run alone: sudo ./scripts/00-preflight.sh
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stage_standalone_init

warn "stage 00-preflight is not implemented yet"
