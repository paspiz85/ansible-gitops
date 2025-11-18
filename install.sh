#!/bin/bash

PROJECT_VERSION="1.0.1"

# ==========================
# Configurazioni di default (modifica se vuoi)
# ==========================
DEFAULT_TIMER_ACTIVATION="5m"                                          # intervallo di attivazione del timer
DEFAULT_GIT_SSH_KEY_NAME="id_ed25519_ansible_gitops"                   # nome file della chiave SSH che userà git (in ~ansible/.ssh)
DEFAULT_GIT_URL=""                                                     # URL SSH del repo (es: git@github.com:org/repo.git)
DEFAULT_GIT_BRANCH="main"                                              # branch predefinito da seguire
DEFAULT_INVENTORY=""                                                   # percorso inventory Ansible di default (relativo al repo)
DEFAULT_PLAYBOOK="playbooks/site.yml"                                  # percorso playbook Ansible di default (relativo al repo)
DEFAULT_RUN_LOCAL=false
DEFAULT_NOTIFICATION_URL=""                                            # url Apprise per le notifiche

UMASK=0027
SERVICE_NAME="ansible-gitops"                                          # nome del servizio/systemd unit
SERVICE_USER="ansible"                                                 # utente di sistema dedicato che esegue il servizio
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"             # percorso unit file systemd
TIMER_NAME="${SERVICE_NAME}"                                           # nome del timer (uguale al servizio)
TIMER_PATH="/etc/systemd/system/${TIMER_NAME}.timer"                   # percorso timer file systemd
GITOPS_DATA_DIR="/var/lib/${SERVICE_NAME}"                             # dati/checkout dei repo per ciascuna istanza
GITOPS_LOG_DIR="/var/log/${SERVICE_NAME}"                              # directory dove salvare i log
GITOPS_CONFIG_DIR="/etc/${SERVICE_NAME}"                               # directory di configurazione (.env, runner, notifiche)
GITOPS_CONFIG_RUNNER="/usr/local/sbin/${SERVICE_NAME}"                 # script runner lanciato dal servizio
GITOPS_VAULT_KEY_FILENAME="ansible-vault.key"                          # file chiave di Ansible Vault
SILENT=false

# ==========================
# Parse opzioni CLI
# ==========================
while getopts "t:u:b:i:n:p:ls" opt; do
  case $opt in
    t) DEFAULT_TIMER_ACTIVATION="$OPTARG" ;;
    u) DEFAULT_GIT_URL="$OPTARG" ;;
    b) DEFAULT_GIT_BRANCH="$OPTARG" ;;
    i) DEFAULT_INVENTORY="$OPTARG" ;;
    n) DEFAULT_NOTIFICATION_URL="$OPTARG" ;;
    p) DEFAULT_PLAYBOOK="$OPTARG" ;;
    l) DEFAULT_RUN_LOCAL=true ;;
    s) SILENT=true ;;
  esac
done

# ==========================
# Prerequisiti
# ==========================
if command -v apt >/dev/null 2>&1; then
  sudo apt update
  sudo apt install -y git ansible moreutils apprise
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y epel-release
  sudo dnf install -y git ansible moreutils
elif command -v yum >/dev/null 2>&1; then
  sudo yum install -y git ansible moreutils
elif command -v zypper >/dev/null 2>&1; then
  sudo zypper install -y git ansible moreutils
else
  echo "Unsupported package manager. Install git/ansible manually." >&2
fi

# ==========================
# Utente di servizio con home e privilegi sudo
# ==========================
if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
  sudo useradd --system --home "${GITOPS_DATA_DIR}" --shell /bin/bash "${SERVICE_USER}"
  sudo tee /etc/sudoers.d/010_${SERVICE_USER}-nopasswd >/dev/null <<EOF
${SERVICE_USER} ALL=(ALL) NOPASSWD: ALL
EOF
  sudo tee /etc/sudoers.d/010_${SERVICE_USER}-umask >/dev/null <<EOF
Defaults:${SERVICE_USER} umask=${UMASK},umask_override
Defaults>${SERVICE_USER} umask=${UMASK},umask_override
EOF
fi
SERVICE_USER_HOME=$(getent passwd ${SERVICE_USER} | cut -d: -f6)

