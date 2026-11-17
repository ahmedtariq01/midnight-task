locals {
  components = {
    cardano_relay    = module.cardano_relay.component
    cardano_db_sync  = module.db_sync.component
    midnight_node    = module.midnight_node.component
    midnight_indexer = module.midnight_indexer.component
  }
  postgres_directory = "${local.data_dir}/postgresql/17/main"
  data_directories   = concat([for component in values(local.components) : component.data_directory], [local.postgres_directory])

  cloud_config = {
    write_files = concat([
      {
        path        = "/etc/midnight-stack/storage.env"
        permissions = "0600"
        content     = "VOLUME_ID=${aws_ebs_volume.data.id}\n"
      },
      {
        path        = "/etc/midnight-stack/network.env"
        permissions = "0644"
        content = join("\n", [
          "STACK_NETWORK=${var.environment}",
          "CARDANO_MAGIC=${local.network.cardano_magic == null ? "" : tostring(local.network.cardano_magic)}",
          "CARDANO_SECURITY_PARAMETER=${local.network.cardano_security_parameter}",
          "CARDANO_SOCKET_PATH=/run/cardano-node/node.socket",
          "MIDNIGHT_SYNC=full",
          "MIDNIGHT_STATE_PRUNING=archive",
          "MIDNIGHT_BLOCKS_PRUNING=archive",
          "",
        ])
      },
      {
        path        = "/usr/local/libexec/midnight-stack-mount"
        permissions = "0755"
        content     = file("${path.module}/bootstrap/mount.sh")
      },
      {
        path        = "/usr/local/libexec/midnight-stack-ready"
        permissions = "0755"
        content     = file("${path.module}/bootstrap/readiness.sh")
      },
      {
        path        = "/usr/local/libexec/midnight-stack-credentials"
        permissions = "0755"
        content     = file("${path.module}/bootstrap/credentials.sh")
      },
      {
        path        = "/etc/systemd/system/midnight-stack-storage.service"
        permissions = "0644"
        content     = templatefile("${path.module}/bootstrap/storage.service.tftpl", { directories = join(" ", local.data_directories) })
      },
      {
        path        = "/etc/systemd/system/midnight-stack-credentials@.service"
        permissions = "0644"
        content     = file("${path.module}/bootstrap/credentials.service")
      },
      {
        path        = "/etc/systemd/system/postgresql@17-main.service.d/10-stack-storage.conf"
        permissions = "0644"
        content     = "[Unit]\nRequires=midnight-stack-storage.service\nAfter=midnight-stack-storage.service\nRequiresMountsFor=${local.postgres_directory}\n"
      },
      module.cardano_relay.drop_in,
      module.db_sync.drop_in,
      module.midnight_node.drop_in,
      module.midnight_indexer.drop_in,
    ], module.db_sync.credential_config, module.midnight_node.credential_config, module.midnight_indexer.credential_config)
    runcmd = [
      ["systemctl", "daemon-reload"],
      ["systemctl", "enable", "--no-block", "--now", "midnight-stack-storage.service"],
    ]
  }
}
