terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.0" }
  }
}

provider "aws" {
  region = "us-east-2"
  default_tags {
    tags = { Proyecto = "lab2-beanstalk-vs-apprunner" }
  }
}

# Etiqueta de las imágenes en ECR (cámbiala si subes una versión nueva, por ejemplo v2)
variable "version_app" {
  default = "v1"
}

data "aws_caller_identity" "yo" {}

data "aws_availability_zones" "zonas" {
  state = "available"
}

# Recursos creados en terraform/comun
data "aws_ecr_repository" "web" {
  name = "lab2-planes-web"
}

data "aws_ecr_repository" "worker" {
  name = "lab2-planes-worker"
}

data "aws_sqs_queue" "planes" {
  name = "lab2-planes"
}

# ---------- Red: VPC con 2 subredes públicas en 2 zonas ----------
resource "aws_vpc" "eb" {
  cidr_block           = "10.30.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "lab2-eb-vpc" }
}

resource "aws_internet_gateway" "eb" {
  vpc_id = aws_vpc.eb.id
}

resource "aws_subnet" "publica" {
  count                   = 2
  vpc_id                  = aws_vpc.eb.id
  cidr_block              = "10.30.${count.index}.0/24"
  availability_zone       = data.aws_availability_zones.zonas.names[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "lab2-eb-publica-${count.index + 1}" }
}

resource "aws_route_table" "publica" {
  vpc_id = aws_vpc.eb.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.eb.id
  }
}

resource "aws_route_table_association" "publica" {
  count          = 2
  subnet_id      = aws_subnet.publica[count.index].id
  route_table_id = aws_route_table.publica.id
}

# ---------- Permisos ----------
# Rol que usa Beanstalk para manejar los recursos
resource "aws_iam_role" "servicio" {
  name = "lab2-eb-servicio"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "elasticbeanstalk.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "servicio" {
  for_each = toset([
    "arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkEnhancedHealth",
    "arn:aws:iam::aws:policy/AWSElasticBeanstalkManagedUpdatesCustomerRolePolicy",
  ])
  role       = aws_iam_role.servicio.name
  policy_arn = each.value
}

# Rol de los servidores EC2 (web y worker)
resource "aws_iam_role" "ec2" {
  name = "lab2-eb-ec2"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier",
    "arn:aws:iam::aws:policy/AWSElasticBeanstalkWorkerTier",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])
  role       = aws_iam_role.ec2.name
  policy_arn = each.value
}

# Acceso solo a nuestras tablas y colas (lab2-*)
resource "aws_iam_role_policy" "datos" {
  name = "lab2-eb-datos"
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Scan"]
        Resource = "arn:aws:dynamodb:us-east-2:${data.aws_caller_identity.yo.account_id}:table/lab2-*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ChangeMessageVisibility"]
        Resource = "arn:aws:sqs:us-east-2:${data.aws_caller_identity.yo.account_id}:lab2-*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "lab2-eb-ec2"
  role = aws_iam_role.ec2.name
}

# ---------- Versiones de la app (qué imagen Docker usa cada entorno) ----------
resource "aws_s3_bucket" "versiones" {
  bucket        = "lab2-eb-versiones-${data.aws_caller_identity.yo.account_id}"
  force_destroy = true
}

locals {
  imagenes = {
    web    = "${data.aws_ecr_repository.web.repository_url}:${var.version_app}"
    worker = "${data.aws_ecr_repository.worker.repository_url}:${var.version_app}"
  }
}

data "archive_file" "version" {
  for_each    = local.imagenes
  type        = "zip"
  output_path = "${path.module}/${each.key}-${var.version_app}.zip"
  source {
    filename = "Dockerrun.aws.json"
    content = jsonencode({
      AWSEBDockerrunVersion = "1"
      Image                 = { Name = each.value, Update = "true" }
      Ports                 = [{ ContainerPort = "8000" }]
    })
  }
}

resource "aws_s3_object" "version" {
  for_each = local.imagenes
  bucket   = aws_s3_bucket.versiones.id
  key      = "${each.key}-${var.version_app}.zip"
  source   = data.archive_file.version[each.key].output_path
  etag     = data.archive_file.version[each.key].output_md5
}

resource "aws_elastic_beanstalk_application" "app" {
  name = "lab2-planes"
}

resource "aws_elastic_beanstalk_application_version" "v" {
  for_each    = local.imagenes
  name        = "${each.key}-${var.version_app}"
  application = aws_elastic_beanstalk_application.app.name
  bucket      = aws_s3_bucket.versiones.id
  key         = aws_s3_object.version[each.key].key
}

data "aws_elastic_beanstalk_solution_stack" "docker" {
  most_recent = true
  name_regex  = "^64bit Amazon Linux 2023 (.*) running Docker$"
}

