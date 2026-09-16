variable "name" {
  type = string
}

variable "create_new_key_pair" {
  type    = bool
  default = true
}

variable "public_key_path" {
  type    = string
  default = ""
}

variable "private_key_output_path" {
  type    = string
  default = "./generated/key.pem"
}
