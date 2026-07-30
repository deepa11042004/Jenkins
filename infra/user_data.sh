#!/bin/bash
# Runs once on first boot (EC2 user-data / cloud-init) to turn a bare
# Ubuntu 22.04 instance into a running Jenkins-in-Docker server.
set -euxo pipefail

exec > >(tee -a /var/log/jenkins-bootstrap.log) 2>&1

############################################
# 1. Wait for the separate data EBS volume to
#    be attached, then format (if new) & mount it.
#    Jenkins data lives here so it survives
#    instance replacement.
############################################

ROOT_DISK="$(lsblk -no PKNAME "$(findmnt -n -o SOURCE --target /)" 2>/dev/null || true)"

DATA_DISK=""
for i in $(seq 1 24); do
  for name in $(lsblk -dno NAME); do
    if [ "$name" != "$ROOT_DISK" ]; then
      DATA_DISK="$name"
      break 2
    fi
  done
  sleep 5
done

if [ -z "$DATA_DISK" ]; then
  echo "ERROR: data EBS volume never showed up, aborting" >&2
  exit 1
fi

DATA_DEV="/dev/${DATA_DISK}"

if ! blkid "$DATA_DEV" >/dev/null 2>&1; then
  mkfs -t ext4 "$DATA_DEV"
fi

mkdir -p /mnt/jenkins-data
mount "$DATA_DEV" /mnt/jenkins-data

DATA_UUID="$(blkid -s UUID -o value "$DATA_DEV")"
grep -q "$DATA_UUID" /etc/fstab || echo "UUID=${DATA_UUID} /mnt/jenkins-data ext4 defaults,nofail 0 2" >> /etc/fstab

mkdir -p /mnt/jenkins-data/jenkins_home
chown -R 1000:1000 /mnt/jenkins-data/jenkins_home

############################################
# 2. Install Docker Engine + Compose plugin
############################################

apt-get update -y
apt-get install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker

# Make sure the SSM agent (used for shell access instead of SSH) is running.
snap start amazon-ssm-agent >/dev/null 2>&1 || true

############################################
# 3. Write the Jenkins docker-compose file
#    and start it
############################################

mkdir -p /opt/jenkins
cat > /opt/jenkins/docker-compose.yml <<'COMPOSEEOF'
services:
  jenkins:
    image: jenkins/jenkins:lts-jdk17
    container_name: jenkins
    restart: unless-stopped
    ports:
      - "8080:8080"
      - "50000:50000"
    volumes:
      - /mnt/jenkins-data/jenkins_home:/var/jenkins_home
      # Uncomment to let Jenkins build/run Docker images from pipelines
      # (Docker-in-Docker via the host socket):
      # - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - JAVA_OPTS=-Djenkins.install.runSetupWizard=true
COMPOSEEOF

cd /opt/jenkins
docker compose up -d
