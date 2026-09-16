output "key_name" {
  value = aws_key_pair.this.key_name
}

output "private_key_path" {
  value       = var.create_new_key_pair ? local_sensitive_file.private_key[0].filename : var.public_key_path
  description = "Local path to the private key when generated. Only meaningful when create_new_key_pair = true."
}
