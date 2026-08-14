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

# --- FASE 2b: CONFIGURAZIONE RETE ---
echo -e "\n${CYAN}--- Configurazione Rete ---${NC}"
echo -e "  1) DHCP (automatico)"
echo -e "  2) IP Statico"
read -p "Scegli modalità rete [1]: " NET_MODE </dev/tty
NET_MODE=${NET_MODE:-1}

if [ "$NET_MODE" = "2" ]; then
  read -p "Indirizzo IP con CIDR (es: 192.168.1.100/24): " STATIC_IP </dev/tty
  while [ -z "$STATIC_IP" ]; do
    echo -e "${RED}Errore: l'indirizzo IP non può essere vuoto.${NC}"
    read -p "Indirizzo IP con CIDR (es: 192.168.1.100/24): " STATIC_IP </dev/tty
  done

  read -p "Gateway (es: 192.168.1.1): " STATIC_GW </dev/tty
  while [ -z "$STATIC_GW" ]; do
    echo -e "${RED}Errore: il gateway non può essere vuoto.${NC}"
    read -p "Gateway (es: 192.168.1.1): " STATIC_GW </dev/tty
  done

  NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP},gw=${STATIC_GW}"
  echo -e "${GREEN}Rete statica configurata: IP=${STATIC_IP} GW=${STATIC_GW}${NC}"
else
  NET_CONFIG="name=eth0,bridge=vmbr0,ip=dhcp"
  echo -e "${GREEN}Rete configurata in DHCP.${NC}"
fi

# --- FASE 3: CHIEDE DI INCOLLARE LE CHIAVI PUBBLICHE (docker e root) ---
echo -e ""
echo -e "${YELLOW}Per abilitare l'accesso SSH puoi aggiungere una o più chiavi pubbliche per ciascun utente.${NC}"

