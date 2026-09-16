variable "name_prefix" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "public_subnet_cidr" {
  type = string
}

variable "availability_zone" {
  description = "AZ for the public subnet. Leave null to let AWS pick the first available AZ."
  type        = string
  default     = null
}
