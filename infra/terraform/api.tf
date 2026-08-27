resource "aws_api_gateway_rest_api" "quiz" {
  name        = "${local.resource_prefix}-api"
  description = "IAM-authenticated quiz portfolio API"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = {
    Portfolio = "step-4"
  }
}

resource "aws_api_gateway_resource" "quiz" {
  rest_api_id = aws_api_gateway_rest_api.quiz.id
  parent_id   = aws_api_gateway_rest_api.quiz.root_resource_id
  path_part   = "quiz"
}

resource "aws_api_gateway_resource" "players" {
  rest_api_id = aws_api_gateway_rest_api.quiz.id
  parent_id   = aws_api_gateway_rest_api.quiz.root_resource_id
  path_part   = "players"
}

resource "aws_api_gateway_resource" "player" {
  rest_api_id = aws_api_gateway_rest_api.quiz.id
  parent_id   = aws_api_gateway_resource.players.id
  path_part   = "{player_id}"
}

resource "aws_api_gateway_resource" "results" {
  rest_api_id = aws_api_gateway_rest_api.quiz.id
  parent_id   = aws_api_gateway_resource.player.id
  path_part   = "results"
}

locals {
  api_methods = {
    get_quiz = {
      resource_id = aws_api_gateway_resource.quiz.id
      http_method = "GET"
    }
    get_player = {
      resource_id = aws_api_gateway_resource.player.id
      http_method = "GET"
    }
    post_result = {
      resource_id = aws_api_gateway_resource.results.id
      http_method = "POST"
    }
  }
}

resource "aws_api_gateway_method" "quiz" {
  for_each = local.api_methods

  rest_api_id   = aws_api_gateway_rest_api.quiz.id
  resource_id   = each.value.resource_id
  http_method   = each.value.http_method
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_integration" "lambda" {
  for_each = aws_api_gateway_method.quiz

  rest_api_id             = each.value.rest_api_id
  resource_id             = each.value.resource_id
  http_method             = each.value.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.api.invoke_arn
  timeout_milliseconds    = 10000
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowApiGatewayLabInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.quiz.execution_arn}/${var.api_stage_name}/*/*"
}

resource "aws_api_gateway_deployment" "quiz" {
  rest_api_id = aws_api_gateway_rest_api.quiz.id

  triggers = {
    redeployment = sha1(jsonencode({
      resources = {
        quiz    = aws_api_gateway_resource.quiz.path
        players = aws_api_gateway_resource.players.path
        player  = aws_api_gateway_resource.player.path
        results = aws_api_gateway_resource.results.path
      }
      methods = {
        for name, method in aws_api_gateway_method.quiz : name => {
          method        = method.http_method
          authorization = method.authorization
          resource_id   = method.resource_id
        }
      }
      integrations = {
        for name, integration in aws_api_gateway_integration.lambda : name => {
          type = integration.type
          uri  = integration.uri
        }
      }
    }))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "lab" {
  rest_api_id   = aws_api_gateway_rest_api.quiz.id
  deployment_id = aws_api_gateway_deployment.quiz.id
  stage_name    = var.api_stage_name
  description   = "Portfolio lab stage; IAM authorization and bounded request rate"

  cache_cluster_enabled = false
  xray_tracing_enabled  = false

  tags = {
    Portfolio = "step-4"
  }
}

resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.quiz.id
  stage_name  = aws_api_gateway_stage.lab.stage_name
  method_path = "*/*"

  settings {
    caching_enabled        = false
    data_trace_enabled     = false
    logging_level          = "OFF"
    metrics_enabled        = false
    throttling_burst_limit = var.api_throttling_burst_limit
    throttling_rate_limit  = var.api_throttling_rate_limit
  }
}
