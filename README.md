# Jenkins on AWS — Infrastructure as Code

Push to `main` and GitHub Actions provisions a Jenkins server on AWS
(single EC2 instance, Jenkins running in Docker, persistent EBS volume,
static IP). Everything is Terraform; nothing is clicked in the console
except the one-time setup below.

## How it's laid out

```
bootstrap/    One-time Terraform: creates the S3 bucket + DynamoDB table
              that hold Terraform's remote state. Run manually, once,
              from your own machine — never from CI.
infra/        The actual Jenkins stack: EC2 instance, security group,
              IAM role, EBS data volume, Elastic IP. This is what
              GitHub Actions applies on every push.
docker/       Reference docker-compose.yml, identical to what gets
              deployed — useful for testing Jenkins locally first.
deploy/       iam-policy.json — least-privilege policy for the AWS
              user GitHub Actions uses to deploy.
.github/workflows/
  deploy.yml   Runs `terraform apply` on push to main.
  destroy.yml  Manual-only, tears everything down (typed confirmation).
```

## One-time setup (do this before your first push)

### 1. Create an AWS IAM user for GitHub Actions

Create an IAM user (e.g. `jenkins-ci-deployer`) with **programmatic
access only** (access key + secret key, no console password). Attach
the policy in [`deploy/iam-policy.json`](deploy/iam-policy.json) — it's
scoped to just EC2, the one IAM role/instance-profile this stack
creates, and the Terraform state bucket/table. Avoid using your root
account or an admin user for this.

Save the resulting Access Key ID and Secret Access Key — you'll need
them in step 3.

### 2. Bootstrap the Terraform state backend

This creates the S3 bucket + DynamoDB lock table Terraform needs
before it can manage anything else. Run it once, locally, with AWS
credentials that can create S3 buckets and DynamoDB tables (your own
admin credentials, not the CI user from step 1):

```bash
cd bootstrap
terraform init
terraform apply
```

Note the two outputs — `state_bucket_name` and `state_lock_table` —
you'll paste them into GitHub secrets next.

### 3. Add GitHub repository secrets

In your GitHub repo: **Settings → Secrets and variables → Actions →
New repository secret**. Add:

| Secret | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | From step 1 |
| `AWS_SECRET_ACCESS_KEY` | From step 1 |
| `AWS_REGION` | `ap-south-1` (or your chosen region) |
| `TF_STATE_BUCKET` | `state_bucket_name` output from step 2 |
| `TF_STATE_DYNAMODB_TABLE` | `state_lock_table` output from step 2 |
| `JENKINS_ADMIN_CIDR` | Your IP in CIDR form, e.g. `1.2.3.4/32` (see security note below) |

Optional but recommended: create a GitHub **Environment** named
`production` (Settings → Environments) and require a reviewer on it.
Both workflows target this environment, so applies/destroys will pause
for manual approval instead of running unattended on every push.

### 4. Push to deploy

```bash
git push -u origin main
```

The `Deploy Jenkins to AWS` workflow runs `terraform init/plan/apply`
against `infra/`. Watch it in the Actions tab. When it finishes, the
job log prints the Jenkins URL (also available via `terraform output
jenkins_url` from `infra/` locally).

## First login

1. Get the instance ID: `terraform output instance_id` (from `infra/`,
   or the Actions log / `ssm_connect_command` output).
2. Connect without SSH, via SSM (requires AWS CLI + Session Manager
   plugin installed locally):
   ```bash
   aws ssm start-session --target <instance-id> --region <region>
   ```
3. Grab the initial admin password:
   ```bash
   sudo docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
   ```
4. Open `http://<elastic-ip>:8080` in a browser and paste it in to
   finish the setup wizard.

## Updating Jenkins / infra

Change anything under `infra/` (instance type, volume size, security
group rules, the Jenkins image tag in `user_data.sh`, etc.) and push to
`main` — the workflow re-applies. Changing `user_data.sh` replaces the
EC2 instance, but the Jenkins data volume is a separate resource and
survives, so plugins/jobs/credentials persist across rebuilds.

## Tearing it down

Don't `git push` a deletion of the Terraform files to remove the
infra — run the manual **Destroy Jenkins AWS Infra** workflow instead
(Actions tab → select it → Run workflow → type `destroy` to confirm).
It's deliberately not triggered by any push, since it deletes the EC2
instance, its data volume, and the Elastic IP.

## Security notes

- **No open SSH port by default.** Access is via AWS SSM Session
  Manager (IAM-authenticated, logged, no key pair to leak). If you do
  need SSH, set `ssh_key_name` and `ssh_cidr` in `infra/variables.tf`
  or via `TF_VAR_ssh_key_name` / `TF_VAR_ssh_cidr`.
- **Restrict `JENKINS_ADMIN_CIDR`** to your own IP once you know it.
  Left at `0.0.0.0/0`, the Jenkins login page (port 8080) is reachable
  by anyone on the internet — fine for a first smoke test, not for
  anything you'll leave running.
- **Plain HTTP, no TLS.** This setup serves Jenkins over `http://` on
  port 8080 — traffic including your login session isn't encrypted.
  If you later point a domain at the Elastic IP, add an Nginx (or
  Caddy) reverse-proxy container with Let's Encrypt in front of
  Jenkins — ask and this can be added.
- **EBS + S3 state are encrypted at rest**, and the state bucket
  blocks all public access.
- The CI IAM policy is scoped down but `ec2:*` is still broad (needed
  for the security group, ENI, EBS, and EIP resources this stack
  manages) — tighten further if you want to.

## Cost

Roughly, in `ap-south-1`: a `t3.medium` on-demand EC2 instance +
2×20GB gp3 EBS volumes + one Elastic IP (free while attached to a
running instance) comes to about **$25–35/month** if left running
24/7. Destroy it when not in use if that matters to you — see teardown
above.
