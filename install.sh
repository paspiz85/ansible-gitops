#!/bin/bash

# ==========================
# Configurazioni di default (modifica se vuoi)
# ==========================
DEFAULT_TIMER_ACTIVATION="5m"                                          # intervallo di attivazione del timer
DEFAULT_GIT_SSH_KEY_NAME="id_ed25519_ansible_gitops"                   # nome file della chiave SSH che userà git (in ~ansible/.ssh)
DEFAULT_GIT_URL=""                                                     # URL SSH del repo (es: git@github.com:org/repo.git)
DEFAULT_GIT_BRANCH="main"                                              # branch predefinito da seguire
DEFAULT_INVENTORY=""                                                   # percorso inventory Ansible di default (relativo al repo)
DEFAULT_PLAYBOOK="playbooks/site.yml"                                  # percorso playbook Ansible di default (relativo al repo)

SERVICE_NAME="ansible-gitops"                                          # nome del servizio/systemd unit
SERVICE_USER="ansible"                                                 # utente di sistema dedicato che esegue il servizio
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"             # percorso unit file systemd
TIMER_NAME="${SERVICE_NAME}"                                           # nome del timer (uguale al servizio)
TIMER_PATH="/etc/systemd/system/${TIMER_NAME}.timer"                   # percorso timer file systemd
GITOPS_DATA_DIR="/var/lib/${SERVICE_NAME}"                             # dati/checkout dei repo per ciascuna istanza
GITOPS_LOG_DIR="/var/log/${SERVICE_NAME}"                              # directory dove salvare i log
GITOPS_CONFIG_DIR="/etc/${SERVICE_NAME}"                               # directory di configurazione (.env, runner, notifiche)
GITOPS_CONFIG_VAULT_KEY_FILENAME="ansible-vault.key"                   # file chiave di Ansible Vault
GITOPS_CONFIG_NOTIFICATIONS_FILENAME="notifications.yml"               # file Apprise con gli URL di notifica
GITOPS_CONFIG_RUNNER="${GITOPS_CONFIG_DIR}/${SERVICE_NAME}.sh"         # script runner lanciato dal servizio
SILENT=false

# ==========================
# Parse opzioni CLI
# ==========================
while getopts "t:u:b:i:p:s" opt; do
  case $opt in
    t) DEFAULT_TIMER_ACTIVATION="$OPTARG" ;;
    u) DEFAULT_GIT_URL="$OPTARG" ;;
    b) DEFAULT_GIT_BRANCH="$OPTARG" ;;
    i) DEFAULT_INVENTORY="$OPTARG" ;;
    p) DEFAULT_PLAYBOOK="$OPTARG" ;;
    s) SILENT=true ;;
  esac
done

# ==========================
# Prerequisiti
# ==========================
if command -v apt >/dev/null 2>&1; then
  sudo apt update
  sudo apt install -y git ansible apprise
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y epel-release
  sudo dnf install -y git ansible
elif command -v yum >/dev/null 2>&1; then
  sudo yum install -y git ansible
elif command -v zypper >/dev/null 2>&1; then
  sudo zypper install -y git ansible
else
  echo "Unsupported package manager. Install git/ansible manually." >&2
fi

# ==========================
# Utente di servizio con home e privilegi sudo
# ==========================
if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
  sudo useradd --create-home --shell /bin/bash "${SERVICE_USER}"
  echo "${SERVICE_USER} ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/010_${SERVICE_USER}-nopasswd >/dev/null
fi
SERVICE_USER_HOME=$(getent passwd ${SERVICE_USER} | cut -d: -f6)

# ==========================
# Cartelle dati, log, configurazioni ed eseguibile
# ==========================
sudo mkdir -p "${GITOPS_DATA_DIR}"
sudo chown -R "${SERVICE_USER}:${SERVICE_USER}" "${GITOPS_DATA_DIR}"
sudo mkdir -p "${GITOPS_LOG_DIR}"
sudo chown -R "${SERVICE_USER}:${SERVICE_USER}" "${GITOPS_LOG_DIR}"
sudo mkdir -p "${GITOPS_CONFIG_DIR}"
if [ ! -f "${GITOPS_CONFIG_DIR}/${GITOPS_CONFIG_VAULT_KEY_FILENAME}" ]; then
    openssl rand -base64 32 | sudo tee "${GITOPS_CONFIG_DIR}/${GITOPS_CONFIG_VAULT_KEY_FILENAME}" > /dev/null
fi
sudo chmod 600 "${GITOPS_CONFIG_DIR}/${GITOPS_CONFIG_VAULT_KEY_FILENAME}"
sudo tee "${GITOPS_CONFIG_RUNNER}" >/dev/null <<EOF
#!/bin/bash

