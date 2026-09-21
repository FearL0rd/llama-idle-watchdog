# llama-idle-watchdog

A Linux systemd helper for **llama.cpp** `llama-server` (single-model or
router mode).

After a long idle period or a large model IO cycle, using the same process
again without a restart often fails (stale CUDA context, hung slots, sleep /
reload bugs). This watchdog does **not** replace llama-server. It only
decides when it is safe to **unload models** or **restart the unit**.

## What it does

Every 15 seconds it:

1. Confirms `llama-server.service` is active.
2. Reads `GET /models` (which model is `loaded` / `loading` / `sleeping`).
3. For each loaded model, reads `GET /slots?model=<id>&autoload=false`.
4. Reads GPU util with `nvidia-smi -i $CUDA_INDEX`.
5. If the API is busy or the GPU is above `CUDA_IDLE_MAX_PCT`, it resets the
   idle clock.
6. After **`IDLE_SECONDS`** (default 300) of no work **and** GPU util ≤
   `CUDA_IDLE_MAX_PCT`, it runs **`IDLE_ACTION`**:

| `IDLE_ACTION` | Effect |
| --- | --- |
| `unload` (default) | `POST /models/unload` for each loaded / sleeping / loading model. The router stays up; the next request can autoload. |
| `restart` | `systemctl restart llama-server.service` |

If `/health` is down, it always **restarts** the unit. Unload cannot run
against a dead HTTP server.

You do not name the running model. The router reports it on `/models`.

## Requirements

- Linux + systemd
- `llama-server` already managed as a unit (default name `llama-server.service`)
- `bash`, `curl`, `python3`
- `nvidia-smi` if `REQUIRE_GPU_IDLE=1` (default)
- Root, so the watchdog can restart another unit

## Files

| File | Installed path | Purpose |
| --- | --- | --- |
| `llama-idle-watchdog.sh` | `/usr/local/bin/llama-idle-watchdog.sh` | Main loop |
| `llama-idle-watchdog.service` | `/etc/systemd/system/llama-idle-watchdog.service` | systemd unit |
| `llama-idle-watchdog.default` | `/etc/default/llama-idle-watchdog` | Settings |
| `install.sh` | run once | Install and enable |
| `uninstall.sh` | run once | Disable and delete installed files |
| `README.md` | this file | Documentation |
| `INSTALL.md` | short cheat sheet | Same install commands |

## Install

```bash
chmod +x install.sh uninstall.sh llama-idle-watchdog.sh
sudo ./install.sh
```

Manual:

```bash
sudo install -m 0755 llama-idle-watchdog.sh /usr/local/bin/llama-idle-watchdog.sh
sudo install -m 0644 llama-idle-watchdog.service /etc/systemd/system/llama-idle-watchdog.service
sudo install -m 0644 llama-idle-watchdog.default /etc/default/llama-idle-watchdog
sudo mkdir -p /var/lib/llama-idle-watchdog
sudo systemctl daemon-reload
sudo systemctl enable --now llama-idle-watchdog.service
```

`install.sh` will **not** overwrite an existing `/etc/default/llama-idle-watchdog`.
When updating the script later, copy only the `.sh` file.

Typical host settings after install (example matching a router on GPU 0):

```bash
# /etc/default/llama-idle-watchdog
LLAMA_URL=http://127.0.0.1:8080
LLAMA_SERVICE=llama-server.service
IDLE_ACTION=unload
IDLE_SECONDS=300
CUDA_INDEX=0
CUDA_IDLE_MAX_PCT=0
VERBOSE=1
HEARTBEAT_SECONDS=60
```

```bash
sudo systemctl restart llama-idle-watchdog.service
```

## Update the script only

```bash
sudo install -m 0755 llama-idle-watchdog.sh /usr/local/bin/llama-idle-watchdog.sh
sudo systemctl restart llama-idle-watchdog.service
```

Do not re-copy the packaged `.default` over a tuned config or you will lose
`CUDA_INDEX` / `IDLE_ACTION`.

## Verify

```bash
systemctl status llama-idle-watchdog.service
systemctl status llama-server.service
journalctl -u llama-idle-watchdog.service -f
```

GPU index:

```bash
nvidia-smi -L
nvidia-smi -i 0 --query-gpu=index,name,utilization.gpu --format=csv
```

`CUDA:0` is `nvidia-smi` index `0`. Set `CUDA_INDEX` to that number.

Router catalog:

