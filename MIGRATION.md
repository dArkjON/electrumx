# ElectrumX BTX Migration Guide

Migration von ElectrumX 1.15.0 zu 1.16.0 für BitCore BTX **ohne BTX RPC Neustart**.

## Wichtige Hinweise

⚠️ **WICHTIG**: Dieses Script startet **NUR** den ElectrumX Container neu, **NICHT** den BTX RPC!

✅ **BTX ist bereits vollständig im neuen Code unterstützt** - keine Code-Änderungen nötig

## Schnellstart (Remote Execution)

Für neue Server - führen Sie diesen Befehl als root aus:

```bash
curl -fsSL https://raw.githubusercontent.com/dArkjON/electrumx/master/migrate-electrumx-btx.sh | bash
```

## Manuelle Ausführung

```bash
# Script herunterladen
cd /root/work
git clone https://github.com/dArkjON/electrumx.git electrumx-new
cd electrumx-new

# Ausführbar machen
chmod +x migrate-electrumx-btx.sh

# Migration starten
./migrate-electrumx-btx.sh
```

## Was macht das Script?

1. ✅ Prüft Voraussetzungen (Docker, docker-compose, BTX RPC)
2. ✅ Wartet bis BTX RPC bereit ist
3. ✅ Erstellt neues DB-Verzeichnis (`/home/bitcore-new/electrumx-db`)
4. ✅ Baut Docker Image (ElectrumX 1.16.0)
5. ✅ Stoppt **nur** alten ElectrumX Container (BTX RPC läuft weiter!)
6. ✅ Startet neuen ElectrumX Container
7. ✅ Zeigt Logs zur Überwachung

## Überwachung

Nach der Migration:

```bash
# Logs live anzeigen
docker logs -f electrumx-new

# Status prüfen (nach Sync)
docker exec electrumx-new python /usr/local/bin/electrumx_rpc getinfo

# BTX RPC Status
docker exec bitcore-rpc bitcore-cli \
  -datadir=/data \
  -conf=/data/bitcore.conf \
  -rpcconnect=172.21.0.11 \
  -rpcuser=btx-rpc-user \
  -rpcpassword=btx-rpc-pwd \
  -rpcport=8556 \
  getblockcount
```

## Rollback

Falls Probleme auftreten:

```bash
./migrate-electrumx-btx.sh --rollback
```

Dies wird:
- Neuen Container stoppen
- Alten Container wiederherstellen
- Alte Konfiguration reaktivieren

## Cleanup (nach erfolgreicher Migration)

```bash
./migrate-electrumx-btx.sh --cleanup
```

Dies wird:
- Alten Backup-Container entfernen (optional)
- Neuen Container zu Standardnamen umbenennen (optional)

## Vergleich: Alt vs. Neu

### Code-Unterschiede

**Einziger Unterschied in coins.py:**
```python
# Alt (Zeile 2116):
P2SH_VERBYTES = [bytes.fromhex("7D")]  # List

# Neu (Zeile 2280):
P2SH_VERBYTES = (bytes.fromhex("7D"),)  # Tuple
```

Funktional identisch! Alle anderen BTX-Parameter sind gleich.

### Container-Unterschiede

| Aspekt | Alt | Neu |
|--------|-----|-----|
| **Version** | 1.15.0 | 1.16.0 |
| **Image** | dalijolijo/electrumx:1.15.0 | electrumx-btx:1.16.0 (selbst gebaut) |
| **Python** | 3.7.9 | 3.10 |
| **DB Engine** | LevelDB/RocksDB | LevelDB (einfacher) |
| **Base OS** | Ubuntu 18.04 | Debian Trixie (Python 3.10 slim) |

## Synchronisations-Dauer

- **BTX Blockchain**: ~126,946 Blocks, ~1.7M Transaktionen
- **Tatsächliche Sync-Zeit**: ~51 Minuten (auf Produktions-Hardware)
- **Wichtig**: BTX-spezifisches Sync-Verhalten!

### BTX Blockchain-Charakteristik

**Frühe Blöcke sind sehr transaktionsreich, spätere Blöcke spärlicher:**

- **Anfangsphase** (Block 0 - 80k): ~142 tx/sec (dichte Blöcke)
- **Mittlere Phase** (Block 80k - 600k): ~2,947 tx/sec (Beschleunigung)
- **Endphase** (Block 600k - 1.7M): Sehr schnell (spärliche Blöcke)

**Resultat:** Der Sync beschleunigt sich natürlich zum Ende hin!