DEFAULT_GIT_SSH_KEY="${SERVICE_USER_HOME}/.ssh/${DEFAULT_GIT_SSH_KEY_NAME}"
DEFAULT_GIT_BRANCH="${DEFAULT_GIT_BRANCH}"
DEFAULT_PLAYBOOK="${DEFAULT_PLAYBOOK}"

GITOPS_DATA_DIR="${GITOPS_DATA_DIR}"
GITOPS_LOG_DIR="${GITOPS_LOG_DIR}"
GITOPS_CONFIG_DIR="${GITOPS_CONFIG_DIR}"
GITOPS_CONFIG_VAULT_KEY_FILENAME="${GITOPS_CONFIG_VAULT_KEY_FILENAME}"
GITOPS_CONFIG_NOTIFICATIONS_FILENAME="${GITOPS_CONFIG_NOTIFICATIONS_FILENAME}"
SERVICE_USER="${SERVICE_USER}"

while getopts "e:" opt; do
  case \$opt in
    e) GITOPS_CONFIG_NAME="\$OPTARG" ;;
  esac
done

if [[ "\$EUID" -ne "\$(id -u "\$SERVICE_USER")" ]]; then
  echo "Error: this command can only be run by user \$SERVICE_USER" >&2
  exit 1
fi

if [[ -z "\${GITOPS_CONFIG_NAME}" ]]; then
  echo "Usage: \$0 -e file.env" >&2
  exit 1
fi

GITOPS_CONFIG_FILE="\${GITOPS_CONFIG_DIR}/\$GITOPS_CONFIG_NAME"
if [[ ! -f "\${GITOPS_CONFIG_FILE}" ]]; then
  echo "Env file not found: \${GITOPS_CONFIG_FILE}" >&2
  exit 1
fi

set -a
. "\${GITOPS_CONFIG_FILE}"
set +a

GITOPS_CONFIG_NAME="\$(basename \$GITOPS_CONFIG_FILE)"

log() {
  printf '%s\n' "GitOps \$GITOPS_CONFIG_NAME : \$*"
}

DEFAULT_REPO_DIR="\${GITOPS_DATA_DIR}/\$GITOPS_CONFIG_NAME"
DEFAULT_REPO_DIR="\${DEFAULT_REPO_DIR%.env}"
REPO_DIR="\${REPO_DIR:-\$DEFAULT_REPO_DIR}"
GIT_SSH_KEY="\${GIT_SSH_KEY:-\$DEFAULT_GIT_SSH_KEY}"
if [[ -z "\${GIT_URL}" ]]; then
  log "GIT_URL not defined" >&2
  exit 1
fi
GIT_BRANCH="\${GIT_BRANCH:-\$DEFAULT_GIT_BRANCH}"
INVENTORY="\${INVENTORY:-}"
PLAYBOOK="\${PLAYBOOK:-\$DEFAULT_PLAYBOOK}"
RUN_LOCAL=\${RUN_LOCAL:-false}

# Configura il comando SSH usato da git: chiave dedicata, niente agent forwarding, accetta nuove chiavi host
export GIT_SSH_COMMAND="ssh -i \${GIT_SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

# Ansible: abilita colori ed evita le "mucche" ;)
export ANSIBLE_FORCE_COLOR=1
export ANSIBLE_NOCOWS=1
export ANSIBLE_COW_SELECTION=tux

