# Besu Infra - Terraform Project

Provisions 6 EC2 instances (SSH-accessible) for a Hyperledger Besu +
DevOps/monitoring stack. Terraform only provisions infrastructure; all
software installation is done by the companion **Ansible** project.

## Instances created

| Key             | Role tag        | Purpose                                             | Default type |
|-----------------|-----------------|------------------------------------------------------|--------------|
| besu-node       | besu-node       | Hyperledger Besu node                                | t2.micro     |
| besu-validator  | besu-validator  | Besu validator node                                  | t2.micro     |
| nodejs-k8s      | nodejs-k8s      | Node.js app on containerized Kubernetes (k3s)        | t2.micro     |
| monitoring      | monitoring      | Prometheus + Grafana                                 | t2.micro     |
| jenkins         | jenkins         | Jenkins + Maven/SonarQube/Trivy/Nexus-client/Docker/K8s/kubeaudit + plugins | t3.medium |
| nexus           | nexus           | Sonatype Nexus repository                            | t2.micro     |

## Important: AWS Free Tier reality check

- Free tier gives **750 combined hours/month** of `t2.micro`/`t3.micro` for a
  new account's first 12 months -- that's roughly **one** instance running
  continuously, not six. Running all 6 nodes 24/7 will exceed free tier and
  incur normal on-demand charges once you cross 750 hours.
- `t2.micro` has **1 GB RAM**. Jenkins + SonarQube + Nexus-client + Docker +
  kubectl + Trivy + kubeaudit together will not run acceptably on 1 GB, which
  is why the `jenkins` node defaults to `t3.medium` in `locals.tf`. Change it
  back to `var.default_instance_type` if you want to force free tier and
  accept degraded/failing behavior.
- EBS free tier covers 30 GB total across the account; this project's default
  volume sizes sum to more than that. Shrink `root_volume_size_gb` per node in
  `locals.tf` if you need to stay under 30 GB.

## Structure

```
terraform/
├── main.tf              # wires modules together with for_each over locals.instances
├── locals.tf             # per-instance definitions: type, disk, security group rules
├── variables.tf
├── outputs.tf
├── providers.tf / versions.tf
├── templates/inventory.tpl   # renders the Ansible inventory
└── modules/
    ├── network/          # VPC, subnet, IGW, route table
    ├── security_group/   # generic SG builder driven by a list of rules
    ├── key_pair/         # generates or imports an SSH key pair
    └── ec2_instance/     # reusable EC2 instance (resolves latest Ubuntu 22.04 AMI)
```

## Usage

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: at minimum restrict ssh_allowed_cidrs to your IP

terraform init
terraform plan
terraform apply
```

On success:

- `terraform output ssh_commands` gives you ready SSH commands per node.
- `terraform/generated/hosts.ini` is generated automatically -- copy it into
  the Ansible project:

```bash
cp generated/hosts.ini ../ansible/inventory/hosts.ini
```

- `terraform/generated/besu-infra-key.pem` is the generated private key
  (only created when `create_new_key_pair = true`). Ansible's inventory
  already points at it.

## Destroying

```bash
terraform destroy
```

## Notes on standards applied here

- Fully modularized (network / security_group / key_pair / ec2_instance),
  each module with its own variables/outputs and a single responsibility.
- `for_each` (not `count`) over a map so adding/removing a node doesn't
  shuffle unrelated resources.
- AMI resolved dynamically via `data.aws_ami` (no hardcoded, region-locked
  AMI IDs).
- IMDSv2 enforced, EBS encryption enabled, `create_before_destroy` on
  mutable resources.
- Input validation blocks on `project_name`, `environment`, `ssh_allowed_cidrs`.
- Remote state backend stubbed out (commented) in `versions.tf` -- turn this
  on for anything beyond solo experimentation.
- Secrets (private key) written via `local_sensitive_file` with `0400`
  permissions and excluded from version control via `.gitignore`.
