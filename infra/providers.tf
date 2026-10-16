terraform {
  required_version = ">= 1.8"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.116"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# Authentication comes from the environment: PROXMOX_VE_API_TOKEN
# SSH is used for the few operations the API can't do (uploading cloud-init
# snippets), authenticating through the running ssh-agent as root.
provider "proxmox" {
  endpoint = "https://homelab.internal:8006/"
  # The host uses Proxmox's self-signed certificate.
  insecure = true

  ssh {
    agent    = true
    username = "root"
  }
}
