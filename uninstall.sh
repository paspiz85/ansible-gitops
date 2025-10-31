#!/bin/bash

SERVICE_NAME="ansible-gitops"                                          # nome del servizio/systemd unit
SERVICE_USER="ansible"                                                 # utente di sistema dedicato che esegue il servizio
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"             # percorso unit file systemd
TIMER_NAME="${SERVICE_NAME}"                                           # nome del timer (uguale al servizio)
TIMER_PATH="/etc/systemd/system/${TIMER_NAME}.timer"                   # percorso timer file systemd
GITOPS_DATA_DIR="/var/lib/${SERVICE_NAME}"                             # dati/checkout dei repo per ciascuna istanza
GITOPS_LOG_DIR="/var/log/${SERVICE_NAME}"                              # directory dove salvare i log
GITOPS_CONFIG_DIR="/etc/${SERVICE_NAME}"                               # directory di configurazione (.env, runner, notifiche)

SERVICE_USER_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6 || true)"

# --- Backup ---
BACKUP_DIR="${SERVICE_NAME}-$(date +%Y%m%d%H%M%S)-bak"
mkdir -p "${BACKUP_DIR}"
if [[ -d "$GITOPS_CONFIG_DIR" ]]; then
  sudo cp -a "$GITOPS_CONFIG_DIR" "${BACKUP_DIR}/.etc"
fi
if [[ -n "$SERVICE_USER_HOME" ]] && sudo test -d "$SERVICE_USER_HOME"; then
  sudo cp -a "$SERVICE_USER_HOME/.ssh" "${BACKUP_DIR}/.ssh"
fi
sudo chown -R "$(id -un):$(id -gn)" "$BACKUP_DIR"

# --- Controllo ---
echo "Ho fatto il seguente backup"
ls -ahR "${BACKUP_DIR}"
read -r -p "Procedo alla rimozione? [y/N] " ANSWER
case "${ANSWER:-N}" in
  [yY]|[yY][eE][sS]) ;;
  *) exit 0 ;;
esac

# --- Eliminazione ---
sudo rm -rf "${TIMER_PATH}"
sudo systemctl daemon-reload
sudo rm -rf "${SERVICE_PATH}"
sudo systemctl daemon-reload
sudo rm -rf "${GITOPS_DATA_DIR}"
sudo rm -rf "${GITOPS_LOG_DIR}"
sudo rm -rf "${GITOPS_CONFIG_DIR}"
sudo userdel -r "${SERVICE_USER}" 2>/dev/null || sudo userdel "${SERVICE_USER}"
if [[ -n "$SERVICE_USER_HOME" ]]; then
  sudo rm -rf "${SERVICE_USER_HOME}"
fi
echo "Rimozione completata"
