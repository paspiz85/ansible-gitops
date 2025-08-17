#!/bin/bash

SERVICE_NAME="ansible-gitops"                                          # nome del servizio/systemd unit
SERVICE_USER="ansible"                                                 # utente di sistema dedicato che esegue il servizio
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"             # percorso unit file systemd
TIMER_NAME="${SERVICE_NAME}"                                           # nome del timer (uguale al servizio)
TIMER_PATH="/etc/systemd/system/${TIMER_NAME}.timer"                   # percorso timer file systemd
GITOPS_DATA_DIR="/var/lib/${SERVICE_NAME}"                             # dati/checkout dei repo per ciascuna istanza
GITOPS_LOG_DIR="/var/log/${SERVICE_NAME}"                              # directory dove salvare i log
GITOPS_CONFIG_DIR="/etc/${SERVICE_NAME}"                               # directory di configurazione (.env, runner, notifiche)

# --- Opzioni ---
DRY_RUN=false
while getopts "-:" opt; do
  case "$opt" in
    -)
      case "$OPTARG" in
        dry-run) DRY_RUN=true ;;
        *) echo "Opzione sconosciuta: --$OPTARG" >&2; exit 1 ;;
      esac
      ;;
    \?) echo "Opzione non valida: -$OPTARG" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

# --- Backup ---
BACKUP_DIR="${SERVICE_NAME}-$(date +%Y%m%d%H%M%S)-bak"
mkdir -p "${BACKUP_DIR}"
if [[ -d "$GITOPS_CONFIG_DIR" ]]; then
  sudo cp -a "$GITOPS_CONFIG_DIR" "${BACKUP_DIR}/conf"
fi
if [[ -d "$SERVICE_USER_HOME" ]]; then
  sudo cp -a "$GITOPS_CONFIG_DIR" "${BACKUP_DIR}/home"
fi

# --- Controllo --dry-run ---
if $DRY_RUN; then
  exit 0
fi

# --- Eliminazione ---
sudo rm -rf "${TIMER_PATH}"
sudo systemctl daemon-reload
sudo rm -rf "${SERVICE_PATH}"
sudo systemctl daemon-reload
sudo rm -rf "/etc/logrotate.d/${SERVICE_NAME}"
sudo rm -rf "${GITOPS_DATA_DIR}"
sudo rm -rf "${GITOPS_LOG_DIR}"
sudo rm -rf "${GITOPS_CONFIG_DIR}"
SERVICE_USER_HOME=$(getent passwd ${SERVICE_USER} | cut -d: -f6)
sudo userdel -r "${SERVICE_USER}" 2>/dev/null || sudo userdel "${SERVICE_USER}"
sudo rm -rf "${SERVICE_USER_HOME}"
