# 0. 使用 Data Source 動態獲取最新的 AL2023 AMI
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }
}

# 定義變數方便之後從外部傳入 Packer 的 AMI ID
variable "custom_ami_id" {
  description = "Packer 產出的 AMI ID，如果不填則使用預設 AL2023"
  type        = string
  default     = "ami-02c10fb05878107ea"
}

# 1. VPC 與網路基礎設施 (建議使用官方模組快速建立)
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "side-project-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

# 2. 安全組 (ALB 與 EC2)
resource "aws_security_group" "alb_sg" {
  name   = "alb-sg"
  vpc_id = module.vpc.vpc_id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
    ingress {
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

# 3. Launch Template (定義啟動規格)
resource "aws_launch_template" "app_lt" {
  name_prefix   = "side-project-lt-"
  
  # 邏輯：如果有傳入變數就用變數，沒有就用 Data Source 抓到的最新 AMI
  image_id      = var.custom_ami_id != "" ? var.custom_ami_id : data.aws_ami.al2023.id
  instance_type = "t3.micro"
  key_name = "deploy project key"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.alb_sg.id]
  }

  lifecycle {
    create_before_destroy = true
    # 生產環境會維持穩定的 AMI ID，不會因為 Data Source 的更新而改變，除非你手動更新變數
    ignore_changes = [image_id] 
  }

  monitoring {
    enabled = true # 開啟 1 分鐘精細度監控
  }

  # # 這裡放你的複雜 User Data
  # user_data = filebase64("${path.module}/userdata.sh")
}

# 4. ASG (混合實例策略)
resource "aws_autoscaling_group" "app_asg" {
  name                = "side-project-asg"
  vpc_zone_identifier = module.vpc.public_subnets
  target_group_arns   = [aws_lb_target_group.app_tg.arn]
  
  min_size     = 3
  max_size     = 10
  desired_capacity = 3

  default_cooldown = 60 # 將 ASG 全域冷卻縮短為 60 秒

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 3 # 最少 3 台 On-Demand
      on_demand_percentage_above_base_capacity = 0 # 超過 3 台後，Spot 比例佔 100%
      spot_allocation_strategy                 = "capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.app_lt.id
        version            = "$Latest"
      }
    }
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50 # 更新時至少保持 50% 的機器是健康的
    }
  }
}

# 4.5 定義ASG擴展政策
resource "aws_autoscaling_policy" "cpu_scaling" {
  name                   = "cpu-scaling-policy"
  autoscaling_group_name = aws_autoscaling_group.app_asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50.0 # 目標 CPU 使用率維持在 50%
  }

  # 縮短擴展後的等待時間 (預設通常是 300)
  estimated_instance_warmup = 60
}

# 5. ALB 基礎設定 (簡略)
resource "aws_lb" "app_alb" {
  name               = "side-project-alb"
  load_balancer_type = "application"
  subnets            = module.vpc.public_subnets
  security_groups    = [aws_security_group.alb_sg.id]
}

resource "aws_lb_target_group" "app_tg" {
  name     = "app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id

  health_check {
    path = "/health.html"                # 重要：這是觀察延遲的關鍵
    interval            = 10             # 可以縮短一點，讓實驗反應快些
    timeout             = 5
    healthy_threshold   = 2              # 成功兩次就亮綠燈
    unhealthy_threshold = 2
  }

  # 將排空延遲縮短。對於簡單的 Nginx，30~60 秒通常綽綽有餘
  deregistration_delay = 30
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}