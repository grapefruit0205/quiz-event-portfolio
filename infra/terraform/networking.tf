resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.resource_prefix}-vpc"
  }
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.value.az
  cidr_block              = each.value.cidr
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.resource_prefix}-private-${each.key}"
    Tier = "private"
  }
}

resource "aws_route_table" "private" {
  for_each = local.private_subnets

  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.resource_prefix}-private-${each.key}"
  }
}

resource "aws_route_table_association" "private" {
  for_each = local.private_subnets

  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

resource "aws_security_group" "lambda" {
  name        = "${local.resource_prefix}-lambda"
  description = "No ingress; HTTPS egress only to the regional DynamoDB prefix list"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.resource_prefix}-lambda"
  }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for route_table in aws_route_table.private : route_table.id]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "OnlyPortfolioTables"
      Effect    = "Allow"
      Principal = "*"
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
    }]
  })

  tags = {
    Name = "${local.resource_prefix}-dynamodb"
  }
}

resource "aws_vpc_security_group_egress_rule" "dynamodb_https" {
  security_group_id = aws_security_group.lambda.id
  description       = "HTTPS to the regional DynamoDB gateway endpoint"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = aws_vpc_endpoint.dynamodb.prefix_list_id
}