# ---------- Configuración ----------
locals {
  subredes = join(",", aws_subnet.publica[*].id)

  # Lo que comparten los dos entornos
  comun = [
    ["aws:ec2:vpc", "VPCId", aws_vpc.eb.id],
    ["aws:ec2:vpc", "Subnets", local.subredes],
    ["aws:ec2:vpc", "AssociatePublicIpAddress", "true"],
    ["aws:elasticbeanstalk:environment", "ServiceRole", aws_iam_role.servicio.arn],
    ["aws:autoscaling:launchconfiguration", "IamInstanceProfile", aws_iam_instance_profile.ec2.name],
    ["aws:autoscaling:launchconfiguration", "DisableIMDSv1", "true"],
    ["aws:elasticbeanstalk:healthreporting:system", "SystemType", "enhanced"],
    ["aws:elasticbeanstalk:cloudwatch:logs", "StreamLogs", "true"],
    ["aws:elasticbeanstalk:cloudwatch:logs", "DeleteOnTerminate", "true"],
    ["aws:elasticbeanstalk:application:environment", "AWS_REGION", "us-east-2"],
    ["aws:elasticbeanstalk:application:environment", "TABLA_PLANES", "lab2-planes"],
  ]

  # Entorno web: ALB + 2 a 4 EC2 t3.micro, escala por peticiones
  web = [
    ["aws:ec2:vpc", "ELBSubnets", local.subredes],
    ["aws:elasticbeanstalk:environment", "EnvironmentType", "LoadBalanced"],
    ["aws:elasticbeanstalk:environment", "LoadBalancerType", "application"],
    ["aws:elasticbeanstalk:environment:process:default", "HealthCheckPath", "/salud"],
    ["aws:ec2:instances", "InstanceTypes", "t3.micro"],
    ["aws:autoscaling:asg", "MinSize", "2"],
    ["aws:autoscaling:asg", "MaxSize", "4"],
    ["aws:autoscaling:trigger", "MeasureName", "RequestCount"],
    ["aws:autoscaling:trigger", "Statistic", "Sum"],
    ["aws:autoscaling:trigger", "Unit", "Count"],
    ["aws:autoscaling:trigger", "Period", "1"],
    ["aws:autoscaling:trigger", "BreachDuration", "1"],
    ["aws:autoscaling:trigger", "UpperThreshold", "2000"],
    ["aws:autoscaling:trigger", "LowerThreshold", "200"],
    ["aws:elasticbeanstalk:application:environment", "TABLA_INGREDIENTES", "lab2-ingredientes"],
    ["aws:elasticbeanstalk:application:environment", "COLA_URL", data.aws_sqs_queue.planes.url],
  ]

  # Entorno worker: lee la cola y escala de 1 a 3 t3.small por CPU
  worker = [
    ["aws:elasticbeanstalk:environment", "EnvironmentType", "LoadBalanced"],
    ["aws:ec2:instances", "InstanceTypes", "t3.small"],
    ["aws:autoscaling:asg", "MinSize", "1"],
    ["aws:autoscaling:asg", "MaxSize", "3"],
    ["aws:autoscaling:trigger", "MeasureName", "CPUUtilization"],
    ["aws:autoscaling:trigger", "Statistic", "Average"],
    ["aws:autoscaling:trigger", "Unit", "Percent"],
    ["aws:autoscaling:trigger", "Period", "1"],
    ["aws:autoscaling:trigger", "BreachDuration", "1"],
    ["aws:autoscaling:trigger", "UpperThreshold", "60"],
    ["aws:autoscaling:trigger", "LowerThreshold", "20"],
    ["aws:elasticbeanstalk:sqsd", "WorkerQueueURL", data.aws_sqs_queue.planes.url],
    ["aws:elasticbeanstalk:sqsd", "HttpPath", "/procesar"],
    ["aws:elasticbeanstalk:sqsd", "MimeType", "application/json"],
    ["aws:elasticbeanstalk:sqsd", "HttpConnections", "2"],
    ["aws:elasticbeanstalk:sqsd", "VisibilityTimeout", "60"],
    ["aws:elasticbeanstalk:sqsd", "InactivityTimeout", "50"],
    ["aws:elasticbeanstalk:sqsd", "MaxRetries", "3"],
    ["aws:elasticbeanstalk:application:environment", "SEGUNDOS_CPU", "15"],
  ]
}

resource "aws_elastic_beanstalk_environment" "web" {
  name                = "lab2-planes-web"
  application         = aws_elastic_beanstalk_application.app.name
  solution_stack_name = data.aws_elastic_beanstalk_solution_stack.docker.name
  version_label       = aws_elastic_beanstalk_application_version.v["web"].name
  tier                = "WebServer"

  dynamic "setting" {
    for_each = concat(local.comun, local.web)
    content {
      namespace = setting.value[0]
      name      = setting.value[1]
      value     = setting.value[2]
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.servicio,
    aws_iam_role_policy_attachment.ec2,
    aws_iam_role_policy.datos,
    aws_route_table_association.publica,
  ]
}

resource "aws_elastic_beanstalk_environment" "worker" {
  name                = "lab2-planes-worker"
  application         = aws_elastic_beanstalk_application.app.name
  solution_stack_name = data.aws_elastic_beanstalk_solution_stack.docker.name
  version_label       = aws_elastic_beanstalk_application_version.v["worker"].name
  tier                = "Worker"

  dynamic "setting" {
    for_each = concat(local.comun, local.worker)
    content {
      namespace = setting.value[0]
      name      = setting.value[1]
      value     = setting.value[2]
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.servicio,
    aws_iam_role_policy_attachment.ec2,
    aws_iam_role_policy.datos,
    aws_route_table_association.publica,
  ]
}

output "url_beanstalk" {
  value = "http://${aws_elastic_beanstalk_environment.web.cname}"
}
