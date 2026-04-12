packer {
  required_plugins {
    tart = {
      source  = "github.com/cirruslabs/tart"
      version = ">= 1.7.0"
    }
  }
}

variable "vm_name" {
  type = string
}

variable "cpu_count" {
  type    = number
  default = 4
}

variable "memory_gb" {
  type    = number
  default = 8
}

variable "ssh_username" {
  type    = string
  default = "dev"
}

variable "ssh_password" {
  type    = string
  default = "dev"
}

source "tart-cli" "arch" {
  vm_name      = var.vm_name
  cpu_count    = var.cpu_count
  memory_gb    = var.memory_gb
  headless     = true
  disable_vnc  = true
  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  ssh_timeout  = "10m"
}

build {
  sources = ["source.tart-cli.arch"]

  provisioner "shell" {
    inline = [
      "sudo pacman -Syu --needed --noconfirm git rsync stow base-devel rust fish",
      "sudo hostnamectl set-hostname arch",
      "sudo sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen",
      "sudo locale-gen",
      "echo 'LANG=en_US.UTF-8' | sudo tee /etc/locale.conf",
      "sudo userdel -r alarm 2>/dev/null || true",
      "sudo chsh -s /usr/bin/fish dev",
    ]
  }

  provisioner "file" {
    source      = "files/tart-guest-agent.service"
    destination = "/tmp/tart-guest-agent.service"
  }

  provisioner "shell" {
    inline = [
      "curl -fsSL https://github.com/cirruslabs/tart-guest-agent/releases/latest/download/tart-guest-agent-linux-arm64.tar.gz -o /tmp/tart-guest-agent.tar.gz",
      "tar -xzf /tmp/tart-guest-agent.tar.gz -C /tmp",
      "sudo install -m 0755 /tmp/tart-guest-agent /usr/local/bin/tart-guest-agent",
      "sudo install -m 0644 /tmp/tart-guest-agent.service /etc/systemd/system/tart-guest-agent.service",
      "rm -f /tmp/tart-guest-agent /tmp/tart-guest-agent.tar.gz /tmp/tart-guest-agent.service",
    ]
  }

  provisioner "file" {
    source      = "files/home-dev-code.mount"
    destination = "/tmp/home-dev-code.mount"
  }

  provisioner "shell" {
    inline = [
      "sudo install -m 0644 /tmp/home-dev-code.mount /etc/systemd/system/home-dev-code.mount",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable tart-guest-agent.service home-dev-code.mount",
      "install -d -m 755 ~/code",
      "rm -f /tmp/home-dev-code.mount",
    ]
  }

  provisioner "shell" {
    inline = [
      "git clone https://aur.archlinux.org/paru.git /tmp/paru",
      "cd /tmp/paru && makepkg -si --noconfirm",
      "rm -rf /tmp/paru",
      "paru --version",
    ]
  }

  provisioner "shell" {
    inline = [
      "sudo rm -rf /var/cache/pacman/pkg/*",
      "sudo passwd -l dev",
    ]
  }
}
