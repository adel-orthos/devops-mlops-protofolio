# ---------------------------------------------------------------------------------------------------------------------
# LAMBDA FUNCTION MODULE VARIABLES
# ---------------------------------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------------------------------------
# REQUIRED VARIABLES
# ---------------------------------------------------------------------------------------------------------------------

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
}

variable "function_name" {
  description = "Name of the Lambda function (will be prefixed with environment)"
  type        = string
}

# ---------------------------------------------------------------------------------------------------------------------
# OPTIONAL VARIABLES
# ---------------------------------------------------------------------------------------------------------------------

variable "description" {
  description = "Description of the Lambda function"
  type        = string
  default     = "Lambda function deployed via Terraform"
}

variable "timeout" {
  description = "Amount of time Lambda function has to run in seconds"
  type        = number
  default     = 30
  
  validation {
    condition     = var.timeout >= 1 && var.timeout <= 900
    error_message = "Lambda timeout must be between 1 and 900 seconds."
  }
}

variable "memory_size" {
  description = "Amount of memory in MB Lambda function can use at runtime"
  type        = number
  default     = 128
  
  validation {
    condition     = var.memory_size >= 128 && var.memory_size <= 10240
    error_message = "Lambda memory size must be between 128 and 10240 MB."
  }
}

variable "ephemeral_storage_size" {
  description = "Size of the Lambda function's ephemeral storage (/tmp) in MB"
  type        = number
  default     = 512
  
  validation {
    condition     = var.ephemeral_storage_size >= 512 && var.ephemeral_storage_size <= 10240
    error_message = "Ephemeral storage size must be between 512 and 10240 MB."
  }
}

variable "environment_variables" {
  description = "Map of environment variables for the Lambda function"
  type        = map(string)
  default     = {}
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 14
  
  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653
    ], var.log_retention_days)
    error_message = "Log retention days must be a valid CloudWatch log retention value."
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# IAM CONFIGURATION
# ---------------------------------------------------------------------------------------------------------------------

variable "lambda_role_arn" {
  description = "ARN of existing IAM role for Lambda function. If null, a new role will be created."
  type        = string
  default     = null
}

variable "additional_iam_policy" {
  description = "Additional IAM policy document (JSON) to attach to the Lambda role"
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------------------------------------------------
# VPC CONFIGURATION
# ---------------------------------------------------------------------------------------------------------------------

variable "vpc_subnet_ids" {
  description = "List of subnet IDs for VPC configuration. Leave empty for non-VPC Lambda."
  type        = list(string)
  default     = []
}

variable "vpc_security_group_ids" {
  description = "List of security group IDs for VPC configuration"
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------------------------------------------------
# CONTAINER/IMAGE CONFIGURATION
# ---------------------------------------------------------------------------------------------------------------------

variable "image_uri" {
  description = "URI of existing container image. If null, will use built image or fail if build_image is false."
  type        = string
  default     = null
}

variable "build_image" {
  description = "Whether to build Docker image locally and push to ECR"
  type        = bool
  default     = false
}

variable "create_ecr_repo" {
  description = "Whether to create ECR repository for the image"
  type        = bool
  default     = true
}

variable "ecr_repo_name" {
  description = "Name of existing ECR repository (used when create_ecr_repo is false)"
  type        = string
  default     = null
}

variable "source_path" {
  description = "Path to source code for Docker build"
  type        = string
  default     = "./src"
}

variable "dockerfile_path" {
  description = "Path to Dockerfile relative to source_path"
  type        = string
  default     = "Dockerfile"
}

variable "image_tag" {
  description = "Tag for the Docker image"
  type        = string
  default     = "latest"
}

variable "build_args" {
  description = "Build arguments for Docker build"
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------------------------------------------------
# FUNCTION URL CONFIGURATION
# ---------------------------------------------------------------------------------------------------------------------

variable "create_function_url" {
  description = "Whether to create a Lambda function URL"
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------------------------------------------------
# TRIGGER CONFIGURATION
# ---------------------------------------------------------------------------------------------------------------------

variable "enable_s3_trigger" {
  description = "Enable S3 trigger for the Lambda function"
  type        = bool
  default     = false
}

variable "enable_sqs_trigger" {
  description = "Enable SQS trigger for the Lambda function"
  type        = bool
  default     = false
}

variable "enable_sns_trigger" {
  description = "Enable SNS trigger for the Lambda function"
  type        = bool
  default     = false
}

variable "enable_apigateway_trigger" {
  description = "Enable API Gateway trigger for the Lambda function"
  type        = bool
  default     = false
}

variable "api_gateway_arn" {
  description = "ARN of the API Gateway to allow triggers from"
  type        = string
  default     = ""
}

variable "custom_triggers" {
  description = "Map of custom triggers for the Lambda function"
  type = map(object({
    principal  = string
    source_arn = string
  }))
  default = {}
}

variable "event_source_mappings" {
  description = "Map of event source mappings (for SQS, Kinesis, DynamoDB, etc.)"
  type        = any
  default     = {}
}

# ---------------------------------------------------------------------------------------------------------------------
# TAGGING
# ---------------------------------------------------------------------------------------------------------------------

variable "tags" {
  description = "Map of tags to apply to all resources"
  type        = map(string)
  default     = {}
} 