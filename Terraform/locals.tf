locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_ssh_rule = {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidrs
  }

  # One entry per requested EC2 instance. instance_type / root_volume_size_gb
  # can be overridden here per-node when you outgrow t2.micro (Jenkins and
  # the k8s node are the most likely candidates).
  instances = {
    besu-node = {
      role                 = "besu-node"
      instance_type        = var.default_instance_type
      root_volume_size_gb  = 15
      ingress_rules = [
        local.common_ssh_rule,
        {
          description = "Besu JSON-RPC"
          from_port   = 8545
          to_port     = 8546
          protocol    = "tcp"
          cidr_blocks = var.app_allowed_cidrs
        },
        {
          description = "Besu P2P"
          from_port   = 30303
          to_port     = 30303
          protocol    = "tcp"
          cidr_blocks = ["0.0.0.0/0"]
        },
      ]
    }

    besu-validator = {
      role                = "besu-validator"
      instance_type       = var.default_instance_type
      root_volume_size_gb = 15
      ingress_rules = [
        local.common_ssh_rule,
        {
          description = "Besu JSON-RPC"
          from_port   = 8545
          to_port     = 8545
          protocol    = "tcp"
          cidr_blocks = var.app_allowed_cidrs
        },
        {
          description = "Besu P2P"
          from_port   = 30303
          to_port     = 30303
          protocol    = "tcp"
          cidr_blocks = ["0.0.0.0/0"]
        },
      ]
    }

    nodejs-k8s = {
      role                = "nodejs-k8s"
      instance_type       = var.default_instance_type
      root_volume_size_gb = 12
      ingress_rules = [
        local.common_ssh_rule,
        {
          description = "Node.js app"
          from_port   = 3000
          to_port     = 3000
          protocol    = "tcp"
          cidr_blocks = var.app_allowed_cidrs
        },
        {
          description = "k3s API server"
          from_port   = 6443
          to_port     = 6443
          protocol    = "tcp"
          cidr_blocks = var.app_allowed_cidrs
        },
        {
          description = "NodePort range"
          from_port   = 30000
          to_port     = 32767
          protocol    = "tcp"
          cidr_blocks = var.app_allowed_cidrs
        },
      ]
    }

    monitoring = {
      role                = "monitoring"
      instance_type       = var.default_instance_type
      root_volume_size_gb = 12
      ingress_rules = [
        local.common_ssh_rule,
        {
          description = "Prometheus"
          from_port   = 9090
          to_port     = 9090
          protocol    = "tcp"
          cidr_blocks = var.app_allowed_cidrs
        },
        {
          description = "Grafana"
          from_port   = 3000
          to_port     = 3000
          protocol    = "tcp"
          cidr_blocks = var.app_allowed_cidrs
        },
      ]
    }

    # Jenkins + Maven + SonarQube + Trivy + Nexus-client + Docker + kubectl +
    # kubeaudit + Prometheus/Grafana plugins all on one box. This is heavy;
    # t2.micro (1GB RAM) is realistically NOT enough to run this stack. It
    # defaults to t3.medium here rather than the free-tier default -- change
    # to var.default_instance_type if you want to force free tier and accept
    # that Jenkins/SonarQube will struggle or fail to start.
    jenkins = {
      role                = "jenkins"
      instance_type       = var.default_instance_type
      root_volume_size_gb = 30
      ingress_rules = [
        local.common_ssh_rule,
        {
          description = "Jenkins UI"
          from_port   = 8080
          to_port     = 8080
          protocol    = "tcp"
          cidr_blocks = var.app_allowed_cidrs
        },
        {
          description = "SonarQube UI"
          from_port   = 9000
          to_port     = 9000
          protocol    = "tcp"
          cidr_blocks = var.app_allowed_cidrs
        },
      ]
    }

    nexus = {
      role                = "nexus"
      instance_type       = var.default_instance_type
      root_volume_size_gb = 20
      ingress_rules = [
        local.common_ssh_rule,
        {
          description = "Nexus repository UI"
          from_port   = 8081
          to_port     = 8081
          protocol    = "tcp"
          cidr_blocks = var.app_allowed_cidrs
        },
      ]
    }
  }

  # Minimal cloud-init: update packages and make sure python3 is present so
  # Ansible can connect immediately. All real configuration happens in the
  # Ansible project.
  bootstrap_user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    apt-get update -y
    apt-get install -y python3 python3-apt
  EOT
}
