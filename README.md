# 🎙️ Dograh Proxmox

[Dograh](https://github.com/dograh-hq/dograh) als Ein-Klick-Installer für **Proxmox VE** – im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE/).

Dograh ist die Open-Source-Alternative zu Vapi & Retell: Voice-Agenten mit einem visuellen Workflow-Builder bauen, direkt im Browser testen (Test Audio / Test Chat), eigene LLM/TTS/STT-Provider verbinden und Telefonie (Twilio, Vonage, Telnyx, Plivo, …) anbinden. Lizenz: BSD-2-Clause.

| | |
|---|---|
| **Web-UI** | `http://<CT-IP>:3010` |
| **API** | `http://<CT-IP>:8000` (benötigt der Browser im Hintergrund) |
| **MinIO** | `http://<CT-IP>:9000` (Voice-Audio-Abruf per Presigned-URL) |
| **Container** | LXC, unprivileged, Debian 13, Docker-in-LXC (`nesting=1,keyctl=1`), 4 vCPU · 4 GB RAM · 24 GB Disk · 1 GB Swap |
| **Stack** | Offizielle `docker-compose.yaml` von upstream (unverändert) + eigenes `docker-compose.override.yaml` (Restart-Policies, Ports, Härtung) |
| **Images** | `ghcr.io/dograh-hq` – kein Build im Container |
| **Daten** | Docker-Volumes (`postgres_data`, `redis_data`, `minio-data`) im CT – bleiben bei `--update` erhalten |

---

## 🚀 Installation (Einzeiler auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Dograh-Proxmox/main/install/dograh.sh)"
```

Das Script:
1. nimmt automatisch die **nächste freie CT-ID** (ab 200) und erstellt einen unprivilegierten LXC (`dograh`, `onboot=1`, `nesting=1,keyctl=1`),
2. installiert **Docker CE** (get.docker.com) im Container,
3. lädt die **offizielle Compose-Datei** von upstream und ergänzt ein eigenes Override (Restart-Policies, UI/API auf 0.0.0.0, Postgres/Redis nur localhost, MinIO auf :9000),
4. erzeugt eine **`.env` mit generierten Secrets** (JWT, Postgres, Redis, MinIO – chmod 600),
5. schreibt die **systemd-Unit `dograh`** (detached Bootstrap: `up -d`, `After=docker.service network-online.target`, IP-Sync als `ExecStartPre`) – die Ausfallsicherung läuft über `restart: unless-stopped` der Container (Compose-Standard, Community-Scripts-Muster),
6. **verifiziert** Service, alle 5 Compose-Services und Web-UI/API per HTTP-Check und gibt die finale URL aus.

Erwartete Ausgabe (Ende):

```
✔ Service dograh läuft (systemctl is-active)
✔ Alle Compose-Services laufen (postgres, redis, minio, api, ui)
✔ Web-UI antwortet (HTTP 200 auf Port 3010)
✔ API gesund (HTTP 200 auf Port 8000)
✔ Vom Host erreichbar: http://192.168.x.x:3010 (HTTP 200)

━━━ 🎙️  Dograh ist bereit! ━━━
  🌐 Web-UI:    http://192.168.x.x:3010
  🔌 API:      http://192.168.x.x:8000  (benötigt der Browser im Hintergrund)
  🐚 Terminal:  pct enter 2xx
```

**Dauer:** ~5–10 Minuten (Image-Pull ~2–4 GB). Erststart: 1–3 Minuten (DB-Migration).

### Optionen (hinter dem schließenden Anführungszeichen anhängen)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Dograh-Proxmox/main/install/dograh.sh)" --id 210 --ip 192.168.178.77/24 --gateway 192.168.178.1
```

| Option | Bedeutung (Default) |
|---|---|
| `--id ID` | Container-ID (nächste freie ab 200) |
| `--hostname NAME` | Container-Hostname (`dograh`) |
| `--rootfs GB` | Disk (24) |
| `--cores N` / `--memory MB` / `--swap MB` | 4 / 4096 / 1024 |
| `--storage NAME` / `--bridge BR` | `local-lvm` / `vmbr0` |
| `--ip CIDR` + `--gateway GW` | statische IP statt DHCP – **empfohlen** |
| `--port PORT` | Web-UI-Port (3010; API läuft fix auf 8000) |
| `--password PW` / `--sshkey PFAD` | Root-Passwort (auto-generiert) / SSH-Key |
| `--telemetry` | Anonyme Nutzungsdaten erlauben (Default: **AUS**) |
| `--force` | Existierenden CT löschen und neu anlegen |
| `--yes / -y` | Rückfragen überspringen |
| `--update` / `--uninstall` / `--status` / `--debug` | Verwaltungsmodi |

---

## 🗣️ Erste Schritte

1. `http://<CT-IP>:3010` öffnen und den **ersten Account anlegen** (Signup ist offen).
2. **Signup schließen** (nach dem ersten Account, in `/opt/dograh/.env` im CT):
   ```bash
   pct enter <CTID>
   sed -i 's/^ENABLE_SIGNUP=true/ENABLE_SIGNUP=false/' /opt/dograh/.env
   exit
   ```
   Danach `--update` laufen lassen (Startet den Stack mit neuer .env neu).
3. **Agent bauen:** Inbound/Outbound wählen, Agent benennen, Anwendungsfall in 5–10 Worten beschreiben → **Test Agent** → **Test Audio** (Mikrofon) oder **Test Chat**.
4. **MCP:** Dograh bringt einen MCP-Server mit – Claude Code/Codex/Cursor können Workflows direkt bearbeiten (siehe [docs.dograh.com/integrations/mcp](https://docs.dograh.com/integrations/mcp)).

### Stimme & Modell (wichtig für „vollständig lokal“)

Die **App läuft 100 % lokal** (Web-UI, API, DB, Objektstorage). Die **Standard-Stimme/Inferenz** jedoch läuft über Dograhs gehosteten Stack mit Auto-Keys (Cloud) – keine eigenen Keys nötig, für Tests sofort funktionstüchtig.

Wer **komplett lokal** bleiben will: eigene Provider in der Web-UI unter Einstellungen hinterlegen – das Backend akzeptiert beliebige LLM/TTS/STT-Provider, inkl. **lokaler OpenAI-kompatibler Endpunkte** (z. B. Ollama, Speaches, whisper+TTS im LAN). Dann verlässt kein Audio-Byte das Haus.

### Telefonie

Telefonie-Provider (Twilio/Vonage/Telnyx/Plivo/Vobiz/Cloudonix/Asterisk ARI) lassen sich in der UI verbinden. **Eingehende Webhooks** brauchen eine öffentliche Erreichbarkeit des CTs (Port-Forward oder Tunnel) – für Browser-Tests im LAN ist das **nicht** nötig. Das Setup startet bewusst **keinen** Cloudflare-Quick-Tunnel (im Gegensatz zum upstream-Quickstart).

---

## 🔄 Update

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Dograh-Proxmox/main/install/dograh.sh)" --update
```

Zieht die aktuelle upstream-Compose-Datei + Images neu (`docker compose pull`), lässt Secrets/Daten unberührt und startet den Stack neu. Ein Bestätigungsschritt gibt es nicht – idempotent und safe für Re-Runs.

## 🗑️ Deinstall

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Dograh-Proxmox/main/install/dograh.sh)" --uninstall [--yes]
```

**Löscht ALLE Daten** (Agenten, Accounts, Postgres, Voice-Audio). Vorher bei Bedarf sichern: `vzdump <CTID> --storage <ziel>` oder `pct backup`.

## 📊 Status

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Dograh-Proxmox/main/install/dograh.sh)" --status
```

Zeigt CT, Service, Compose-Stack, Signup-Status und Erreichbarkeit von Web-UI + API.

---

## 🔁 Reboot-Verhalten

- CT: `onboot=1` → startet automatisch mit dem Host.
- Docker-Stack: systemd-Unit `dograh` synchronisiert beim Boot (`up -d`, idempotent), die Container tragen `restart: unless-stopped` – Docker startet sie auch ohne Unit selbst wieder.
- DHCP-IP-Hüpfer: `ExecStartPre` (`sync-backend-url.sh`) aktualisiert die IP-abhängigen `.env`-Einträge bei jedem Start selbst → die Browser→API-URL bleibt korrekt.
- **Trotzdem empfohlen:** DHCP-Reservierung im Router oder `--ip` bei der Installation – so bleiben Agent-Webhooks und Bookmarks stabil.

## 🩺 Troubleshooting

```bash
# Voller bash -x-Trace bei Installationsfehlern (exakter Befehl):
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Dograh-Proxmox/main/install/dograh.sh)" --debug

