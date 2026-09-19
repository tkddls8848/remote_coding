# state 는 기본적으로 로컬 파일(terraform.tfstate)에 남는다. 그 파일에는 SSH 키·IP·
# 리소스 ID 가 들어 있고, 관리 PC 를 잃으면 인프라 상태도 함께 사라진다.
# S3 remote backend 로 옮기려면 backend.tf.example 을 backend.tf 로 복사한 뒤
# `terraform init -migrate-state` 를 한 번 돌린다 (docs/stability-plan.md 3.1).
terraform {
  # S3 네이티브 잠금(use_lockfile)을 쓰려면 실행 환경이 1.10 이상이어야 한다.
  # 로컬 state 로만 쓸 때는 1.5.0 이상이면 된다.
  required_version = ">= 1.5.0"

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

  # 이 계정의 Lightsail 자원은 전부 이 모듈이 만든다 — 입주 앱 저장소는 AWS 자원을
  # 만들지 않는다. 그래서 태그도 여기 한 곳에서만 나온다. 키 표기(Project/ManagedBy)는
  # 입주 앱 저장소의 문서와 같은 것을 쓴다.
  default_tags {
    tags = merge({ Project = var.instance_name }, var.tags)
  }
}
