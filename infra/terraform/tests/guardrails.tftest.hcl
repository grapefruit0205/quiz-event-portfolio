mock_provider "aws" {
  override_during = plan
}

override_data {
  target = data.aws_partition.current
  values = {
    partition = "aws"
  }
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
    arn        = "arn:aws:iam::123456789012:user/terraform-test"
    user_id    = "AIDATEST"
  }
}

override_data {
  target = data.aws_availability_zones.available
  values = {
    names = ["ap-northeast-2a", "ap-northeast-2b"]
  }
}

run "step4_guardrails" {
  command = plan

  assert {
    condition     = length(aws_subnet.private) == 2
    error_message = "프라이빗 서브넷은 서로 다른 두 AZ에 하나씩 있어야 합니다."
  }

  assert {
    condition     = alltrue([for subnet in aws_subnet.private : subnet.map_public_ip_on_launch == false])
    error_message = "프라이빗 서브넷은 공개 IPv4 자동 할당을 금지해야 합니다."
  }

  assert {
    condition     = aws_vpc_endpoint.dynamodb.vpc_endpoint_type == "Gateway"
    error_message = "DynamoDB 연결은 추가 시간당 비용이 없는 Gateway endpoint여야 합니다."
  }

  assert {
    condition     = length(aws_route_table.private) == 2
    error_message = "DynamoDB endpoint에 연결할 프라이빗 라우팅 테이블은 두 개여야 합니다."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.dynamodb_https.from_port == 443 && aws_vpc_security_group_egress_rule.dynamodb_https.to_port == 443
    error_message = "Lambda 보안 그룹은 DynamoDB prefix list의 HTTPS만 허용해야 합니다."
  }

  assert {
    condition     = aws_dynamodb_table.players.billing_mode == "PAY_PER_REQUEST" && aws_dynamodb_table.events.billing_mode == "PAY_PER_REQUEST"
    error_message = "작은 실습의 두 테이블은 온디맨드 용량 모드를 사용해야 합니다."
  }

  assert {
    condition     = aws_dynamodb_table.players.deletion_protection_enabled && aws_dynamodb_table.events.deletion_protection_enabled
    error_message = "두 테이블 모두 삭제 보호가 필요합니다."
  }

  assert {
    condition     = aws_dynamodb_table.players.point_in_time_recovery[0].enabled && aws_dynamodb_table.events.point_in_time_recovery[0].enabled
    error_message = "두 테이블 모두 PITR을 활성화해야 합니다."
  }

  assert {
    condition     = aws_dynamodb_table.events.stream_enabled && aws_dynamodb_table.events.stream_view_type == "NEW_IMAGE"
    error_message = "Events 테이블은 다음 단계 전달을 위한 NEW_IMAGE stream이 필요합니다."
  }

  assert {
    condition     = length(aws_s3_bucket.data) == 3
    error_message = "raw-events, athena-results, recovery 용도의 버킷 세 개가 필요합니다."
  }

  assert {
    condition = alltrue([
      for settings in aws_s3_bucket_public_access_block.data :
      settings.block_public_acls && settings.block_public_policy && settings.ignore_public_acls && settings.restrict_public_buckets
    ])
    error_message = "모든 S3 버킷에서 네 가지 Block Public Access 설정을 켜야 합니다."
  }

  assert {
    condition = alltrue([
      for versioning in aws_s3_bucket_versioning.data :
      versioning.versioning_configuration[0].status == "Enabled"
    ])
    error_message = "모든 S3 버킷에서 Versioning을 활성화해야 합니다."
  }

  assert {
    condition = (
      aws_dynamodb_table.players.on_demand_throughput[0].max_read_request_units == 100 &&
      aws_dynamodb_table.players.on_demand_throughput[0].max_write_request_units == 100 &&
      aws_dynamodb_table.events.on_demand_throughput[0].max_read_request_units == 100 &&
      aws_dynamodb_table.events.on_demand_throughput[0].max_write_request_units == 100
    )
    error_message = "두 DynamoDB 테이블은 기본 최대 요청 단위 100의 비용 가드레일이 필요합니다."
  }

  assert {
    condition     = aws_api_gateway_rest_api.quiz.endpoint_configuration[0].types[0] == "REGIONAL"
    error_message = "API Gateway는 단일 서울 리전 REGIONAL endpoint여야 합니다."
  }

  assert {
    condition     = length(aws_api_gateway_method.quiz) == 3 && alltrue([for method in aws_api_gateway_method.quiz : method.authorization == "AWS_IAM"])
    error_message = "세 API method 모두 SigV4 AWS_IAM 인증이 필요합니다."
  }

  assert {
    condition     = alltrue([for integration in aws_api_gateway_integration.lambda : integration.type == "AWS_PROXY" && integration.integration_http_method == "POST"])
    error_message = "모든 API method는 Lambda proxy integration을 사용해야 합니다."
  }

  assert {
    condition = (
      aws_api_gateway_method_settings.all.method_path == "*/*" &&
      aws_api_gateway_method_settings.all.settings[0].throttling_rate_limit == 5 &&
      aws_api_gateway_method_settings.all.settings[0].throttling_burst_limit == 10 &&
      !aws_api_gateway_method_settings.all.settings[0].data_trace_enabled &&
      !aws_api_gateway_method_settings.all.settings[0].metrics_enabled
    )
    error_message = "lab stage 전체에 5 req/s, burst 10 제한을 두고 유료 상세 로그·지표는 꺼야 합니다."
  }

  assert {
    condition = (
      aws_lambda_function.api.runtime == "python3.12" &&
      aws_lambda_function.api.architectures[0] == "arm64" &&
      aws_lambda_function.api.timeout == 10 &&
      aws_lambda_function.api.memory_size == 256 &&
      length(aws_lambda_function.api.vpc_config) == 1
    )
    error_message = "Lambda는 작고 제한된 런타임으로 두 프라이빗 서브넷에 연결해야 합니다."
  }

  assert {
    condition     = aws_cloudwatch_log_group.api.retention_in_days == 7 && aws_lambda_function.api.logging_config[0].log_format == "JSON"
    error_message = "Lambda 로그는 JSON 형식과 7일 보관을 사용해야 합니다."
  }

  assert {
    condition = (
      aws_wafv2_web_acl.api.scope == "REGIONAL" &&
      one(one(one(aws_wafv2_web_acl.api.rule).statement).rate_based_statement).aggregate_key_type == "IP" &&
      one(one(one(aws_wafv2_web_acl.api.rule).statement).rate_based_statement).evaluation_window_sec == 60 &&
      one(one(one(aws_wafv2_web_acl.api.rule).statement).rate_based_statement).limit == 100 &&
      !one(aws_wafv2_web_acl.api.rule).visibility_config[0].sampled_requests_enabled &&
      !aws_wafv2_web_acl.api.visibility_config[0].sampled_requests_enabled
    )
    error_message = "Regional WAF는 IP별 60초 100요청 rate rule 하나와 본문 없는 지표만 사용해야 합니다."
  }

  assert {
    condition = (
      length(aws_iam_role.caller) == 2 &&
      alltrue([for player, role in aws_iam_role.caller : role.tags.Player == player]) &&
      alltrue([for role in aws_iam_role.caller : jsondecode(role.assume_role_policy).Statement[0].Principal.AWS == "arn:aws:iam::123456789012:user/terraform-test"])
    )
    error_message = "Alice/Bob 역할은 배포 운영자만 assume할 수 있게 분리해야 합니다."
  }

  assert {
    condition = (
      aws_sqs_queue.pipe_dlq.message_retention_seconds == 1209600 &&
      aws_sqs_queue.pipe_dlq.sqs_managed_sse_enabled
    )
    error_message = "Pipe DLQ는 SQS 관리형 암호화와 14일 보관을 사용해야 합니다."
  }

  assert {
    condition = (
      aws_kinesis_firehose_delivery_stream.events.destination == "extended_s3" &&
      aws_kinesis_firehose_delivery_stream.events.extended_s3_configuration[0].buffering_interval == 60 &&
      aws_kinesis_firehose_delivery_stream.events.extended_s3_configuration[0].buffering_size == 1 &&
      aws_kinesis_firehose_delivery_stream.events.extended_s3_configuration[0].compression_format == "GZIP" &&
      startswith(aws_kinesis_firehose_delivery_stream.events.extended_s3_configuration[0].prefix, "raw/schema_version=2/format=ndjson/") &&
      one(aws_kinesis_firehose_delivery_stream.events.extended_s3_configuration[0].processing_configuration[0].processors).type == "AppendDelimiterToRecord"
    )
    error_message = "Firehose는 Kinesis 없이 GZIP NDJSON을 S3에 직접 전달해야 합니다."
  }

  assert {
    condition = (
      aws_pipes_pipe.events.desired_state == "RUNNING" &&
      aws_pipes_pipe.events.source_parameters[0].dynamodb_stream_parameters[0].starting_position == "LATEST" &&
      aws_pipes_pipe.events.source_parameters[0].dynamodb_stream_parameters[0].batch_size == 10 &&
      aws_pipes_pipe.events.source_parameters[0].dynamodb_stream_parameters[0].maximum_retry_attempts == 3 &&
      aws_pipes_pipe.events.source_parameters[0].dynamodb_stream_parameters[0].maximum_record_age_in_seconds == 3600 &&
      !strcontains(aws_pipes_pipe.events.target_parameters[0].input_template, "\n") &&
      length(aws_pipes_pipe.events.source_parameters[0].dynamodb_stream_parameters[0].dead_letter_config) == 1
    )
    error_message = "Pipe는 LATEST부터 작은 batch·제한된 retry·SQS DLQ로 전달해야 합니다."
  }

  assert {
    condition = (
      aws_glue_catalog_table.quiz_events.table_type == "EXTERNAL_TABLE" &&
      aws_glue_catalog_table.quiz_events.parameters.classification == "json" &&
      aws_athena_workgroup.analytics.configuration[0].enforce_workgroup_configuration &&
      aws_athena_workgroup.analytics.configuration[0].bytes_scanned_cutoff_per_query == 10485760 &&
      aws_athena_workgroup.analytics.configuration[0].result_configuration[0].encryption_configuration[0].encryption_option == "SSE_S3"
    )
    error_message = "Glue JSON table과 10 MiB 스캔 상한·SSE-S3 결과의 Athena workgroup이 필요합니다."
  }
}
