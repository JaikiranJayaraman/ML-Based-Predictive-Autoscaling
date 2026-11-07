import json
import boto3
import os
import time

s3 = boto3.client('s3')
autoscaling = boto3.client('autoscaling')

S3_BUCKET_NAME = os.getenv("S3_BUCKET_NAME")
ASG_NAME = os.getenv("ASG_NAME") # Optionally could be passed if needed for counting
EXPECTED_FRAC = 0.8 # E.g., at least 80% expected
TIMEOUT_SECS = 60 # 60 seconds timeout per round for fast demo

# Simple mock PyTorch implementation to avoid huge layer
# Real implementation uses torch.load and state_dict averaging
def perform_weighted_fedavg(models_info):
    import torch
    global_state_dict = None
    total_samples = 0
    
    # 1. Load all local models
    local_states = []
    for info in models_info:
        local_path = f"/tmp/{info['instance_id']}.pt"
        s3.download_file(S3_BUCKET_NAME, info['s3_key'], local_path)
        
        state_dict = torch.load(local_path)
        local_states.append({
            'state_dict': state_dict,
            'n_i': info['n_i']
        })
        total_samples += info['n_i']
        
    # 2. Perform Weighted Averaging: Sum(wi * ni) / Sum(ni)
    for i, local in enumerate(local_states):
        weight = local['n_i'] / total_samples
        if i == 0:
            global_state_dict = {k: v * weight for k, v in local['state_dict'].items()}
        else:
            for k in global_state_dict.keys():
                global_state_dict[k] += local['state_dict'][k] * weight
                
    return global_state_dict

def lambda_handler(event, context):
    print("Received event:", json.dumps(event))
    
    rounds_data = {}
    
    for record in event['Records']:
        body = json.loads(record['body'])
        round_id = body['round_id']
        
        if round_id not in rounds_data:
            rounds_data[round_id] = []
            
        rounds_data[round_id].append(body)
    
    # Check aggregation criteria for each round
    for round_id, messages in rounds_data.items():
        # List items in S3 for this round
        response = s3.list_objects_v2(Bucket=S3_BUCKET_NAME, Prefix=f"{round_id}/")
        
        # A crude way to see how many workers submitted vs total workers
        # Get ASG desired capacity
        try:
            asg_response = autoscaling.describe_auto_scaling_groups(AutoScalingGroupNames=[ASG_NAME])
            desired_cap = asg_response['AutoScalingGroups'][0]['DesiredCapacity']
        except:
            desired_cap = len(messages) # mock if ASG_NAME not set for Aggregator
            
        num_submitted = response.get('KeyCount', 0)
        
        # Check timeout string from round_id "round_162334" where timestamp = int
        try:
            round_ts = int(round_id.split("_")[1]) * 900
            time_elapsed = int(time.time()) - round_ts
        except:
            time_elapsed = 0
            
        # Conditionally Aggregate
        if num_submitted >= (desired_cap * EXPECTED_FRAC) or time_elapsed > TIMEOUT_SECS:
            print(f"Aggregating models for {round_id} - Submitted: {num_submitted}, Desired: {desired_cap}")
            
            # Use real S3 data rather than batch (since batch might only be partial SQS)
            all_files = response.get('Contents', [])
            
            # Since SQS might not have all `n_i` if scattered across batches, 
            # ideally, the train script uploads a JSON with `n_i` alongside `.pt` or inside SQS
            # For this simple demo, we will use the `n_i` from the messages we do have, 
            # or default mock `n_i` for those missing in this batch.
            models_info = []
            for item in all_files:
                # Find matching message if any
                s3_key = item['Key']
                n_i = 10 # Default
                for msg in messages:
                    if msg['s3_key'] == s3_key:
                        n_i = msg['n_i']
                
                models_info.append({
                    's3_key': s3_key,
                    'instance_id': s3_key.split("_")[2].split(".")[0], # hacky parsing
                    'n_i': n_i
                })
            
            # Perform Weighted FedAvg
            # Uncomment in real env:
            # global_model = perform_weighted_fedavg(models_info)
            # torch.save(global_model, f"/tmp/global_{round_id}.pt")
            
            # Mock saving
            with open(f"/tmp/global_{round_id}.pt", "w") as f:
                f.write("Global Model Representation")
                
            s3.upload_file(f"/tmp/global_{round_id}.pt", S3_BUCKET_NAME, f"global_models/{round_id}_global.pt")
            print(f"Uploaded Global Model for {round_id}")
            
        else:
            print(f"Round {round_id} not yet ready. Submitted: {num_submitted}. Skipping.")
            # Note: To retry properly without deleting from queue, lambda can raise an Exception, 
            # but then it retries the whole batch. Real implementation might push to DynamoDB.
            
    return {
        'statusCode': 200,
        'body': json.dumps('Aggregator completed.')
    }
