# Lambda Function Terraform Module

This module creates a containerized AWS Lambda function with comprehensive configuration options including VPC integration, IAM roles, triggers, and optional Docker image building.

## Features

- **Containerized Lambda**: Support for container images with automatic ECR integration
- **VPC Integration**: Optional VPC deployment with security groups
- **Multiple Triggers**: S3, SQS, SNS, API Gateway, and custom triggers
- **IAM Management**: Automatic IAM role creation with least privilege principles
- **Docker Build**: Optional local Docker build and ECR push
- **Function URLs**: Optional Lambda function URL with CORS configuration
- **Monitoring**: CloudWatch logging with configurable retention
- **Event Sources**: Support for SQS, Kinesis, DynamoDB event source mappings

## Usage

### Basic Example

```hcl
module "my_lambda" {
  source = "./terraform-modules/lambda-function"
  
  environment     = "dev"
  function_name   = "document-processor"
  description     = "Process uploaded documents"
  
  # Use existing image
  image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-app:latest"
  
  # Configuration
  timeout     = 60
  memory_size = 512
  
  environment_variables = {
    LOG_LEVEL = "INFO"
    REGION    = "us-east-1"
  }
  
  tags = {
    Project = "document-processing"
    Owner   = "data-team"
  }
}
```

### Build and Deploy Example

```hcl
module "my_lambda_with_build" {
  source = "./terraform-modules/lambda-function"
  
  environment     = "dev"
  function_name   = "api-handler"
  
  # Build configuration
  build_image      = true
  create_ecr_repo  = true
  source_path      = "./src/lambda"
  dockerfile_path  = "Dockerfile"
  image_tag        = "v1.0.0"
  
  # Function configuration
  timeout     = 30
  memory_size = 256
  
  # Enable function URL
  create_function_url = true
  
  # API Gateway trigger
  enable_apigateway_trigger = true
  api_gateway_arn          = "arn:aws:execute-api:us-east-1:123456789012:abc123/*/*/*"
}
```

### VPC Lambda with SQS Trigger

```hcl
module "vpc_lambda" {
  source = "./terraform-modules/lambda-function"
  
  environment     = "prod"
  function_name   = "queue-processor"
  
  image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/queue-processor:latest"
  
  # VPC configuration
  vpc_subnet_ids         = ["subnet-12345", "subnet-67890"]
  vpc_security_group_ids = ["sg-abcdef123"]
  
  # SQS event source mapping
  event_source_mappings = {
    sqs = {
      event_source_arn = "arn:aws:sqs:us-east-1:123456789012:my-queue"
      batch_size       = 10
      maximum_batching_window_in_seconds = 5
    }
  }
  
  # Additional IAM permissions for SQS
  additional_iam_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = "arn:aws:sqs:us-east-1:123456789012:my-queue"
      }
    ]
  })
}
```

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.0 |
| aws | ~> 5.0 |
| docker | ~> 3.0 |

## Providers

| Name | Version |
|------|---------|
| aws | ~> 5.0 |
| docker | ~> 3.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| lambda | terraform-aws-modules/lambda/aws | ~> 6.0 |
| docker_build | terraform-aws-modules/lambda/aws//modules/docker-build | ~> 6.0 |

## Resources

| Name | Type |
|------|------|
| aws_iam_role.lambda | resource |
| aws_iam_role_policy.lambda_additional | resource |
| aws_iam_role_policy_attachment.lambda_basic | resource |
| aws_iam_role_policy_attachment.lambda_vpc | resource |
| aws_ecr_repository.this | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| environment | Environment name (e.g., dev, staging, prod) | `string` | n/a | yes |
| function_name | Name of the Lambda function (will be prefixed with environment) | `string` | n/a | yes |
| description | Description of the Lambda function | `string` | `"Lambda function deployed via Terraform"` | no |
| timeout | Amount of time Lambda function has to run in seconds | `number` | `30` | no |
| memory_size | Amount of memory in MB Lambda function can use at runtime | `number` | `128` | no |
| image_uri | URI of existing container image | `string` | `null` | no |
| build_image | Whether to build Docker image locally and push to ECR | `bool` | `false` | no |
| vpc_subnet_ids | List of subnet IDs for VPC configuration | `list(string)` | `[]` | no |
| enable_s3_trigger | Enable S3 trigger for the Lambda function | `bool` | `false` | no |
| tags | Map of tags to apply to all resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| lambda_function_arn | ARN of the Lambda function |
| lambda_function_name | Name of the Lambda function |
| lambda_function_url | Function URL of the Lambda function (if enabled) |
| lambda_role_arn | ARN of the IAM role for the Lambda function |
| cloudwatch_log_group_name | Name of the CloudWatch log group |
| ecr_repository_url | URL of the ECR repository (if created) |

## Security Considerations

- **IAM Roles**: Creates least-privilege IAM roles with only necessary permissions
- **VPC Integration**: Supports deployment in private subnets for network isolation
- **Encryption**: ECR repositories use encryption at rest
- **Secrets**: Use AWS Systems Manager Parameter Store or Secrets Manager for sensitive data
- **Image Scanning**: ECR repositories have vulnerability scanning enabled

## Cost Optimization

- **Right-sizing**: Configure appropriate memory and timeout settings
- **Log Retention**: Configurable CloudWatch log retention to manage costs
- **ECR Lifecycle**: Automatic cleanup of old container images
- **Reserved Capacity**: Consider provisioned concurrency for predictable workloads

## Examples

See the [examples](../../examples/) directory for complete working examples:

- [Web Application](../../examples/web-application/) - API Gateway + Lambda
- [ML Pipeline](../../examples/ml-pipeline/) - SQS + Lambda for batch processing 