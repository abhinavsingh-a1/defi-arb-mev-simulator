variable "name" {
  description = "Name tag / logical identifier for this instance."
  type        = string
}

variable "role" {
  description = "Role tag, e.g. besu-node, jenkins, nexus. Used by Ansible dynamic grouping too."
  type        = string
}

variable "instance_type" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "vpc_security_group_ids" {
  type = list(string)
}

variable "key_name" {
  type = string
}

variable "root_volume_size_gb" {
  type    = number
  default = 10
}

variable "root_volume_type" {
  type    = string
  default = "gp3"
}

variable "associate_public_ip" {
  type    = bool
  default = true
}

variable "user_data" {
  description = "Cloud-init/user-data script. Kept minimal; Ansible does the real configuration."
  type        = string
  default     = null
}

variable "extra_tags" {
  type    = map(string)
  default = {}
}
