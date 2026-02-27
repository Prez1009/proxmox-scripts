# proxmox-scripts

## 🚀 Installazione Rapida: Proxmox LXC Docker

Questo script Bash permette di creare rapidamente un container LXC su Proxmox VE, ottimizzato per eseguire **Docker Engine**. 
Lo script cerca automaticamente il template generato dal Makefile e configura il container con parametri ideali per Docker (Unprivileged, Nesting abilitato, 100GB di storage di default).

### ⚠️ Prerequisiti
Prima di lanciare lo script, assicurati di aver:
1. Generato il template tramite `make` (il file `debian-12-docker-template*.tar.gz` deve trovarsi in `/var/lib/vz/template/cache/` sul tuo nodo Proxmox).
2. Accesso alla **Shell del nodo Proxmox** come utente `root`.

### 💻 Come eseguire lo script

Apri la shell del tuo server Proxmox ed esegui questo singolo comando:

```bash
bash -c "$(curl -fsSL https://is.gd/MhZgI9)"
```

### ⚙️ Cosa fa questo comando?
Una volta lanciato, lo script è interattivo e ti guiderà nella creazione del container. Nello specifico:
- Trova automaticamente l'ID LXC libero successivo.
- Imposta di default **100 GB** di disco (modificabile durante l'esecuzione).
- Applica i flag essenziali per far girare Docker dentro LXC (`nesting=1`, `keyctl=1`).
- Avvia il container in modalità **Unprivileged** per garantire la massima sicurezza.
- Alla fine dell'installazione, rileva e mostra l'indirizzo IP assegnato dal DHCP per il collegamento immediato via SSH.
