resource "aws_wafv2_web_acl" "api" {
  name        = "${local.resource_prefix}-api"
  description = "Single-rule portfolio guardrail for abusive source IPs"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "ip-rate-limit"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        aggregate_key_type    = "IP"
        evaluation_window_sec = 60
        limit                 = var.waf_rate_limit
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.resource_prefix}-ip-rate-limit"
      sampled_requests_enabled   = false
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.resource_prefix}-api"
    sampled_requests_enabled   = false
  }

  tags = {
    Portfolio = "step-4"
  }
}

resource "aws_wafv2_web_acl_association" "api_stage" {
  resource_arn = aws_api_gateway_stage.lab.arn
  web_acl_arn  = aws_wafv2_web_acl.api.arn
}
