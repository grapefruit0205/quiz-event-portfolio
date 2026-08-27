output "account_id" {
  description = "Terraform이 인증한 AWS 계정 ID"
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "단일 배포 리전"
  value       = var.aws_region
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "private_subnet_ids" {
  value = [for subnet in aws_subnet.private : subnet.id]
}

output "lambda_security_group_id" {
  value = aws_security_group.lambda.id
}

output "dynamodb_gateway_endpoint_id" {
  value = aws_vpc_endpoint.dynamodb.id
}

output "dynamodb_tables" {
  value = {
    players = {
      name = aws_dynamodb_table.players.name
      arn  = aws_dynamodb_table.players.arn
    }
    events = {
      name       = aws_dynamodb_table.events.name
      arn        = aws_dynamodb_table.events.arn
      stream_arn = aws_dynamodb_table.events.stream_arn
    }
  }
}

output "s3_buckets" {
  value = { for purpose, bucket in aws_s3_bucket.data : purpose => bucket.id }
}

output "lambda_runtime_role_arn" {
  value = aws_iam_role.lambda_runtime.arn
}
