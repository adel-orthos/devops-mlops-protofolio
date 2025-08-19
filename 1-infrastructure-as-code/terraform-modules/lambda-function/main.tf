# ---------------------------------------------------------------------------------------------------------------------
# LAMBDA FUNCTION MODULE
# This module creates a containerized Lambda function with proper IAM roles, VPC integration,
# and trigger configurations for various AWS services
# ---------------------------------------------------------------------------------------------------------------------

terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# DATA SOURCES
# ---------------------------------------------------------------------------------------------------------------------

data "aws_region" "current" {}
data "aws_caller_identity" "this" {}

# ECR authorization token for Docker provider
data "aws_ecr_authorization_token" "token" {
  count = var.build_image ? 1 : 0
}

# ---------------------------------------------------------------------------------------------------------------------
# LAMBDA FUNCTION
# ---------------------------------------------------------------------------------------------------------------------

module "lambda" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 6.0"

  # Basic configuration
  function_name = "${var.environment}-${var.function_name}"
  description   = var.description
  
  # Container configuration
  package_type  = "Image"
  image_uri     = var.image_uri != null ? var.image_uri : (var.build_image ? module.docker_build[0].image_uri : null)
  architectures = ["x86_64"]

  # Runtime configuration
  timeout       = var.timeout
  memory_size   = var.memory_size
  ephemeral_storage_size = var.ephemeral_storage_size
  
  # Environment variables
  environment_variables = var.environment_variables

  # IAM configuration
  lambda_role = var.lambda_role_arn != null ? var.lambda_role_arn : aws_iam_role.lambda[0].arn
  create_role = var.lambda_role_arn == null

  # VPC configuration (optional)
  vpc_subnet_ids         = var.vpc_subnet_ids
  vpc_security_group_ids = var.vpc_security_group_ids
  attach_network_policy  = length(var.vpc_subnet_ids) > 0

  # Logging
  cloudwatch_logs_retention_in_days = var.log_retention_days
  attach_cloudwatch_logs_policy     = true

  # Function URL (optional)
  create_lambda_function_url = var.create_function_url
  cors = var.create_function_url ? {
    allow_credentials = false
    allow_methods     = ["*"]
    allow_origins     = ["*"]
    expose_headers    = ["date", "keep-alive"]
    max_age          = 86400
  } : {}

  # Triggers
  create_current_version_allowed_triggers = false
  allowed_triggers = local.triggers

  # Event source mappings (for SQS, Kinesis, DynamoDB, etc.)
  event_source_mapping = var.event_source_mappings

  # Tags
  tags = merge(var.tags, {
    Module = "lambda-function"
  })
}

# ---------------------------------------------------------------------------------------------------------------------
# IAM ROLE (if not provided)
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_iam_role" "lambda" {
  count = var.lambda_role_arn == null ? 1 : 0
  
  name = "${var.environment}-${var.function_name}-lambda-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

# Basic Lambda execution policy
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  count = var.lambda_role_arn == null ? 1 : 0
  
  role       = aws_iam_role.lambda[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# VPC access policy (if VPC is configured)
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  count = var.lambda_role_arn == null && length(var.vpc_subnet_ids) > 0 ? 1 : 0
  
  role       = aws_iam_role.lambda[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Additional IAM policies
resource "aws_iam_role_policy" "lambda_additional" {
  count = var.lambda_role_arn == null && var.additional_iam_policy != null ? 1 : 0
  
  name = "${var.environment}-${var.function_name}-additional-policy"
  role = aws_iam_role.lambda[0].id
  
  policy = var.additional_iam_policy
}

# ---------------------------------------------------------------------------------------------------------------------
# DOCKER BUILD (optional)
# ---------------------------------------------------------------------------------------------------------------------

# Docker provider configuration
provider "docker" {
  count = var.build_image ? 1 : 0
  
  registry_auth {
    address  = "${data.aws_caller_identity.this.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com"
    username = data.aws_ecr_authorization_token.token[0].user_name
    password = data.aws_ecr_authorization_token.token[0].password
  }
}

# ECR repository
resource "aws_ecr_repository" "this" {
  count = var.build_image && var.create_ecr_repo ? 1 : 0
  
  name                 = "${var.environment}-${var.function_name}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  lifecycle_policy {
    policy = jsonencode({
      rules = [
        {
          rulePriority = 1
          description  = "Keep last 10 images"
          selection = {
            tagStatus     = "tagged"
            tagPrefixList = ["v"]
            countType     = "imageCountMoreThan"
            countNumber   = 10
          }
          action = {
            type = "expire"
          }
        }
      ]
    })
  }

  tags = var.tags
}

# Docker build module
module "docker_build" {
  source  = "terraform-aws-modules/lambda/aws//modules/docker-build"
  version = "~> 6.0"
  count   = var.build_image ? 1 : 0

  create_ecr_repo = false
  ecr_repo        = var.create_ecr_repo ? aws_ecr_repository.this[0].name : var.ecr_repo_name
  ecr_repo_lifecycle_policy = null
  
  source_path = var.source_path
  image_tag   = var.image_tag
  
  docker_file_path = var.dockerfile_path
  build_args       = var.build_args

  depends_on = [aws_ecr_repository.this]
}

# ---------------------------------------------------------------------------------------------------------------------
# LOCALS
# ---------------------------------------------------------------------------------------------------------------------

locals {
  # Configure triggers based on variables
  triggers = merge(
    # S3 triggers
    var.enable_s3_trigger ? {
      s3 = {
        principal  = "s3.amazonaws.com"
        source_arn = "arn:aws:s3:::${var.environment}*"
      }
    } : {},
    
    # SQS triggers  
    var.enable_sqs_trigger ? {
      sqs = {
        principal  = "sqs.amazonaws.com"
        source_arn = "arn:aws:sqs:${data.aws_region.current.name}:${data.aws_caller_identity.this.account_id}:${var.environment}*"
      }
    } : {},
    
    # API Gateway triggers
    var.enable_apigateway_trigger ? {
      apigateway = {
        principal  = "apigateway.amazonaws.com"
        source_arn = var.api_gateway_arn != "" ? var.api_gateway_arn : "arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.this.account_id}:*/*/*/*"
      }
    } : {},
    
    # SNS triggers
    var.enable_sns_trigger ? {
      sns = {
        principal  = "sns.amazonaws.com"
        source_arn = "arn:aws:sns:${data.aws_region.current.name}:${data.aws_caller_identity.this.account_id}:${var.environment}*"
      }
    } : {},
    
    # Custom triggers
    var.custom_triggers
  )
} 