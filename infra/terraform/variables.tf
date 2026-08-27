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

variable "additional_tags" {
  description = "기본 태그에 추가할 사용자 태그"
  type        = map(string)
  default     = {}
}
