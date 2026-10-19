#!/usr/bin/env bash
# Initialize users and social graph relationships for SocialNetwork
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd -- "$ROOT_DIR/.." && pwd)

. "$ROOT_DIR/config/experiment.env"
HOST_IP=${HOST_IP:-127.0.0.1}
TARGET_HOST="social-network.${HOST_IP}.sslip.io"
PORT=80
GRAPH_NAME="${1:-soc-small}"

echo "=== 1. Checking prerequisites ==="
python3 -c "import aiohttp" 2>/dev/null || {
    echo "ERROR: aiohttp is required. Install with: pip install aiohttp" >&2
    exit 1
}

echo "=== 2. Checking connectivity to $TARGET_HOST:$PORT ==="
if ! curl -fsS --max-time 5 "http://${TARGET_HOST}:${PORT}/" >/dev/null 2>&1; then
    echo "WARNING: $TARGET_HOST:$PORT is not responding yet or root path returns 404. Proceeding..."
fi

echo "=== 3. Seeding users and social graph relationships ($GRAPH_NAME) ==="
cd "$REPO_ROOT/DeathStarBench/socialNetwork"
python3 scripts/init_social_graph.py \
    --graph="$GRAPH_NAME" \
    --ip="$TARGET_HOST" \
    --port="$PORT" \
    --compose

echo
echo "=========================================================="
echo "Data initialization completed successfully!"
echo "SocialNetwork is now ready for load testing."
echo "=========================================================="
