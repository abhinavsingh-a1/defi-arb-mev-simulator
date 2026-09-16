module "vpc" {
  source = "./modules/vpc"

  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  private_subnet_cidrs = var.private_subnet_cidrs
  public_subnet_cidrs  = var.public_subnet_cidrs
  cluster_name         = var.cluster_name
}

module "network" {
  source = "./modules/network"

  name_prefix         = local.name_prefix
  vpc_cidr            = var.vpc_cidr
  public_subnet_cidr  = var.public_subnet_cidrs[0]
}

module "key_pair" {
  source = "./modules/key_pair"

  name                     = "${local.name_prefix}-key"
  create_new_key_pair      = var.create_new_key_pair
  public_key_path          = var.public_key_path
  private_key_output_path  = var.private_key_output_path
}

module "security_group" {
  source   = "./modules/security_group"
  for_each = local.instances

  name          = "${local.name_prefix}-${each.key}-sg"
  vpc_id        = module.network.vpc_id
  ingress_rules = each.value.ingress_rules
}

module "instance" {
  source   = "./modules/ec2_instance"
  for_each = local.instances

  name                    = "${local.name_prefix}-${each.key}"
  role                    = each.value.role
  instance_type           = each.value.instance_type
  subnet_id               = module.network.public_subnet_id
  vpc_security_group_ids  = [module.security_group[each.key].id]
  key_name                = module.key_pair.key_name
  root_volume_size_gb     = each.value.root_volume_size_gb
  root_volume_type        = var.root_volume_type
  user_data               = local.bootstrap_user_data
}

# Renders a ready-to-use Ansible inventory from the instances Terraform just
# created, grouped by role, so `ansible/inventory/hosts.ini` never has to be
# hand-maintained.
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/generated/hosts.ini"
  content = templatefile("${path.module}/templates/inventory.tpl", {
    instances       = module.instance
    private_key_path = module.key_pair.private_key_path
  })
}
