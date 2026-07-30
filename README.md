# Jenkins on AWS — Infrastructure as Code (CloudFormation)

Push to `main` and GitHub Actions provisions a Jenkins server on AWS
(single EC2 instance, Jenkins running in Docker, persistent EBS volume,
static IP), using a native AWS CloudFormation template — no separate
state backend to manage, AWS tracks the stack for you.

## How it's laid out

```
cloudformation/
  jenkins-stack.yaml   The whole stack: EC2 instance, security group,
                        IAM role, EBS data volume, Elastic IP. This is
                        what GitHub Actions deploys on every push.
docker/
  Dockerfile           Your custom Jenkins image — starts from
                        jenkins/jenkins:lts-jdk17, add plugins/config here.
  plugins.txt           Plugin list installed into the image at build time.
  docker-compose.yml    Builds & runs the same image locally, for testing
                         before you push.
deploy/
  iam-policy.json       Least-privilege policy for the AWS user GitHub
                         Actions uses to deploy.
.github/workflows/
  deploy.yml   Builds + pushes docker/ to your Docker Hub repo, discovers
               your default VPC/subnet, then runs `aws cloudformation
               deploy` on push to main.
  destroy.yml  Manual-only, deletes the whole stack (typed confirmation).
```

## One-time setup (do this before your first push)

### 1. Create an AWS IAM user for GitHub Actions

Create an IAM user (e.g. `jenkins-ci-deployer`) with **programmatic
access only** (access key + secret key, no console password). Attach
the policy in [`deploy/iam-policy.json`](deploy/iam-policy.json) — it's
scoped to CloudFormation actions on just this stack, EC2, and the one
IAM role/instance-profile this stack creates. Avoid using your root
account or an admin user for this.

Save the resulting Access Key ID and Secret Access Key — you'll need
them next.

### 2. Add GitHub repository secrets

In your GitHub repo: **Settings → Secrets and variables → Actions →
New repository secret**. Add:

