locals {
  proxmox_node = "homelab"

  # Network shared by every node.
  gateway     = "192.168.8.1"
  dns_servers = ["192.168.8.1"]

  # Where each kind of disk lives (see docs/bootstrap.md).
  boot_datastore    = "nvme-ssd-1tb"
  data_datastore    = "sata-ssd-1tb"
  snippet_datastore = "nvme-ssd-1tb"

  # Single source of truth for the cluster. Everything else (VMs, Ansible
  # inventory) is derived from this map. memory is in MiB, disks in GiB.
  nodes = {
    k3s-cp-1 = {
      vmid      = 301
      ip        = "192.168.8.11"
      role      = "server"
      cores     = 2
      memory    = 3072
      boot_disk = 30
      data_disk = 0
    }
    k3s-worker-1 = {
      vmid      = 311
      ip        = "192.168.8.12"
      role      = "agent"
      cores     = 8
      memory    = 16384
      boot_disk = 30
      data_disk = 100
    }
    k3s-worker-2 = {
      vmid      = 312
      ip        = "192.168.8.13"
      role      = "agent"
      cores     = 6
      memory    = 8192
      boot_disk = 30
      data_disk = 50
    }
  }
}

module "node" {
  source   = "./modules/proxmox-vm"
  for_each = local.nodes

  name      = each.key
  vm_id     = each.value.vmid
  node_name = local.proxmox_node
  role      = each.value.role

  cores     = each.value.cores
  memory    = each.value.memory
  boot_disk = each.value.boot_disk
  data_disk = each.value.data_disk

  ip_address  = each.value.ip
  gateway     = local.gateway
  dns_servers = local.dns_servers

  image_id          = proxmox_download_file.ubuntu_noble.id
  boot_datastore    = local.boot_datastore
  data_datastore    = local.data_datastore
  snippet_datastore = local.snippet_datastore

  username        = local.admin_user
  ssh_public_keys = local.ssh_public_keys
}
