terraform {
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
