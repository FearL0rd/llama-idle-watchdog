#!/usr/bin/env bash
# Watch llama-server for 5 minutes of idle (no inference / no meaningful work)
# and restart llama-server.service so a later request hits a fresh process.
#
# Install:
#   sudo install -m 0755 llama-idle-watchdog.sh /usr/local/bin/llama-idle-watchdog.sh
#   sudo install -m 0644 llama-idle-watchdog.service /etc/systemd/system/
#   sudo systemctl daemon-reload
#   sudo systemctl enable --now llama-idle-watchdog.service
#
# Override defaults in /etc/default/llama-idle-watchdog

set -euo pipefail

: "${LLAMA_URL:=http://127.0.0.1:8080}"
: "${LLAMA_SERVICE:=llama-server.service}"
: "${IDLE_SECONDS:=300}"          # 5 minutes
: "${POLL_SECONDS:=15}"
: "${HEALTH_TIMEOUT:=3}"
: "${COOLDOWN_SECONDS:=120}"      # do not restart again within this window
: "${STATE_DIR:=/var/lib/llama-idle-watchdog}"
: "${REQUIRE_SERVICE_ACTIVE:=1}"
# Optional: comma-separated model ids. Empty = discover via GET /models
: "${LLAMA_MODELS:=}"
# CUDA device index to require idle before restart (1 = CUDA:1)
: "${CUDA_INDEX:=1}"
# Max GPU util % allowed to treat the device as idle (0 = must be 0%)
: "${CUDA_IDLE_MAX_PCT:=0}"
: "${REQUIRE_GPU_IDLE:=1}"
# idle action: restart | unload
: "${IDLE_ACTION:=restart}"

STATE_FILE="${STATE_DIR}/state"
LAST_RESTART_FILE="${STATE_DIR}/last_restart"

log() {
  printf '%s llama-idle-watchdog: %s\n' "$(date -Is)" "$*" >&2
}

mkdir -p "$STATE_DIR"

now() { date +%s; }

http_code() {
  local path="$1"
  curl -sS -o /dev/null -w '%{http_code}' --max-time "$HEALTH_TIMEOUT" \
    "${LLAMA_URL}${path}" 2>/dev/null || echo "000"
}

fetch() {
  local path="$1"
  curl -sS --max-time "$HEALTH_TIMEOUT" "${LLAMA_URL}${path}" 2>/dev/null || true
}

urlencode() {
  # RFC3986-ish encode for model ids like org/name:Q4_K_M
  python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1" 2>/dev/null \
    || printf '%s' "$1" | sed 's|/|%2F|g; s|:|%3A|g; s| |%20|g'
}

# Prints: <id><TAB><status>  status = loaded|loading|downloading|sleeping|unloaded|unknown
parse_model_rows() {
  python3 -c '
import json,sys
raw=sys.stdin.read()
try:
    data=json.loads(raw)
except Exception:
    sys.exit(0)
items=data.get("data", data if isinstance(data, list) else [])
for m in items:
    if not isinstance(m, dict):
        continue
    mid=m.get("id") or m.get("model") or ""
    if not mid:
        continue
    st=m.get("status")
    if isinstance(st, dict):
        val=st.get("value") or "unknown"
    elif isinstance(st, str):
        val=st
    else:
        val="unknown"
    print(f"{mid}\t{val.lower()}")
' 2>/dev/null || true
}

list_model_rows() {
  local body
  body="$(fetch /models)"
  if [[ -z "$body" ]]; then
    body="$(fetch /v1/models)"
  fi
  printf '%s' "$body" | parse_model_rows
}

slots_body_busy() {
  local body="$1"
  printf '%s' "$body" | grep -Eqi '"is_processing"[[:space:]]*:[[:space:]]*true'
}

is_processing() {
  # Single-model: GET /slots works.
  # Router mode: GET /slots returns 400 "model name is missing".
  # Discover which models are actually running from GET /models status.
  # Only probe /slots for loaded models, and pass autoload=false so we
  # never wake an unloaded model.
  local body mid status enc slots
  body="$(fetch /slots)"
  if slots_body_busy "$body"; then
    return 0
  fi
  if ! printf '%s' "$body" | grep -Fqi 'model name is missing'; then
    return 1
  fi

  while IFS=$'\t' read -r mid status; do
    [[ -z "$mid" ]] && continue
    if [[ -n "$LLAMA_MODELS" ]] && ! printf '%s' ",${LLAMA_MODELS}," | grep -Fq ",${mid},"; then
      continue
    fi
    case "$status" in
      loading|downloading)
        log "busy: ${mid} status=${status}"
        return 0
        ;;
      loaded)
        enc="$(urlencode "$mid")"
        # autoload=false: do not load other models just to inspect slots
        slots="$(fetch "/slots?model=${enc}&autoload=false")"
        if slots_body_busy "$slots"; then
          log "busy: ${mid} is_processing=true"
          return 0
        fi
        ;;
      sleeping|unloaded|failed|unknown|"")
        ;;
    esac
  done < <(list_model_rows)

  # Resident but not generating = idle (timer keeps running).
  # No resident models at all = also idle.
  return 1
}

