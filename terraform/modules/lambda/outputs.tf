output "remediator_function_arn" {
  description = "ARN of the remediator Lambda function"
  value       = aws_lambda_function.remediator.arn
}

output "rca_summariser_function_arn" {
  description = "ARN of the RCA summariser Lambda function"
  value       = aws_lambda_function.rca_summariser.arn
}

output "role_arn" {
  description = "ARN of the shared Lambda execution IAM role"
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Name of the shared Lambda execution IAM role"
  value       = aws_iam_role.this.name
}
