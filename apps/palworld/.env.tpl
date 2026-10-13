# 1Password secret references. Safe to commit: these are pointers, not values.
#
# Generate the real .env (gitignored) with:
#   op inject -i .env.tpl -o .env
#
# Non-secret configuration lives in compose.yaml, not here.

PALWORLD_SERVER_PASSWORD=op://homelab/palworld/server-password
PALWORLD_ADMIN_PASSWORD=op://homelab/palworld/admin-password
