# Insurance Policy Portal — end-to-end

## Cost warning — read first
This architecture is **not guaranteed to be Free Tier**. An Application Load Balancer, Fargate, RDS, CloudWatch Logs, S3 usage and public IPv4 addresses can incur charges; check AWS Billing/pricing before applying. This lab avoids a NAT Gateway charge by placing Fargate tasks in public subnets with public IPs; their security group accepts app traffic only from the ALB. RDS remains private. Check current AWS pricing and Billing before applying.

## Components
ALB → ECS Fargate (2 tasks) → private RDS MySQL; ECS uploads documents to a private encrypted S3 bucket. ECS CPU autoscaling is configured from 1 to 4 tasks to reduce baseline compute cost. Terraform creates VPC, 2 public subnets, 2 private DB subnets, security groups, ECR, S3, Secrets Manager, RDS, IAM, ALB, ECS and autoscaling.

## Requirements
AWS CLI configured (`aws configure`), Docker Desktop running, Terraform >= 1.5, and AWS permissions for networking, ECS, ECR, ALB, IAM, RDS, S3, Secrets Manager, CloudWatch and Application Auto Scaling.

## 1. Configure Terraform
From the project folder:
```powershell
cd terraform
Copy-Item terraform.tfvars.example terraform.tfvars
```
Edit `terraform.tfvars` and set a unique strong password. Do not share or commit it. Confirm account and region with `aws sts get-caller-identity` and `aws configure get region`.

## 2. Create infrastructure
```bash
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```
Review the plan and cost implications before typing `yes`. The first ECS tasks may fail until the Docker image is pushed.

## 3. Build and push the image
Run from the project root (the folder containing `app` and `terraform`). Replace `<ACCOUNT_ID>` with your AWS account ID:
```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com
docker build -t insurance-policy-portal ./app
docker tag insurance-policy-portal:latest <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/insurance-policy-portal:latest
docker push <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/insurance-policy-portal:latest
```
Then ECS → cluster `insurance-policy-portal-cluster` → service `insurance-policy-portal-service` → Update service → tick **Force new deployment** → Update.

## 4. Open the form
```bash
cd terraform
terraform output -raw alb_url
```
Open the URL. Enter customer name, policy number, insurance type and coverage amount; attach a PDF/JPG/JPEG/PNG file up to 10 MB. Submit. The file is uploaded to private S3 and policy metadata is stored in RDS.

## 5. Verify
- ECS service has 2 running tasks; target group targets are healthy.
- CloudWatch log group: `/ecs/insurance-policy-portal`.
- S3 bucket name: `terraform output -raw s3_bucket_name`; public access is blocked.
- RDS is private; its security group allows 3306 only from ECS security group.

## Update later
Rebuild/tag/push the Docker image and force a new ECS deployment. Pushing `latest` alone does not restart running tasks.

## Troubleshooting
- ALB 503: check task status, target health, port 8080 and `/health`.
- DB connection error: inspect ECS CloudWatch logs; verify RDS SG 3306 from ECS SG, DB endpoint and Secrets Manager credentials.
- S3 upload error: check ECS task-role permissions and `S3_BUCKET` environment variable.
- Existing resource/duplicate-name errors: do not blindly destroy existing infrastructure. Use a unique `project_name` or reconcile/import resources.

## Cleanup
`terraform destroy` from the `terraform` folder deletes Terraform-managed resources and can delete database data. Back up anything needed first; S3 bucket deletion can fail if it contains objects. Check Billing afterward.
# insurance-project
