resource "aws_iam_role" "firehose" {
  name = "${local.resource_prefix}-firehose"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Service = "firehose.amazonaws.com"
      }
    }]
  })
  permissions_boundary = var.permissions_boundary_arn

  tags = {
    Name      = "${local.resource_prefix}-firehose"
    Portfolio = "step-5"
  }
}

resource "aws_iam_role_policy" "firehose" {
  name = "${local.resource_prefix}-firehose"
  role = aws_iam_role.firehose.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteRawEventObjects"
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:GetBucketLocation",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:PutObject",
        ]
        Resource = [
          aws_s3_bucket.data["raw-events"].arn,
          "${aws_s3_bucket.data["raw-events"].arn}/*",
        ]
      },
      {
        Sid      = "WriteDeliveryLogs"
        Effect   = "Allow"
        Action   = "logs:PutLogEvents"
        Resource = "${aws_cloudwatch_log_group.firehose.arn}:log-stream:${aws_cloudwatch_log_stream.firehose.name}"
      },
    ]
  })
}

resource "aws_iam_role" "pipe" {
  name = "${local.resource_prefix}-pipe"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Service = "pipes.amazonaws.com"
      }
    }]
  })
  permissions_boundary = var.permissions_boundary_arn

  tags = {
    Name      = "${local.resource_prefix}-pipe"
    Portfolio = "step-5"
  }
}

resource "aws_iam_role_policy" "pipe" {
  name = "${local.resource_prefix}-pipe"
  role = aws_iam_role.pipe.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadEventsStream"
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeStream",
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator",
        ]
        Resource = aws_dynamodb_table.events.stream_arn
      },
      {
        Sid      = "ListStreams"
        Effect   = "Allow"
        Action   = "dynamodb:ListStreams"
        Resource = "*"
      },
      {
        Sid    = "PutFirehoseRecords"
        Effect = "Allow"
        Action = [
          "firehose:PutRecord",
          "firehose:PutRecordBatch",
        ]
        Resource = aws_kinesis_firehose_delivery_stream.events.arn
      },
      {
        Sid      = "SendFailedRecordsToDlq"
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.pipe_dlq.arn
      },
    ]
  })
}
