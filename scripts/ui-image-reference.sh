#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tag=$(sha256sum ui/Dockerfile ui/UPSTREAM_REF ui/oidc-return-page.patch | sha256sum | cut -c1-32)
printf 'ghcr.io/mzhk-repo/dspace-angular:oidc-%s\n' "$tag"
