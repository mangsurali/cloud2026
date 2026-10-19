#!/usr/bin/env bash
# Collect Prometheus metrics for an executed SocialNetwork experiment
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd -- "$ROOT_DIR/.." && pwd)
METRICS_DIR="$REPO_ROOT/cloud2023/kubernetes/research/cloud-dynamics-metrics"

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 /path/to/results/<experiment-id>" >&2
    exit 2
fi

EXP_PATH=$1
case "$EXP_PATH" in
    /*) ;;
    *) EXP_PATH="$ROOT_DIR/$EXP_PATH" ;;
esac

[ -d "$EXP_PATH" ] || { echo "Experiment directory not found: $EXP_PATH" >&2; exit 1; }
[ -f "$EXP_PATH/measurement-window.env" ] || { echo "Missing measurement-window.env in $EXP_PATH" >&2; exit 1; }

POD_PATTERN=${2:-".*"}

echo "=== Collecting Prometheus metrics into: $EXP_PATH (pod pattern: '$POD_PATTERN') ==="
"$METRICS_DIR/scripts/collect-experiment.sh" "$EXP_PATH" "$POD_PATTERN"

echo "Metrics collection completed!"
