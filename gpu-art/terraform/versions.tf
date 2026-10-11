# state 는 기본적으로 이 디렉터리의 로컬 terraform.tfstate 에 남는다. 최상위 terraform/ 과
# state 를 섞지 않는다 — 그림 서버는 Orca 호스트와 수명이 달라서(필요할 때만 켜고, 통째로
# 지웠다 다시 만들기도 한다) 따로 관리한다.
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

# 자격증명은 최상위 terraform/ 과 같이 AWS CLI 기본 체인을 그대로 쓴다.
provider "aws" {
  region = var.region

  default_tags {
    tags = merge({ Project = var.instance_name }, var.tags)
  }
}
