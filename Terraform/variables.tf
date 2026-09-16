variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Short name used as a prefix for all resource names/tags."
  type        = string
  default     = "besu-infra"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric/hyphen, 3-21 chars, starting with a letter."
  }
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones"
  type        = list(string)
  default     = ["us-west-2a", "us-west-2b", "us-west-2c"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
}

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed to reach instances over SSH (22). Restrict this to your own IP/32 in real use."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0
    error_message = "ssh_allowed_cidrs must contain at least one CIDR block."
  }
}

variable "app_allowed_cidrs" {
  description = "CIDR blocks allowed to reach application ports (Besu RPC, Jenkins UI, Grafana, Nexus, etc)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "create_new_key_pair" {
  description = "If true, Terraform generates a new SSH key pair and saves the private key locally. If false, provide public_key_path."
  type        = bool
  default     = true
}

variable "public_key_path" {
  description = "Path to an existing public key file, used when create_new_key_pair = false."
  type        = string
  default     = ""
}

variable "private_key_output_path" {
  description = "Local path where the generated private key (.pem) will be written when create_new_key_pair = true."
  type        = string
  default     = "./generated/besu-infra-key.pem"
}

# Free tier note: AWS Free Tier grants 750 combined hours/month of t2.micro or
# t3.micro (12 months for new accounts). Running 6 instances 24/7 exceeds
# that. instance_type is overridable per-node in locals.tf if you need more
# headroom for Jenkins/Nexus/Kubernetes.
variable "default_instance_type" {
  description = "Default EC2 instance type applied to nodes that don't override it (free-tier eligible)."
  type        = string
  default     = "t3.micro"
}

variable "root_volume_type" {
  description = "EBS root volume type."
  type        = string
  default     = "gp3"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "my-eks-cluster"
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.30"
}

variable "node_groups" {
  description = "EKS node group configuration"
  type = map(object({
    instance_types = list(string)
    capacity_type  = string
    scaling_config = object({
      desired_size = number
      max_size     = number
      min_size     = number
    })
  }))
  default = {
    general = {
      instance_types = ["t3.micro"]
      capacity_type  = "ON_DEMAND"
      scaling_config = {
        desired_size = 2
        max_size     = 4
        min_size     = 1
      }
    }
  }
}
