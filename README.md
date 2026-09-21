# llama-idle-watchdog

A Linux systemd helper for **llama.cpp** `llama-server`.

After a long idle period or a large model IO cycle, coming back to the same
process without a restart often fails (stale CUDA context, hung slots, model
sleep/reload bugs). This watchdog watches the server and, only when it is
truly idle, either **restarts `llama-server.service`** or **unloads loaded
models** (`IDLE_ACTION`).

It does **not** load models and does **not** replace llama-server. It only
decides when an unload or a clean `systemctl restart` is safe.

## What it fixes

Typical failure:

1. A large GGUF is loaded on GPU 0 (`CUDA:0`).
2. The server sits idle.
3. You send a new request without restarting the unit.
4. Inference fails or hangs.

Workaround this tool automates: if there has been no real work for **5 minutes**
**and** GPU 1 is at **0%** utilization, take `IDLE_ACTION` (`restart` by
default, or `unload` in router mode). The next client request hits a fresh
process or an autoload.

## Requirements

- Linux with systemd
- `llama-server` already running as `llama-server.service` (rename in config if needed)
- `curl`, `python3`, `bash`
- `nvidia-smi` if you keep the CUDA idle gate (default on)
- Root (or equivalent) so the watchdog can run `systemctl restart llama-server.service`

## Files

| File | Installed path | Purpose |
| --- | --- | --- |
| `llama-idle-watchdog.sh` | `/usr/local/bin/llama-idle-watchdog.sh` | Main loop |
| `llama-idle-watchdog.service` | `/etc/systemd/system/llama-idle-watchdog.service` | systemd unit |
| `llama-idle-watchdog.default` | `/etc/default/llama-idle-watchdog` | Settings |
| `install.sh` | run once | Copies files and enables the unit |
| `README.md` | this file | Documentation |

## Install

From the directory that contains these files:

```bash
chmod +x install.sh llama-idle-watchdog.sh
sudo ./install.sh
```

Manual install:

```bash
sudo install -m 0755 llama-idle-watchdog.sh /usr/local/bin/llama-idle-watchdog.sh
sudo install -m 0644 llama-idle-watchdog.service /etc/systemd/system/llama-idle-watchdog.service
sudo install -m 0644 llama-idle-watchdog.default /etc/default/llama-idle-watchdog
sudo mkdir -p /var/lib/llama-idle-watchdog
sudo systemctl daemon-reload
sudo systemctl enable --now llama-idle-watchdog.service
```

`install.sh` will not overwrite an existing `/etc/default/llama-idle-watchdog`.

## Verify

```bash
systemctl status llama-idle-watchdog.service
systemctl status llama-server.service
journalctl -u llama-idle-watchdog.service -f
```

Confirm GPU index:

```bash
nvidia-smi -L
nvidia-smi -i 1 --query-gpu=index,name,utilization.gpu --format=csv
```

`CUDA:0` is `nvidia-smi` index `0`. If your llama-server GPU is index `0`, set
`CUDA_INDEX=0` (see below).

See which models the router thinks are running:

```bash
curl -s http://127.0.0.1:8080/models | python3 -m json.tool
```

Look for `"status": { "value": "loaded" }` or `"loading"`.

## How it works

Every **15 seconds** the script:

1. Checks that `llama-server.service` is active. If not, it resets the idle
   clock and waits.
