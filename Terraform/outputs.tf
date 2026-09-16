output "instance_public_ips" {
  description = "Public IP of every created instance, keyed by role."
  value       = { for k, i in module.instance : k => i.public_ip }
}

output "instance_ids" {
  value = { for k, i in module.instance : k => i.id }
}

output "ssh_private_key_path" {
  description = "Local path to the SSH private key (only set when create_new_key_pair = true)."
  value       = module.key_pair.private_key_path
}

output "ssh_commands" {
  description = "Ready-to-copy SSH commands for each instance."
  value = {
    for k, i in module.instance :
    k => "ssh -i ${module.key_pair.private_key_path} ubuntu@${i.public_ip}"
  }
}

output "ansible_inventory_path" {
  description = "Generated Ansible inventory file."
  value       = local_file.ansible_inventory.filename
}
