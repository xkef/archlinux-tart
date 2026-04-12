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

  # Core developer tooling. Running against a real booted system is both
  # more reliable than a chroot install and easy to iterate on: a failed
  # provisioner does not invalidate the bootstrap disk.
  provisioner "shell" {
    inline = [
      "sudo pacman -Sy --needed --noconfirm git rsync stow base-devel rust cloud-init"
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
