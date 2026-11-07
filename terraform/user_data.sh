#!/bin/bash
exec > /var/log/user-data.log 2>&1

echo "Starting EC2 User Data Execution..."

# --- ADD SWAP SPACE TO PREVENT OOM KILLS ---
echo "Creating 2GB swap file..."
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
# -------------------------------------------

# 1. Update and install basic dependencies
yum update -y
yum install -y python3 python3-pip git python3-devel gcc gcc-c++ docker

# Start docker
systemctl enable docker
systemctl start docker
usermod -a -G docker ec2-user

# --- DEPLOY WEBSITE EARLY ---
# Inject website files
mkdir -p /home/ec2-user/website
cat << 'WEBSITEOF' > /home/ec2-user/website/docker-compose.yml
${docker_compose_content}
WEBSITEOF
chown -R ec2-user:ec2-user /home/ec2-user/website

# Install docker-compose
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Run docker-compose
cd /home/ec2-user/website
/usr/local/bin/docker-compose up -d
# -----------------------------

# 2. Install Python requirements in a venv
echo "Setting up Python venv..."
python3 -m venv /home/ec2-user/fl_venv
source /home/ec2-user/fl_venv/bin/activate
pip install --upgrade pip
pip install --no-cache-dir setuptools wheel "urllib3<2" boto3 pandas requests
pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu
chown -R ec2-user:ec2-user /home/ec2-user/fl_venv

# 3. Inject the local training script
echo "Injecting train.py from Terraform..."
cat << 'PYEOF' > /home/ec2-user/train.py
${train_py_content}
PYEOF

chown ec2-user:ec2-user /home/ec2-user/train.py
chmod +x /home/ec2-user/train.py

# 4. Set up the environment variables globally for the user session
echo "export S3_BUCKET_NAME=${s3_bucket_name}" >> /home/ec2-user/.bashrc
echo "export SQS_QUEUE_URL=${sqs_queue_url}" >> /home/ec2-user/.bashrc

# 5. Optional: Create a cron job to run it on a schedule
echo "* * * * * ec2-user bash -l -c '/home/ec2-user/fl_venv/bin/python /home/ec2-user/train.py >> /tmp/worker.log 2>&1'" > /etc/cron.d/fl_worker_cron

echo "FL worker instantiated successfully." > /tmp/worker.log
chown ec2-user:ec2-user /tmp/worker.log

# 6. Run training logic immediately upon instance creation as ec2-user
su - ec2-user -c "export S3_BUCKET_NAME=${s3_bucket_name} && export SQS_QUEUE_URL=${sqs_queue_url} && cd /home/ec2-user && nohup /home/ec2-user/fl_venv/bin/python train.py >> /tmp/worker.log 2>&1 &"