# ==========================
# Cartelle dati, log, configurazioni ed eseguibile
# ==========================
sudo mkdir -p "${GITOPS_LOG_DIR}"
sudo mkdir -p "${GITOPS_DATA_DIR}"
sudo mkdir -p "${GITOPS_CONFIG_DIR}"
if [ ! -f "${GITOPS_DATA_DIR}/${GITOPS_VAULT_KEY_FILENAME}" ]; then
    openssl rand -base64 32 | sudo tee "${GITOPS_DATA_DIR}/${GITOPS_VAULT_KEY_FILENAME}" > /dev/null
fi
sudo tee "${GITOPS_CONFIG_RUNNER}" >/dev/null <<EOF
#!/bin/bash

PROJECT_VERSION="${PROJECT_VERSION}"
LOG_RETENTION_DAYS=14

DEFAULT_GIT_SSH_KEY="${SERVICE_USER_HOME}/.ssh/${DEFAULT_GIT_SSH_KEY_NAME}"
DEFAULT_GIT_BRANCH="${DEFAULT_GIT_BRANCH}"
DEFAULT_PLAYBOOK="${DEFAULT_PLAYBOOK}"

GITOPS_DATA_DIR="${GITOPS_DATA_DIR}"
GITOPS_LOG_DIR="${GITOPS_LOG_DIR}"
GITOPS_CONFIG_DIR="${GITOPS_CONFIG_DIR}"
GITOPS_VAULT_KEY_FILENAME="${GITOPS_VAULT_KEY_FILENAME}"
SERVICE_USER="${SERVICE_USER}"

if [[ "\$EUID" -ne "\$(id -u "\$SERVICE_USER")" ]]; then
  if [[ "\$EUID" -eq 0 ]]; then
    # lo script è stato lanciato da root → rilancialo come SERVICE_USER
    exec sudo -u "\$SERVICE_USER" "\$0" "\$@"
  else
    echo "Error: this command can only be run by user \$SERVICE_USER" >&2
    exit 1
  fi
fi

ACTION=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -e)
      [[ -n "\${2:-}" ]] || { echo "Errore: -e richiede un argomento" >&2; exit 1; }
      GITOPS_CONFIG_NAME="\$2"
      shift 2
      ;;
    -l|--list)
      ACTION="list"
      shift
      ;;
    -r|--reset)
      ACTION="reset"
      shift
      ;;
    --) shift; break ;;
    -*)
      echo "Unknown option: \$1" >&2; exit 1
      ;;
    *)
      echo "Unknown argument: \$1" >&2; exit 1
      ;;
  esac
done

load_gitops_config() {
  GITOPS_CONFIG_FILE="\${GITOPS_CONFIG_DIR}/\$1.env"
  if [[ ! -f "\${GITOPS_CONFIG_FILE}" ]]; then
    echo "Env file not found: \${GITOPS_CONFIG_FILE}" >&2
    exit 1
  fi

  set -a
  . "\${GITOPS_CONFIG_FILE}"
  set +a
}

if [[ -n "\${GITOPS_CONFIG_NAME}" ]]; then
  load_gitops_config "\${GITOPS_CONFIG_NAME}"
fi

