resource "aws_sqs_queue" "pipe_dlq" {
  name                       = "${local.resource_prefix}-pipe-dlq"
  message_retention_seconds  = 1209600
  visibility_timeout_seconds = 60
  receive_wait_time_seconds  = 10
  sqs_managed_sse_enabled    = true

  tags = {
    Name      = "${local.resource_prefix}-pipe-dlq"
    Portfolio = "step-5"
  }
}

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/${local.resource_prefix}-events"
  retention_in_days = 7

  tags = {
    Portfolio = "step-5"
  }
}

resource "aws_cloudwatch_log_stream" "firehose" {
  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

resource "aws_kinesis_firehose_delivery_stream" "events" {
  name        = "${local.resource_prefix}-events"
  destination = "extended_s3"

  server_side_encryption {
    enabled  = true
    key_type = "AWS_OWNED_CMK"
  }

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = aws_s3_bucket.data["raw-events"].arn

    prefix              = "raw/schema_version=2/format=ndjson/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/"
    error_output_prefix = "errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    buffering_size      = 1
    buffering_interval  = 60
    compression_format  = "GZIP"

    processing_configuration {
      enabled = true

      processors {
        type = "AppendDelimiterToRecord"
      }
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose.name
    }
  }

  depends_on = [aws_iam_role_policy.firehose]

  tags = {
    Portfolio = "step-5"
  }
}

resource "aws_pipes_pipe" "events" {
  name          = "${local.resource_prefix}-events"
  description   = "QuizCompleted stream records to Firehose Direct PUT"
  desired_state = "RUNNING"
  role_arn      = aws_iam_role.pipe.arn
  source        = aws_dynamodb_table.events.stream_arn
  target        = aws_kinesis_firehose_delivery_stream.events.arn

  source_parameters {
    filter_criteria {
      filter {
        pattern = jsonencode({
          eventName = ["INSERT"]
          dynamodb = {
            NewImage = {
              event_type     = { S = ["QuizCompleted"] }
              schema_version = { N = ["2"] }
            }
          }
        })
      }
    }

    dynamodb_stream_parameters {
      batch_size                         = 10
      maximum_batching_window_in_seconds = 1
      maximum_record_age_in_seconds      = 3600
      maximum_retry_attempts             = 3
      on_partial_batch_item_failure      = "AUTOMATIC_BISECT"
      parallelization_factor             = 1
      starting_position                  = "LATEST"

      dead_letter_config {
        arn = aws_sqs_queue.pipe_dlq.arn
      }
    }
  }

  target_parameters {
    input_template = trimspace(<<-JSON
      {"schema_version":<$.dynamodb.NewImage.schema_version.N>,"event_type":<$.dynamodb.NewImage.event_type.S>,"player_id":<$.dynamodb.NewImage.player_id.S>,"event_id":<$.dynamodb.NewImage.event_id.S>,"entity_version":<$.dynamodb.NewImage.entity_version.N>,"quiz_id":<$.dynamodb.NewImage.quiz_id.S>,"score":<$.dynamodb.NewImage.score.N>,"correct_count":<$.dynamodb.NewImage.correct_count.N>,"question_count":<$.dynamodb.NewImage.question_count.N>,"recorded_at":<$.dynamodb.NewImage.recorded_at.S>,"test_run_id":<$.dynamodb.NewImage.test_run_id.S>,"request_hash":<$.dynamodb.NewImage.request_hash.S>,"payload_hash":<$.dynamodb.NewImage.payload_hash.S>,"body_json":<$.dynamodb.NewImage.body_json.S>,"response_json":<$.dynamodb.NewImage.response_json.S>,"recovery_pk":<$.dynamodb.NewImage.recovery_pk.S>,"recovery_sk":<$.dynamodb.NewImage.recovery_sk.S>,"stream_sequence_number":<$.dynamodb.SequenceNumber>,"pipe_ingestion_time":<aws.pipes.event.ingestion-time>}
    JSON
    )
  }

  depends_on = [aws_iam_role_policy.pipe]

  tags = {
    Portfolio = "step-5"
  }
}

resource "aws_glue_catalog_database" "analytics" {
  name        = replace(local.resource_prefix, "-", "_")
  description = "Quiz event portfolio schema 2 analytics"

  tags = {
    Portfolio = "step-5"
  }
}

resource "aws_glue_catalog_table" "quiz_events" {
  name          = "quiz_events_v2"
  database_name = aws_glue_catalog_database.analytics.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL        = "TRUE"
    classification  = "json"
    compressionType = "gzip"
    typeOfData      = "file"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.data["raw-events"].id}/raw/schema_version=2/format=ndjson/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    compressed    = true

    dynamic "columns" {
      for_each = {
        schema_version         = "string"
        event_type             = "string"
        player_id              = "string"
        event_id               = "string"
        entity_version         = "string"
        quiz_id                = "string"
        score                  = "string"
        correct_count          = "string"
        question_count         = "string"
        recorded_at            = "string"
        test_run_id            = "string"
        request_hash           = "string"
        payload_hash           = "string"
        body_json              = "string"
        response_json          = "string"
        recovery_pk            = "string"
        recovery_sk            = "string"
        stream_sequence_number = "string"
        pipe_ingestion_time    = "string"
      }
      content {
        name = columns.key
        type = columns.value
      }
    }

    ser_de_info {
      name                  = "OpenXJsonSerDe"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters = {
        "case.insensitive" = "true"
      }
    }
  }
}

resource "aws_athena_workgroup" "analytics" {
  name        = "${local.resource_prefix}-analytics"
  description = "Bounded quiz event portfolio queries"
  state       = "ENABLED"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = 10485760

    result_configuration {
      output_location = "s3://${aws_s3_bucket.data["athena-results"].id}/${local.athena_result_prefix}/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  tags = {
    Portfolio = "step-5"
  }
}
