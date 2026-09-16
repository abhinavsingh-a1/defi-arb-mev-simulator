# Generates a new key pair when create_new_key_pair = true, otherwise imports
# an existing public key from public_key_path.

resource "tls_private_key" "generated" {
  count     = var.create_new_key_pair ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "this" {
  key_name   = var.name
  public_key = var.create_new_key_pair ? tls_private_key.generated[0].public_key_openssh : file(var.public_key_path)
}

resource "local_sensitive_file" "private_key" {
  count           = var.create_new_key_pair ? 1 : 0
  content         = tls_private_key.generated[0].private_key_pem
  filename        = var.private_key_output_path
  file_permission = "0400"
}