```
INFO:DB:flush #1: Height 79,542   | ETA: 08h 53m | 142 tx/sec   (langsam)
INFO:DB:flush #2: Height 635,132  | ETA: 12m 08s | 2,947 tx/sec (schnell!)
INFO:DB:flush #3: Height 1,708,067 | ETA: 00s     | 1,395 tx/sec (komplett)
INFO:BlockProcessor:ElectrumX 1.16.0 synced to height 1,708,067
```

- **Empfohlen**: SSD für bessere Performance in der dichten Anfangsphase

## Konfiguration

Alle wichtigen Einstellungen:

```yaml
COIN: "Bitcore"
NET: "mainnet"
RPC_PORT: 8556
DAEMON_URL: "http://btx-rpc-user:btx-rpc-pwd@172.21.0.11:8556/"
SERVICES: "tcp://:50001,ssl://:50002,wss://:50004,rpc://0.0.0.0:8000"
DB_ENGINE: "leveldb"
CACHE_MB: "512"  # siehe CACHE_MB Empfehlungen unten!
REPORT_SERVICES: "tcp://ele1.bitcore.cc:50001,ssl://ele1.bitcore.cc:50002"
```

### CACHE_MB Empfehlungen (wichtig!)

**Kritisch für Performance und Stabilität:**

| System RAM | CACHE_MB | Empfehlung |
|------------|----------|------------|
| **< 4 GB** | `512` | Minimum - verhindert SWAP-Thrashing |
| **4-8 GB** | `2048` | Standard - gute Balance |
| **> 8 GB** | `4096` | Optimal - maximale Geschwindigkeit |

⚠️ **Warnung:** Zu hoher CACHE_MB führt zu:
- SWAP-Nutzung und Disk I/O Bottleneck
- Sehr langsamer Sync (Faktor 10x langsamer!)
- System-Instabilität

**Beispiel:** System mit 2.4 GB RAM + CACHE_MB 2048 = 85% RAM-Nutzung → SWAP-Thrashing!

### REPORT_SERVICES Konfiguration

**Wichtig für Peer Discovery:**

```yaml
# Option 1: Eigene Domain (wenn vorhanden)
REPORT_SERVICES: "tcp://your-server.com:50001,ssl://your-server.com:50002"

# Option 2: Bekannter BTX ElectrumX Server (Standard)
REPORT_SERVICES: "tcp://ele1.bitcore.cc:50001,ssl://ele1.bitcore.cc:50002"

# Option 3: Alternative BTX Server
REPORT_SERVICES: "tcp://ele.bitcore.wtf:50001,ssl://ele.bitcore.wtf:50002"
```

**Bekannte BTX ElectrumX Server:**
- `ele1.bitcore.cc`
- `ele2.bitcore.cc`
- `ele3.bitcore.cc`
- `ele4.bitcore.cc`
- `ele.bitcore.wtf`

⚠️ **NICHT verwenden:** Placeholder wie `your-domain.com` führen zu Verbindungsfehlern!

## Netzwerk

```
Docker Network: btx-rpc-docker_bitcore-net (172.21.0.0/24)

┌─────────────────────────────────────────┐
│  BTX RPC (bitcore-rpc)                  │
│  IP: 172.21.0.11                        │
│  Ports: 8555, 8556                      │
└─────────────────────────────────────────┘
           ↓ RPC Connection
┌─────────────────────────────────────────┐
│  ElectrumX (electrumx-new)              │
│  IP: 172.21.0.12                        │
│  Ports: 50001 (TCP), 50002 (SSL),      │
│         50004 (WSS), 8000 (RPC)         │
└─────────────────────────────────────────┘
```

## Troubleshooting

### Container startet nicht

```bash
# Logs prüfen
docker logs electrumx-new --tail 100

# Container Status
docker ps -a --filter "name=electrumx"

# Rollback durchführen
./migrate-electrumx-btx.sh --rollback
```

### Sync zu langsam

**Erste Diagnose - SWAP-Nutzung prüfen:**

```bash
# System-Ressourcen prüfen
free -h
docker stats electrumx-new --no-stream

# Wenn SWAP stark genutzt wird (>500MB):
# → CACHE_MB ist zu hoch für verfügbaren RAM!
```

**Lösung basierend auf Diagnose:**

```bash
# Fall 1: System hat viel freien RAM → Cache ERHÖHEN
# docker-compose-electrumx-new.yml
CACHE_MB: "4096"  # wenn >8GB freier RAM

# Fall 2: SWAP wird stark genutzt → Cache REDUZIEREN
CACHE_MB: "512"   # wenn <4GB RAM

# Container neu starten
docker-compose -f /root/btx-rpc-docker/docker-compose-electrumx-new.yml restart electrumx
```

**Erwartetes Verhalten:**
- Sync startet langsam (~142 tx/sec)
- Beschleunigt sich automatisch (~2,947 tx/sec)
- Dies ist NORMAL für BTX! (siehe "Synchronisations-Dauer")