if [[ "\$ACTION" == "list" ]]; then
  ls -1 "\${GITOPS_CONFIG_DIR}"/*.env 2>/dev/null | xargs -r -n1 basename | sed 's/\.env$//' | sort
  exit 0
elif [[ "\$ACTION" == "reset" ]]; then
  if [[ -n "\${GITOPS_CONFIG_NAME}" ]]; then
    if [[ -d "\${REPO_DIR}" ]]; then
      rm -rf "\${REPO_DIR}"
      exit \$?
    else
      exit 0
    fi
  else
    \$0 --list | while IFS= read -r line; do
      REPO_DIR=
      load_gitops_config "\$line"
      if [[ -d "\${REPO_DIR}" ]]; then
        rm -rf "\${REPO_DIR}"
      fi
    done
    exit 0
  fi
fi

if [[ -z "\${INVOCATION_ID:-}" ]]; then
  echo "This script must be run by systemd" >&2
  exit 1
fi

if [[ -z "\${GITOPS_CONFIG_NAME}" ]]; then
  echo "Usage: \$0 -e envname" >&2
  exit 1
fi

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
NOTIFICATION_URL="\${NOTIFICATION_URL:-}"

# Configura il comando SSH usato da git: chiave dedicata, niente agent forwarding, accetta nuove chiavi host
export GIT_SSH_COMMAND="ssh -i \${GIT_SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

# Ansible: abilita colori ed evita le "mucche" ;)
export ANSIBLE_FORCE_COLOR=1
export ANSIBLE_NOCOWS=1
export ANSIBLE_COW_SELECTION=tux

find "\${GITOPS_LOG_DIR}" -type f -mtime +\$LOG_RETENTION_DAYS -delete

LOG_LINK="\${GITOPS_LOG_DIR}/\${GITOPS_CONFIG_NAME%.env}.log"
RUN_PLAYBOOK=0       # flag globale: 1 se abbiamo lanciato ansible-playbook
STATUS=0             # codice di ritorno del blocco "critico"

{
  set -euo pipefail   # fallisci su errore/variabile non definita e pipe

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
    log "playbook not found: \$PLAYBOOK" >&2
    exit 1
  fi
  if (( RUN_PLAYBOOK )); then
    # Log: crea un file per run con timestamp e un link simbolico "ultimo.log" per consultazione rapida
    RUN_ID="\$(date +%Y%m%d-%H%M%S)-\${GITOPS_CONFIG_NAME%.env}"
    LOG_FILE="\${GITOPS_LOG_DIR}/\${RUN_ID}.log"
    touch "\$LOG_FILE"
    ln -sfn "\$LOG_FILE" "\$LOG_LINK"

    ARGS=( --vault-password-file "\$GITOPS_DATA_DIR/\$GITOPS_VAULT_KEY_FILENAME" )
    case "\$ANSIBLE_VERBOSITY" in
      1) ARGS+=( -v ) ;;
      2) ARGS+=( -vv ) ;;
      3) ARGS+=( -vvv ) ;;
      4) ARGS+=( -vvvv ) ;;
    esac
    if [[ -n "\${INVENTORY:-}" ]]; then
      ARGS+=( -i "\$INVENTORY" )
    fi
    if [[ "\$RUN_LOCAL" == true ]]; then
      ARGS+=( --connection=local )
    fi
    ARGS+=( "\$PLAYBOOK" )
    log "ansible-playbook running ..."
    ANSIBLE_FORCE_COLOR=1 ansible-playbook "\${ARGS[@]}" 2>&1 | ts '[%Y-%m-%dT%H:%M:%S%z]' >> "\$LOG_FILE"
    log "ansible-playbook completed"
  else
    log "ansible-playbook skipped"
  fi
} || STATUS=$?   # se qualcosa fallisce nel blocco, STATUS prende il codice di errore

# Se il run è fallito, prova a inviare una notifica tramite Apprise (se presente e configurato)
if [ "\$STATUS" -ne 0 ]; then
  if (( RUN_PLAYBOOK )); then
    log "error checking repository"
  elif ! command -v apprise >/dev/null 2>&1; then
    log "error notification not sent: missing apprise"
  elif [[ -z "\$NOTIFICATION_URL" ]]; then
    log "error notification not sent: missing notification url"
  else
    log "error"
    MSG_BODY=\$(<"\$LOG_LINK")
    if [ "\${#MSG_BODY}" -gt 1900 ]; then
      MSG_BODY="\${MSG_BODY:\$((\${#MSG_BODY}-1900))}"
    fi
    MSG_BODY="\${MSG_BODY:=see log for details}"
    apprise -t "⚠️ GitOps \${GITOPS_CONFIG_NAME} error on \$(hostname)" -b "\${MSG_BODY}" "\${NOTIFICATION_URL}" || true
  fi
fi
EOF

sudo chmod 0755 "${GITOPS_CONFIG_RUNNER}"
sudo chmod 600 "${GITOPS_DATA_DIR}/${GITOPS_VAULT_KEY_FILENAME}"
sudo chown -R "${SERVICE_USER}:${SERVICE_USER}" "${GITOPS_CONFIG_DIR}"
sudo chown -R "${SERVICE_USER}:${SERVICE_USER}" "${GITOPS_DATA_DIR}"
sudo chown -R "${SERVICE_USER}:${SERVICE_USER}" "${GITOPS_LOG_DIR}"

# ==========================
# Unit file systemd (service)
# ==========================
# L'unità oneshot esegue il runner per OGNI file .env presente in ${GITOPS_CONFIG_DIR}
sudo install -d -m 0755 "$(dirname "$SERVICE_PATH")"
sudo tee "$SERVICE_PATH" >/dev/null <<EOF
[Unit]
Description=GitOps converge via ansible-playbook
ConditionACPower=yes
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=${SERVICE_USER}
Group=${SERVICE_USER}
UMask=${UMASK}
ExecStart=/bin/bash -c '${GITOPS_CONFIG_RUNNER} --list | xargs -r -n1 ${GITOPS_CONFIG_RUNNER} -e'
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

# ==========================
# Impostazioni SSH
# ==========================
sudo -u ${SERVICE_USER} install -d -m 700 ${SERVICE_USER_HOME}/.ssh
SSH_ENVIRONMENT=${SERVICE_USER_HOME}/.ssh/environment
sudo -u ${SERVICE_USER} touch ${SSH_ENVIRONMENT}
sudo chmod 600 ${SSH_ENVIRONMENT}
if ! grep -q '^UMASK=' ${SSH_ENVIRONMENT}; then
  echo "UMASK=${UMASK}" | sudo -u ${SERVICE_USER} tee -a ${SSH_ENVIRONMENT} >/dev/null
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
DEFAULT_GIT_SSH_KEY="${SERVICE_USER_HOME}/.ssh/${DEFAULT_GIT_SSH_KEY_NAME}"
if [[ "$SILENT" == true ]]; then
  GIT_SSH_KEY="${DEFAULT_GIT_SSH_KEY}"
else
  echo
  read -r -p "Git SSH key [${DEFAULT_GIT_SSH_KEY}]: " GIT_SSH_KEY
  GIT_SSH_KEY="${GIT_SSH_KEY:-$DEFAULT_GIT_SSH_KEY}"
fi
if [[ "$SILENT" != true || ! $(sudo -u "$SERVICE_USER" test -f "$GIT_SSH_KEY"; echo $?) -eq 0 ]]; then
  sudo -u "$SERVICE_USER" ssh-keygen -f "$GIT_SSH_KEY" \
    -t ed25519 -C "${SERVICE_NAME}@$(hostname)" -N ''
fi

# ==========================
# Configurazione interattiva
# ==========================
if [[ "$SILENT" == true ]]; then
  GIT_URL="${DEFAULT_GIT_URL}"
  if ! validate_git_ssh_url "$GIT_URL"; then
    echo "Invalid '$GIT_URL' format. Must be like: git@host:user/repo.git"
    exit 1
  fi
  GIT_BRANCH="${DEFAULT_GIT_BRANCH}"
  INVENTORY="${DEFAULT_INVENTORY}"
  PLAYBOOK="${DEFAULT_PLAYBOOK}"
  RUN_LOCAL=$DEFAULT_RUN_LOCAL
  NOTIFICATION_URL="${DEFAULT_NOTIFICATION_URL}"
else
  echo
  while true; do
    read -r -p "Git URL [${DEFAULT_GIT_URL}]: " GIT_URL
    GIT_URL="${GIT_URL:-$DEFAULT_GIT_URL}"
    if ! validate_git_ssh_url "$GIT_URL"; then
      echo "Invalid '$GIT_URL' format. Must be like: git@host:user/repo.git"
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
  if [[ "$DEFAULT_RUN_LOCAL" == true ]]; then
    DEFAULT_RUN_LOCAL_ANSWER=Y
    read -r -p "Run playbook only in local mode (Y/n)? " RUN_LOCAL_ANSWER
  else
    DEFAULT_RUN_LOCAL_ANSWER=N
    read -r -p "Run playbook only in local mode (y/N)? " RUN_LOCAL_ANSWER
  fi
  case "${RUN_LOCAL_ANSWER:-$DEFAULT_RUN_LOCAL_ANSWER}" in
    [yY]|[yY][eE][sS]) RUN_LOCAL=true ;;
    *) RUN_LOCAL=false ;;
  esac
  read -r -p "Notification Apprise URL [${DEFAULT_NOTIFICATION_URL}]: " NOTIFICATION_URL
  NOTIFICATION_URL="${NOTIFICATION_URL:-$DEFAULT_NOTIFICATION_URL}"
fi

# Trasforma l'URL SSH in uno HTTP (solo per mostrare le istruzioni su dove aggiungere la deploy key)
GIT_URL_HTTP=$(echo "$GIT_URL" | sed -E 's#:#/#')
GIT_URL_HTTP=$(echo "$GIT_URL_HTTP" | sed -E 's#^git@#https://#')
GIT_URL_HTTP="${GIT_URL_HTTP%.git}"

# Nome di default per la config ricavato dal nome repo (usato per REPO_DIR e per i log)
DEFAULT_GITOPS_NAME="$(basename $GIT_URL_HTTP)"
if [[ "$SILENT" == true ]]; then
  GITOPS_CONFIG_NAME="${DEFAULT_GITOPS_NAME}"
else
  read -r -p "GitOps config name [${DEFAULT_GITOPS_NAME}]: " GITOPS_CONFIG_NAME
  GITOPS_CONFIG_NAME="${GITOPS_CONFIG_NAME:-$DEFAULT_GITOPS_NAME}"
fi
GITOPS_CONFIG_FILE="${GITOPS_CONFIG_DIR}/${GITOPS_CONFIG_NAME}.env"

GITOPS_CONFIG_SAVE=true
if [[ "$SILENT" == true ]]; then
  if [[ -f "${GITOPS_CONFIG_FILE}" ]]; then
    GITOPS_CONFIG_SAVE=false
  fi
else
  # Se il file .env esiste già, chiedi se sovrascriverlo
  if [[ -f "${GITOPS_CONFIG_FILE}" ]]; then
    echo "${GITOPS_CONFIG_FILE} already exists."
    read -r -p "Overwrite (y/N)? " GITOPS_OVERWRITE_ANSWER
    case "${GITOPS_OVERWRITE_ANSWER:-N}" in
      [yY]|[yY][eE][sS]) ;;
      *) GITOPS_CONFIG_SAVE=false ;;
    esac
  fi
fi
# Scrive il file .env con i parametri minimi; puoi aggiungere altre variabili (es. REPO_DIR personalizzato)
if [[ "$GITOPS_CONFIG_SAVE" == true ]]; then
  sudo -u ${SERVICE_USER} tee "${GITOPS_CONFIG_FILE}" >/dev/null <<EOF
REPO_DIR="${GITOPS_DATA_DIR}/${GITOPS_CONFIG_NAME}"
GIT_SSH_KEY="${GIT_SSH_KEY}"
GIT_URL="${GIT_URL}"
GIT_BRANCH="${GIT_BRANCH}"
ANSIBLE_VERBOSITY=0
PLAYBOOK="${PLAYBOOK}"
EOF
  if [[ -n "${INVENTORY:-}" ]]; then
    echo "INVENTORY=\"${INVENTORY}\"" | sudo -u ${SERVICE_USER} tee -a "${GITOPS_CONFIG_FILE}" >/dev/null
  fi
  if [[ "$RUN_LOCAL" == true ]]; then
    echo "RUN_LOCAL=true" | sudo -u ${SERVICE_USER} tee -a "${GITOPS_CONFIG_FILE}" >/dev/null
  fi
  if [[ -n "${NOTIFICATION_URL:-}" ]]; then
    echo "NOTIFICATION_URL=\"${NOTIFICATION_URL}\"" | sudo -u ${SERVICE_USER} tee -a "${GITOPS_CONFIG_FILE}" >/dev/null
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

Test the service manually:
  sudo systemctl start ${SERVICE_NAME}.service

If everything is OK, you can enable the timer:
  sudo systemctl enable --now ${TIMER_NAME}.timer

EOF
