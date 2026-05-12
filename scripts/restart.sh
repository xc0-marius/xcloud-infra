#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/opt/xcloud-infra"

"${BASE}/scripts/down.sh"
"${BASE}/scripts/up.sh"
