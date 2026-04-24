packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.8"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

source "amazon-ebs" "nginx_ami" {
  ami_name      = "nginx-golden-image-{{timestamp}}" # AMI 的名字，加上時間戳記避免重複
  instance_type = "t3.micro"
  region        = "ap-northeast-1" # 東京

  # 來源 Image：使用 Amazon Linux 2023
  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023.*-x86_64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["137112412989"] # Amazon 的官方 ID
  }
  ssh_username = "ec2-user"
}

build {
  sources = ["source.amazon-ebs.nginx_ami"]

  # 將 setup.sh 上傳並執行
  provisioner "shell" {
    script = "./setup.sh"
  }
}