2. Asks llama-server whether anything is working (see [Busy vs idle](#busy-vs-idle)).
3. Reads GPU util for `CUDA_INDEX` via `nvidia-smi`.
4. If the API is busy **or** the GPU is not 0%, it writes “last busy = now”.
5. If the API is up, nothing is processing, and the GPU is 0%, idle time grows.
6. When idle time ≥ **300 seconds**, cooldown is clear, and GPU util is still
   **0%**, it runs `IDLE_ACTION`:

   - `restart` (default): `systemctl restart llama-server.service`
   - `unload`: `POST /models/unload` for each loaded / sleeping / loading model.
     The router stays up; the next request can autoload.

State is stored in `/var/lib/llama-idle-watchdog/`:

- `state` — unix timestamp of last busy moment
- `last_restart` — unix timestamp of last restart (120s cooldown)

On first start, “last busy” is set to now so the unit is not restarted
immediately.

### Busy vs idle

**Single-model server** (`-m` / `--model` set):

- `GET /slots`
- Busy if any slot has `"is_processing": true`

**Router mode** (no model on the parent; your setup):

- Bare `GET /slots` returns `400 model name is missing` — expected
- Script calls `GET /models` and reads each `status.value`
- `loading` or `downloading` → **busy** (large GGUF IO; do not restart)
- `loaded` → `GET /slots?model=<id>&autoload=false`
  - `autoload=false` so inspecting slots cannot wake other models
  - Busy if `"is_processing": true`
- `sleeping` / `unloaded` → ignored

You do not name the running model. The router already reports it.

`GET /health`, `GET /props`, `GET /models`, and `GET /metrics` are llama.cpp
idle-exempt endpoints. Polling them does not count as user work and does not
reset llama.cpp’s own `--sleep-idle-seconds` timer.

### CUDA:0 gate

Before every restart:

```bash
nvidia-smi -i 0 --query-gpu=utilization.gpu --format=csv,noheader,nounits
```

Must be `0` (or ≤ `CUDA_IDLE_MAX_PCT`).

If util is non-zero:

- the idle clock resets
- restart is skipped
- log line: `idle timeout reached but CUDA:0 util=N% — wait for 0%`

If `nvidia-smi` is missing or the query fails, restart is skipped while
`REQUIRE_GPU_IDLE=1`.

### Cooldown

After a restart, another restart is blocked for **120 seconds** so a slow model
reload cannot loop.

### Hung server

If `llama-server.service` is active but `/health` does not answer, the same
5-minute timer still applies, and the CUDA 0% check still runs before restart.

## Configuration

Edit `/etc/default/llama-idle-watchdog`, then:

```bash
sudo systemctl restart llama-idle-watchdog.service
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `LLAMA_URL` | `http://127.0.0.1:8080` | llama-server base URL |
| `LLAMA_SERVICE` | `llama-server.service` | Unit to restart when `IDLE_ACTION=restart` |
| `IDLE_ACTION` | `restart` | `restart` = restart the unit; `unload` = unload models via API |
| `IDLE_SECONDS` | `600` | Idle time before restart (10 minutes) |
| `POLL_SECONDS` | `60` | How often to poll |
| `HEALTH_TIMEOUT` | `3` | curl timeout in seconds |
| `COOLDOWN_SECONDS` | `120` | Minimum time between restarts |
| `REQUIRE_SERVICE_ACTIVE` | `1` | Ignore idle if the unit is not active |
| `STATE_DIR` | `/var/lib/llama-idle-watchdog` | Timestamp files |
| `LLAMA_MODELS` | empty | Optional comma-separated model ids; empty = all from `/models` |
| `CUDA_INDEX` | `0` | `nvidia-smi` GPU index (`1` = CUDA:0) |
| `CUDA_IDLE_MAX_PCT` | `0` | Max util % treated as idle |
| `REQUIRE_GPU_IDLE` | `1` | `1` = refuse restart unless GPU is idle |

Examples:

```bash
# Server on port 8081
LLAMA_URL=http://127.0.0.1:8081

# Different systemd unit name
LLAMA_SERVICE=llama-server-gpu1.service

# Restart after 10 minutes instead of 5
IDLE_SECONDS=600

# GPU 0 instead of GPU 1
CUDA_INDEX=0

# Disable the GPU gate (API idle only)
REQUIRE_GPU_IDLE=0

# Unload models instead of restarting the unit (router mode)
IDLE_ACTION=unload
```

`unload` only works in **router mode** (`POST /models/unload`). If `/health` is
down, the script always restarts the unit because unload cannot run.

## Log lines

```text
journalctl -u llama-idle-watchdog.service -f
```

| Line | Meaning |
| --- | --- |
| `started url=... cuda=0` | Watchdog process started |
| `busy: MODEL status=loading` | Model IO in progress; clock reset |
| `busy: MODEL is_processing=true` | Generation in progress; clock reset |
| `idle timeout reached but CUDA:0 util=12% — wait for 0%` | API idle, GPU not idle |
| `idle timeout reached but cooldown active` | Restart too recent |
| `idle for >= 600s and CUDA:0=0% — restarting llama-server.service` | Restart issued |
| `idle for >= 600s ... — unloading models` | Unload action started |
| `unloading MODEL (status=loaded)` | `POST /models/unload` |
| `restart issued` | `systemctl restart` succeeded |
| `health down and idle Ns — restarting` | Unit up, HTTP down |

## Operations

```bash
# Start / stop / restart the watchdog
sudo systemctl start llama-idle-watchdog.service
sudo systemctl stop llama-idle-watchdog.service
sudo systemctl restart llama-idle-watchdog.service

# Disable at boot
sudo systemctl disable llama-idle-watchdog.service

# Force a llama-server restart yourself
sudo systemctl restart llama-server.service
```

Update after changing the script file:

```bash
sudo install -m 0755 llama-idle-watchdog.sh /usr/local/bin/llama-idle-watchdog.sh
sudo systemctl restart llama-idle-watchdog.service
```

## Uninstall

```bash
sudo systemctl disable --now llama-idle-watchdog.service
sudo rm -f /etc/systemd/system/llama-idle-watchdog.service
sudo rm -f /usr/local/bin/llama-idle-watchdog.sh
sudo rm -f /etc/default/llama-idle-watchdog
sudo rm -rf /var/lib/llama-idle-watchdog
sudo systemctl daemon-reload
```

This does not remove `llama-server.service`.

## Notes and limits

- `--sleep-idle-seconds` unloads weights **inside the same process**. After that,
  the next request often fails on some backends. This tool restarts the
  **process** instead.
- A poll of `/slots` or `/models` is not treated as user traffic.
- If a model load takes longer than `IDLE_SECONDS` **and** GPU util sits at 0%
  the whole time (unusual), raise `IDLE_SECONDS`. Normal loads show
  `loading`/`downloading` or non-zero GPU util and reset the clock.
- The watchdog runs as root so it can restart another unit. Restrict the host
  accordingly.
- AMD / ROCm / Vulkan are not read by `nvidia-smi`. Set `REQUIRE_GPU_IDLE=0`
  or replace `gpu_util_pct` if you are not on NVIDIA.

## Troubleshooting

**Watchdog active but never restarts**

- Traffic or `is_processing=true` keeps resetting the clock
- `CUDA:0` is not 0% — check `nvidia-smi -i 0`
- Wrong `CUDA_INDEX`
- Cooldown still active after a previous restart

**Restarts during a load**

- `/models` is not reporting `loading`/`downloading`
- GPU util is already 0 while weights stream from disk
- Raise `IDLE_SECONDS`

**`model name is missing` in your own curls**

- Normal for bare `GET /slots` on a router. The script handles that. Use
  `GET /models` or `GET /slots?model=ID&autoload=false`.

**Wrong service restarted**

- Set `LLAMA_SERVICE` to the exact unit name from `systemctl list-units '*llama*'`.
