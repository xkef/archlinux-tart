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

variable "tart_guest_agent_version" {
  type    = string
  default = "v0.9.0"
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

  # Core developer tooling. Running against a real booted system is both
  # more reliable than a chroot install and easy to iterate on: a failed
  # provisioner does not invalidate the bootstrap disk.
  provisioner "shell" {
    inline = [
      "sudo pacman -Sy --needed --noconfirm git rsync stow base-devel rust cloud-init"
    ]
  }

  # Tart Guest Agent: lets the host resolve the VM's IP via `tart ip
  # --resolver agent`. Not required for Packer itself (it connects over
  # the DHCP-assigned IP), so it lives here rather than in bootstrap.
  provisioner "file" {
    source      = "files/tart-guest-agent.service"
    destination = "/tmp/tart-guest-agent.service"
  }

  provisioner "shell" {
    environment_vars = [
      "TART_GUEST_AGENT_VERSION=${var.tart_guest_agent_version}",
    ]
    inline = [
      "curl -fsSL \"https://github.com/cirruslabs/tart-guest-agent/releases/download/$TART_GUEST_AGENT_VERSION/tart-guest-agent-linux-arm64.tar.gz\" -o /tmp/tart-guest-agent.tar.gz",
      "tar -xzf /tmp/tart-guest-agent.tar.gz -C /tmp",
      "sudo install -m 0755 /tmp/tart-guest-agent /usr/local/bin/tart-guest-agent",
      "sudo install -m 0644 /tmp/tart-guest-agent.service /etc/systemd/system/tart-guest-agent.service",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable tart-guest-agent.service",
      "rm -f /tmp/tart-guest-agent /tmp/tart-guest-agent.tar.gz /tmp/tart-guest-agent.service",
    ]
  }

  # Install paru from the AUR as the unprivileged dev user.
  provisioner "shell" {
    inline = [
      "git clone https://aur.archlinux.org/paru-bin.git /tmp/paru-bin",
      "cd /tmp/paru-bin && makepkg -si --noconfirm",
      "rm -rf /tmp/paru-bin",
    ]
  }
}
