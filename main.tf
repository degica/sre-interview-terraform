terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  profile = "sandbox"
  region  = "ap-northeast-1"
}

resource "aws_vpc" "testvpc" {
  cidr_block = "10.1.0.0/16"
}

resource "aws_internet_gateway" "testgateway" {
  vpc_id = aws_vpc.testvpc.id
}

resource "aws_subnet" "testappsubnet" {
  vpc_id            = aws_vpc.testvpc.id
  cidr_block        = "10.1.110.0/24"
  availability_zone = "ap-northeast-1a"
}

resource "aws_subnet" "testnatsubnet" {
  vpc_id                  = aws_vpc.testvpc.id
  cidr_block              = "10.1.100.0/24"
  availability_zone       = "ap-northeast-1a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "testalbsubneta" {
  vpc_id                  = aws_vpc.testvpc.id
  cidr_block              = "10.1.4.0/24"
  availability_zone       = "ap-northeast-1a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "testalbsubnetc" {
  vpc_id                  = aws_vpc.testvpc.id
  cidr_block              = "10.1.5.0/24"
  availability_zone       = "ap-northeast-1c"
  map_public_ip_on_launch = true
}

resource "aws_ecs_cluster" "testcluster" {
  name = "test-ecs-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_route_table" "testalbroutetable" {
  vpc_id = aws_vpc.testvpc.id
}

resource "aws_route" "albroute" {
  route_table_id         = aws_route_table.testalbroutetable.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.testgateway.id
}

resource "aws_route_table_association" "albrouteassoc_a" {
  subnet_id      = aws_subnet.testalbsubneta.id
  route_table_id = aws_route_table.testalbroutetable.id
}

resource "aws_route_table_association" "albrouteassoc_c" {
  subnet_id      = aws_subnet.testalbsubnetc.id
  route_table_id = aws_route_table.testalbroutetable.id
}

resource "aws_route_table_association" "natrouteassoc" {
  subnet_id      = aws_subnet.testnatsubnet.id
  route_table_id = aws_route_table.testalbroutetable.id
}

resource "aws_route" "testalbroute" {
  route_table_id         = aws_route_table.testalbroutetable.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.testgateway.id
}


resource "aws_nat_gateway" "testappgateway" {
  allocation_id = aws_eip.testnatip.id
  subnet_id     = aws_subnet.testnatsubnet.id
  depends_on    = [aws_internet_gateway.testgateway]
}

resource "aws_eip" "testnatip" {
  vpc = true
}

resource "aws_route_table" "testapproutetable" {
  vpc_id = aws_vpc.testvpc.id
}

resource "aws_route" "testapproute" {
  route_table_id         = aws_route_table.testapproutetable.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.testappgateway.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.testappsubnet.id
  route_table_id = aws_route_table.testapproutetable.id
}




resource "aws_iam_role" "testecsrole" {
  name = "ECSTaskRole"

  assume_role_policy = <<EOF
{
 "Version": "2012-10-17",
 "Statement": [
   {
     "Action": "sts:AssumeRole",
     "Principal": {
       "Service": "ecs-tasks.amazonaws.com"
     },
     "Effect": "Allow",
     "Sid": ""
   }
 ]
}
EOF
}

resource "aws_iam_role" "testecsexecutionrole" {
  name = "ECSTaskExecutionRole"

  assume_role_policy = <<EOF
{
 "Version": "2012-10-17",
 "Statement": [
   {
     "Action": "sts:AssumeRole",
     "Principal": {
       "Service": "ecs-tasks.amazonaws.com"
     },
     "Effect": "Allow",
     "Sid": ""
   }
 ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "testattachment" {
  role       = aws_iam_role.testecsexecutionrole.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "testtaskdef" {
  network_mode             = "awsvpc"
  family                   = "main"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.testecsexecutionrole.arn
  task_role_arn            = aws_iam_role.testecsrole.arn
  container_definitions = jsonencode([{
    name      = "hello-world"
    image     = "public.ecr.aws/degica/barcelona-hello:latest"
    essential = true
    environment = [{
      "name" = "hello"
    }]
    portMappings = [{
      protocol      = "tcp"
      containerPort = 3000
    }]
  }])
}

resource "aws_ecs_service" "testhelloworld" {
  name                               = "testhelloworld"
  cluster                            = aws_ecs_cluster.testcluster.id
  task_definition                    = aws_ecs_task_definition.testtaskdef.arn
  desired_count                      = 1
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200
  launch_type                        = "FARGATE"
  scheduling_strategy                = "REPLICA"

  network_configuration {
    security_groups  = [aws_security_group.testappsg.id]
    subnets          = [aws_subnet.testappsubnet.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_alb_target_group.testtargetgroup.arn
    container_name   = "hello-world"
    container_port   = "3000"
  }

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}

resource "aws_security_group" "testappsg" {
  name   = "testappsg"
  vpc_id = aws_vpc.testvpc.id

  ingress {
    protocol         = "tcp"
    from_port        = 3000
    to_port          = 3000
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    protocol         = "-1"
    from_port        = 0
    to_port          = 0
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_security_group" "testalbsg" {
  name   = "testalbsg"
  vpc_id = aws_vpc.testvpc.id

  ingress {
    protocol         = "tcp"
    from_port        = 80
    to_port          = 80
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    protocol         = "-1"
    from_port        = 0
    to_port          = 0
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_lb" "testlb" {
  name               = "testlb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.testalbsg.id]
  subnets            = [
    aws_subnet.testalbsubneta.id,
    aws_subnet.testalbsubnetc.id
  ]

  enable_deletion_protection = false
}

resource "aws_alb_target_group" "testtargetgroup" {
  name        = "testtargetgroup"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.testvpc.id
  target_type = "ip"

  health_check {
    healthy_threshold   = "3"
    interval            = "30"
    protocol            = "HTTP"
    matcher             = "200"
    timeout             = "3"
    path                = "/"
    unhealthy_threshold = "2"
  }
}

resource "aws_alb_listener" "httplistener" {
  load_balancer_arn = aws_lb.testlb.id
  port              = 80
  protocol          = "HTTP"
 
  default_action {
    target_group_arn = aws_alb_target_group.testtargetgroup.id
    type             = "forward"
  }
}
 