variable "aws_region" {
  description = "AWS region to deploy Jenkins into"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Name prefix used on all resources"
  type        = string
  default     = "jenkins"
}

variable "instance_type" {
  description = "EC2 instance type running the Jenkins Docker container"
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size" {
  description = "Root (OS + Docker images) volume size in GB"
  type        = number
  default     = 20
}

variable "jenkins_data_volume_size" {
  description = "Size in GB of the separate EBS volume that persists /var/jenkins_home"
  type        = number
  default     = 20
}

variable "jenkins_admin_cidr" {
  description = "CIDR block allowed to reach the Jenkins web UI (port 8080) and JNLP agent port (50000). Restrict this to your own IP (e.g. 1.2.3.4/32) once you know it — 0.0.0.0/0 exposes Jenkins login to the whole internet."
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssh_key_name" {
  description = "Optional existing EC2 key pair name to enable SSH (port 22) access. Leave null to rely solely on AWS SSM Session Manager (recommended — no open SSH port, no key to manage)."
  type        = string
  default     = null
}

variable "ssh_cidr" {
  description = "CIDR allowed to SSH in, only used if ssh_key_name is set"
  type        = string
  default     = "0.0.0.0/0"
}
