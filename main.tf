
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}


variable "AWS_ACCESS_KEY_ID" {
  description = "AWS account access key"
  type        = string
}

variable "AWS_SECRET_ACCESS_KEY" {
  description = "AWS account secret key"
  type        = string
}

provider "aws" {
  region     = "us-west-2"
  access_key = var.AWS_ACCESS_KEY_ID
  secret_key = var.AWS_SECRET_ACCESS_KEY
}


# Create VPC
resource "aws_vpc" "my_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}



# Create Internet Gateway
resource "aws_internet_gateway" "my_igw" {
  vpc_id = aws_vpc.my_vpc.id
}

# Attach the Internet Gateway to the VPC
resource "aws_route" "route_to_igw" {
  route_table_id         = aws_vpc.my_vpc.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.my_igw.id
}

variable "availability_zones" {
  default = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
}


# Create public subnets
variable "subnet_names" {
  default = ["public_subnet1", "public_subnet2", "public_subnet3"]
}

resource "aws_subnet" "public_subnet" {
  count             = 3
  vpc_id            = aws_vpc.my_vpc.id
  cidr_block        = "10.0.1${count.index + 1}.0/24"
  availability_zone = var.availability_zones[count.index]

  map_public_ip_on_launch = true

  tags = {
    Name = element(var.subnet_names, count.index)
  }
}



variable "private_subnet_names" {
  default = ["private_subnet1", "private_subnet2", "private_subnet3"]
}

# Create private subnets
resource "aws_subnet" "private_subnet" {
  count             = 3
  vpc_id            = aws_vpc.my_vpc.id
  cidr_block        = "10.0.2${count.index + 1}.0/24"
  availability_zone = var.availability_zones[count.index]

  map_public_ip_on_launch = false

  tags = {
    Name = var.private_subnet_names[count.index]
  }
}




# Create a security group for EC2 instance
resource "aws_security_group" "instance_sg" {
  name        = "instance-sg"
  description = "Security group for EC2 instance in private subnet"
  vpc_id      = aws_vpc.my_vpc.id

  # Define ingress and egress rules as needed
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }


  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

}



# Create EC2 instances in private subnets
resource "aws_instance" "my_instance" {
  ami             = "ami-04fb7beeed4da358b"
  instance_type   = "t2.micro"
  subnet_id       = element(aws_subnet.private_subnet[*].id, 0)
  security_groups = [aws_security_group.instance_sg.id]
  key_name = "ec2 tutorial"

 

  user_data     = <<-EOF
                   #!/bin/bash
                   # Use this for your user data (script from top to bottom)
                   # install httpd (Linux 2 version)
                   yum update -y
                   yum install -y httpd
                   systemctl start httpd
                   systemctl enable httpd
                   echo "<h1>Hello World from $(hostname -f)</h1>" > /var/www/html/index.html
                   EOF

  tags = {
    Name = "my-instance"
  }
}



resource "aws_eip" "nat_eip" {
  instance = null 
  domain = "vpc"
}

resource "aws_nat_gateway" "nat_gateway" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = element(aws_subnet.public_subnet[*].id, 2)
}



resource "aws_route" "route_to_nat" {
  # count                  = length(var.private_subnet_names)
  route_table_id         = aws_route_table.private_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat_gateway.id
}

# Create private route table
resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.my_vpc.id
}

# Associate private route table with private subnets
resource "aws_route_table_association" "private_subnet_association" {
  count          = length(var.private_subnet_names)
  subnet_id      = aws_subnet.private_subnet[count.index].id
  route_table_id = aws_route_table.private_route_table.id
}


# Create public route table
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.my_vpc.id

}

# Associate public route table with public subnets
resource "aws_route_table_association" "public_subnet_association" {
  count          = length(var.subnet_names)
  subnet_id      = aws_subnet.public_subnet[count.index].id
  route_table_id = aws_route_table.public_route_table.id
}



# Create ALB in the public subnet
resource "aws_lb" "my_alb" {
  name               = "my-alb"
  internal           = false
  load_balancer_type = "application"

  subnets = [for index in range(length(var.subnet_names) - 1) : aws_subnet.public_subnet[index].id]


  enable_deletion_protection = false

  enable_http2 = true



  tags = {
    Name = "my-alb"
  }
}

