terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region = "us-east-2"
}

# Prueba: servicio App Runner con la imagen pública de ejemplo de AWS
resource "aws_apprunner_service" "catalogo" {
  service_name = "lab2-catalogo"

  source_configuration {
    auto_deployments_enabled = false
    image_repository {
      image_identifier      = "public.ecr.aws/aws-containers/hello-app-runner:latest"
      image_repository_type = "ECR_PUBLIC"
      image_configuration {
        port = "8000"
      }
    }
  }

  instance_configuration {
    cpu    = "256"
    memory = "512"
  }
}

output "url_apprunner" {
  value = "https://${aws_apprunner_service.catalogo.service_url}"
}