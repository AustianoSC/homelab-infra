# Ubuntu 24.04 cloud image, pinned to a dated release and verified against its
# published checksum so a rebuild months from now gets the same bytes. To
# upgrade, change the date in the URL and the checksum together (the checksum
# is in https://cloud-images.ubuntu.com/noble/<date>/SHA256SUMS).
#
# Proxmox requires the `import` content type to use a .qcow2 file name even
# though the download is a .img file.
resource "proxmox_download_file" "ubuntu_noble" {
  node_name    = local.proxmox_node
  datastore_id = "local"
  content_type = "import"

  url                = "https://cloud-images.ubuntu.com/noble/20260926/noble-server-cloudimg-amd64.img"
  file_name          = "noble-server-cloudimg-amd64-20260926.qcow2"
  checksum           = "6a81c37564db9b1ee84e141922625e1d7c5b389b99bb3c572e0243607d5bb4d2"
  checksum_algorithm = "sha256"
}
