# llama-server idle restart watchdog

Short install notes. Full documentation is in `README.md`.

After 5 minutes of no inference and CUDA:0 at 0% util, takes `IDLE_ACTION`:
`restart` (default) or `unload` (`POST /models/unload`).

## Files

| File | Destination |
| --- | --- |
| `llama-idle-watchdog.sh` | `/usr/local/bin/llama-idle-watchdog.sh` |
| `llama-idle-watchdog.service` | `/etc/systemd/system/llama-idle-watchdog.service` |
| `llama-idle-watchdog.default` | `/etc/default/llama-idle-watchdog` |
| `install.sh` | run once on the host |

## Install

```bash
chmod +x install.sh llama-idle-watchdog.sh
sudo ./install.sh
```

Or by hand:

```bash
sudo install -m 0755 llama-idle-watchdog.sh /usr/local/bin/llama-idle-watchdog.sh
sudo install -m 0644 llama-idle-watchdog.service /etc/systemd/system/llama-idle-watchdog.service
sudo install -m 0644 llama-idle-watchdog.default /etc/default/llama-idle-watchdog
sudo mkdir -p /var/lib/llama-idle-watchdog
sudo systemctl daemon-reload
sudo systemctl enable --now llama-idle-watchdog.service
```

## Check

```bash
systemctl status llama-idle-watchdog.service
journalctl -u llama-idle-watchdog.service -f
```

## Notes

- Default port is `8080`. Change `LLAMA_URL` in `/etc/default/llama-idle-watchdog`
  if your server listens elsewhere.
- If your unit is not named `llama-server.service`, set `LLAMA_SERVICE`.
- Router mode: bare `GET /slots` returns 400 `model name is missing`. The
  script then uses `GET /models` and `GET /slots?model=<id>`. Status
  `loading` / `downloading` counts as busy so a long GGUF load is not idle.
- `/health` and `/slots` do **not** reset llama.cpp’s own `--sleep-idle-seconds`
  timer. This watchdog uses `/slots` so a health poll does not count as work.
- Before action, `nvidia-smi -i 0` must show GPU util 0% (`CUDA:0`).
  Non-zero util resets the idle clock. Set `CUDA_INDEX` in
  `/etc/default/llama-idle-watchdog` if the card is not index 1.
- If you already use `--sleep-idle-seconds`, that unloads weights inside the
  same process. Several backends then fail on the next request. This unit
  restarts the whole service instead, which is the reliable fix.
- Cooldown is 120s so a slow model load after restart does not immediately
  trip another restart. Raise `IDLE_SECONDS` if loads take longer than 5
  minutes (or the first load after restart will look “idle” only after
  `/slots` stops reporting processing — load itself usually shows activity).