(
  set -euo pipefail   # fallisci su errore/variabile non definita e pipe

  RUN_PLAYBOOK=0      # flag: 1 se dobbiamo lanciare ansible-playbook

  if [[ ! -d "\${REPO_DIR}/.git" ]]; then
    # Primo run: clona il repo e poi esegui il playbook
    log "cloning \${GIT_URL} ..."
    mkdir -p "\$REPO_DIR"
    git clone --branch "\${GIT_BRANCH}" "\${GIT_URL}" "\${REPO_DIR}"
    log "cloning completed"
    RUN_PLAYBOOK=1
  else
    cd "\${REPO_DIR}" >/dev/null
    # Aggiorna referenze remote (silenzioso) e rimuove rami remoti eliminati
    git fetch --quiet --prune
    # Verifica che il branch remoto esista (utile quando viene rinominato o cancellato)
    if ! git rev-parse --verify -q "origin/\${GIT_BRANCH}" >/dev/null; then
      log "remote branch origin/\${GIT_BRANCH} not found" >&2
      exit 1
    fi
    # Se non ci sono differenze tra HEAD locale e remote HEAD, non fare nulla
    if git diff --quiet HEAD..origin/"\${GIT_BRANCH}"; then
      log "no changes detected"
    else
      # Avanza al nuovo stato e segna che dobbiamo eseguire il playbook
      git checkout -q "\${GIT_BRANCH}"
      git reset --hard "origin/\${GIT_BRANCH}"
      log "changes detected"
      RUN_PLAYBOOK=1
    fi
  fi
  cd "\${REPO_DIR}" >/dev/null
  # Controlli di esistenza per inventory e playbook (percorsi relativi al repo)
  if [[ -n "\${INVENTORY:-}" ]] && [[ "\$INVENTORY" != *,* ]] && [[ ! -f "\$INVENTORY" ]]; then
    log "inventory not found: \$INVENTORY" >&2
    exit 1
  fi
  if [[ ! -f "\$PLAYBOOK" ]]; then
    log "playbook not found: \$PLAYBOOK" >&2;
    exit 1
  fi
  if (( RUN_PLAYBOOK )); then
    # Log: crea un file per run con timestamp e un link simbolico "ultimo.log" per consultazione rapida
    RUN_ID="\$(date +%Y%m%d-%H%M%S)-\${GITOPS_CONFIG_NAME%.env}"
    LOG_FILE="\${GITOPS_LOG_DIR}/\${RUN_ID}.log"
    LOG_LINK="\${GITOPS_LOG_DIR}/\${GITOPS_CONFIG_NAME%.env}.log"
    touch "\$LOG_FILE"
    ln -sfn "\$LOG_FILE" "\$LOG_LINK"

    ARGS=( --vault-password-file "\$GITOPS_CONFIG_DIR/\$GITOPS_CONFIG_VAULT_KEY_FILENAME" )
    if [[ -n "\${INVENTORY:-}" ]]; then
      ARGS+=( -i "\$INVENTORY" )
    fi
    if [[ "\$RUN_LOCAL" == true ]]; then
      ARGS+=( --connection=local )
    fi
    ARGS+=( "\$PLAYBOOK" )
    log "ansible-playbook running ..."
    # stdbuf: forza flushing riga-per-riga; awk: preprende timestamp ISO-8601 ad ogni riga
    stdbuf -oL -eL ansible-playbook "\${ARGS[@]}" 2>&1 | awk '{ print strftime("[%Y-%m-%dT%H:%M:%S%z]"), \$0 }' >>"\$LOG_FILE"
    log "ansible-playbook completed"
  else
    log "ansible-playbook skipped"
  fi
)
STATUS=\$?
# Se il run è fallito, prova a inviare una notifica tramite Apprise (se presente e configurato)
if (( STATUS != 0 )); then
  log "error"
  if ! command -v apprise >/dev/null 2>&1; then
    log "error notification not sent: missing apprise"
  elif [[ ! -f "\${GITOPS_CONFIG_DIR}/\$GITOPS_CONFIG_NOTIFICATIONS_FILENAME" ]]; then
    log "error notification not sent: missing \${GITOPS_CONFIG_DIR}/\$GITOPS_CONFIG_NOTIFICATIONS_FILENAME"
  elif [ "\$(grep -cE '^[[:space:]]*-\s' "\${GITOPS_CONFIG_DIR}/\$GITOPS_CONFIG_NOTIFICATIONS_FILENAME")" -eq 0 ]; then
    log "error notification not sent: no config in \${GITOPS_CONFIG_DIR}/\$GITOPS_CONFIG_NOTIFICATIONS_FILENAME"
  else
    MSG_BODY=\$(cat \$LOG_LINK)
    if (( \${#MSG_BODY} > 1900 )); then
      MSG_BODY="\${MSG_BODY: -1900}"
    fi
    apprise --config "\${GITOPS_CONFIG_DIR}/\$GITOPS_CONFIG_NOTIFICATIONS_FILENAME" -t "⚠️ GitOps \$GITOPS_CONFIG_NAME error on \$(hostname)" -b "\$MSG_BODY" || true
  fi
fi
EOF

# Inizializzazione YAML per Apprise: inserirai qui gli URL dei canali (Slack/Telegram/ntfy/email...)
if [[ ! -f "${GITOPS_CONFIG_DIR}/${GITOPS_CONFIG_NOTIFICATIONS_FILENAME}" ]]; then
  sudo tee "${GITOPS_CONFIG_DIR}/${GITOPS_CONFIG_NOTIFICATIONS_FILENAME}" >/dev/null <<EOF
# Each line is an Apprise notification "URL": you can add more than one.
urls:
# Examples (replace with your own tokens/chat IDs):
# Slack:
#  - slack://xoxb-123456-abcdefg@C12345678
# Telegram:
#  - tgram://BOT_TOKEN/CHAT_ID
# Discord:
#  - discord://WEBHOOK_ID/WEBHOOK_TOKEN
# ntfy (public or self-hosted):
#  - ntfy://ntfy.sh/your-topic
# SMTP/email:
#  - mailtos://user:pass@smtp.example.com:587/?from=gitops@example.com&to=ops@example.com
EOF
fi
sudo chmod 0744 "${GITOPS_CONFIG_RUNNER}"
sudo chown -R "${SERVICE_USER}:${SERVICE_USER}" "${GITOPS_CONFIG_DIR}"

# ==========================
# Configurazione logrotate
# ==========================
# Regole di rotazione dei log del servizio (una volta al giorno, conserva ~2 settimane, comprime, ecc.)

if [[ ! -f "/etc/logrotate.d/${SERVICE_NAME}" ]]; then
  sudo tee "/etc/logrotate.d/${SERVICE_NAME}" >/dev/null <<EOF
/var/log/ansible-gitops/*.log {
  daily                 # rotate every day
  rotate 14             # keep 14 rotated files (about 2 weeks)
  maxsize 50M           # rotate earlier if larger than 50MB
  missingok
  notifempty
  compress
  delaycompress
  dateext
  dateformat -%Y%m%d
  su ansible ansible    # rotate with service's uid/gid
  create 0640 ansible ansible
  copytruncate          # truncate open file without killing the process
}
EOF
fi

# ==========================
# Unit file systemd (service)
# ==========================
# L'unità oneshot esegue il runner per OGNI file .env presente in ${GITOPS_CONFIG_DIR}
sudo install -d -m 0755 "$(dirname "$SERVICE_PATH")"
sudo tee "$SERVICE_PATH" >/dev/null <<EOF
[Unit]
Description=GitOps converge via ansible-playbook
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=/bin/bash -c 'find ${GITOPS_CONFIG_DIR} -maxdepth 1 -type f -name "*.env" -printf "%%f\n" | sort | xargs -r -n1 ${GITOPS_CONFIG_RUNNER} -e'
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload

# ==========================
# Timer systemd
# ==========================
if [[ ! -f "${TIMER_PATH}" ]]; then
  if [[ "$SILENT" == true ]]; then
    TIMER_ACTIVATION="${DEFAULT_TIMER_ACTIVATION}"
  else
    echo
    read -r -p "How often to run the service [${DEFAULT_TIMER_ACTIVATION}]: " TIMER_ACTIVATION
    TIMER_ACTIVATION="${TIMER_ACTIVATION:-$DEFAULT_TIMER_ACTIVATION}"
  fi

  sudo tee "$TIMER_PATH" >/dev/null <<EOF
[Unit]
Description=Run ${SERVICE_NAME} periodically

[Timer]
OnBootSec=2m
OnUnitActiveSec=${TIMER_ACTIVATION}
RandomizedDelaySec=60
Unit=${SERVICE_NAME}.service

[Install]
WantedBy=timers.target
EOF
  sudo systemctl daemon-reload
fi

if [[ "$SILENT" == true && -z "$DEFAULT_GIT_URL" ]]; then
  exit 0
fi

# ==========================
# Helpers
# ==========================
# Valida URL SSH in forma: git@host:utente/repo.git (molto utile per evitare formati HTTP/HTTPS qui)
validate_git_ssh_url() {
  [[ "$1" =~ ^git@[^:]+:[^/]+/.+\.git$ ]]
}

# ==========================
# Chiave SSH (senza passphrase)
# ==========================
echo
DEFAULT_GIT_SSH_KEY="${SERVICE_USER_HOME}/.ssh/${DEFAULT_GIT_SSH_KEY_NAME}"
read -r -p "Git SSH key [${DEFAULT_GIT_SSH_KEY}]: " GIT_SSH_KEY
GIT_SSH_KEY="${GIT_SSH_KEY:-$DEFAULT_GIT_SSH_KEY}"
sudo -u ${SERVICE_USER} install -d -m 700 ${SERVICE_USER_HOME}/.ssh
if [[ "$SILENT" != true || ! -f "$GIT_SSH_KEY" ]]; then
  sudo -u "$SERVICE_USER" ssh-keygen -f "$GIT_SSH_KEY" \
    -t ed25519 -C "${SERVICE_NAME}@$(hostname)" -N ''
fi

# ==========================
# Configurazione interattiva
# ==========================
echo
while true; do
  read -r -p "Git URL [${DEFAULT_GIT_URL}]: " GIT_URL
  GIT_URL="${GIT_URL:-$DEFAULT_GIT_URL}"
  if ! validate_git_ssh_url "$GIT_URL"; then
    echo "Invalid format. Must be like: git@host:user/repo.git"
  else
    break
  fi
done
read -r -p "Git branch [${DEFAULT_GIT_BRANCH}]: " GIT_BRANCH
GIT_BRANCH="${GIT_BRANCH:-$DEFAULT_GIT_BRANCH}"
read -r -p "Inventory path [${DEFAULT_INVENTORY}]: " INVENTORY
INVENTORY="${INVENTORY:-$DEFAULT_INVENTORY}"
read -r -p "Playbook path [${DEFAULT_PLAYBOOK}]: " PLAYBOOK
PLAYBOOK="${PLAYBOOK:-$DEFAULT_PLAYBOOK}"
read -r -p "Run playbook only in local mode (y/N)? " RUN_LOCAL_ANSWER
case "${RUN_LOCAL_ANSWER:-N}" in
  [yY]|[yY][eE][sS])
    RUN_LOCAL=true
    ;;
  *)
    RUN_LOCAL=false
    ;;
esac

# Trasforma l'URL SSH in uno HTTP (solo per mostrare le istruzioni su dove aggiungere la deploy key)
GIT_URL_HTTP=$(echo "$GIT_URL" | sed -E 's#:#/#')
GIT_URL_HTTP=$(echo "$GIT_URL_HTTP" | sed -E 's#^git@#https://#')
GIT_URL_HTTP="${GIT_URL_HTTP%.git}"

# Nome di default per la config ricavato dal nome repo (usato per REPO_DIR e per i log)
DEFAULT_GITOPS_NAME="$(basename $GIT_URL_HTTP)"
read -r -p "GitOps config name [${DEFAULT_GITOPS_NAME}]: " GITOPS_CONFIG_NAME
GITOPS_CONFIG_NAME="${GITOPS_CONFIG_NAME:-$DEFAULT_GITOPS_NAME}"
GITOPS_CONFIG_FILE="${GITOPS_CONFIG_DIR}/${GITOPS_CONFIG_NAME}.env"

GITOPS_CONFIG_SAVE=true
# Se il file .env esiste già, chiedi se sovrascriverlo
if [[ -f "${GITOPS_CONFIG_FILE}" ]]; then
  echo "${GITOPS_CONFIG_FILE} already exists."
  read -r -p "Overwrite (y/N)? " GITOPS_OVERWRITE_ANSWER
  case "${GITOPS_OVERWRITE_ANSWER:-N}" in
    [yY]|[yY][eE][sS]) ;;
    *) GITOPS_CONFIG_SAVE=false ;;
  esac
fi
# Scrive il file .env con i parametri minimi; puoi aggiungere altre variabili (es. REPO_DIR personalizzato)
if [[ "$GITOPS_CONFIG_SAVE" == true ]]; then
  sudo -u ${SERVICE_USER} tee "${GITOPS_CONFIG_FILE}" >/dev/null <<EOF
REPO_DIR="${GITOPS_DATA_DIR}/${GITOPS_CONFIG_NAME}"
GIT_SSH_KEY="${GIT_SSH_KEY}"
GIT_URL="${GIT_URL}"
GIT_BRANCH="${GIT_BRANCH}"
PLAYBOOK="${PLAYBOOK}"
EOF
  if [[ -n "${INVENTORY:-}" ]]; then
    echo "INVENTORY=\"${INVENTORY}\"" | sudo -u ${SERVICE_USER} tee -a "${GITOPS_CONFIG_FILE}" >/dev/null
  fi
  if [[ "$RUN_LOCAL" == true ]]; then
    echo "RUN_LOCAL=true" | sudo -u ${SERVICE_USER} tee -a "${GITOPS_CONFIG_FILE}" >/dev/null
  fi
fi

# ==========================
# Istruzioni finali
# ==========================
cat <<EOF

####### Installation completed! #######

Now add the SSH key to your Git repository (deploy key/readonly):
  - Go to ${GIT_URL_HTTP}/settings/keys
  - Click 'Add deploy key', paste the following content, and save

EOF
sudo -u ${SERVICE_USER} cat "${GIT_SSH_KEY}.pub"
cat <<EOF

If needed customize notifications/logrotate:
  - ${GITOPS_CONFIG_DIR}/${GITOPS_CONFIG_NOTIFICATIONS_FILENAME}
  - /etc/logrotate.d/${SERVICE_NAME}

Test the service manually:
  sudo systemctl start ${SERVICE_NAME}.service

If everything is OK, you can enable the timer:
  sudo systemctl enable --now ${TIMER_NAME}.timer

EOF
