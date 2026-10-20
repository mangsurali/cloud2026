#!/usr/bin/env bash
# Execute controlled workload experiment against SocialNetwork
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
CONFIG="$ROOT_DIR/config/experiment.env"

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 scenarios/<scenario>.env" >&2
    exit 2
fi

SCENARIO=$1
case "$SCENARIO" in
    /*) ;;
    *) SCENARIO="$ROOT_DIR/$SCENARIO" ;;
esac

[ -f "$CONFIG" ] || { echo "Missing $CONFIG" >&2; exit 1; }
[ -f "$SCENARIO" ] || { echo "Missing scenario: $SCENARIO" >&2; exit 1; }

# Allow caller overrides
CALLER_HOST_IP=${HOST_IP-}
CALLER_TARGET_URL=${TARGET_URL-}
CALLER_REPLICATE=${REPLICATE-}
CALLER_DURATION=${DURATION-}
CALLER_RPS=${RPS-}
CALLER_WORKLOAD_TYPE=${WORKLOAD_TYPE-}

. "$CONFIG"
. "$SCENARIO"

[ -n "$CALLER_HOST_IP" ] && HOST_IP=$CALLER_HOST_IP
[ -n "$CALLER_TARGET_URL" ] && TARGET_URL=$CALLER_TARGET_URL
[ -n "$CALLER_REPLICATE" ] && REPLICATE=$CALLER_REPLICATE
[ -n "$CALLER_DURATION" ] && DURATION=$CALLER_DURATION
[ -n "$CALLER_RPS" ] && RPS=$CALLER_RPS
[ -n "$CALLER_WORKLOAD_TYPE" ] && WORKLOAD_TYPE=$CALLER_WORKLOAD_TYPE

HOST_IP=${HOST_IP:-127.0.0.1}
TARGET_URL=${TARGET_URL:-http://social-network.${HOST_IP}.sslip.io}
REPLICATE=${REPLICATE:-1}

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
WORKLOAD_TYPE=${WORKLOAD_TYPE:-mixed}
EXPERIMENT_ID="${PROFILE}-${WORKLOAD_TYPE}-${STAMP}-r${REPLICATE}"
OUT="$ROOT_DIR/results/$EXPERIMENT_ID"
mkdir -p "$OUT"

cp "$CONFIG" "$OUT/experiment.env"
cp "$SCENARIO" "$OUT/scenario.env"

echo "=========================================================="
echo "Experiment ID : $EXPERIMENT_ID"
echo "Profile       : $PROFILE"
echo "Target URL    : $TARGET_URL"
echo "Results Dir   : $OUT"
echo "=========================================================="

echo "Running Warm-up (${WARMUP_SECONDS}s at ${WARMUP_RPS} RPS)..."
python3 "$SCRIPT_DIR/loadgen-socialnetwork.py" \
    --url "$TARGET_URL" \
    --profile constant \
    --duration "$WARMUP_SECONDS" \
    --rps "$WARMUP_RPS" \
    --timeout "$REQUEST_TIMEOUT" \
    --sample-interval "$SAMPLE_INTERVAL" \
    --discard-output || true

MEASUREMENT_START_EPOCH=$(date +%s)
echo "Measurement started: $MEASUREMENT_START_EPOCH"

ARGS="--url $TARGET_URL --profile $PROFILE --workload-type $WORKLOAD_TYPE --duration $DURATION --timeout $REQUEST_TIMEOUT --sample-interval $SAMPLE_INTERVAL --max-users $MAX_USER_INDEX --output $OUT/workload.csv"

case "$PROFILE" in
  constant|overload)
    set -- --rps "$RPS"
    ;;
  ramp)
    set -- --start-rps "$START_RPS" --end-rps "$END_RPS"
    ;;
  burst)
    set -- --base-rps "$BASE_RPS" --burst-rps "$BURST_RPS" --burst-start "$BURST_START" --burst-duration "$BURST_DURATION"
    ;;
  *)
    set -- --rps "${RPS:-20}"
    ;;
esac

python3 "$SCRIPT_DIR/loadgen-socialnetwork.py" $ARGS "$@"

MEASUREMENT_END_EPOCH=$(date +%s)
echo "Measurement ended: $MEASUREMENT_END_EPOCH"

cat > "$OUT/measurement-window.env" <<EOF
EXPERIMENT_ID=$EXPERIMENT_ID
MEASUREMENT_START_EPOCH=$MEASUREMENT_START_EPOCH
MEASUREMENT_END_EPOCH=$MEASUREMENT_END_EPOCH
SAMPLE_INTERVAL=$SAMPLE_INTERVAL
EOF

python3 - "$OUT/metadata.json" <<PY
import json, platform
meta = {
  "experiment_id": "$EXPERIMENT_ID",
  "profile": "$PROFILE",
  "workload_type": "$WORKLOAD_TYPE",
  "target_url": "$TARGET_URL",
  "host_ip": "$HOST_IP",
  "measurement_start_epoch": int("$MEASUREMENT_START_EPOCH"),
  "measurement_end_epoch": int("$MEASUREMENT_END_EPOCH"),
  "sample_interval_seconds": float("$SAMPLE_INTERVAL"),
  "warmup_seconds": int("$WARMUP_SECONDS"),
  "cooldown_seconds": int("$COOLDOWN_SECONDS"),
  "replicate": int("$REPLICATE"),
  "application": {
    "name": "$APPLICATION_NAME",
    "architecture": "$APPLICATION_ARCHITECTURE"
  },
  "runtime": {"python": platform.python_version(), "platform": platform.platform()}
}
with open("$OUT/metadata.json", "w") as f:
    json.dump(meta, f, indent=2)
PY

echo "Cool-down: ${COOLDOWN_SECONDS}s"
sleep "$COOLDOWN_SECONDS"

echo
echo "=========================================================="
echo "Experiment completed: $EXPERIMENT_ID"
echo "Outputs generated:"
echo " - $OUT/workload.csv"
echo " - $OUT/measurement-window.env"
echo " - $OUT/metadata.json"
echo "=========================================================="
