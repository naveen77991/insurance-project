variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region"
}

variable "project_name" {
  type        = string
  default     = "insurance-policy-portal"
  description = "Use a unique name if resources already exist"
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "db_name" {
  type    = string
  default = "insurance"
}

variable "db_username" {
  type    = string
  default = "portaladmin"
}

variable "db_password" {
  type        = string
  sensitive   = true
  description = "Set a unique password in terraform.tfvars; never commit it"
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "app_image_tag" {
  type    = string
  default = "latest"
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "min_capacity" {
  type    = number
  default = 1
}

variable "max_capacity" {
  type    = number
  default = 4
}
