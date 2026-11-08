terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region = "us-east-2"
  default_tags {
    tags = { Proyecto = "lab2-beanstalk-vs-apprunner" }
  }
}

# Tabla de planes (la llena la app de Beanstalk)
resource "aws_dynamodb_table" "planes" {
  name         = "lab2-planes"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  attribute {
    name = "id"
    type = "S"
  }
}

# Tabla del catálogo (la lee la app de App Runner)
resource "aws_dynamodb_table" "ingredientes" {
  name         = "lab2-ingredientes"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  attribute {
    name = "id"
    type = "S"
  }
}

# Carga los ingredientes solo si ya existe el archivo de Karina
locals {
  archivo      = "${path.module}/../../datos/ingredientes.json"
  ingredientes = fileexists(local.archivo) ? jsondecode(file(local.archivo)) : []
}

resource "aws_dynamodb_table_item" "ingrediente" {
  for_each   = { for i in local.ingredientes : tostring(i.id) => i }
  table_name = aws_dynamodb_table.ingredientes.name
  hash_key   = "id"
  item = jsonencode({
    id        = { S = tostring(each.value.id) }
    nombre    = { S = each.value.nombre }
    categoria = { S = each.value.categoria }
    kcal      = { N = tostring(each.value.kcal) }
  })
}

# Cola de planes con su cola de errores (DLQ)
resource "aws_sqs_queue" "planes_dlq" {
  name = "lab2-planes-dlq"
}

resource "aws_sqs_queue" "planes" {
  name                       = "lab2-planes"
  visibility_timeout_seconds = 60
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.planes_dlq.arn
    maxReceiveCount     = 3
  })
}

# Repositorios de imágenes Docker
resource "aws_ecr_repository" "app" {
  for_each     = toset(["lab2-planes-web", "lab2-planes-worker", "lab2-catalogo"])
  name         = each.key
  force_delete = true
}

output "repositorios" {
  value = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}
output "cola_url" {
  value = aws_sqs_queue.planes.url
}