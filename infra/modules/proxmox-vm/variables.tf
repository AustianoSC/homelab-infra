variable "name" {
  description = "VM and hostname."
  type        = string
}

variable "vm_id" {
  description = "Proxmox VM ID."
  type        = number
}

variable "node_name" {
  description = "Proxmox node to create the VM on."
  type        = string
}

variable "role" {
  description = "k3s role, used as a tag: server or agent."
  type        = string

  validation {
    condition     = contains(["server", "agent"], var.role)
    error_message = "role must be \"server\" or \"agent\"."
  }
}

variable "cores" {
  type = number
}

variable "memory" {
  description = "RAM in MiB. Ballooning is disabled, so this is fixed."
  type        = number
}

variable "boot_disk" {
  description = "Boot disk size in GiB."
  type        = number
}

variable "data_disk" {
  description = "Second disk size in GiB, mounted for k3s local-path volumes. 0 for none."
  type        = number
  default     = 0
}

variable "ip_address" {
  description = "Static IPv4 address, without a prefix length (a /24 is assumed)."
  type        = string
}

variable "gateway" {
  type = string
}

variable "dns_servers" {
  type = list(string)
}

variable "image_id" {
  description = "ID of the cloud image to import as the boot disk."
  type        = string
}

variable "boot_datastore" {
  type = string
}

variable "data_datastore" {
  type = string
}

variable "snippet_datastore" {
  description = "Datastore for the cloud-init user-data snippet (needs the snippets content type)."
  type        = string
}

variable "username" {
  description = "Admin user created by cloud-init."
  type        = string
}

variable "ssh_public_keys" {
  type = list(string)
}
