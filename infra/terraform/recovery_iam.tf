resource "aws_iam_role" "recovery_operator" {
  name = "${local.resource_prefix}-recovery-operator"
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
    Name      = "${local.resource_prefix}-recovery-operator"
    Portfolio = "step-7"
  }
}

resource "aws_iam_role_policy" "recovery_operator" {
  name = "${local.resource_prefix}-recovery-operator"
  role = aws_iam_role.recovery_operator.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadImmutableEventsByRecoveryIndex"
        Effect   = "Allow"
        Action   = "dynamodb:Query"
        Resource = "${aws_dynamodb_table.events.arn}/index/recovery-by-time"
      },
      {
        Sid    = "ControlRecoveryJobs"
        Effect = "Allow"
        Action = [
          "dynamodb:DeleteItem",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:TransactWriteItems",
          "dynamodb:UpdateItem",
        ]
        Resource = aws_dynamodb_table.recovery_jobs.arn
      },
      {
        Sid      = "ReplayToExistingFirehose"
        Effect   = "Allow"
        Action   = "firehose:PutRecord"
        Resource = aws_kinesis_firehose_delivery_stream.events.arn
      },
      {
        Sid      = "PauseForApiAlarms"
        Effect   = "Allow"
        Action   = "cloudwatch:DescribeAlarms"
        Resource = "*"
      },
      {
        Sid    = "InspectAthenaDestination"
        Effect = "Allow"
        Action = [
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StartQueryExecution",
          "athena:StopQueryExecution",
        ]
        Resource = aws_athena_workgroup.analytics.arn
      },
      {
        Sid    = "ReadAnalyticsCatalog"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetPartitions",
          "glue:GetTable",
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.analytics.name}",
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.analytics.name}/${aws_glue_catalog_table.quiz_events.name}",
        ]
      },
      {
        Sid      = "LocateAthenaResultBucket"
        Effect   = "Allow"
        Action   = "s3:GetBucketLocation"
        Resource = aws_s3_bucket.data["athena-results"].arn
      },
      {
        Sid      = "ListAthenaResults"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.data["athena-results"].arn
        Condition = {
          StringLike = {
            "s3:prefix" = [local.athena_result_prefix, "${local.athena_result_prefix}/*"]
          }
        }
      },
      {
        Sid    = "ReadWriteAthenaResults"
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:GetObject",
          "s3:ListMultipartUploadParts",
          "s3:PutObject",
        ]
        Resource = "${aws_s3_bucket.data["athena-results"].arn}/${local.athena_result_prefix}/*"
      },
      {
        Sid      = "ListCatalogedRawEvents"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.data["raw-events"].arn
        Condition = {
          StringLike = {
            "s3:prefix" = [
              "raw/schema_version=2/format=ndjson",
              "raw/schema_version=2/format=ndjson/*",
            ]
          }
        }
      },
      {
        Sid      = "ReadCatalogedRawEvents"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.data["raw-events"].arn}/raw/schema_version=2/format=ndjson/*"
      },
      {
        Sid      = "WriteRecoveryEvidence"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.data["recovery"].arn}/recovery-jobs/*"
      },
    ]
  })
}
