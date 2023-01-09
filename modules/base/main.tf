locals {
  resource_name_prefix = "${var.name}"
  images_used =  var.image
    image_urls = {
    opensuse154o    = "https://download.opensuse.org/distribution/leap/15.4/appliances/openSUSE-Leap-15.4-JeOS.x86_64-OpenStack-Cloud.qcow2"
  }
  manufacturer = lookup(var.provider_settings, "manufacturer", "Intel")
  product      = lookup(var.provider_settings, "product", "Genuine")
  provider_settings = merge({
    memory          = 1024
    vcpu            = 1
    running         = true
    mac             = null
    cpu_model       = "custom"
    xslt            = null
    },
    var.provider_settings)
  cloud_init = length(regexall("o$", var.image)) > 0
  pool               = lookup(var.provider_settings, "pool", "default")
  network_name       = lookup(var.provider_settings, "network_name", "default")
  bridge             = lookup(var.provider_settings, "bridge", null)
}


resource "libvirt_volume" "volumes" {
  name   = "${var.name}"
  source = local.image_urls[var.image]
  pool   = local.pool
}


data "template_file" "user_data" {
  template = file("${path.module}/user_data.yaml")
  vars = {
    image               = var.image
    install_salt_bundle = var.install_salt_bundle
  }
}

data "template_file" "network_config" {
  template = file("${path.module}/network_config.yaml")
  vars = {
    image = var.image
  }
}

resource "libvirt_volume" "main_disk" {
  name             = "${local.resource_name_prefix}${var.quantity > 1 ? "-${count.index + 1}" : ""}-main-disk"
  base_volume_name = "${var.name}"
  pool             = local.pool
  size             = 107374182400
  count            = var.quantity
}

resource "libvirt_volume" "data_disk" {
  name  = "${local.resource_name_prefix}${var.quantity > 1 ? "-${count.index + 1}" : ""}-data-disk"
  // needs to be converted to bytes
  size  = (var.additional_disk_size == null? 0: var.additional_disk_size) * 1024 * 1024 * 1024
  pool  = lookup(var.provider_settings, "pool", "default")
  count = var.additional_disk_size == null? 0 : var.additional_disk_size > 0 ? var.quantity : 0
}

resource "libvirt_cloudinit_disk" "cloudinit_disk" {
  name           = "${local.resource_name_prefix}${var.quantity > 1 ? "-${count.index + 1}" : ""}-cloudinit-disk"
  user_data      = data.template_file.user_data.rendered
  network_config = data.template_file.network_config.rendered
  pool             = local.pool
  count            = local.cloud_init ? var.quantity : 0
}


resource "libvirt_domain" "domain" {
  name       = "${local.resource_name_prefix}${var.quantity > 1 ? "-${count.index + 1}" : ""}"
  memory     = local.provider_settings["memory"]
  vcpu       = local.provider_settings["vcpu"]
  running    = local.provider_settings["running"]
  count      = var.quantity
  qemu_agent = true

  // copy host CPU model to guest to get the vmx flag if present
  # cpu = {
  #   mode = local.provider_settings["cpu_model"]
  # }

  // base disk + additional disks if any
  dynamic "disk" {
    for_each = concat(
      length(libvirt_volume.main_disk) == var.quantity ? [{"volume_id" : libvirt_volume.main_disk[count.index].id}] : [],
      length(libvirt_volume.data_disk) == var.quantity ? [{"volume_id" : libvirt_volume.data_disk[count.index].id}] : []
    )
    content {
      volume_id = disk.value.volume_id
    }
  }

  cloudinit = length(libvirt_cloudinit_disk.cloudinit_disk) == var.quantity ? libvirt_cloudinit_disk.cloudinit_disk[count.index].id : null

  network_interface {
    wait_for_lease = true
    network_name   = local.network_name
    network_id     = null
    bridge         = local.bridge
    mac            = local.provider_settings["mac"]
  }

  console {
    type           = "pty"
    target_port    = "0"
    target_type    = "serial"
    source_host    = null
    source_service = null
  }

  console {
    type           = "pty"
    target_port    = "1"
    target_type    = "virtio"
    source_host    = null
    source_service = null
  }

 video {
      type = "virtio"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
    listen_address = "127.0.0.1"
    autoport    = true
  }

  xml {
    xslt = local.provider_settings["xslt"]
  }
}

resource "null_resource" "provisioning" {
  depends_on = [libvirt_domain.domain]

  triggers = {
    main_volume_id = length(libvirt_volume.main_disk) == var.quantity ? libvirt_volume.main_disk[count.index].id : null
    domain_id      = length(libvirt_domain.domain) == var.quantity ? libvirt_domain.domain[count.index].id : null
    grains_subset = yamlencode(
      {
        roles                     = var.roles
        use_os_released_updates   = var.use_os_released_updates
        use_os_unreleased_updates = var.use_os_unreleased_updates
        install_salt_bundle       = var.install_salt_bundle
        additional_repos          = var.additional_repos
        additional_repos_only     = var.additional_repos_only
        additional_certs          = var.additional_certs
        additional_packages       = var.additional_packages
        swap_file_size            = var.swap_file_size
        authorized_keys           = var.ssh_key_path
        gpg_keys                  = var.gpg_keys
        ipv6                      = var.ipv6
    })
  }

  count = var.provision ? var.quantity : 0

  connection {
    host     = libvirt_domain.domain[count.index].network_interface[0].addresses[0]
    user     = "root"
    password = "linux"
  }

  provisioner "file" {
    source      = "salt"
    destination = "/root"
  }
  
  provisioner "remote-exec" {
    inline = local.cloud_init ? [
      "bash /root/salt/wait_for_salt.sh",
    ] : ["bash -c \"echo 'no cloud init, nothing to do'\""]
  }

  provisioner "file" {
    content = yamlencode(merge(
      {
        hostname                  = "${local.resource_name_prefix}${var.quantity > 1 ? "-${count.index + 1}" : ""}"
        roles                     = var.roles
        use_os_released_updates   = var.use_os_released_updates
        use_os_unreleased_updates = var.use_os_unreleased_updates
        install_salt_bundle       = var.install_salt_bundle
        additional_repos          = var.additional_repos
        additional_repos_only     = var.additional_repos_only
        additional_certs          = var.additional_certs
        additional_packages       = var.additional_packages
        swap_file_size            = var.swap_file_size
        authorized_keys           = var.ssh_key_path
        gpg_keys                      = var.gpg_keys
        reset_ids                     = true
        ipv6                          = var.ipv6
        data_disk_device              = contains(var.roles, "server") || contains(var.roles, "proxy") || contains(var.roles, "mirror") || contains(var.roles, "jenkins") ? "vdb" : null
        provider                      = "libvirt"
      },
    var.grains))
    destination = "/etc/salt/grains"
  }

  provisioner "remote-exec" {
    inline = [
      "bash /root/salt/first_deployment_highstate.sh",
    ]
  }

  provisioner "remote-exec" {
    inline = [
      "bash /root/salt/post_provisioning_cleanup.sh",
    ]
  }
}

output "configuration" {
  depends_on = [libvirt_domain.domain, null_resource.provisioning]
  value = {
    ids       = libvirt_domain.domain[*].id
//    hostnames = [for value_used in libvirt_domain.domain : "${value_used.name}.${var.base_configuration["domain"]}"]
    macaddrs  = [for value_used in libvirt_domain.domain : value_used.network_interface[0].mac if length(value_used.network_interface) > 0]
    ipaddrs  = [for value_used in libvirt_domain.domain : value_used.network_interface[0].addresses if length(value_used.network_interface) > 0]
  }
}
