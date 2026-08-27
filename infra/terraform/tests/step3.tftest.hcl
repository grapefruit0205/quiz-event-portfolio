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

run "step3_guardrails" {
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
}
