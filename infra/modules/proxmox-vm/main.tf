locals {
  has_data_disk = var.data_disk > 0

  # k3s' local-path provisioner stores volumes here by default, so mounting the
  # SATA SSD disk here puts game data on it without extra configuration.
  data_mount = "/var/lib/rancher/k3s/storage"

  user_data = templatefile("${path.module}/user-data.yaml.tftpl", {
    hostname        = var.name
    username        = var.username
    ssh_public_keys = var.ssh_public_keys
    has_data_disk   = local.has_data_disk
    data_mount      = local.data_mount
  })
}

resource "proxmox_virtual_environment_file" "user_data" {
  node_name    = var.node_name
  datastore_id = var.snippet_datastore
  content_type = "snippets"

  source_raw {
    file_name = "${var.name}-user-data.yaml"
    data      = local.user_data
  }
}

resource "proxmox_virtual_environment_vm" "this" {
  name      = var.name
  node_name = var.node_name
  vm_id     = var.vm_id
  tags      = sort(["k3s", var.role, "opentofu"])

  on_boot = true
  started = true
  # Shut the guest down cleanly (via the agent) before destroying it.
  stop_on_destroy = true

  scsi_hardware = "virtio-scsi-single"

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true
  }

  cpu {
    cores = var.cores
    type  = "host"
  }

  # floating = 0 disables ballooning. The kubelet reads node memory once at
  # startup, so a balloon that changes it later would make scheduling wrong.
  memory {
    dedicated = var.memory
    floating  = 0
  }

  disk {
    datastore_id = var.boot_datastore
    import_from  = var.image_id
    interface    = "scsi0"
    size         = var.boot_disk
    file_format  = "qcow2"
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  dynamic "disk" {
    for_each = local.has_data_disk ? [1] : []
    content {
      datastore_id = var.data_datastore
      interface    = "scsi1"
      size         = var.data_disk
      file_format  = "qcow2"
      discard      = "on"
      ssd          = true
      iothread     = true
    }
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  # Ubuntu cloud images expect a serial console.
  serial_device {}

  initialization {
    datastore_id = var.boot_datastore

    ip_config {
      ipv4 {
        address = "${var.ip_address}/24"
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    user_data_file_id = proxmox_virtual_environment_file.user_data.id
  }

  lifecycle {
    # The boot disk is imported once from the image. A newer image must not
    # recreate a running node; replace nodes deliberately instead.
    ignore_changes = [disk[0].import_from]
  }
}
