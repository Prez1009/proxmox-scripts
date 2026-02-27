#!/usr/bin/env bash

# Abilita l'uscita in caso di errore
set -e

# Colori per un output leggibile
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${CYAN}=======================================================${NC}"
echo -e "${CYAN}  Proxmox LXC Docker Container Creator                 ${NC}"
echo -e "${CYAN}=======================================================${NC}"

# Verifica di essere su Proxmox (richiede permessi di root)
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Errore: Questo script deve essere eseguito come root.${NC}"
  exit 1
fi

if ! command -v pct &> /dev/null; then
  echo -e "${RED}Errore: Comando 'pct' non trovato. Sei su un nodo Proxmox?${NC}"
  exit 1
fi

# Ricerca del template generato da dab
echo -e "${YELLOW}Cerco il template in /var/lib/vz/template/cache/...${NC}"
TEMPLATE_FILE=$(ls /var/lib/vz/template/cache/debian-12-docker-template*.tar.gz 2>/dev/null | head -n 1)

if [ -z "$TEMPLATE_FILE" ]; then
  echo -e "${RED}Errore: Nessun template trovato.${NC}"
  echo "Assicurati di aver eseguito 'make' per generare il template con dab."
  exit 1
fi

TEMPLATE_NAME=$(basename "$TEMPLATE_FILE")
# Proxmox si aspetta la sintassi storage:vztmpl/nomefile
TEMPLATE_PATH="local:vztmpl/$TEMPLATE_NAME"
echo -e "${GREEN}Template trovato: ${TEMPLATE_NAME}${NC}"

# Ottieni il prossimo ID libero
NEXT_ID=$(pvesh get /cluster/nextid)

# Lettura variabili con default (usa /dev/tty per supportare l'esecuzione via curl)
read -p "ID Container [$NEXT_ID]: " CTID </dev/tty
CTID=${CTID:-$NEXT_ID}

read -p "Hostname [docker-node-$CTID]: " HOSTNAME </dev/tty
HOSTNAME=${HOSTNAME:-docker-node-$CTID}

read -p "Spazio Disco in GB [100]: " DISK_SIZE </dev/tty
DISK_SIZE=${DISK_SIZE:-100}

# Chiedi in quale storage creare il disco (solitamente local-lvm o local-zfs)
read -p "Storage di destinazione [local-lvm]: " STORAGE </dev/tty
STORAGE=${STORAGE:-local-lvm}

read -p "Cores CPU [2]: " CORES </dev/tty
CORES=${CORES:-2}

read -p "RAM in MB [2048]: " RAM </dev/tty
RAM=${RAM:-2048}

echo -e "${CYAN}-------------------------------------------------------${NC}"
echo -e "Creazione del container con i seguenti parametri:"
echo -e "ID:         ${GREEN}$CTID${NC}"
echo -e "Hostname:   ${GREEN}$HOSTNAME${NC}"
echo -e "Template:   ${GREEN}$TEMPLATE_PATH${NC}"
echo -e "Disco:      ${GREEN}$DISK_SIZE GB su $STORAGE${NC}"
echo -e "CPU:        ${GREEN}$CORES core${NC}"
echo -e "RAM:        ${GREEN}$RAM MB${NC}"
echo -e "${CYAN}-------------------------------------------------------${NC}"

# Creazione del container
# NOTA: unprivileged=1 per sicurezza, nesting=1 e keyctl=1 sono obbligatori per Docker in LXC
echo -e "${YELLOW}Creazione del container in corso...${NC}"
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

# Avvio automatico
read -p "Vuoi avviare il container ora? (Y/n): " START_CT </dev/tty
START_CT=${START_CT:-Y}

if [[ "$START_CT" =~ ^[Yy]$ ]]; then
  echo -e "${YELLOW}Avvio del container...${NC}"
  pct start "$CTID"
  
  # Attendi qualche secondo per fargli prendere l'IP dal DHCP
  sleep 4
  IP_ADDRESS=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
  
  echo -e "${GREEN}Container avviato!${NC}"
  if [ -n "$IP_ADDRESS" ]; then
    echo -e "Indirizzo IP (DHCP): ${CYAN}$IP_ADDRESS${NC}"
    echo -e "Puoi collegarti tramite: ${CYAN}ssh docker@$IP_ADDRESS${NC} (usando la chiave SSH di Andrea)"
  else
    echo -e "${YELLOW}Non è stato possibile rilevare l'IP. Potrebbe essere necessario più tempo per il DHCP.${NC}"
  fi
fi

echo -e "${CYAN}Operazione completata.${NC}"