### SSL Zertifikat-Fehler

```bash
# Prüfen ob Zertifikate existieren
ls -lh /home/bitcore/electrumx.{crt,key}

# Permissions prüfen
chmod 644 /home/bitcore/electrumx.crt
chmod 600 /home/bitcore/electrumx.key
```

### BTX RPC nicht erreichbar

```bash
# RPC Status prüfen
docker exec bitcore-rpc bitcore-cli \
  -datadir=/data \
  -conf=/data/bitcore.conf \
  -rpcconnect=172.21.0.11 \
  -rpcuser=btx-rpc-user \
  -rpcpassword=btx-rpc-pwd \
  -rpcport=8556 \
  mnsync status

# Network prüfen
docker network inspect btx-rpc-docker_bitcore-net
```

### Peer Connection Errors

**Fehler:**
```
ERROR:PeerManager:[your-domain.com:50002 SSL] [Errno -5] No address associated with hostname
```

**Ursache:** `REPORT_SERVICES` enthält ungültigen Placeholder `your-domain.com`

**Lösung:**
```bash
# docker-compose-electrumx-new.yml anpassen
REPORT_SERVICES: "tcp://ele1.bitcore.cc:50001,ssl://ele1.bitcore.cc:50002"

# Container neu starten
docker-compose -f /root/btx-rpc-docker/docker-compose-electrumx-new.yml restart electrumx
```

## Multi-Server Deployment

Für 5 Server automatisch:

### Option 1: Mit Ansible

```yaml
# playbook.yml
- hosts: btx_servers
  become: yes
  tasks:
    - name: Run migration script
      shell: |
        curl -fsSL https://raw.githubusercontent.com/dArkjON/electrumx/master/migrate-electrumx-btx.sh | bash
      args:
        executable: /bin/bash
```

Ausführen:
```bash
ansible-playbook -i inventory.ini playbook.yml
```

### Option 2: Mit SSH Loop

```bash
#!/bin/bash
SERVERS=(
    "server1.example.com"
    "server2.example.com"
    "server3.example.com"
    "server4.example.com"
    "server5.example.com"
)

for server in "${SERVERS[@]}"; do
    echo "Migriere $server..."
    ssh root@$server 'curl -fsSL https://raw.githubusercontent.com/dArkjON/electrumx/master/migrate-electrumx-btx.sh | bash'
    echo "✓ $server fertig"
    echo ""
done
```

### Option 3: Parallel mit GNU Parallel

```bash
parallel -j 3 \
    'ssh root@{} "curl -fsSL https://raw.githubusercontent.com/dArkjON/electrumx/master/migrate-electrumx-btx.sh | bash"' \
    ::: server1.example.com server2.example.com server3.example.com server4.example.com server5.example.com
```

## Monitoring während Multi-Server Migration

```bash
# tmux Session mit Split-Screens für 5 Server
tmux new-session \; \
  split-window -h \; \
  split-window -v \; \
  select-pane -t 0 \; \
  split-window -v \; \
  split-window -v \; \
  send-keys 'ssh root@server1 "docker logs -f electrumx-new"' C-m \; \
  select-pane -t 2 \; \
  send-keys 'ssh root@server2 "docker logs -f electrumx-new"' C-m \; \
  select-pane -t 3 \; \
  send-keys 'ssh root@server3 "docker logs -f electrumx-new"' C-m \; \
  select-pane -t 4 \; \
  send-keys 'ssh root@server4 "docker logs -f electrumx-new"' C-m \; \
  select-pane -t 1 \; \
  send-keys 'ssh root@server5 "docker logs -f electrumx-new"' C-m
```

## Support

- GitHub Issues: https://github.com/dArkjON/electrumx/issues
- ElectrumX Docs: https://electrumx.readthedocs.io/

## Changelog

### Version 1.16.0 (2025-12-01)
- ✅ Initial migration script mit Rollback-Funktion
- ✅ Python 3.10 base (statt 3.7.9)
- ✅ LevelDB statt RocksDB (einfacher, weniger Dependencies)
- ✅ Migration ohne BTX RPC Neustart
- ✅ Multi-Server Support (Ansible, SSH, Parallel)
- ✅ Automatische Disk Space Checks mit Cleanup
- ✅ BTX-spezifische Sync-Charakteristik dokumentiert
- ✅ CACHE_MB Tuning Guidelines für verschiedene RAM-Größen
- ✅ REPORT_SERVICES Konfiguration für BTX Peer Network
- ✅ Produktions-getestet: 51 Min Sync auf ~1.7M Transaktionen

## Lizenz

Basiert auf ElectrumX (MIT License) - https://github.com/spesmilo/electrumx
