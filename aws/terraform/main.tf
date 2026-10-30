data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "amazon_linux_2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  public_cidr  = cidrsubnet(var.vpc_cidr, 8, 0)
  private_cidr = cidrsubnet(var.vpc_cidr, 8, 1)
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-public"
  }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.private_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-private"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-nat"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name = "${var.name_prefix}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-public"
  }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-private"
  }
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "${var.name_prefix}-s3"
  }
}

# No ingress block means there is no inbound rule.
# Declaring egress replaces the default allow-all rule with only the paths below.
resource "aws_security_group" "backend" {
  name        = "${var.name_prefix}-backend"
  description = "Private backend with no inbound access"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "HTTPS to Supabase, AWS APIs, and container registries"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Outbound QUIC to Cloudflare Tunnel"
    from_port   = 7844
    to_port     = 7844
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Outbound TCP fallback for Cloudflare Tunnel"
    from_port   = 7844
    to_port     = 7844
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS to the Amazon VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "DNS over TCP to the Amazon VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${var.name_prefix}-backend"
  }
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.name_prefix}-${data.aws_caller_identity.current.account_id}-artifacts"
  force_destroy = true

  tags = {
    Name = "${var.name_prefix}-artifacts"
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "artifacts" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = data.aws_iam_policy_document.artifacts.json

  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}

resource "aws_secretsmanager_secret" "supabase_url" {
  name                    = "${var.name_prefix}/supabase/project-url"
  description             = "Supabase project URL. Set the value outside Terraform."
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret" "supabase_publishable_key" {
  name                    = "${var.name_prefix}/supabase/publishable-key"
  description             = "Supabase publishable key. Set the value outside Terraform."
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret" "supabase_internal_api_key" {
  name                    = "${var.name_prefix}/supabase/internal-api-key"
  description             = "Data API gateway secret. Set the value outside Terraform."
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret" "backend_auth_token" {
  name                    = "${var.name_prefix}/backend/worker-auth-token"
  description             = "Worker to backend credential. Set the value outside Terraform."
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret" "cloudflare_tunnel_token" {
  name                    = "${var.name_prefix}/cloudflare/tunnel-token"
  description             = "Cloudflare Tunnel token. Set the value outside Terraform."
  recovery_window_in_days = var.secret_recovery_window_days
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backend" {
  name               = "${var.name_prefix}-backend"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.backend.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "backend" {
  statement {
    sid = "ReadDemoSecrets"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      aws_secretsmanager_secret.supabase_url.arn,
      aws_secretsmanager_secret.supabase_publishable_key.arn,
      aws_secretsmanager_secret.supabase_internal_api_key.arn,
      aws_secretsmanager_secret.backend_auth_token.arn,
      aws_secretsmanager_secret.cloudflare_tunnel_token.arn,
    ]
  }

  statement {
    sid       = "ReadArtifacts"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn]
  }

  statement {
    sid       = "ReadArtifactObjects"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
}

resource "aws_iam_role_policy" "backend" {
  name   = "${var.name_prefix}-backend"
  role   = aws_iam_role.backend.id
  policy = data.aws_iam_policy_document.backend.json
}

resource "aws_iam_instance_profile" "backend" {
  name = "${var.name_prefix}-backend"
  role = aws_iam_role.backend.name
}

resource "aws_instance" "backend" {
  ami                         = data.aws_ssm_parameter.amazon_linux_2023.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.backend.id]
  iam_instance_profile        = aws_iam_instance_profile.backend.name
  associate_public_ip_address = false
  user_data                   = file("${path.module}/user_data.sh")
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    volume_size = 30
    volume_type = "gp3"
  }

  depends_on = [
    aws_route.private_default,
    aws_nat_gateway.main,
    aws_iam_instance_profile.backend,
  ]

  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name = "${var.name_prefix}-backend"
  }
}
