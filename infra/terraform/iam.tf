resource "aws_iam_role" "lambda_runtime" {
  name = "${local.resource_prefix}-lambda-runtime"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
  permissions_boundary = var.permissions_boundary_arn

  tags = {
    Name = "${local.resource_prefix}-lambda-runtime"
  }
}

resource "aws_iam_role_policy" "lambda_runtime" {
  name = "${local.resource_prefix}-runtime"
  role = aws_iam_role.lambda_runtime.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteFunctionLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.resource_prefix}-*:log-stream:*",
        ]
      },
      {
        Sid    = "ManageVpcNetworkInterface"
        Effect = "Allow"
        Action = [
          "ec2:AssignPrivateIpAddresses",
          "ec2:CreateNetworkInterface",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSubnets",
          "ec2:UnassignPrivateIpAddresses",
        ]
        Resource = "*"
      },
      {
        Sid    = "ReadAndWriteQuizTables"
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeTable",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Query",
          "dynamodb:TransactWriteItems",
          "dynamodb:UpdateItem",
        ]
        Resource = [
          aws_dynamodb_table.players.arn,
          aws_dynamodb_table.events.arn,
          "${aws_dynamodb_table.events.arn}/index/*",
        ]
      },
    ]
  })
}

resource "aws_iam_role" "caller" {
  for_each = toset(["alice", "bob"])

  name = "${local.resource_prefix}-${each.key}-caller"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        AWS = local.operator_principal_arn
      }
    }]
  })
  permissions_boundary = var.permissions_boundary_arn

  tags = {
    Name      = "${local.resource_prefix}-${each.key}-caller"
    Portfolio = "step-4"
    Player    = each.key
  }
}

resource "aws_iam_role_policy" "caller" {
  for_each = aws_iam_role.caller

  name = "${local.resource_prefix}-${each.key}-invoke"
  role = each.value.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "InvokeLabQuizApi"
      Effect   = "Allow"
      Action   = "execute-api:Invoke"
      Resource = "${aws_api_gateway_rest_api.quiz.execution_arn}/${var.api_stage_name}/*/*"
    }]
  })
}
