import os
import time
import json
import boto3
import torch
import torch.nn as nn
import pandas as pd
import requests

# Set metadata and clients
region = "ap-south-1"
s3 = boto3.client('s3', region_name=region)
sqs = boto3.client('sqs', region_name=region)
cloudwatch = boto3.client('cloudwatch', region_name=region)

# From Terraform or User Data
S3_BUCKET_NAME = os.getenv("S3_BUCKET_NAME", "fl-auto-scaling-models-xyz")
SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL", "https://sqs.ap-south-1.amazonaws.com/123/fl-auto-scaling-updates-queue")

# Fetch local EC2 Instance ID using IMDSv2
try:
    token = requests.put('http://169.254.169.254/latest/api/token', headers={'X-aws-ec2-metadata-token-ttl-seconds': '21600'}).text
    INSTANCE_ID = requests.get('http://169.254.169.254/latest/meta-data/instance-id', headers={'X-aws-ec2-metadata-token': token}).text
except:
    INSTANCE_ID = "i-local-dev-mock"

class LSTMPredictor(nn.Module):
    def __init__(self, input_size=2, hidden_size=64, num_layers=1):
        super(LSTMPredictor, self).__init__()
        self.lstm = nn.LSTM(input_size, hidden_size, num_layers, batch_first=True)
        self.fc = nn.Linear(hidden_size, 1)

    def forward(self, x):
        out, _ = self.lstm(x)
        out = self.fc(out[:, -1, :])
        return out

def get_local_metrics():
    import datetime
    # Fetch last 1 hour of CPU and Network metrics for this instance (2 features)
    end_time = datetime.datetime.now(datetime.timezone.utc)
    start_time = end_time - datetime.timedelta(hours=1)
    
    try:
        # 1. Fetch CPUUtilization (Standard AWS/EC2 metric)
        cpu_response = cloudwatch.get_metric_statistics(
            Namespace='AWS/EC2',
            MetricName='CPUUtilization',
            Dimensions=[{'Name': 'InstanceId', 'Value': INSTANCE_ID}],
            StartTime=start_time,
            EndTime=end_time,
            Period=300,
            Statistics=['Average']
        )
        
        # 2. Fetch NetworkIn (Standard AWS/EC2 metric, using instead of Memory which requires CWAgent)
        net_response = cloudwatch.get_metric_statistics(
            Namespace='AWS/EC2',
            MetricName='NetworkIn',
            Dimensions=[{'Name': 'InstanceId', 'Value': INSTANCE_ID}],
            StartTime=start_time,
            EndTime=end_time,
            Period=300,
            Statistics=['Average']
        )
        
        cpu_dps = sorted(cpu_response.get('Datapoints', []), key=lambda k: k['Timestamp'])
        net_dps = sorted(net_response.get('Datapoints', []), key=lambda k: k['Timestamp'])
        
        cpu_values = [float(dp['Average']) for dp in cpu_dps]
        net_values = [float(dp['Average']) for dp in net_dps]
    except Exception as e:
        print(f"Failed to fetch from CloudWatch: {e}")
        cpu_values = []
        net_values = []

    # Sequence length
    seq_len = 10
    
    # Pad with zeros if insufficient data points
    if len(cpu_values) < seq_len:
        cpu_values = [0.0] * (seq_len - len(cpu_values)) + cpu_values
    if len(net_values) < seq_len:
        net_values = [0.0] * (seq_len - len(net_values)) + net_values
        
    # Take the last 'seq_len' points
    cpu_values = cpu_values[-seq_len:]
    net_values = net_values[-seq_len:]
    
    # Create tensor of shape (batch=1, seq_len=10, features=2)
    features = [[c, n] for c, n in zip(cpu_values, net_values)]
    data = torch.tensor([features], dtype=torch.float32)
    
    # Provide a mock label for sequence prediction objective (e.g. next time step)
    labels = torch.rand(1, 1)
    
    return data, labels, seq_len

def train_local_model():
    model = LSTMPredictor()
    criterion = nn.MSELoss()
    optimizer = torch.optim.Adam(model.parameters(), lr=0.01)

    data, labels, n_i = get_local_metrics()
    
    # Train
    model.train()
    for epoch in range(5):
        optimizer.zero_grad()
        outputs = model(data)
        loss = criterion(outputs, labels)
        loss.backward()
        optimizer.step()
    
    return model, n_i

def main():
    # Define current round based on minute block for synchronization
    # E.g., Round ID changes every 1 minute
    timestamp = int(time.time())
    round_id = f"round_{timestamp // 60}"
    
    model, n_i = train_local_model()
    
    # Save model weights
    local_model_path = f"/tmp/{INSTANCE_ID}_{timestamp}_model.pt"
    torch.save(model.state_dict(), local_model_path)
    
    # Upload to S3
    s3_key = f"{round_id}/worker_{INSTANCE_ID}.pt"
    s3.upload_file(local_model_path, S3_BUCKET_NAME, s3_key)
    
    # Clean up local file to prevent storage bloat and permission issues
    if os.path.exists(local_model_path):
        os.remove(local_model_path)
    
    # Send to SQS
    message_body = {
        "round_id": round_id,
        "instance_id": INSTANCE_ID,
        "n_i": n_i,
        "s3_key": s3_key
    }
    
    sqs.send_message(
        QueueUrl=SQS_QUEUE_URL,
        MessageBody=json.dumps(message_body)
    )
    print(f"Successfully uploaded weights for {round_id} with {n_i} samples.")

if __name__ == "__main__":
    main()
