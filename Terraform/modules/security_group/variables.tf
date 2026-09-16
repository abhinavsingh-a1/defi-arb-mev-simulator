variable "name" {
  description = "Name for the security group."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "ingress_rules" {
  description = "List of ingress rules to open on this security group."
  type = list(object({
    description = string
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
  }))
  default = []
}

variable "egress_cidr_blocks" {
  description = "CIDR blocks allowed for all outbound traffic."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
