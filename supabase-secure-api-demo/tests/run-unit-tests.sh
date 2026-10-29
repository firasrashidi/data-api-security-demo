#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
(cd "$root/aws/backend" && npm test && npm run typecheck)
(cd "$root/cloudflare/worker" && npm test && npm run typecheck)
