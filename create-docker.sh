#!/usr/bin/env bash
set -e

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}=======================================================${NC}"
echo -e "${CYAN}  Proxmox LXC Docker - Build & Deploy                  ${NC}"
echo -e "${CYAN}=======================================================${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Errore: Esegui come root.${NC}"; exit 1
fi

if ! command -v dab &> /dev/null; then
  echo -e "${YELLOW}Il tool 'dab' (Debian Appliance Builder) non è installato. Lo installo...${NC}"
  apt-get update >/dev/null && apt-get install -y dab make
fi

# --- FASE 1: GENERAZIONE DEL TEMPLATE ---
TEMPLATE_FILE=$(ls /var/lib/vz/template/cache/debian-12-docker-template*.tar.gz 2>/dev/null | head -n 1 || true)

if [ -z "$TEMPLATE_FILE" ]; then
  echo -e "${YELLOW}Template non trovato. Inizio la build del template con DAB...${NC}"
  echo -e "Questa operazione richiederà alcuni minuti."
  
  BUILD_DIR=$(mktemp -d)
  cd "$BUILD_DIR"

  wget -q https://raw.githubusercontent.com/Prez1009/proxmox-dab-templates/main/debian-docker/Makefile -O Makefile
  wget -q https://raw.githubusercontent.com/Prez1009/proxmox-dab-templates/main/debian-docker/dab.conf -O dab.conf

  make

  cd /
  rm -rf "$BUILD_DIR"
  
  echo -e "${GREEN}Build completata!${NC}"
  TEMPLATE_FILE=$(ls /var/lib/vz/template/cache/debian-12-docker-template*.tar.gz 2>/dev/null | head -n 1)
else
  echo -e "${GREEN}Template già esistente trovato! Salto la fase di build.${NC}"
fi

TEMPLATE_NAME=$(basename "$TEMPLATE_FILE")
TEMPLATE_PATH="local:vztmpl/$TEMPLATE_NAME"

# --- FASE 2: CREAZIONE CONTAINER ---
NEXT_ID=$(pvesh get /cluster/nextid)

echo -e "\n${CYAN}--- Configurazione Container ---${NC}"
read -p "ID Container [$NEXT_ID]: " CTID </dev/tty
CTID=${CTID:-$NEXT_ID}

read -p "Hostname [docker-node-$CTID]: " HOSTNAME </dev/tty
HOSTNAME=${HOSTNAME:-docker-node-$CTID}

read -p "Cores CPU [2]: " CORES </dev/tty
CORES=${CORES:-2}

read -p "RAM in MB [2048]: " RAM </dev/tty
RAM=${RAM:-2048}

echo -e "\n${YELLOW}Storage disponibili e attivi sul nodo:${NC}"
pvesm status | awk 'NR==1 {print "\033[1;36m" $0 "\033[0m"} NR>1 && $3=="active" {print $0}'
STORAGE_ATTIVI=$(pvesm status | awk 'NR>1 && $3=="active" {print $1}')
DEFAULT_STORAGE=$(echo "$STORAGE_ATTIVI" | grep -m 1 -E '^local-lvm$|^local-zfs$' || true)
[ -z "$DEFAULT_STORAGE" ] && DEFAULT_STORAGE=$(echo "$STORAGE_ATTIVI" | head -n 1)

echo -e ""
read -p "Storage di destinazione [$DEFAULT_STORAGE]: " STORAGE </dev/tty
STORAGE=${STORAGE:-$DEFAULT_STORAGE}

read -p "Spazio Disco in GB [100]: " DISK_SIZE </dev/tty
DISK_SIZE=${DISK_SIZE:-100}

# --- FASE 3: CHIEDE DI INCOLLARE LA CHIAVE PUBBLICA ---
echo -e ""
echo -e "${YELLOW}Per abilitare l'accesso SSH all'utente 'docker', incolla la tua chiave pubblica.${NC}"
read -p "Chiave SSH pubblica (es: ssh-ed25519 AAAA... user@host): " SSH_PUBLIC_KEY </dev/tty

echo -e "\n${CYAN}Creazione del container in corso...${NC}"
pct create "$CTID" "$TEMPLATE_PATH" \
  --ostype debian \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$RAM" \
  --swap "$RAM" \
  --rootfs "$STORAGE:$DISK_SIZE" \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --onboot 1

echo -e "${GREEN}Container $CTID creato con successo!${NC}"

read -p "Vuoi avviare il container ora? (Y/n): " START_CT </dev/tty
START_CT=${START_CT:-Y}

if [[ "$START_CT" =~ ^[Yy]$ ]]; then
  echo -e "${YELLOW}Avvio del container...${NC}"
  pct start "$CTID"
  sleep 5

  # --- FASE 4: CONFIGURA LA CHIAVE SSH SE È STATA INCOLLATA ---
  if [ -n "$SSH_PUBLIC_KEY" ]; then
    echo -e "${YELLOW}Configurazione della chiave SSH inserita...${NC}"
    pct exec $CTID -- bash -c "mkdir -p /home/docker/.ssh && chmod 700 /home/docker/.ssh"
    pct exec $CTID -- bash -c "echo '$SSH_PUBLIC_KEY' > /home/docker/.ssh/authorized_keys"
    pct exec $CTID -- bash -c "chmod 600 /home/docker/.ssh/authorized_keys && chown -R docker:docker /home/docker/.ssh"
    echo -e "${GREEN}Chiave SSH configurata con successo!${NC}"
  fi
  
  IP_ADDRESS=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)
  
  echo -e "${GREEN}Container avviato!${NC}"
  if [ -n "$IP_ADDRESS" ]; then
    echo -e "IP (DHCP): ${CYAN}$IP_ADDRESS${NC}"
    echo -e "Collegamento: ${CYAN}ssh docker@$IP_ADDRESS${NC}"
  else
    echo -e "${YELLOW}IP non rilevato in automatico, controlla la console di Proxmox.${NC}"
  fi
fi
