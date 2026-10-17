data "aws_availability_zones" "available" {
  state = "available"
}
locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
  tags = { Project = var.project_name, ManagedBy = "Terraform" }
}
# Network: ALB and ECS tasks use public subnets to avoid NAT Gateway charges. RDS is private.
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
  enable_dns_support = true
  enable_dns_hostnames = true
  tags = merge(local.tags, { Name = "${var.project_name}-vpc" })
}
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = merge(local.tags, { Name = "${var.project_name}-igw" })
}
resource "aws_subnet" "public" {
  count = 2
  vpc_id = aws_vpc.main.id
  cidr_block = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = local.azs[count.index]
  map_public_ip_on_launch = true
  tags = merge(local.tags, { Name = "${var.project_name}-public-${count.index + 1}" })
}
resource "aws_subnet" "db" {
  count = 2
  vpc_id = aws_vpc.main.id
  cidr_block = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]
  tags = merge(local.tags, { Name = "${var.project_name}-private-db-${count.index + 1}" })
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = merge(local.tags, { Name = "${var.project_name}-public-rt" })
}
resource "aws_route_table_association" "public" {
  count = 2
  subnet_id = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id
  tags = merge(local.tags, { Name = "${var.project_name}-db-rt" })
}
resource "aws_route_table_association" "db" {
  count = 2
  subnet_id = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}
# SG chain: internet -> ALB:80 -> ECS:8080 -> RDS:3306.
resource "aws_security_group" "alb" {
  name = "${var.project_name}-alb-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}
resource "aws_security_group" "ecs" {
  name = "${var.project_name}-ecs-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port = 8080
    to_port = 8080
    protocol = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}
resource "aws_security_group" "db" {
  name = "${var.project_name}-db-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port = 3306
    to_port = 3306
    protocol = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}
# ECR repository for the app container.
resource "aws_ecr_repository" "app" {
  name = var.project_name
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = local.tags
}
# Private S3 bucket with public access blocked and default encryption enabled.
resource "aws_s3_bucket" "docs" {
  bucket_prefix = "${var.project_name}-docs-"
  force_destroy = false
  tags = local.tags
}
resource "aws_s3_bucket_public_access_block" "docs" {
  bucket = aws_s3_bucket.docs.id
  block_public_acls = true
  block_public_policy = true
  ignore_public_acls = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_server_side_encryption_configuration" "docs" {
  bucket = aws_s3_bucket.docs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
resource "aws_s3_bucket_versioning" "docs" {
  bucket = aws_s3_bucket.docs.id
  versioning_configuration {
    status = "Enabled"
  }
}
# Secret stores the DB login.
# ECS task role is granted read access below.
resource "aws_secretsmanager_secret" "db" {
  name = "${var.project_name}/db-credentials"
  recovery_window_in_days = 0
  tags = local.tags
}
resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({ username = var.db_username, password = var.db_password })
}
resource "aws_db_subnet_group" "db" {
  name = "${var.project_name}-db-subnets"
  subnet_ids = aws_subnet.db[*].id
  tags = local.tags
}
resource "aws_db_instance" "mysql" {
  identifier = "${var.project_name}-mysql"
  engine = "mysql"
  engine_version = "8.0"
  instance_class = var.db_instance_class
  allocated_storage = 20
  max_allocated_storage = 50
  storage_type = "gp3"
  storage_encrypted = true
  db_name = var.db_name
  username = var.db_username
  password = var.db_password
  port = 3306
  db_subnet_group_name = aws_db_subnet_group.db.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible = false
  multi_az = false
  backup_retention_period = 1
  deletion_protection = false
  skip_final_snapshot = true
  apply_immediately = true
  tags = local.tags
}
# Execution role pulls images/writes logs. Task role accesses S3 and Secrets Manager.
resource "aws_iam_role" "execution" {
  name = "${var.project_name}-execution-role"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  tags = local.tags
}
resource "aws_iam_role_policy_attachment" "execution" {
  role = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role" "task" {
  name = "${var.project_name}-task-role"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  tags = local.tags
}
resource "aws_iam_role_policy" "app_access" {
  name = "${var.project_name}-app-access"
  role = aws_iam_role.task.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = [aws_secretsmanager_secret.db.arn] },
    { Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"], Resource = ["${aws_s3_bucket.docs.arn}/*"] }
  ] })
}
# ALB listener forwards HTTP traffic to healthy ECS task IPs.
resource "aws_lb" "app" {
  name = substr("${var.project_name}-alb", 0, 32)
  internal = false
  load_balancer_type = "application"
  security_groups = [aws_security_group.alb.id]
  subnets = aws_subnet.public[*].id
  tags = local.tags
}
resource "aws_lb_target_group" "app" {
  name = substr("${var.project_name}-tg", 0, 32)
  port = 8080
  protocol = "HTTP"
  vpc_id = aws_vpc.main.id
  target_type = "ip"
  health_check {
    path = "/health"
    matcher = "200"
    interval = 30
    timeout = 5
    healthy_threshold = 2
    unhealthy_threshold = 3
  }
  tags = local.tags
}
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port = 80
  protocol = "HTTP"
  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
  tags = local.tags
}
resource "aws_cloudwatch_log_group" "app" {
  name = "/ecs/${var.project_name}"
  retention_in_days = 7
  tags = local.tags
}
resource "aws_ecs_task_definition" "app" {
  family = var.project_name
  requires_compatibilities = ["FARGATE"]
  network_mode = "awsvpc"
  cpu = "256"
  memory = "512"
  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn = aws_iam_role.task.arn
  container_definitions = jsonencode([{
    name = "insurance-portal"
    image = "${aws_ecr_repository.app.repository_url}:${var.app_image_tag}"
    essential = true
    portMappings = [{ containerPort = 8080, hostPort = 8080, protocol = "tcp" }]
    environment = [
      { name = "AWS_REGION", value = var.aws_region },
      { name = "DOCUMENTS_BUCKET", value = aws_s3_bucket.docs.bucket },
      { name = "DB_HOST", value = aws_db_instance.mysql.address },
      { name = "DB_NAME", value = var.db_name },
      { name = "DB_SECRET_ARN", value = aws_secretsmanager_secret.db.arn }
    ]
    logConfiguration = { logDriver = "awslogs", options = {
      "awslogs-group" = aws_cloudwatch_log_group.app.name,
      "awslogs-region" = var.aws_region,
      "awslogs-stream-prefix" = "app"
    }}
  }])
  tags = local.tags
}
resource "aws_ecs_service" "app" {
  name = "${var.project_name}-service"
  cluster = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count = var.desired_count
  launch_type = "FARGATE"
  platform_version = "LATEST"
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent = 200
  health_check_grace_period_seconds = 90
  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "insurance-portal"
    container_port   = 8080
  }
  depends_on = [aws_lb_listener.http, aws_iam_role_policy_attachment.execution, aws_iam_role_policy.app_access]
  tags = local.tags
}
# ECS service scales between min_capacity and max_capacity based on average CPU.
resource "aws_appautoscaling_target" "ecs" {
  max_capacity = var.max_capacity
  min_capacity = var.min_capacity
  resource_id = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace = "ecs"
}
resource "aws_appautoscaling_policy" "cpu" {
  name = "${var.project_name}-cpu-scaling"
  policy_type = "TargetTrackingScaling"
  resource_id = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace = aws_appautoscaling_target.ecs.service_namespace
  target_tracking_scaling_policy_configuration {
    target_value = 60
    scale_in_cooldown = 60
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
