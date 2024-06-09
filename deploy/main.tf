terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.53"
    }
  }
}

locals {
  common_tags = {
    Environment = "dev"
    Project     = "background-jobs"
    Maintainer  = "Beo Hoang"
  }
}

provider "aws" {
  region = "ap-southeast-1"
}

data "aws_vpc" "default" {
  default = true
}
data "aws_subnets" "subnets" {
  filter {
    name = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

// roles

resource "aws_iam_role" "ecsTaskExecutionRole" {
  name = "ecsTaskExecutionRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
  tags_all = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRolePolicy" {
  role       = aws_iam_role.ecsTaskExecutionRole.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "AmazonPipesServiceRole" {
  name = "AmazonPipesServiceRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "pipes.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags_all = local.common_tags
}

resource "aws_iam_role_policy_attachment" "AmazonPipesServiceRolePolicy" {
  role       = aws_iam_role.AmazonPipesServiceRole.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonPipesServiceRolePolicy"
}

// ecs cluster
resource "aws_ecs_cluster" "ecs" {
  name = "ecs-background-jobs"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags_all = local.common_tags
}

resource "aws_ecs_cluster_capacity_providers" "capacity_providers" {
  cluster_name = "ecs-background-jobs"
  capacity_providers = ["FARGATE"]
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 0
    weight            = 50
  }
}

resource "aws_ecs_task_definition" "echo-env" {
  container_definitions = jsonencode([
    {
      name      = "echo-env"
      image     = "amazonlinux:2"
      cpu       = 256
      memory    = 512
      essential = true
      command = ["env"]
      log_configuration = {
        log_driver = "awslogs"
        options = {
          "awslogs-group"         = "awslogs-group"
          "awslogs-region"        = "ap-southeast-1"
          "awslogs-stream-prefix" = "awslogs-stream-prefix"
        }
      }
    }
  ])
  family             = "echo-env"
  task_role_arn      = aws_iam_role.ecsTaskExecutionRole.arn
  execution_role_arn = aws_iam_role.ecsTaskExecutionRole.arn
  cpu                = "256"
  memory             = "512"
  pid_mode           = "task"
  network_mode       = "awsvpc"

  tags_all = local.common_tags
}

resource "aws_sqs_queue" "sqs" {
  name = "sqs"
}

resource "aws_pipes_pipe" "pipe" {
  name     = "pipe"
  source   = aws_sqs_queue.sqs.arn
  target   = aws_ecs_cluster.ecs.arn
  role_arn = aws_iam_role.AmazonPipesServiceRole.arn

  source_parameters {
    sqs_queue_parameters {
      batch_size = 1
    }
  }

  target_parameters {
    ecs_task_parameters {
      task_definition_arn     = aws_ecs_task_definition.echo-env.arn
      enable_ecs_managed_tags = true
      enable_execute_command  = true
      launch_type             = "FARGATE"
      network_configuration {
        aws_vpc_configuration {
          assign_public_ip = "ENABLED"
          subnets          = [
            for subnet_id in data.aws_subnets.subnets.ids : subnet_id
          ]
        }
      }
      overrides {
        container_override {
          name = "echo-env"
          environment {
            name  = "SQS_MESSAGE"
            value = "$.body"
          }
        }
      }
    }
  }

  tags_all = local.common_tags
}