# Stack-Logs live:
pct exec <CTID> -- docker compose --project-directory /opt/dograh logs -f

# Service-Status & Unit-Logs:
pct exec <CTID> -- systemctl status dograh
pct exec <CTID> -- journalctl -u dograh -e

# Alles zum Setup-Nachlauf:
pct exec <CTID> -- tail -100 /var/log/dograh-setup.log
```

Der Installer schneidet das **vollständige Log** in `/tmp/dograh-installer-<timestamp>.log` mit und gibt bei Fehlern die komplette Fehlerkette aus (Zeile, Befehl, Exit-Code, Log-Tail, Container-Logs) – Container werden bei Fehlern **nicht** gelöscht.

## 🧪 Harness (lokal testbar, ohne Proxmox)

```bash
bash harness/run.sh
```

Testet den Installer End-to-End gegen gemockte `pct`/`pveam`/`curl`/`docker`/`systemd`-Umgebung (`unshare -rm`): Install, Update, Status, Uninstall, Fehlerpfade, .env-Idempotenz, IP-Sync, Bootstrap-Reihenfolge.

---

## 📄 License

MIT – siehe [LICENSE](LICENSE). Dograh selbst: BSD-2-Clause ([dograh-hq/dograh](https://github.com/dograh-hq/dograh)).
