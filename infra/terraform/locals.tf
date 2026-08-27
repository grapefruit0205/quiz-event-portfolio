locals {
  resource_prefix      = "${var.project_name}-${var.environment}"
  bucket_prefix        = substr(local.resource_prefix, 0, 20)
  athena_result_prefix = "step5"
  operator_principal_arn = (
    var.operator_principal_arn != null
    ? var.operator_principal_arn
    : data.aws_caller_identity.current.arn
  )

  common_tags = merge({
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Portfolio   = "step-3"
  }, var.additional_tags)

  private_subnets = {
    for index, cidr in var.private_subnet_cidrs : tostring(index + 1) => {
      cidr = cidr
      az   = data.aws_availability_zones.available.names[index]
    }
  }

  s3_purposes = toset([
    "raw-events",
    "athena-results",
    "recovery",
  ])

  s3_bucket_names = {
    for purpose in local.s3_purposes :
    purpose => "${local.bucket_prefix}-${data.aws_caller_identity.current.account_id}-${purpose}"
  }
}
