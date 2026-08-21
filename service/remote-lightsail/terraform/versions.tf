terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

# 자격증명은 scripts/ 와 동일하게 AWS CLI 기본 체인을 그대로 쓴다
# (aws configure 로 설정한 것). 여기 값을 따로 넣지 않는다.
provider "aws" {
  region = var.region
}
