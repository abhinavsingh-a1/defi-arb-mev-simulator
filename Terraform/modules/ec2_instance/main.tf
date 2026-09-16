# Latest Ubuntu 22.04 LTS AMI, resolved dynamically so the module is
# region-portable instead of hardcoding an AMI ID.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "this" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.vpc_security_group_ids
  key_name                    = var.key_name
  associate_public_ip_address = var.associate_public_ip
  user_data                   = var.user_data

  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type            = var.root_volume_type
    delete_on_termination = true
    encrypted              = true
  }

  metadata_options {
    http_tokens   = "required" # enforce IMDSv2
    http_endpoint = "enabled"
  }

  tags = merge(
    {
      Name = var.name
      Role = var.role
    },
    var.extra_tags
  )

  lifecycle {
    create_before_destroy = true
  }
}
