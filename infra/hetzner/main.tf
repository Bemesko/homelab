# Primary account password: restic only uses the SSH key, but the API requires a password.
# It lives only in the encrypted state (`tofu output -raw storage_box_password`).
resource "random_password" "storage_box" {
  length           = 32
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "-_+="
}

resource "hcloud_storage_box" "nas_offsite" {
  name             = "nas-offsite"
  storage_box_type = "bx11"
  location         = "fsn1"
  password         = random_password.storage_box.result

  labels = {
    "managed-by" = "opentofu"
    "purpose"    = "nas-offsite-backup"
  }

  # SFTP/SSH only (port 23), reachable from the home internet.
  access_settings = {
    reachable_externally = true
    ssh_enabled          = true
    samba_enabled        = false
    webdav_enabled       = false
    zfs_enabled          = false
  }

  # Snapshots on Hetzner's side, out of reach of the cluster's SSH key: if the restic
  # repository is deleted or corrupted, you can go back up to 7 days. They run at
  # 06:00 UTC (03:00 in Brasília), before the 04:00 backup, so they keep the state from
  # before that day's prune. No extra charge, but they use the box quota.
  snapshot_plan = {
    max_snapshots = 7
    hour          = 6
    minute        = 0
  }

  delete_protection = true

  # Public key of the restic CronJob; the private one is in
  # kubernetes/workloads/backup/overlays/nas/restic.sops.yaml.
  ssh_keys = [trimspace(file("${path.module}/restic_ed25519.pub"))]

  lifecycle {
    # The API cannot change SSH keys after creation: changing ssh_keys would recreate the
    # box (deleting the backup). To rotate the key, edit .ssh/authorized_keys on the box.
    ignore_changes  = [ssh_keys]
    prevent_destroy = true
  }
}
