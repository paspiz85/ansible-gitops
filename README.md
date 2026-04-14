# ansible-gitops

> [English version](#english)

> Script di installazione del software di base per progetti GitOps.

### 📦 Installazione

Lanciare la procedura guidata con:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/paspiz85/ansible-gitops/main/install.sh)
```

Per aggiornare:

```bash
bash <(curl -fsSL -H 'Cache-Control: no-cache, no-store, must-revalidate' -H 'Pragma: no-cache' https://raw.githubusercontent.com/paspiz85/ansible-gitops/main/install.sh) -s
```

---

### ▶️ Esecuzione manuale

Per eseguire l'aggiornamento degli ambienti configurati:

```bash
sudo systemctl start ansible-gitops.service
```

Se è necessario forzare l'esecuzione si può eliminare il repository locale, con:

```bash
sudo ansible-gitops --reset -e test-infra
```

---

### 🕓 Esecuzione temporizzata

Per attivare l'esecuzione automatica:

```bash
sudo systemctl enable --now ansible-gitops.timer
```

Per disattivare l'esecuzione automatica:

```bash
sudo systemctl disable ansible-gitops.timer
```

---

### 👤 Configurazione utente ansible su altre macchine

Accedere alla macchina remota con un utente con privilegi amministrativi e creare l'utente con:

```bash
sudo useradd --create-home --shell /bin/bash ansible
echo "ansible ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/010_ansible-nopasswd
sudo -u ansible install -d -m 700 ~ansible/.ssh
sudo -u ansible install -D -m 600 ~ansible/.ssh/authorized_keys
sudo -u ansible cat ~ansible/.ssh/id_ed25519_ansible_gitops.pub >> ~ansible/.ssh/authorized_keys
```

---

### 🧪 Ambiente di test

Installare [Vagrant](https://developer.hashicorp.com/vagrant) e [VirtualBox](https://www.virtualbox.org/),
poi dalla cartella di questo progetto avviare la macchina virtuale ed accedere con la password ```vagrant```:

```bash
vagrant up
ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null vagrant@localhost
sudo apt update
sudo apt install -y curl
bash <(curl -fsSL https://raw.githubusercontent.com/paspiz85/ansible-gitops/main/install.sh) \
 -u git@github.com:paspiz85/ansible-gitops.git
sudo systemctl start ansible-gitops.service
cat /var/log/ansible-gitops/ansible-gitops.log
```

Per spegnere e distruggere la macchina virtuale:

```bash
vagrant halt
vagrant destroy
```

---

### 📦 Disinstallazione

Lanciare la procedura guidata con:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/paspiz85/ansible-gitops/main/uninstall.sh)
```

---

### 🔗 Link Utili

- https://www.techsyncer.com/it/what-is-ansible.html
- https://learnansible.dev/article/Getting_Started_with_Ansible_A_Beginners_Guide.html

---

# ansible-gitopt (english version)

> Base software installation script for GitOps projects.

### 📦 Installation

Run the guided setup with:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/paspiz85/ansible-gitops/main/install.sh)
```

To update:

```bash
bash <(curl -fsSL -H 'Cache-Control: no-cache, no-store, must-revalidate' -H 'Pragma: no-cache' https://raw.githubusercontent.com/paspiz85/ansible-gitops/main/install.sh) -s
```

---

### ▶️ Manual execution

To trigger an update of all configured environments:

```bash
sudo systemctl start ansible-gitops.service
```

To force execution, you can delete the local repository clone with:

```bash
sudo ansible-gitops --reset -e test-infra
```

---

### 🕓 Scheduled execution

To enable automatic execution:

```bash
sudo systemctl enable --now ansible-gitops.timer
```

To disable automatic execution:

```bash
sudo systemctl disable ansible-gitops.timer
```

---

### 👤 Configuring the ansible user on remote machines

Log into the remote machine with an administrative user and create the user with:

```bash
sudo useradd --create-home --shell /bin/bash ansible
echo "ansible ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/010_ansible-nopasswd
sudo -u ansible install -d -m 700 ~ansible/.ssh
sudo -u ansible install -D -m 600 ~ansible/.ssh/authorized_keys
sudo -u ansible cat ~ansible/.ssh/id_ed25519_ansible_gitops.pub >> ~ansible/.ssh/authorized_keys
```

---

### 🧪 Test environment

Install [Vagrant](https://developer.hashicorp.com/vagrant) and [VirtualBox](https://www.virtualbox.org/),
then from the project folder start the virtual machine and log in with the password ```vagrant```:

```bash
vagrant up
ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null vagrant@localhost
sudo apt update
sudo apt install -y curl
bash <(curl -fsSL https://raw.githubusercontent.com/paspiz85/ansible-gitops/main/install.sh) \
 -u git@github.com:paspiz85/ansible-gitops.git
sudo systemctl start ansible-gitops.service
cat /var/log/ansible-gitops/ansible-gitops.log
```

To stop and destroy the virtual machine:

```bash
vagrant halt
vagrant destroy
```

---

### 📦 Uninstallation

Run the guided setup with:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/paspiz85/ansible-gitops/main/uninstall.sh)
```

---

### 🔗 Useful links

- https://www.techsyncer.com/it/what-is-ansible.html
- https://learnansible.dev/article/Getting_Started_with_Ansible_A_Beginners_Guide.html