```bash
curl -s http://127.0.0.1:8080/models | python3 -m json.tool
```

Look for `"status": { "value": "loaded" }` or `"loading"`.

## Busy vs idle

**Single-model** (`-m` / `--model` set):

- `GET /slots`
- Busy if any slot has `"is_processing": true`

**Router mode** (no model on the parent):

- Bare `GET /slots` returns `400 model name is missing` — expected
- `GET /models` → each `status.value`
- `loading` / `downloading` → **busy** (do not unload mid-IO)
- `loaded` → `GET /slots?model=<id>&autoload=false`
  - `autoload=false` so a status poll cannot wake other models
  - Busy if `"is_processing": true`
- `sleeping` / `unloaded` → not generating; `sleeping` is still unloaded when
  `IDLE_ACTION=unload`

`GET /health`, `GET /props`, `GET /models`, and `GET /metrics` are llama.cpp
idle-exempt. Polling them is not treated as user work.

State files in `/var/lib/llama-idle-watchdog/`:

- `state` — unix time of last busy moment
- `last_restart` — last action time (cooldown)

First start seeds “last busy” to now so it does not fire immediately.

## GPU gate

```bash
nvidia-smi -i "$CUDA_INDEX" --query-gpu=utilization.gpu --format=csv,noheader,nounits
```

Must be ≤ `CUDA_IDLE_MAX_PCT` (default `0`) before an action.

If util is above the cap:

- idle clock resets (`reason=gpu-busy`)
- at timeout: `idle timeout reached but CUDA:N util=X% — wait for 0%`

`nvidia-smi` reports a snapshot. The log line reads util again, so you can
see `reason=idle` and `cuda0=1%` on the same line. The **action** still uses
a fresh read and will wait if that read is above the cap.

If the card never reports a true `0%` (1–2% driver noise), raise the cap:

```bash
CUDA_IDLE_MAX_PCT=2
```

If `nvidia-smi` is missing and `REQUIRE_GPU_IDLE=1`, actions are skipped.

## Logging

By default the journal is quiet except start, busy events, and actions.

| Variable | Default | Effect |
| --- | --- | --- |
| `VERBOSE` | `0` | `1` = a `check` line on **every** poll (~15s) |
| `HEARTBEAT_SECONDS` | `60` | Even with `VERBOSE=0`, one `check` line this often. `0` disables |

Enable live checks:

```bash
sudo sed -i 's/^VERBOSE=.*/VERBOSE=1/' /etc/default/llama-idle-watchdog
# or append if the key is missing:
echo 'VERBOSE=1' | sudo tee -a /etc/default/llama-idle-watchdog
sudo systemctl restart llama-idle-watchdog.service
journalctl -u llama-idle-watchdog.service -f
```

### Example check line

```text
check reason=idle 144s/300s cuda0=1% models=1 resident: unsloth/Qwen3.8-Flash-Next-GGUF:IQ3_XXS=loaded/idle (unloaded=5)
```

| Token | Meaning |
| --- | --- |
| `reason=idle 144s/300s` | No API work for 144s; action at 300s |
| `reason=api-busy` | A slot is processing, or a model is loading |
| `reason=gpu-busy` | GPU util above `CUDA_IDLE_MAX_PCT` |
| `reason=service-inactive` | `llama-server.service` is not active |
| `reason=health-down …` | Unit up, HTTP not answering |
| `cuda0=1%` | `nvidia-smi -i 0` at log time |
| `MODEL=loaded/idle` | Resident, not generating |
| `MODEL=loaded/processing` | Resident, generating |
| `MODEL=loading` | GGUF IO in progress |
| `(unloaded=5)` | Catalog models not resident (not listed) |
| `models=none-loaded` | Nothing in loaded / loading / sleeping |

Other lines:

| Line | Meaning |
| --- | --- |
| `started url=... action=unload cuda=0 verbose=1` | Process start, resolved config |
| `busy: MODEL status=loading` | Load/download; clock reset |
| `busy: MODEL is_processing=true` | Generation; clock reset |
| `idle timeout reached but CUDA:0 util=1% — wait for 0%` | Timer done, GPU not idle |
| `idle timeout reached but cooldown active` | Action too recent |
| `idle for >= 300s ... — unloading models` | Unload started |
| `unloading MODEL (status=loaded)` | `POST /models/unload` |
| `unload MODEL: {"success": true}` | Router reply |
| `no loaded/sleeping models to unload` | Nothing to do |
| `idle for >= 300s ... — restarting llama-server.service` | Restart started |
| `restart issued` | `systemctl restart` succeeded |

