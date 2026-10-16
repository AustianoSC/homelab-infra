output "nodes" {
  description = "Cluster nodes and their addresses."
  value = {
    for name, node in module.node : name => {
      vm_id = node.vm_id
      ip    = node.ip_address
    }
  }
}
