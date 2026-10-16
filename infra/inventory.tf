# Renders the Ansible inventory from the same node map that creates the VMs, so
# the two can't drift apart.
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory/hosts.yml"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/hosts.yml.tftpl", {
    admin_user = local.admin_user
    nodes      = local.nodes
  })
}
