terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.5"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "http" "public_ip" {
  url = "https://api.ipify.org"
}

locals {
  ssh_allowed_cidr = var.ssh_allowed_cidr != "" ? var.ssh_allowed_cidr : "${chomp(data.http.public_ip.response_body)}/32"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated" {
  key_name   = "${var.project_name}-${terraform.workspace}"
  public_key = tls_private_key.ssh.public_key_openssh

  tags = {
    Name = "${var.project_name}-${terraform.workspace}"
  }
}

resource "local_file" "private_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "${path.module}/${var.project_name}-${terraform.workspace}.pem"
  file_permission = "0400"
}

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb"
  description = "Allow HTTP traffic from the Internet to the ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP from Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "ALB to EC2 NodePort"
    from_port   = var.node_port
    to_port     = var.node_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-alb"
  }
}

resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-ec2"
  description = "Allow ALB to K8s NodePort and SSH from the operator"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Kubernetes NodePort from ALB only"
    from_port       = var.node_port
    to_port         = var.node_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "SSH for manual debug"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.ssh_allowed_cidr]
  }

  egress {
    description = "Outbound Internet for package and image downloads"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-ec2"
  }
}

resource "aws_lb" "app" {
  name               = var.project_name
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids

  tags = {
    Name = var.project_name
  }
}

resource "aws_lb_target_group" "app" {
  name        = "${var.project_name}-tg"
  port        = var.node_port
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = data.aws_vpc.default.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200-399"
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${var.project_name}-tg"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_instance" "k8s" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  key_name                    = aws_key_pair.generated.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = self.public_ip
    private_key = tls_private_key.ssh.private_key_pem
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p /home/ubuntu/k8s-manifests",
      "mkdir -p /home/ubuntu/frontend"
    ]
  }

  provisioner "file" {
    source      = "${path.module}/k8s-manifests/"
    destination = "/home/ubuntu/k8s-manifests"
  }

  provisioner "file" {
    source      = "${path.module}/frontend/"
    destination = "/home/ubuntu/frontend"
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      #!/usr/bin/env bash
      set -euxo pipefail

      sudo apt-get update
      sudo apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https

      sudo install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      sudo chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
      sudo apt-get update
      sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      sudo usermod -aG docker ubuntu
      sudo systemctl enable --now docker

      curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
      sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
      rm -f kubectl

      curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
      sudo install minikube-linux-amd64 /usr/local/bin/minikube
      rm -f minikube-linux-amd64

      sudo -u ubuntu -H minikube start --driver=docker --cpus=2 --memory=${var.minikube_memory_mb}mb --ports=${var.node_port}:${var.node_port}
      sudo docker build -t xbrain-portfolio:latest /home/ubuntu/frontend
      sudo -u ubuntu -H minikube image load xbrain-portfolio:latest
      sudo -u ubuntu -H kubectl apply -f /home/ubuntu/k8s-manifests/
      sudo -u ubuntu -H kubectl rollout status deployment/portfolio --timeout=180s
      curl --retry 20 --retry-delay 3 --retry-connrefused -I http://127.0.0.1:${var.node_port}/
      EOT
    ]
  }

  tags = {
    Name = "${var.project_name}-minikube"
  }
}

resource "aws_lb_target_group_attachment" "ec2" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.k8s.id
  port             = var.node_port
}
