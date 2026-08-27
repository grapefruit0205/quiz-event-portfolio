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

output "api_invoke_url" {
  description = "IAM SigV4 서명이 필요한 Step 4 API 기본 URL"
  value       = aws_api_gateway_stage.lab.invoke_url
}

output "lambda_function_name" {
  value = aws_lambda_function.api.function_name
}

output "caller_role_arns" {
  description = "Alice/Bob 교차 접근 거부 실험용 역할"
  value       = { for player, role in aws_iam_role.caller : player => role.arn }
}

output "waf_web_acl_arn" {
  value = aws_wafv2_web_acl.api.arn
}

output "analysis_pipeline" {
  value = {
    pipe_name        = aws_pipes_pipe.events.name
    firehose_name    = aws_kinesis_firehose_delivery_stream.events.name
    dlq_url          = aws_sqs_queue.pipe_dlq.url
    glue_database    = aws_glue_catalog_database.analytics.name
    glue_table       = aws_glue_catalog_table.quiz_events.name
    athena_workgroup = aws_athena_workgroup.analytics.name
  }
}

output "monitoring" {
  value = {
    alert_topic_arn    = aws_sns_topic.alerts.arn
    evidence_queue_url = aws_sqs_queue.alarm_evidence.url
    budget_name        = aws_budgets_budget.monthly_lab.name
    alarm_names = {
      api_high_requests       = aws_cloudwatch_metric_alarm.api_high_requests.alarm_name
      lambda_high_concurrency = aws_cloudwatch_metric_alarm.lambda_high_concurrency.alarm_name
      lambda_throttles        = aws_cloudwatch_metric_alarm.lambda_throttles.alarm_name
      players_write_throttles = aws_cloudwatch_metric_alarm.dynamodb_write_throttles["players"].alarm_name
      events_write_throttles  = aws_cloudwatch_metric_alarm.dynamodb_write_throttles["events"].alarm_name
      pipe_execution_failed   = aws_cloudwatch_metric_alarm.pipe_execution_failed.alarm_name
      firehose_delivery       = aws_cloudwatch_metric_alarm.firehose_delivery_failed.alarm_name
      pipe_dlq_visible        = aws_cloudwatch_metric_alarm.pipe_dlq_visible.alarm_name
    }
  }
}
