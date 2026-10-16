locals {
  # Admin user created on every node by cloud-init.
  admin_user = "austin"

  # Public keys allowed to log in to the nodes. Public keys are safe to
  # commit. They live here, not in per-machine files, so every machine
  # (WSL desktop, MacBook) renders identical cloud-init and `tofu plan` reports
  # no changes. Add the MacBook's key (`cat ~/.ssh/id_ed25519.pub`) to this
  # list before working from it.
  ssh_public_keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICnpOHYq33NoIVrXtSqS5wXWmVuRFsZjFxNp1guHc2Fm wsl-desktop",
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOEWAC14hfDesqPfXEbAeWnlQswxy7Vz/D5eCORuBQZe m2-macbook"
  ]
}
