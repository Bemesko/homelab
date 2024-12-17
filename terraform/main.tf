resource "aws_instance" "bernetes" {
  ami           = "ami-0453ec754f44f9a4a"
  instance_type = "t3.micro"

  tags = {
    Name = "Free-Tier-VM"
  }

  # Optional: Add a security group to allow SSH
  vpc_security_group_ids = [aws_security_group.bernetes.id]

  # Optional: Add a key pair for SSH access
  key_name = aws_key_pair.bernetes.key_name
}

resource "aws_security_group" "bernetes" {
  name_prefix = "allow-ssh-"

  ingress {
    description = "Allow SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_key_pair" "bernetes" {
  key_name   = "free-tier-key"
  public_key = file("~/.ssh/id_rsa.pub") # Update with your actual public key path
}

output "public_ip" {
  value = aws_instance.bernetes.public_ip
}
