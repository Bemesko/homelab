# Read by scripts/backup-fill-secret.sh to build the cluster's RESTIC_REPOSITORY.
# Sensitive so they do not show up in logs: the username and FQDN identify the account.
output "storage_box_username" {
  value     = hcloud_storage_box.nas_offsite.username
  sensitive = true
}

output "storage_box_server" {
  value     = hcloud_storage_box.nas_offsite.server
  sensitive = true
}

output "storage_box_password" {
  value     = random_password.storage_box.result
  sensitive = true
}
