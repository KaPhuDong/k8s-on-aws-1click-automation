variable "aws_region" {
  description = "AWS region used for the lab."
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Prefix for AWS resource names."
  type        = string
  default     = "portfolio-k8s-challenge"
}

variable "instance_type" {
  description = "EC2 size for Docker + minikube."
  type        = string
  default     = "t3.small"
}

variable "ssh_allowed_cidr" {
  description = "CIDR allowed to SSH to the EC2 instance. Leave empty to auto-detect your current public IP and append /32."
  type        = string
  default     = ""
}

variable "node_port" {
  description = "Fixed Kubernetes NodePort exposed through the ALB target group."
  type        = number
  default     = 30080

  validation {
    condition     = var.node_port >= 30000 && var.node_port <= 32767
    error_message = "node_port must be in the Kubernetes NodePort range 30000-32767."
  }
}

variable "minikube_memory_mb" {
  description = "Memory passed to minikube start. 1800 works on t3.small."
  type        = number
  default     = 1800
}