| Secret | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | From step 1 |
| `AWS_SECRET_ACCESS_KEY` | From step 1 |
| `AWS_REGION` | `ap-south-1` (or your chosen region) |
| `JENKINS_ADMIN_CIDR` | Your IP in CIDR form, e.g. `1.2.3.4/32` (see security note below) |
| `DOCKERHUB_USERNAME` | Your Docker Hub username. If unset, the workflow falls back to deploying the public `jenkins/jenkins` image and skips the build/push step entirely — set it to deploy your own image from `docker/`. |
| `DOCKERHUB_TOKEN` | Required if `DOCKERHUB_USERNAME` is set. A Docker Hub **access token** with **Read & Write** scope (the workflow pushes images), not your account password — generate one at [hub.docker.com](https://hub.docker.com) → Account Settings → Security → New Access Token. See security note below. |

Optional but recommended: create a GitHub **Environment** named
`production` (Settings → Environments) and require a reviewer on it.
Both workflows target this environment, so deploys/destroys will pause
for manual approval instead of running unattended on every push.

### 3. Push to deploy

```bash
git push -u origin main
```

The `Deploy Jenkins to AWS` workflow looks up your account's default
VPC and a subnet in it, then runs `aws cloudformation deploy` against
`cloudformation/jenkins-stack.yaml`. Watch it in the Actions tab — the
last step prints the stack outputs, including the Jenkins URL.

> Your AWS account needs a **default VPC** in the target region for
> the auto-discovery step to work (every new AWS account has one
> unless it was deleted). If yours doesn't, pass `VpcId`/`SubnetId`
> explicitly in the workflow's `--parameter-overrides` instead.

## First login

1. Get the instance ID from the stack outputs (Actions log, or
   `aws cloudformation describe-stacks --stack-name jenkins --query "Stacks[0].Outputs"`).
2. Connect without SSH, via SSM (requires AWS CLI + Session Manager
   plugin installed locally):
   ```bash
   aws ssm start-session --target <instance-id> --region <region>
   ```
3. Grab the initial admin password:
   ```bash
   sudo docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
   ```
4. Open the `JenkinsURL` from the stack outputs
   (`http://<elastic-ip>:8080`) in a browser and paste it in to finish
   the setup wizard.

## Customizing the Jenkins image

Add or remove plugins in [`docker/plugins.txt`](docker/plugins.txt)
(one plugin ID per line, optionally pinned — `git:5.2.1`), or extend
[`docker/Dockerfile`](docker/Dockerfile) directly for anything else
(base packages, JCasC config, etc.). Push it, and the workflow:

1. Builds the image and pushes it to `<your-dockerhub-username>/jenkins-deployment`,
   tagged with both `:latest` and a short hash of the Dockerfile +
   plugins.txt contents.
2. Deploys the stack with that hash tag as the instance's image — since
   the tag only changes when the image content actually changes, this
   naturally only replaces the EC2 instance (see below) when there's
   something new to run.

Test locally first if you want faster iteration:
```bash
cd docker
docker compose up -d --build
open http://localhost:8080
```

## Updating Jenkins / infra

Change anything in `cloudformation/jenkins-stack.yaml` (instance type,
volume size, security group rules, etc.) and push to `main` — the
workflow re-deploys the stack. Changing the deployed image tag or
anything else that alters `UserData` replaces the EC2 instance, but
the Jenkins data volume is a separate resource and survives, so
plugins/jobs/credentials persist across rebuilds.

## Tearing it down

Don't delete the CloudFormation files and push — run the manual
**Destroy Jenkins AWS Infra** workflow instead (Actions tab → select
it → Run workflow → type `destroy` to confirm). It's deliberately not
triggered by any push, since it deletes the whole stack: EC2 instance,
data volume, and Elastic IP.

## Security notes

- **No open SSH port by default.** Access is via AWS SSM Session
  Manager (IAM-authenticated, logged, no key pair to leak). If you do
  need SSH, set the `KeyName` and `SshCidr` parameters (add them to
  the `--parameter-overrides` line in `deploy.yml`).
- **Restrict `JENKINS_ADMIN_CIDR`** to your own IP once you know it.
  Left at `0.0.0.0/0`, the Jenkins login page (port 8080) is reachable
  by anyone on the internet — fine for a first smoke test, not for
  anything you'll leave running.
- **Plain HTTP, no TLS.** This setup serves Jenkins over `http://` on
  port 8080 — traffic including your login session isn't encrypted.
  If you later point a domain at the Elastic IP, add an Nginx (or
  Caddy) reverse-proxy container with Let's Encrypt in front of
  Jenkins — ask and this can be added.
- **EBS volumes are encrypted at rest.**
- The CI IAM policy is scoped down but `ec2:*` is still broad (needed
  for the security group, ENI, EBS, and EIP resources this stack
  manages, plus the VPC/subnet discovery step) — tighten further if
  you want to.
- **`DOCKERHUB_TOKEN` is not stored securely on the instance.** It's
  passed through as an EC2 `UserData` value, which is stored in
  plaintext (not encrypted, not secret) — readable by anyone who can
  call `ec2:DescribeInstanceAttribute` on this instance, or who gets a
  shell on it. That's why this uses a scoped, revocable Docker Hub
  **access token**, not your real password — if it ever leaks, revoke
  it from Docker Hub's Security settings and issue a new one, rather
  than rotating your account password.

## Cost

With the default `t3.micro`, compute is covered by the AWS Free Tier
(if your account still has it — 750 hrs/month for the first 12 months
on older accounts, or the newer 6-month credit-based Free Tier on
recent accounts). The 2×20GB gp3 EBS volumes and the Elastic IP
(free while attached to a running instance) aren't Free Tier–unlimited
and run roughly **$5–8/month** combined. If you bump `InstanceType` up
to `t3.medium` for more headroom, add another **~$20–25/month** for
on-demand compute. Destroy the stack when not in use if cost matters —
see teardown above.

Note: some AWS accounts (new sign-ups, accounts still under review)
are restricted to Free Tier–eligible instance types only — launching
anything larger fails with `InvalidRequest: not eligible for Free
Tier` until that restriction lifts, regardless of what `InstanceType`
you set here.
