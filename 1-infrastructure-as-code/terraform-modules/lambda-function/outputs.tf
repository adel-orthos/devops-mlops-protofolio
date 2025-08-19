# ---------------------------------------------------------------------------------------------------------------------
# LAMBDA FUNCTION MODULE OUTPUTS
# ---------------------------------------------------------------------------------------------------------------------

output "lambda_function_arn" {
  description = "ARN of the Lambda function"
  value       = module.lambda.lambda_function_arn
}

output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = module.lambda.lambda_function_name
}

output "lambda_function_qualified_arn" {
  description = "Qualified ARN of the Lambda function"
  value       = module.lambda.lambda_function_qualified_arn
}

output "lambda_function_version" {
  description = "Latest published version of the Lambda function"
  value       = module.lambda.lambda_function_version
}

output "lambda_function_url" {
  description = "Function URL of the Lambda function (if enabled)"
  value       = var.create_function_url ? module.lambda.lambda_function_url : null
}

output "lambda_function_invoke_arn" {
  description = "Invoke ARN of the Lambda function"
  value       = module.lambda.lambda_function_invoke_arn
}

output "lambda_role_arn" {
  description = "ARN of the IAM role for the Lambda function"
  value       = var.lambda_role_arn != null ? var.lambda_role_arn : aws_iam_role.lambda[0].arn
}

output "lambda_role_name" {
  description = "Name of the IAM role for the Lambda function"
  value       = var.lambda_role_arn != null ? split("/", var.lambda_role_arn)[1] : aws_iam_role.lambda[0].name
}

output "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch log group for the Lambda function"
  value       = module.lambda.lambda_cloudwatch_log_group_name
}

output "cloudwatch_log_group_arn" {
  description = "ARN of the CloudWatch log group for the Lambda function"
  value       = module.lambda.lambda_cloudwatch_log_group_arn
}

output "ecr_repository_url" {
  description = "URL of the ECR repository (if created)"
  value       = var.build_image && var.create_ecr_repo ? aws_ecr_repository.this[0].repository_url : null
}

output "image_uri" {
  description = "URI of the container image used by the Lambda function"
  value       = var.image_uri != null ? var.image_uri : (var.build_image ? module.docker_build[0].image_uri : null)
} 