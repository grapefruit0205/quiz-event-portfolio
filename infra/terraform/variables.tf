variable "project_name" {
  description = "리소스 이름과 태그에 사용할 프로젝트 이름"
  type        = string
  default     = "quiz-event-portfolio"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,31}$", var.project_name))
    error_message = "project_name은 소문자로 시작하는 3~32자의 소문자·숫자·하이픈이어야 합니다."
  }
}

variable "environment" {
  description = "격리와 태그에 사용할 환경 이름"
  type        = string
  default     = "lab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,15}$", var.environment))
    error_message = "environment는 소문자로 시작하는 2~16자의 소문자·숫자·하이픈이어야 합니다."
  }
}

variable "aws_region" {
  description = "단일 배포 리전"
  type        = string
  default     = "ap-northeast-2"

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.aws_region))
    error_message = "aws_region은 ap-northeast-2와 같은 AWS 리전 형식이어야 합니다."
  }
}

variable "vpc_cidr" {
  description = "Step 3 전용 VPC IPv4 CIDR"
  type        = string
  default     = "10.40.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr은 유효한 IPv4 CIDR이어야 합니다."
  }
}

variable "private_subnet_cidrs" {
  description = "서로 다른 두 AZ에 배치할 프라이빗 서브넷 CIDR"
  type        = list(string)
  default     = ["10.40.1.0/24", "10.40.2.0/24"]

  validation {
    condition = (
      length(var.private_subnet_cidrs) == 2 &&
      length(distinct(var.private_subnet_cidrs)) == 2 &&
      alltrue([for cidr in var.private_subnet_cidrs : can(cidrhost(cidr, 0))])
    )
    error_message = "서로 다른 유효한 프라이빗 서브넷 CIDR 두 개가 필요합니다."
  }
}

variable "dynamodb_pitr_recovery_period_days" {
  description = "DynamoDB PITR 복구 기간. 기간을 줄여도 PITR 단가는 줄지 않습니다."
  type        = number
  default     = 14

  validation {
    condition     = var.dynamodb_pitr_recovery_period_days >= 1 && var.dynamodb_pitr_recovery_period_days <= 35
    error_message = "DynamoDB PITR 복구 기간은 1~35일이어야 합니다."
  }
}

variable "dynamodb_deletion_protection_enabled" {
  description = "실수로 테이블을 삭제하지 못하게 보호"
  type        = bool
  default     = true
}

variable "dynamodb_max_read_request_units" {
  description = "온디맨드 테이블별 최대 읽기 요청 단위. 실습 비용·부하 가드레일."
  type        = number
  default     = 100

  validation {
    condition     = var.dynamodb_max_read_request_units >= 1 && floor(var.dynamodb_max_read_request_units) == var.dynamodb_max_read_request_units
    error_message = "DynamoDB 최대 읽기 요청 단위는 1 이상의 정수여야 합니다."
  }
}

variable "dynamodb_max_write_request_units" {
  description = "온디맨드 테이블별 최대 쓰기 요청 단위. 실습 비용·부하 가드레일."
  type        = number
  default     = 100

  validation {
    condition     = var.dynamodb_max_write_request_units >= 1 && floor(var.dynamodb_max_write_request_units) == var.dynamodb_max_write_request_units
    error_message = "DynamoDB 최대 쓰기 요청 단위는 1 이상의 정수여야 합니다."
  }
}

variable "api_stage_name" {
  description = "API Gateway 배포 stage"
  type        = string
  default     = "lab"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,32}$", var.api_stage_name))
    error_message = "api_stage_name은 영숫자, 밑줄, 하이픈 1~32자여야 합니다."
  }
}

variable "api_throttling_rate_limit" {
  description = "API stage 전체 초당 정상 처리 목표"
  type        = number
  default     = 5

  validation {
    condition     = var.api_throttling_rate_limit > 0 && var.api_throttling_rate_limit <= 20
    error_message = "개인 실습 API rate limit은 0 초과 20 이하여야 합니다."
  }
}

variable "api_throttling_burst_limit" {
  description = "API stage 전체 순간 burst 목표"
  type        = number
  default     = 10

  validation {
    condition     = var.api_throttling_burst_limit >= 1 && var.api_throttling_burst_limit <= 40 && floor(var.api_throttling_burst_limit) == var.api_throttling_burst_limit
    error_message = "개인 실습 API burst limit은 1~40 정수여야 합니다."
  }
}

variable "waf_rate_limit" {
  description = "같은 IP가 60초 동안 허용받는 요청 수. 초과 요청은 WAF에서 차단."
  type        = number
  default     = 100

  validation {
    condition     = var.waf_rate_limit >= 10 && floor(var.waf_rate_limit) == var.waf_rate_limit
    error_message = "WAF rate limit은 10 이상의 정수여야 합니다."
  }
}

variable "operator_principal_arn" {
  description = "Alice/Bob 호출 역할을 assume할 배포 사용자 또는 역할 ARN. null이면 현재 Terraform 호출자."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.operator_principal_arn == null || can(regex("^arn:[^:]+:iam::[0-9]{12}:(user|role)/.+$", var.operator_principal_arn))
    error_message = "operator_principal_arn은 장기 IAM user 또는 role ARN이어야 합니다."
  }
}

variable "allow_bucket_force_destroy" {
  description = "true이면 객체가 남은 버킷도 destroy가 삭제합니다. 정리 직전에만 명시적으로 사용합니다."
  type        = bool
  default     = false
}

variable "permissions_boundary_arn" {
  description = "조직 정책이 요구하는 IAM permissions boundary ARN. 개인 실습은 null."
  type        = string
  default     = null
  nullable    = true
}

variable "lambda_concurrency_warning_threshold" {
  description = "Quiz Lambda 동시 실행 경고값. 현재 개인 실습 계정 한도 10보다 낮게 둡니다."
  type        = number
  default     = 8

  validation {
    condition     = var.lambda_concurrency_warning_threshold >= 1 && var.lambda_concurrency_warning_threshold <= 20 && floor(var.lambda_concurrency_warning_threshold) == var.lambda_concurrency_warning_threshold
    error_message = "Lambda 동시 실행 경고값은 1~20 정수여야 합니다."
  }
}

variable "monthly_budget_usd" {
  description = "월간 비용 알림 기준. 강제 지출 상한은 아닙니다."
  type        = number
  default     = 20

  validation {
    condition     = var.monthly_budget_usd >= 1 && var.monthly_budget_usd <= 100
    error_message = "개인 실습 월 예산 알림은 US$1~100 범위여야 합니다."
  }
}

variable "additional_tags" {
  description = "기본 태그에 추가할 사용자 태그"
  type        = map(string)
  default     = {}
}