# Create target group
resource "aws_lb_target_group" "my_target_group" {
  name     = "my-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.my_vpc.id

  health_check {
    path                = "/"
    port                = "80"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    interval            = 30
  }

  tags = {
    Name = "my-target-group"
  }
}

resource "aws_lb_target_group_attachment" "my_target_group_attachment" {
  target_group_arn = aws_lb_target_group.my_target_group.arn
  target_id        = aws_instance.my_instance.id
}


# Create listener and attach target group to ALB
resource "aws_lb_listener" "my_listener" {
  load_balancer_arn = aws_lb.my_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      status_code  = 200

      message_body = "OK"
    }
  }
}

resource "aws_lb_listener_rule" "my_listener_rule" {
  listener_arn = aws_lb_listener.my_listener.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.my_target_group.arn
  }

  condition {
    path_pattern {
      values = ["/"]
    }
  }
}


# Create launch configuration
resource "aws_launch_configuration" "my_launch_config2" {
  name          = "my-launch-config2"
  image_id      = "ami-04fb7beeed4da358b" 
  instance_type = "t2.micro"             
  key_name                    = "ec2 tutorial"
  associate_public_ip_address = true
  security_groups = [
    aws_security_group.instance_sg.id,
    
  ]

  # User data script to install Nginx
  user_data     = <<-EOF
                   #!/bin/bash
                   # Use this for your user data (script from top to bottom)
                   # install httpd (Linux 2 version)
                   yum update -y
                   yum install -y httpd
                   systemctl start httpd
                   systemctl enable httpd
                   echo "<h1>Hello World from $(hostname -f)</h1>" > /var/www/html/index.html
                   EOF


  

  lifecycle {
    create_before_destroy = true
  }
}

# Create Auto Scaling Group
resource "aws_autoscaling_group" "my_asg" {
  desired_capacity          = 2
  max_size                  = 4
  min_size                  = 1
  vpc_zone_identifier       = [aws_subnet.private_subnet[0].id] 
  launch_configuration      = aws_launch_configuration.my_launch_config2.id
  health_check_type         = "EC2"
  health_check_grace_period = 300
  force_delete              = true


}

# Attach instances to the target group
resource "aws_autoscaling_attachment" "my_asg_attachment" {
  autoscaling_group_name = aws_autoscaling_group.my_asg.name
  lb_target_group_arn    = aws_lb_target_group.my_target_group.arn
}

# Create CloudWatch alarms for CPU utilization scaling policies
resource "aws_cloudwatch_metric_alarm" "high_cpu_utilization" {
  alarm_name          = "HighCPUUtilization"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  threshold           = 70
  period              = 300 # 5 minutes
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.my_asg.name
  }

  alarm_description = "Scale up when CPU utilization is greater than or equal to 70% for 10 minutes."
  alarm_actions     = [aws_autoscaling_policy.scale_up_policy.arn]
}

resource "aws_cloudwatch_metric_alarm" "low_cpu_utilization" {
  alarm_name          = "LowCPUUtilization"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 2
  threshold           = 40
  period              = 300 # 5 minutes
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.my_asg.name
  }

  alarm_description = "Scale down when CPU utilization is less than or equal to 40% for 10 minutes."
  alarm_actions     = [aws_autoscaling_policy.scale_down_policy.arn]
}

# Create scaling policies
resource "aws_autoscaling_policy" "scale_up_policy" {
  autoscaling_group_name  = aws_autoscaling_group.my_asg.name
  scaling_adjustment      = 1
  cooldown                = 300
  adjustment_type         = "ChangeInCapacity"
  metric_aggregation_type = "Average"
  name                    = "ScaleUpPolicy"


}

resource "aws_autoscaling_policy" "scale_down_policy" {
  autoscaling_group_name = aws_autoscaling_group.my_asg.name
  scaling_adjustment     = -1
  cooldown               = 300 # 5 minutes cooldown period
  adjustment_type        = "ChangeInCapacity"

  metric_aggregation_type = "Average"
  name                    = "ScaleDownPolicy"



}
