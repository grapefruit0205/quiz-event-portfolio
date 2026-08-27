resource "aws_dynamodb_table" "players" {
  name         = "${local.resource_prefix}-players"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "player_id"

  deletion_protection_enabled = var.dynamodb_deletion_protection_enabled

  attribute {
    name = "player_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled                 = true
    recovery_period_in_days = var.dynamodb_pitr_recovery_period_days
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Name     = "${local.resource_prefix}-players"
    DataType = "current-state"
  }
}

resource "aws_dynamodb_table" "events" {
  name         = "${local.resource_prefix}-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "player_id"
  range_key    = "event_id"

  deletion_protection_enabled = var.dynamodb_deletion_protection_enabled
  stream_enabled              = true
  stream_view_type            = "NEW_IMAGE"

  attribute {
    name = "player_id"
    type = "S"
  }

  attribute {
    name = "event_id"
    type = "S"
  }

  attribute {
    name = "recovery_pk"
    type = "S"
  }

  attribute {
    name = "recovery_sk"
    type = "S"
  }

  global_secondary_index {
    name            = "recovery-by-time"
    projection_type = "ALL"

    key_schema {
      attribute_name = "recovery_pk"
      key_type       = "HASH"
    }

    key_schema {
      attribute_name = "recovery_sk"
      key_type       = "RANGE"
    }
  }

  point_in_time_recovery {
    enabled                 = true
    recovery_period_in_days = var.dynamodb_pitr_recovery_period_days
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Name     = "${local.resource_prefix}-events"
    DataType = "immutable-history"
  }
}
