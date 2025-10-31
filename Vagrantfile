Vagrant.configure("2") do |config|
  config.vm.box = "debian/bookworm64"
  config.vm.hostname = "test-ansible-gitops"
  config.vm.provider "virtualbox" do |vb|
    vb.cpus = 1
    vb.memory = 1024
  end
  config.ssh.username = "vagrant"
  config.vm.provision "shell", inline: <<-SHELL
    sudo timedatectl set-timezone Europe/Rome
    sudo sed -i 's/^#PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sudo sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sudo systemctl restart sshd
    echo "vagrant:vagrant" | sudo chpasswd
  SHELL
end
