resource "aws_sns_topic" "alerts" {
  name = "${local.resource_prefix}-alerts"

  tags = {
    Portfolio = "step-6"
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AccountOwnerManagement"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "SNS:GetTopicAttributes",
          "SNS:SetTopicAttributes",
          "SNS:AddPermission",
          "SNS:RemovePermission",
          "SNS:DeleteTopic",
          "SNS:Subscribe",
          "SNS:ListSubscriptionsByTopic",
          "SNS:Publish",
        ]
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Sid    = "CloudWatchAlarmPublish"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.alerts.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:${local.resource_prefix}-*"
          }
        }
      },
      {
        Sid    = "BudgetAlertPublish"
        Effect = "Allow"
        Principal = {
          Service = "budgets.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.alerts.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })
}

resource "aws_sqs_queue" "alarm_evidence" {
  name                       = "${local.resource_prefix}-alarm-evidence"
  message_retention_seconds  = 86400
  visibility_timeout_seconds = 30
  receive_wait_time_seconds  = 10
  sqs_managed_sse_enabled    = true

  tags = {
    Portfolio = "step-6"
  }
}

resource "aws_sqs_queue_policy" "alarm_evidence" {
  queue_url = aws_sqs_queue.alarm_evidence.url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowAlertTopic"
      Effect = "Allow"
      Principal = {
        Service = "sns.amazonaws.com"
      }
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.alarm_evidence.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_sns_topic.alerts.arn
        }
      }
    }]
  })
}

resource "aws_sns_topic_subscription" "alarm_evidence" {
  topic_arn            = aws_sns_topic.alerts.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.alarm_evidence.arn
  raw_message_delivery = true

  depends_on = [aws_sqs_queue_policy.alarm_evidence]
}

locals {
  alarm_action_arns = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "api_high_requests" {
  alarm_name          = "${local.resource_prefix}-api-high-requests"
  alarm_description   = "Two minutes above 80 percent of the configured steady API request rate"
  namespace           = "AWS/ApiGateway"
  metric_name         = "Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = var.api_throttling_rate_limit * 60 * 0.8
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  actions_enabled     = true
  alarm_actions       = local.alarm_action_arns

  dimensions = {
    ApiName = aws_api_gateway_rest_api.quiz.name
    Stage   = aws_api_gateway_stage.lab.stage_name
  }

  tags = {
    Portfolio = "step-6"
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_high_concurrency" {
  alarm_name          = "${local.resource_prefix}-lambda-high-concurrency"
  alarm_description   = "Quiz Lambda concurrency reached the lab warning threshold"
  namespace           = "AWS/Lambda"
  metric_name         = "ConcurrentExecutions"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = var.lambda_concurrency_warning_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  actions_enabled     = true
  alarm_actions       = local.alarm_action_arns

  dimensions = {
    FunctionName = aws_lambda_function.api.function_name
  }

  tags = {
    Portfolio = "step-6"
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  alarm_name          = "${local.resource_prefix}-lambda-throttles"
  alarm_description   = "At least one quiz Lambda invocation was throttled"
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  actions_enabled     = true
  alarm_actions       = local.alarm_action_arns

  dimensions = {
    FunctionName = aws_lambda_function.api.function_name
  }

  tags = {
    Portfolio = "step-6"
  }
}

resource "aws_cloudwatch_metric_alarm" "dynamodb_write_throttles" {
  for_each = {
    players = aws_dynamodb_table.players.name
    events  = aws_dynamodb_table.events.name
  }

  alarm_name          = "${local.resource_prefix}-${each.key}-write-throttles"
  alarm_description   = "At least one ${each.key} table write was throttled"
  namespace           = "AWS/DynamoDB"
  metric_name         = "WriteThrottleEvents"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  actions_enabled     = true
  alarm_actions       = local.alarm_action_arns

  dimensions = {
    TableName = each.value
  }

  tags = {
    Portfolio = "step-6"
  }
}

resource "aws_cloudwatch_metric_alarm" "pipe_execution_failed" {
  alarm_name          = "${local.resource_prefix}-pipe-execution-failed"
  alarm_description   = "At least one EventBridge Pipe execution failed"
  namespace           = "AWS/EventBridge/Pipes"
  metric_name         = "ExecutionFailed"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  actions_enabled     = true
  alarm_actions       = local.alarm_action_arns

  dimensions = {
    PipeName = aws_pipes_pipe.events.name
  }

  tags = {
    Portfolio = "step-6"
  }
}

resource "aws_cloudwatch_metric_alarm" "firehose_delivery_failed" {
  alarm_name          = "${local.resource_prefix}-firehose-s3-delivery-failed"
  alarm_description   = "Firehose reported an unsuccessful S3 delivery interval"
  namespace           = "AWS/Firehose"
  metric_name         = "DeliveryToS3.Success"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  actions_enabled     = true
  alarm_actions       = local.alarm_action_arns

  dimensions = {
    DeliveryStreamName = aws_kinesis_firehose_delivery_stream.events.name
  }

  tags = {
    Portfolio = "step-6"
  }
}

resource "aws_cloudwatch_metric_alarm" "pipe_dlq_visible" {
  alarm_name          = "${local.resource_prefix}-pipe-dlq-visible"
  alarm_description   = "The Pipe source DLQ contains at least one visible message"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  actions_enabled     = true
  alarm_actions       = local.alarm_action_arns

  dimensions = {
    QueueName = aws_sqs_queue.pipe_dlq.name
  }

  tags = {
    Portfolio = "step-6"
  }
}

resource "aws_budgets_budget" "monthly_lab" {
  name         = "${local.resource_prefix}-monthly-cost"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator       = "GREATER_THAN"
    notification_type         = "ACTUAL"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    notification_type         = "FORECASTED"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }

  depends_on = [aws_sns_topic_policy.alerts]

  tags = {
    Portfolio = "step-6"
  }
}
