#!/bin/bash
#
# ElectrumX BTX Migration Script
# Migriert von ElectrumX 1.15.0 zu 1.16.0 ohne BTX RPC Neustart
#
# Usage: curl -fsSL https://raw.githubusercontent.com/your-repo/migrate-electrumx-btx.sh | bash
# Or:    bash migrate-electrumx-btx.sh
#

set -e  # Exit on error
set -u  # Exit on undefined variable

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ELECTRUMX_OLD_CONTAINER="electrumx"
ELECTRUMX_NEW_CONTAINER="electrumx-new"
ELECTRUMX_BACKUP_CONTAINER="electrumx-old-backup"
BTX_RPC_CONTAINER="bitcore-rpc"
DOCKER_IMAGE="electrumx-btx:1.16.0"
NEW_DB_PATH="/home/bitcore-new/electrumx-db"
OLD_DB_PATH="/home/bitcore"
COMPOSE_DIR="/root/btx-rpc-docker"
WORK_DIR="/root/work"

# Logging
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Bitte als root ausführen"
        exit 1
    fi
}

# Check disk space
check_disk_space() {
    log_info "Prüfe Festplatten-Speicher..."

    local root_usage=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
    local root_avail=$(df -h / | awk 'NR==2 {print $4}')

    log_info "Root-Partition: ${root_usage}% verwendet, ${root_avail} frei"

    if [ "$root_usage" -gt 90 ]; then
        log_error "KRITISCH: Festplatte ist zu ${root_usage}% voll!"
        log_error "Mindestens 10% (2-3 GB) freier Speicher empfohlen"
        echo ""
        echo "Speicher-Fresser:"
        du -h --max-depth=1 /root 2>/dev/null | sort -rh | head -5
        echo ""
        echo "Empfohlene Bereinigung:"
        echo "  rm -rf /root/.npm/_cacache      # npm Cache"
        echo "  rm -rf /root/.nuget/packages    # nuget"
        echo "  rm -rf /root/.cache/*           # Temp Cache"
        echo "  docker system prune -af         # Docker"
        echo "  apt-get clean                   # APT Cache"
        echo ""
        read -p "Automatisch bereinigen? (j/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Jj]$ ]]; then
            log_info "Bereinige Caches..."
            rm -rf /root/.npm/_cacache /root/.npm/_npx
            rm -rf /root/.nuget/packages
            rm -rf /root/.cache/*
            docker system prune -af --volumes
            apt-get clean
            log_success "Bereinigung abgeschlossen"

            # Re-check disk space
            local new_usage=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
            local new_avail=$(df -h / | awk 'NR==2 {print $4}')
            log_info "Neuer Status: ${new_usage}% verwendet, ${new_avail} frei"

            if [ "$new_usage" -gt 85 ]; then
                log_error "Immer noch zu wenig Speicher! Bitte manuell aufräumen."
                exit 1
            fi
        else
            log_error "Bitte Speicher freigeben und Script erneut ausführen"
            exit 1
        fi
    elif [ "$root_usage" -gt 80 ]; then
        log_warning "WARNUNG: Festplatte ist zu ${root_usage}% voll"
        log_warning "Empfehlung: Speicher bereinigen vor Migration"
    else
        log_success "Genügend Speicher verfügbar (${root_usage}% verwendet)"
    fi
}

# Check prerequisites
check_prerequisites() {
    log_info "Prüfe Voraussetzungen..."

    # Check if docker is installed
    if ! command -v docker &> /dev/null; then
        log_error "Docker ist nicht installiert"
        exit 1
    fi

    # Check if docker-compose is installed
    if ! command -v docker-compose &> /dev/null; then
        log_error "docker-compose ist nicht installiert"
        exit 1
    fi

    # Check if BTX RPC container is running
    if ! docker ps --filter "name=$BTX_RPC_CONTAINER" --format '{{.Names}}' | grep -q "$BTX_RPC_CONTAINER"; then
        log_error "BTX RPC Container '$BTX_RPC_CONTAINER' läuft nicht"
        exit 1
    fi

    # Check if old ElectrumX container exists
    if ! docker ps -a --filter "name=$ELECTRUMX_OLD_CONTAINER" --format '{{.Names}}' | grep -q "$ELECTRUMX_OLD_CONTAINER"; then
        log_warning "Alter ElectrumX Container '$ELECTRUMX_OLD_CONTAINER' nicht gefunden"
    fi

    log_success "Alle Voraussetzungen erfüllt"
}

# Check BTX RPC status
check_btx_rpc() {
    log_info "Prüfe BTX RPC Status..."

    local max_attempts=60
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if docker exec $BTX_RPC_CONTAINER bitcore-cli \
            -datadir=/data \
            -conf=/data/bitcore.conf \
            -rpcconnect=172.21.0.11 \
            -rpcuser=btx-rpc-user \
            -rpcpassword=btx-rpc-pwd \
            -rpcport=8556 \
            getblockcount &>/dev/null; then
            log_success "BTX RPC ist bereit"
            return 0
        fi

        log_info "BTX RPC lädt noch... (Versuch $((attempt+1))/$max_attempts)"
        sleep 5
        ((attempt++))
    done

    log_error "BTX RPC ist nach $max_attempts Versuchen nicht bereit"
    return 1
}

# Create new database directory
create_db_directory() {
    log_info "Erstelle neues Datenbank-Verzeichnis..."

    if [ ! -d "$NEW_DB_PATH" ]; then
        mkdir -p "$NEW_DB_PATH"
        chown root:root "$NEW_DB_PATH"
        chmod 755 "$NEW_DB_PATH"
        log_success "Verzeichnis erstellt: $NEW_DB_PATH"
    else
        log_warning "Verzeichnis existiert bereits: $NEW_DB_PATH"
    fi
}

# Download or create Dockerfile
setup_dockerfile() {
    log_info "Erstelle Dockerfile..."

    mkdir -p "$WORK_DIR/electrumx-new"

    cat > "$WORK_DIR/electrumx-new/Dockerfile.minimal" <<'EOF'
# Minimal Dockerfile without optional dependencies
FROM python:3.10-slim

WORKDIR /usr/src/app

# Install electrumx from PyPI (without optional extras)
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir e-x==1.16.0 && \
    chmod +x /usr/local/bin/electrumx_* || true

# Environment variables
ENV SERVICES="tcp://:50001"
ENV COIN=Bitcoin
ENV DB_DIRECTORY=/var/lib/electrumx
ENV DAEMON_URL="http://username:password@hostname:port/"
ENV ALLOW_ROOT=true
ENV DB_ENGINE=leveldb
ENV MAX_SEND=10000000
ENV BANDWIDTH_UNIT_COST=50000
ENV CACHE_MB=2000

VOLUME /var/lib/electrumx

RUN mkdir -p "$DB_DIRECTORY"

CMD ["python", "/usr/local/bin/electrumx_server"]
EOF

    log_success "Dockerfile erstellt"
}

# Build Docker image
build_docker_image() {
    log_info "Baue Docker Image..."

    cd "$WORK_DIR/electrumx-new"

    if docker build -f Dockerfile.minimal -t "$DOCKER_IMAGE" .; then
        log_success "Docker Image gebaut: $DOCKER_IMAGE"
    else
        log_error "Docker Image Build fehlgeschlagen"
        exit 1
    fi
}

# Create docker-compose file
create_docker_compose() {
    log_info "Erstelle docker-compose Datei..."

    cat > "$COMPOSE_DIR/docker-compose-electrumx-new.yml" <<'EOF'
version: '3.3'

services:
  electrumx:
    image: electrumx-btx:1.16.0
    container_name: electrumx-new
    restart: unless-stopped
    networks:
      bitcore-net:
        ipv4_address: 172.21.0.12
    ports:
      - "50001:50001"  # TCP
      - "50002:50002"  # SSL
      - "50004:50004"  # WSS
      - "8000:8000"    # RPC
    expose:
      - 50001
      - 50002
      - 50004
      - 8000
    volumes:
      - /home/bitcore-new/electrumx-db:/var/lib/electrumx
      - /home/bitcore/electrumx.crt:/etc/electrumx/ssl/electrumx.crt:ro
      - /home/bitcore/electrumx.key:/etc/electrumx/ssl/electrumx.key:ro
    environment:
      COIN: "Bitcore"
      NET: "mainnet"
      DB_DIRECTORY: "/var/lib/electrumx"
      DB_ENGINE: "leveldb"
      DAEMON_URL: "http://btx-rpc-user:btx-rpc-pwd@172.21.0.11:8556/"
      SERVICES: "tcp://:50001,ssl://:50002,wss://:50004,rpc://0.0.0.0:8000"
      SSL_CERTFILE: "/etc/electrumx/ssl/electrumx.crt"
      SSL_KEYFILE: "/etc/electrumx/ssl/electrumx.key"
      ALLOW_ROOT: "true"
      CACHE_MB: "2048"
      MAX_SEND: "10000000"
      BANDWIDTH_UNIT_COST: "50000"
      LOG_LEVEL: "info"
      COST_SOFT_LIMIT: "0"
      COST_HARD_LIMIT: "0"
      REPORT_SERVICES: "tcp://your-domain.com:50001,ssl://your-domain.com:50002"
      PEER_DISCOVERY: "on"
      PEER_ANNOUNCE: "true"
    depends_on:
      - bitcored
    healthcheck:
      test: ["CMD", "python", "/usr/local/bin/electrumx_rpc", "getinfo"]
      interval: 2m
      timeout: 30s
      retries: 3

  bitcored:
    image: bitcored
    container_name: bitcore-rpc
    command:
      -externalip=51.15.77.33
      -whitebind=172.21.0.11:8555
      -rpcbind=172.21.0.11
      -maxconnections=64
      -rpcuser=btx-rpc-user
      -rpcpassword=btx-rpc-pwd
    restart: unless-stopped
    networks:
      bitcore-net:
        ipv4_address: 172.21.0.11
    ports:
      - "8555:8555"
    expose:
      - 8555
      - 8556
    volumes:
      - /home/bitcore:/data

networks:
  bitcore-net:
    external:
      name: btx-rpc-docker_bitcore-net
EOF

    log_success "docker-compose Datei erstellt"
}

# Stop old ElectrumX container
stop_old_container() {
    log_info "Stoppe alten ElectrumX Container..."

    if docker ps --filter "name=$ELECTRUMX_OLD_CONTAINER" --format '{{.Names}}' | grep -q "$ELECTRUMX_OLD_CONTAINER"; then
        docker stop "$ELECTRUMX_OLD_CONTAINER"
        docker rename "$ELECTRUMX_OLD_CONTAINER" "$ELECTRUMX_BACKUP_CONTAINER"
        log_success "Alter Container gestoppt und umbenannt zu: $ELECTRUMX_BACKUP_CONTAINER"
    else
        log_warning "Alter Container nicht gefunden oder bereits gestoppt"
    fi
}

# Start new ElectrumX container
start_new_container() {
    log_info "Starte neuen ElectrumX Container..."

    cd "$COMPOSE_DIR"

    # Start only electrumx service (not bitcored!)
    if docker-compose -f docker-compose-electrumx-new.yml up -d electrumx; then
        log_success "Neuer Container gestartet: $ELECTRUMX_NEW_CONTAINER"
    else
        log_error "Container-Start fehlgeschlagen"
        return 1
    fi

    # Wait a few seconds for container to start
    sleep 5

    # Check if container is running
    if docker ps --filter "name=$ELECTRUMX_NEW_CONTAINER" --format '{{.Names}}' | grep -q "$ELECTRUMX_NEW_CONTAINER"; then
        log_success "Container läuft"
    else
        log_error "Container läuft nicht"
        docker logs "$ELECTRUMX_NEW_CONTAINER" --tail 50
        return 1
    fi
}

# Monitor sync progress
monitor_sync() {
    log_info "Überwache Synchronisation (Strg+C zum Beenden)..."

    echo ""
    echo "Verwenden Sie diese Befehle zur Überwachung:"
    echo "  docker logs -f $ELECTRUMX_NEW_CONTAINER"
    echo "  docker exec $ELECTRUMX_NEW_CONTAINER python /usr/local/bin/electrumx_rpc getinfo"
    echo ""

    # Show initial logs
    docker logs "$ELECTRUMX_NEW_CONTAINER" --tail 20
}

# Rollback function
rollback() {
    log_warning "Führe Rollback durch..."

    # Stop new container
    if docker ps --filter "name=$ELECTRUMX_NEW_CONTAINER" --format '{{.Names}}' | grep -q "$ELECTRUMX_NEW_CONTAINER"; then
        docker stop "$ELECTRUMX_NEW_CONTAINER"
        docker rm "$ELECTRUMX_NEW_CONTAINER"
    fi

    # Restart old container
    if docker ps -a --filter "name=$ELECTRUMX_BACKUP_CONTAINER" --format '{{.Names}}' | grep -q "$ELECTRUMX_BACKUP_CONTAINER"; then
        docker start "$ELECTRUMX_BACKUP_CONTAINER"
        docker rename "$ELECTRUMX_BACKUP_CONTAINER" "$ELECTRUMX_OLD_CONTAINER"
        log_success "Rollback abgeschlossen - alter Container wiederhergestellt"
    else
        log_error "Backup-Container nicht gefunden"
    fi
}

# Cleanup after successful migration
cleanup_success() {
    log_info "Bereinige..."

    # Remove old backup container
    if docker ps -a --filter "name=$ELECTRUMX_BACKUP_CONTAINER" --format '{{.Names}}' | grep -q "$ELECTRUMX_BACKUP_CONTAINER"; then
        read -p "Alten Backup-Container entfernen? (j/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Jj]$ ]]; then
            docker rm "$ELECTRUMX_BACKUP_CONTAINER"
            log_success "Backup-Container entfernt"
        fi
    fi

    # Rename new container to standard name
    read -p "Neuen Container zu '$ELECTRUMX_OLD_CONTAINER' umbenennen? (j/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Jj]$ ]]; then
        docker stop "$ELECTRUMX_NEW_CONTAINER"
        docker rename "$ELECTRUMX_NEW_CONTAINER" "$ELECTRUMX_OLD_CONTAINER"
        docker start "$ELECTRUMX_OLD_CONTAINER"
        log_success "Container umbenannt zu: $ELECTRUMX_OLD_CONTAINER"
    fi
}

# Main execution
main() {
    echo "=========================================="
    echo " ElectrumX BTX Migration Script"
    echo " Version 1.16.0"
    echo "=========================================="
    echo ""

    # Trap errors for rollback
    trap 'log_error "Script fehlgeschlagen! Führen Sie rollback() manuell aus wenn nötig."; exit 1' ERR

    check_root
    check_disk_space
    check_prerequisites
    check_btx_rpc
    create_db_directory
    setup_dockerfile
    build_docker_image
    create_docker_compose
    stop_old_container
    start_new_container

    log_success "Migration abgeschlossen!"
    echo ""
    monitor_sync

    echo ""
    log_info "Nächste Schritte:"
    echo "  1. Überwachen Sie die Logs: docker logs -f $ELECTRUMX_NEW_CONTAINER"
    echo "  2. Prüfen Sie den Status: docker exec $ELECTRUMX_NEW_CONTAINER python /usr/local/bin/electrumx_rpc getinfo"
    echo "  3. Nach erfolgreicher Sync: bash $0 --cleanup"
    echo "  4. Bei Problemen: bash $0 --rollback"
    echo ""
}

# Handle command line arguments
case "${1:-}" in
    --rollback)
        rollback
        ;;
    --cleanup)
        cleanup_success
        ;;
    --check)
        check_btx_rpc
        docker ps --filter "name=electrumx"
        docker logs electrumx-new --tail 20
        ;;
    *)
        main
        ;;
esac
