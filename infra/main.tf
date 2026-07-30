############################################
# Networking — use the account's default VPC
############################################

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
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

############################################
# Security group
############################################

resource "aws_security_group" "jenkins" {
  name        = "${var.project_name}-sg"
  description = "Jenkins EC2 security group"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Jenkins web UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.jenkins_admin_cidr]
  }

  ingress {
    description = "Jenkins JNLP agent port"
    from_port   = 50000
    to_port     = 50000
    protocol    = "tcp"
    cidr_blocks = [var.jenkins_admin_cidr]
  }

  dynamic "ingress" {
    for_each = var.ssh_key_name != null ? [1] : []
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [var.ssh_cidr]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg"
  }
}

############################################
# IAM role — lets us reach the instance via
# SSM Session Manager instead of opening SSH
############################################

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins_instance" {
  name               = "${var.project_name}-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.jenkins_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.jenkins_instance.name
}

############################################
# Persistent data volume for /var/jenkins_home
############################################

resource "aws_ebs_volume" "jenkins_data" {
  availability_zone = aws_instance.jenkins.availability_zone
  size              = var.jenkins_data_volume_size
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "${var.project_name}-data"
  }
}

resource "aws_volume_attachment" "jenkins_data" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.jenkins_data.id
  instance_id = aws_instance.jenkins.id

  # avoid Terraform trying to force-detach on every apply
  stop_instance_before_detaching = true
}

############################################
# EC2 instance running Jenkins in Docker
############################################

resource "aws_instance" "jenkins" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  # sort() keeps this deterministic across applies — the raw data source
  # order isn't guaranteed stable, which would otherwise risk an
  # unwanted instance replacement on a later `terraform apply`.
  subnet_id              = sort(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids = [aws_security_group.jenkins.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins.name
  key_name               = var.ssh_key_name

  # user_data intentionally does NOT provision/mount the data volume itself;
  # the attachment above happens after boot, so the volume is formatted/
  # mounted by a separate bootstrap step that polls for the device (see
  # user_data.sh). Changing user_data replaces the instance but not the
  # data volume, so Jenkins data survives instance replacement.
  user_data                    = file("${path.module}/user_data.sh")
  user_data_replace_on_change = true

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.project_name}-server"
  }
}

############################################
# Static public IP
############################################

resource "aws_eip" "jenkins" {
  instance = aws_instance.jenkins.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-eip"
  }
}
