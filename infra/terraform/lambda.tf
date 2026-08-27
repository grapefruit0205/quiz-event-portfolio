data "archive_file" "quiz_backend" {
  type        = "zip"
  output_path = "${path.module}/.terraform/quiz_backend.zip"

  dynamic "source" {
    for_each = toset(["__init__.py", "handler.py", "quiz.py", "storage.py"])
    content {
      content  = file("${path.module}/../../backend/quiz_backend/${source.value}")
      filename = "quiz_backend/${source.value}"
    }
  }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${local.resource_prefix}-api"
  retention_in_days = 7

  tags = {
    Portfolio = "step-4"
  }
}

resource "aws_lambda_function" "api" {
  function_name = "${local.resource_prefix}-api"
  description   = "Quiz API: atomic player state and event history"
  role          = aws_iam_role.lambda_runtime.arn
  handler       = "quiz_backend.handler.lambda_handler"
  runtime       = "python3.12"
  architectures = ["arm64"]

  filename         = data.archive_file.quiz_backend.output_path
  source_code_hash = data.archive_file.quiz_backend.output_base64sha256
  memory_size      = 256
  timeout          = 10

  environment {
    variables = {
      PLAYERS_TABLE = aws_dynamodb_table.players.name
      EVENTS_TABLE  = aws_dynamodb_table.events.name
      PRINCIPAL_MAP_JSON = jsonencode({
        (aws_iam_role.caller["alice"].arn) = "alice"
        (aws_iam_role.caller["bob"].arn)   = "bob"
      })
    }
  }

  logging_config {
    log_format            = "JSON"
    application_log_level = "INFO"
    system_log_level      = "WARN"
    log_group             = aws_cloudwatch_log_group.api.name
  }

  vpc_config {
    subnet_ids         = [for subnet in aws_subnet.private : subnet.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  tracing_config {
    mode = "PassThrough"
  }

  depends_on = [aws_iam_role_policy.lambda_runtime]

  tags = {
    Portfolio = "step-4"
  }
}
