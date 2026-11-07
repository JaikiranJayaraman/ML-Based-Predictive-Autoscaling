provider "aws" {
  region = var.aws_region
}

# ==========================================
# VPC and Networking
# ==========================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "${var.project_name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block             = var.public_subnet_cidrs[count.index]
  map_public_ip_on_launch = true
  availability_zone      = data.aws_availability_zones.available.names[count.index]
  tags = { Name = "${var.project_name}-public-${count.index + 1}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

data "aws_availability_zones" "available" {
  state = "available"
}

# ==========================================
# Security Groups
# ==========================================
resource "aws_security_group" "alb_sg" {
  name        = "${var.project_name}-alb-sg"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ec2_sg" {
  name        = "${var.project_name}-ec2-sg"
  description = "Security group for EC2 workers"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  # Allow SSH for debugging if needed
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==========================================
# Application Load Balancer
# ==========================================
resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "main" {
  name     = "${var.project_name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = true
  }

  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 30
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# ==========================================
# S3, SQS, SNS
# ==========================================
resource "aws_s3_bucket" "fl_models" {
  bucket        = "${var.project_name}-models-${random_id.bucket_suffix.hex}"
  force_destroy = true
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_sqs_queue" "fl_updates" {
  name                       = "${var.project_name}-updates-queue"
  visibility_timeout_seconds = 300
}

resource "aws_sns_topic" "scaling_alerts" {
  name = "${var.project_name}-scaling-alerts"
}

resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.scaling_alerts.arn
  protocol  = "email"
  endpoint  = var.sns_email
}

# ==========================================
# IAM Roles
# ==========================================
# EC2 Role
resource "aws_iam_role" "ec2_role" {
  name = "${var.project_name}-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ec2_policy" {
  name = "${var.project_name}-ec2-policy"
  role = aws_iam_role.ec2_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Effect   = "Allow"
        Resource = [aws_s3_bucket.fl_models.arn, "${aws_s3_bucket.fl_models.arn}/*"]
      },
      {
        Action   = ["sqs:SendMessage"]
        Effect   = "Allow"
        Resource = [aws_sqs_queue.fl_updates.arn]
      },
      {
        Action   = ["cloudwatch:PutMetricData", "cloudwatch:GetMetricStatistics"]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# Lambda Aggregator Role
resource "aws_iam_role" "lambda_aggregator_role" {
  name = "${var.project_name}-lambda-aggregator-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_aggregator_policy" {
  name = "${var.project_name}-lambda-aggregator-policy"
  role = aws_iam_role.lambda_aggregator_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Effect   = "Allow"
        Resource = [aws_s3_bucket.fl_models.arn, "${aws_s3_bucket.fl_models.arn}/*"]
      },
      {
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Effect   = "Allow"
        Resource = [aws_sqs_queue.fl_updates.arn]
      },
      {
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Effect   = "Allow"
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# Lambda Predictor Role
resource "aws_iam_role" "lambda_predictor_role" {
  name = "${var.project_name}-lambda-predictor-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_predictor_policy" {
  name = "${var.project_name}-lambda-predictor-policy"
  role = aws_iam_role.lambda_predictor_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Effect   = "Allow"
        Resource = [aws_s3_bucket.fl_models.arn, "${aws_s3_bucket.fl_models.arn}/*"]
      },
      {
        Action   = ["cloudwatch:GetMetricStatistics"]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action   = ["autoscaling:SetDesiredCapacity", "autoscaling:DescribeAutoScalingGroups", "autoscaling:DescribeScalingActivities"]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action   = ["sns:Publish"]
        Effect   = "Allow"
        Resource = [aws_sns_topic.scaling_alerts.arn]
      },
      {
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Effect   = "Allow"
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# ==========================================
# Auto Scaling Group
# ==========================================
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_launch_template" "worker" {
  name_prefix   = "${var.project_name}-lt"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 20
      volume_type = "gp3"
    }
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    s3_bucket_name         = aws_s3_bucket.fl_models.bucket
    sqs_queue_url          = aws_sqs_queue.fl_updates.url
    train_py_content       = file("${path.module}/../src/ec2_fl_worker/train.py")
    docker_compose_content = templatefile("${path.module}/../src/website/docker-compose.yml", {
      alb_dns = aws_lb.main.dns_name
    })
  }))
}

resource "aws_autoscaling_group" "fl_asg" {
  name                = "${var.project_name}-asg"
  vpc_zone_identifier = aws_subnet.public[*].id
  target_group_arns   = [aws_lb_target_group.main.arn]
  min_size            = var.min_capacity
  max_size            = var.max_capacity
  desired_capacity    = var.min_capacity

  launch_template {
    id      = aws_launch_template.worker.id
    version = aws_launch_template.worker.latest_version
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-worker"
    propagate_at_launch = true
  }
}

# ==========================================
# Lambda Functions
# ==========================================
data "archive_file" "aggregator_zip" {
  type        = "zip"
  source_dir  = "../src/aggregator_lambda"
  output_path = "${path.module}/aggregator_lambda.zip"
}

resource "aws_lambda_function" "aggregator" {
  filename         = data.archive_file.aggregator_zip.output_path
  function_name    = "${var.project_name}-aggregator"
  role             = aws_iam_role.lambda_aggregator_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.aggregator_zip.output_base64sha256
  timeout          = 300
  memory_size      = 2048

  environment {
    variables = {
      S3_BUCKET_NAME = aws_s3_bucket.fl_models.bucket
      SQS_QUEUE_URL  = aws_sqs_queue.fl_updates.url
    }
  }
}

resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.fl_updates.arn
  function_name    = aws_lambda_function.aggregator.arn
  batch_size       = 10
}

data "archive_file" "predictor_zip" {
  type        = "zip"
  source_dir  = "../src/predictor_lambda"
  output_path = "${path.module}/predictor_lambda.zip"
}

resource "aws_lambda_function" "predictor" {
  filename         = data.archive_file.predictor_zip.output_path
  function_name    = "${var.project_name}-predictor"
  role             = aws_iam_role.lambda_predictor_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.predictor_zip.output_base64sha256
  timeout          = 180
  memory_size      = 1024

  environment {
    variables = {
      S3_BUCKET_NAME   = aws_s3_bucket.fl_models.bucket
      ASG_NAME         = aws_autoscaling_group.fl_asg.name
      SNS_TOPIC_ARN    = aws_sns_topic.scaling_alerts.arn
    }
  }
}

# Schedule Predictor Lambda via EventBridge
resource "aws_cloudwatch_event_rule" "predictor_schedule" {
  name                = "${var.project_name}-predictor-schedule"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "predictor_target" {
  rule      = aws_cloudwatch_event_rule.predictor_schedule.name
  target_id = "predictor_lambda"
  arn       = aws_lambda_function.predictor.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.predictor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.predictor_schedule.arn
}
