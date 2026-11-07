import threading
import requests
import time
import sys

# Replace with your actual ALB DNS
ALB_URL = "http://fl-auto-scaling-alb-1343679114.ap-south-1.elb.amazonaws.com/"
CONCURRENT_USERS = 300

def simulate_user():
    while True:
        try:
            # Send a request to the website
            requests.get(ALB_URL, timeout=5)
            requests.get(ALB_URL, timeout=5)
            requests.get(ALB_URL, timeout=5)
        except requests.exceptions.RequestException:
            pass

def main():
    print(f"🚀 Starting Simulated Load Test with {CONCURRENT_USERS} concurrent users...")
    print(f"🎯 Target: {ALB_URL}")
    print("Press Ctrl+C to stop the load test.\n")
    
    threads = []
    
    # Create threads to simulate concurrent users
    for i in range(CONCURRENT_USERS):
        t = threading.Thread(target=simulate_user)
        t.daemon = True
        t.start()
        threads.append(t)
        
        if i % 50 == 0 and i > 0:
            print(f"Started {i} users...")
            
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n🛑 Stopping load test...")
        sys.exit(0)

if __name__ == "__main__":
    main()
