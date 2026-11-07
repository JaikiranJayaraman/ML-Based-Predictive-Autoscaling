variable "aws_region" {
  description = "The AWS region to deploy resources in"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "fl-auto-scaling"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "instance_type" {
  description = "EC2 instance type for FL workers"
  type        = string
  default     = "t3.small"
}

variable "min_capacity" {
  description = "Minimum capacity for ASG"
  type        = number
  default     = 2
}

variable "max_capacity" {
  description = "Maximum capacity for ASG"
  type        = number
  default     = 10
}

variable "sns_email" {
  description = "Email address for SNS notifications"
  type        = string
  default     = "admin@example.com" # Should be changed by the user
}