# Richiede N chiavi SSH per un utente, valida il formato con ssh-keygen e scarta i duplicati.
# Uso: read_ssh_keys "etichetta utente" nome_array_di_destinazione
read_ssh_keys() {
  local user_label="$1"
  local -n keys_array="$2"
  local count added=0
  local fingerprints=()

  read -p "Quante chiavi SSH pubbliche vuoi aggiungere per $user_label? [1] (0 per saltare): " count </dev/tty
  count=${count:-1}

  if ! [[ "$count" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Valore non valido, imposto 0 chiavi per $user_label.${NC}"
    count=0
  fi

  while [ "$added" -lt "$count" ]; do
    read -p "Chiave SSH pubblica #$((added+1)) per $user_label (es: ssh-ed25519 AAAA... user@host): " key </dev/tty

    if [ -z "$key" ]; then
      echo -e "${RED}Chiave vuota, riprova.${NC}"
      continue
    fi

    local fp
    fp=$(ssh-keygen -lf <(echo "$key") 2>/dev/null | awk '{print $2}')
    if [ -z "$fp" ]; then
      echo -e "${RED}Chiave non valida (formato non riconosciuto), riprova.${NC}"
      continue
    fi

    local is_dup=0
    for existing_fp in "${fingerprints[@]}"; do
      if [ "$existing_fp" = "$fp" ]; then
        is_dup=1
        break
      fi
    done

    if [ "$is_dup" -eq 1 ]; then
      echo -e "${YELLOW}Chiave già inserita in precedenza (duplicato), la scarto.${NC}"
    else
      fingerprints+=("$fp")
      keys_array+=("$key")
      echo -e "${GREEN}Chiave valida (fingerprint: $fp) aggiunta.${NC}"
    fi
    added=$((added+1))
  done
}

DOCKER_SSH_KEYS=()
read_ssh_keys "l'utente docker" DOCKER_SSH_KEYS

echo -e ""
ROOT_SSH_KEYS=()
read_ssh_keys "l'utente root" ROOT_SSH_KEYS

# --- FASE 3b: CHIEDE LA PASSWORD DI ROOT ---
echo -e ""
echo -e "${YELLOW}Imposta la password per l'utente root del container.${NC}"
while true; do
  read -s -p "Password root: " ROOT_PASSWORD </dev/tty
  echo ""
  read -s -p "Conferma password root: " ROOT_PASSWORD_CONFIRM </dev/tty
  echo ""
  if [ "$ROOT_PASSWORD" = "$ROOT_PASSWORD_CONFIRM" ]; then
    if [ -z "$ROOT_PASSWORD" ]; then
      echo -e "${RED}Errore: la password non può essere vuota. Riprova.${NC}"
    else
      echo -e "${GREEN}Password confermata.${NC}"
      break
    fi
  else
    echo -e "${RED}Errore: le password non coincidono. Riprova.${NC}"
  fi
done

echo -e "\n${CYAN}Creazione del container in corso...${NC}"
pct create "$CTID" "$TEMPLATE_PATH" \
  --ostype debian \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$RAM" \
  --swap "$RAM" \
  --rootfs "$STORAGE:$DISK_SIZE" \
  --net0 "$NET_CONFIG" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --onboot 1

echo -e "${GREEN}Container $CTID creato con successo!${NC}"

# --- FASE 3c: PROFILO APPARMOR UNCONFINED ---
CONF_FILE="/etc/pve/lxc/${CTID}.conf"
if [ -f "$CONF_FILE" ]; then
  echo -e "${YELLOW}Imposto lxc.apparmor.profile: unconfined nel file di configurazione...${NC}"
  if grep -q '^lxc.apparmor.profile' "$CONF_FILE"; then
    sed -i 's/^lxc.apparmor.profile.*/lxc.apparmor.profile: unconfined/' "$CONF_FILE"
  else
    echo "lxc.apparmor.profile: unconfined" >> "$CONF_FILE"
  fi
  echo -e "${GREEN}Profilo AppArmor impostato su unconfined.${NC}"
  echo -e "${YELLOW}Nota: questo riduce l'isolamento del container. Necessario tipicamente per Docker-in-LXC.${NC}"
else
  echo -e "${RED}Attenzione: file di configurazione $CONF_FILE non trovato, impossibile impostare AppArmor.${NC}"
fi

read -p "Vuoi avviare il container ora? (Y/n): " START_CT </dev/tty
START_CT=${START_CT:-Y}

if [[ "$START_CT" =~ ^[Yy]$ ]]; then
  echo -e "${YELLOW}Avvio del container...${NC}"
  pct start "$CTID"
  sleep 5

  # --- FASE 4: IMPOSTA LA PASSWORD ROOT ---
  echo -e "${YELLOW}Impostazione della password root...${NC}"
  pct exec "$CTID" -- bash -c "echo 'root:${ROOT_PASSWORD}' | chpasswd"
  echo -e "${GREEN}Password root impostata con successo!${NC}"

  # --- FASE 5: CONFIGURA LE CHIAVI SSH SE SONO STATE INSERITE ---
  # Uso: push_authorized_keys "/home/docker/.ssh" "docker:docker" chiave1 chiave2 ...
  push_authorized_keys() {
    local ssh_dir="$1"
    local owner="$2"
    shift 2
    local keys=("$@")
    local tmp_file
    tmp_file=$(mktemp)
    printf '%s\n' "${keys[@]}" > "$tmp_file"

    pct exec "$CTID" -- bash -c "mkdir -p '$ssh_dir' && chmod 700 '$ssh_dir'"
    pct push "$CTID" "$tmp_file" "$ssh_dir/authorized_keys"
    pct exec "$CTID" -- bash -c "chmod 600 '$ssh_dir/authorized_keys' && chown -R $owner '$ssh_dir'"

    rm -f "$tmp_file"
  }

  if [ ${#DOCKER_SSH_KEYS[@]} -gt 0 ]; then
    echo -e "${YELLOW}Configurazione di ${#DOCKER_SSH_KEYS[@]} chiave/i SSH per l'utente docker...${NC}"
    push_authorized_keys "/home/docker/.ssh" "docker:docker" "${DOCKER_SSH_KEYS[@]}"
    echo -e "${GREEN}Chiavi SSH configurate per l'utente docker!${NC}"
  else
    echo -e "${YELLOW}Nessuna chiave SSH inserita per l'utente docker, salto.${NC}"
  fi

  if [ ${#ROOT_SSH_KEYS[@]} -gt 0 ]; then
    echo -e "${YELLOW}Configurazione di ${#ROOT_SSH_KEYS[@]} chiave/i SSH per l'utente root...${NC}"
    push_authorized_keys "/root/.ssh" "root:root" "${ROOT_SSH_KEYS[@]}"
    echo -e "${GREEN}Chiavi SSH configurate per root!${NC}"
  else
    echo -e "${YELLOW}Nessuna chiave SSH inserita per root, salto.${NC}"
  fi

  # --- FASE 5b: ABILITA ACCESSO SSH PER ROOT ---
  echo -e "${YELLOW}Abilitazione dell'accesso SSH per root...${NC}"
  pct exec "$CTID" -- bash -c "
    if [ -f /etc/ssh/sshd_config ]; then
      if grep -q '^#\?PermitRootLogin' /etc/ssh/sshd_config; then
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
      else
        echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
      fi
      systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart
    fi
  "
  echo -e "${GREEN}Accesso SSH per root abilitato (PermitRootLogin yes)!${NC}"
  echo -e "${YELLOW}Nota: valuta se preferire l'accesso solo tramite chiave (PermitRootLogin prohibit-password) per maggiore sicurezza.${NC}"

  # --- FASE 6: AGGIUNGI DOCKER AL GRUPPO SUDO ---
  echo -e "${YELLOW}Aggiunta dell'utente docker al gruppo sudo...${NC}"
  pct exec "$CTID" -- bash -c "usermod -aG sudo docker"
  pct exec "$CTID" -- bash -c "echo 'docker ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/docker && chmod 440 /etc/sudoers.d/docker"
  echo -e "${GREEN}Utente docker aggiunto a sudo con NOPASSWD!${NC}"

  if [ "$NET_MODE" = "2" ]; then
    IP_ADDRESS=$(echo "$STATIC_IP" | cut -d'/' -f1)
  else
    IP_ADDRESS=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)
  fi
  
  echo -e "${GREEN}Container avviato!${NC}"
  if [ -n "$IP_ADDRESS" ]; then
    echo -e "IP (DHCP): ${CYAN}$IP_ADDRESS${NC}"
    echo -e "Collegamento: ${CYAN}ssh docker@$IP_ADDRESS${NC}"
    echo -e "Collegamento root: ${CYAN}ssh root@$IP_ADDRESS${NC}"
  else
    echo -e "${YELLOW}IP non rilevato in automatico, controlla la console di Proxmox.${NC}"
  fi
fi
