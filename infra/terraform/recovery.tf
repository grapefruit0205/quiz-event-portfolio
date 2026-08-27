resource "aws_dynamodb_table" "recovery_jobs" {
  name         = "${local.resource_prefix}-recovery-jobs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_id"

  deletion_protection_enabled = var.dynamodb_deletion_protection_enabled

  on_demand_throughput {
    max_read_request_units  = var.recovery_jobs_max_request_units
    max_write_request_units = var.recovery_jobs_max_request_units
  }

  attribute {
    name = "job_id"
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
    Name      = "${local.resource_prefix}-recovery-jobs"
    DataType  = "recovery-control"
    Portfolio = "step-7"
  }
}