server_up() {
  local code
  code="$(http_code /health)"
  [[ "$code" == "200" || "$code" == "503" ]]
}

service_active() {
  systemctl is-active --quiet "$LLAMA_SERVICE"
}

read_last_busy() {
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
  else
    now
  fi
}

write_last_busy() {
  printf '%s\n' "$1" > "$STATE_FILE"
}

last_restart_age() {
  if [[ -f "$LAST_RESTART_FILE" ]]; then
    echo $(( $(now) - $(cat "$LAST_RESTART_FILE") ))
  else
    echo 999999
  fi
}

mark_restart() {
  printf '%s\n' "$(now)" > "$LAST_RESTART_FILE"
}

gpu_util_pct() {
  # Prints integer util for CUDA:${CUDA_INDEX}, or empty on failure.
  nvidia-smi -i "$CUDA_INDEX" --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null \
    | head -n1 | tr -dc '0-9'
}

gpu_is_idle() {
  local util
  if [[ "$REQUIRE_GPU_IDLE" != "1" ]]; then
    return 0
  fi
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    return 1
  fi
  util="$(gpu_util_pct)"
  [[ -n "$util" ]] || return 1
  (( util <= CUDA_IDLE_MAX_PCT ))
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1" 2>/dev/null \
    || printf '"%s"' "${1//\"/\\\"}"
}

unload_loaded_models() {
  local mid status payload resp any=0
  while IFS=$'\t' read -r mid status; do
    [[ -z "$mid" ]] && continue
    if [[ -n "$LLAMA_MODELS" ]] && ! printf '%s' ",${LLAMA_MODELS}," | grep -Fq ",${mid},"; then
      continue
    fi
    case "$status" in
      loaded|sleeping|loading)
        any=1
        payload="{\"model\":$(json_escape "$mid")}"
        log "unloading ${mid} (status=${status})"
        resp="$(curl -sS --max-time "$HEALTH_TIMEOUT" \
          -X POST -H 'Content-Type: application/json' \
          -d "$payload" \
          "${LLAMA_URL}/models/unload" 2>/dev/null || true)"
        log "unload ${mid}: ${resp:-no response}"
        ;;
    esac
  done < <(list_model_rows)
  if (( any == 0 )); then
    log "no loaded/sleeping models to unload"
  fi
}

take_idle_action() {
  local age
  age="$(last_restart_age)"
  if (( age < COOLDOWN_SECONDS )); then
    log "idle timeout reached but cooldown active (${age}s < ${COOLDOWN_SECONDS}s); skip"
    return 0
  fi
  if ! gpu_is_idle; then
    log "idle timeout reached but CUDA:${CUDA_INDEX} util=$(gpu_util_pct)% — wait for 0%"
    return 0
  fi

  case "$IDLE_ACTION" in
    unload)
      log "idle for >= ${IDLE_SECONDS}s and CUDA:${CUDA_INDEX}=$(gpu_util_pct)% — unloading models"
      unload_loaded_models
      mark_restart
      write_last_busy "$(now)"
      ;;
    restart|*)
      log "idle for >= ${IDLE_SECONDS}s and CUDA:${CUDA_INDEX}=$(gpu_util_pct)% — restarting ${LLAMA_SERVICE}"
      if systemctl restart "$LLAMA_SERVICE"; then
        mark_restart
        write_last_busy "$(now)"
        log "restart issued"
      else
        log "systemctl restart failed"
      fi
      ;;
  esac
}

# Seed last-busy so we do not immediately restart on first start.
if [[ ! -f "$STATE_FILE" ]]; then
  write_last_busy "$(now)"
fi

log "started url=${LLAMA_URL} service=${LLAMA_SERVICE} action=${IDLE_ACTION} idle=${IDLE_SECONDS}s poll=${POLL_SECONDS}s cuda=${CUDA_INDEX}"

while true; do
  if [[ "$REQUIRE_SERVICE_ACTIVE" == "1" ]] && ! service_active; then
    write_last_busy "$(now)"
    sleep "$POLL_SECONDS"
    continue
  fi

  if is_processing; then
    write_last_busy "$(now)"
  elif [[ "$REQUIRE_GPU_IDLE" == "1" ]] && ! gpu_is_idle; then
    # GPU still computing (IO / kernels) even if /slots looks idle
    write_last_busy "$(now)"
  elif server_up; then
    last="$(read_last_busy)"
    idle=$(( $(now) - last ))
    if (( idle >= IDLE_SECONDS )); then
      take_idle_action
    fi
  else
    # Server not answering health — leave last-busy alone so a dead hang
    # still trips the idle restart once IDLE_SECONDS has passed since last work.
    last="$(read_last_busy)"
    idle=$(( $(now) - last ))
    if service_active && (( idle >= IDLE_SECONDS )); then
      log "health down and idle ${idle}s — forcing restart"
      IDLE_ACTION=restart take_idle_action
    fi
  fi

  sleep "$POLL_SECONDS"
done
