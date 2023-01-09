terraform {
  required_version = ">= 0.13"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
    }
  }
}

# instance the provider
provider "libvirt" {
  uri = "qemu:///system"
}

module "base" {
  source = "./modules/base"
   # base_configuration = module.base.configuration 
  name = "test-openqa"
  image = "opensuse154o"
  ssh_key_path = "~/.ssh/id_rsa.pub"
  provider_settings = {
    memory = 8192
    vcpu = 4
    cpu_model = "host-passthrough"
    mac = "52:54:00:72:26:b8"
  }
  roles = ["openqa"]
}