A lone `started` line with no `check` for more than ~15s usually means
`VERBOSE=0` and heartbeat not due yet, **or** the first poll is blocked
(`curl` to `:8080` or `nvidia-smi`). Test:

```bash
curl -sS -m 3 http://127.0.0.1:8080/health
curl -sS -m 3 http://127.0.0.1:8080/models | head
nvidia-smi -i 0 --query-gpu=utilization.gpu --format=csv,noheader,nounits
```

## Configuration

Edit `/etc/default/llama-idle-watchdog`, then:

```bash
sudo systemctl restart llama-idle-watchdog.service
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `LLAMA_URL` | `http://127.0.0.1:8080` | llama-server base URL |
| `LLAMA_SERVICE` | `llama-server.service` | Unit to restart when `IDLE_ACTION=restart` |
| `IDLE_ACTION` | `unload` | `unload` (router API) or `restart` (systemd unit) |
| `IDLE_SECONDS` | `300` | Idle time before action |
| `POLL_SECONDS` | `15` | Poll interval |
| `HEALTH_TIMEOUT` | `3` | curl timeout (seconds) |
| `COOLDOWN_SECONDS` | `120` | Minimum time between actions |
| `REQUIRE_SERVICE_ACTIVE` | `1` | Ignore idle if the unit is not active |
| `STATE_DIR` | `/var/lib/llama-idle-watchdog` | Timestamp files |
| `LLAMA_MODELS` | empty | Optional comma-separated ids; empty = all from `/models` |
| `CUDA_INDEX` | `0` | `nvidia-smi` GPU index (`0` = CUDA:0) |
| `CUDA_IDLE_MAX_PCT` | `0` | Max util % treated as idle |
| `REQUIRE_GPU_IDLE` | `1` | Require GPU idle before action |
| `VERBOSE` | `0` | `1` = log every poll |
| `HEARTBEAT_SECONDS` | `60` | Status line interval when `VERBOSE=0` |

```bash
LLAMA_URL=http://127.0.0.1:8081
LLAMA_SERVICE=llama-server-gpu0.service
IDLE_ACTION=unload
IDLE_SECONDS=300
CUDA_INDEX=0
CUDA_IDLE_MAX_PCT=2
VERBOSE=1
```

`unload` requires router mode (`POST /models/unload`).

## Operations

```bash
sudo systemctl start llama-idle-watchdog.service
sudo systemctl stop llama-idle-watchdog.service
sudo systemctl restart llama-idle-watchdog.service
sudo systemctl disable llama-idle-watchdog.service

# llama-server itself
sudo systemctl restart llama-server.service
```

## Uninstall

```bash
chmod +x uninstall.sh
sudo ./uninstall.sh
```

Removes the watchdog unit, script, `/etc/default/llama-idle-watchdog`, and
`/var/lib/llama-idle-watchdog`. Does **not** touch `llama-server.service`.

## Notes

- `--sleep-idle-seconds` unloads weights **inside the same process**. That
  path is what often breaks on the next request. Prefer `IDLE_ACTION=restart`
  if unload is not enough.
- Watchdog polls of `/slots` and `/models` are not user traffic.
- If a load lasts longer than `IDLE_SECONDS` with GPU at 0% the whole time,
  raise `IDLE_SECONDS`. Normal loads show `loading` or non-zero GPU util.
- The watchdog runs as root.
- AMD / ROCm / Vulkan: `nvidia-smi` will not work. Set `REQUIRE_GPU_IDLE=0`.

## Troubleshooting

**Only a `started` line in the journal**

- `VERBOSE=0` and heartbeat not due — set `VERBOSE=1`
- First poll blocked — test `curl` and `nvidia-smi` as above
- Unit running an old script — reinstall the `.sh` and restart the unit

**Timer reaches 300s but nothing unloads**

- GPU util above `CUDA_IDLE_MAX_PCT` (including 1% noise)
- Cooldown from a previous action
- `IDLE_ACTION=unload` but no model in loaded / sleeping / loading

**Unloads or restarts while you are still loading**

- `/models` is not reporting `loading` / `downloading`
- Raise `IDLE_SECONDS`

**`model name is missing` on your own `GET /slots`**

- Normal on a router. Use `/models` or `/slots?model=ID&autoload=false`.

**Wrong unit restarted**

- Set `LLAMA_SERVICE` from `systemctl list-units '*llama*'`.
