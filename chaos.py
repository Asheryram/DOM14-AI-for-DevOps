import argparse
import threading
import time
import requests
import boto3
import subprocess
import sys
import psutil
import multiprocessing
import json
from datetime import datetime


LOG_GROUP = '/techstream/chaos-events'


def cw_log(client, stream_name, message):
    try:
        client.create_log_group(logGroupName=LOG_GROUP)
    except client.exceptions.ResourceAlreadyExistsException:
        pass
    try:
        client.create_log_stream(logGroupName=LOG_GROUP, logStreamName=stream_name)
    except client.exceptions.ResourceAlreadyExistsException:
        pass

    timestamp = int(time.time() * 1000)
    client.put_log_events(
        logGroupName=LOG_GROUP,
        logStreamName=stream_name,
        logEvents=[{'timestamp': timestamp, 'message': json.dumps(message)}]
    )


def scenario_http_500(alb_dns, region, duration=180):
    client = boto3.client('logs', region_name=region)
    stream = f'http_500-{int(time.time())}'
    chaos_start = {
        'scenario': 'http_500',
        'timestamp': datetime.utcnow().isoformat() + 'Z',
        'target_endpoint': f'http://{alb_dns}/api/v1/ingest',
        'expected_signal_impact': '5xx increase >10%'
    }
    cw_log(client, stream, {'chaos_start': chaos_start})

    stop_time = time.time() + duration
    error_count = 0
    total = 0

    def worker():
        nonlocal error_count, total
        url = f'http://{alb_dns}/api/v1/ingest'
        payload = {'malformed': True}
        try:
            r = requests.post(url, json=payload, timeout=5)
            if r.status_code >= 500:
                error_count += 1
        except Exception:
            error_count += 1
        total += 1

    threads = []
    while time.time() < stop_time:
        # spawn up to 200 threads in bursts
        for _ in range(200):
            t = threading.Thread(target=worker)
            t.start()
            threads.append(t)
        time.sleep(1)
        print(f'[http_500] elapsed={int(time.time())} errors={error_count} total={total}')

    for t in threads:
        t.join()

    cw_log(client, stream, {'chaos_end': {'scenario': 'http_500', 'timestamp': datetime.utcnow().isoformat() + 'Z'}})


def scenario_cpu_spike(region, duration=120):
    client = boto3.client('logs', region_name=region)
    stream = f'cpu_spike-{int(time.time())}'
    cw_log(client, stream, {'chaos_start': {'scenario': 'cpu_spike', 'timestamp': datetime.utcnow().isoformat() + 'Z', 'target_endpoint': None, 'expected_signal_impact': 'CPU >85%'}})

    try:
        subprocess.check_call(['which', 'stress-ng'])
        proc = subprocess.Popen(['stress-ng', '--cpu', '4', '--timeout', f'{duration}s'])
        start = time.time()
        while time.time() - start < duration:
            cpu = psutil.cpu_percent(interval=5)
            print(f'[cpu_spike] elapsed={int(time.time()-start)} cpu={cpu}%')
        proc.wait()
    except Exception:
        # fallback: spin processes
        def busy_loop(sec):
            end = time.time() + sec
            while time.time() < end:
                x = 0
                for i in range(1000000):
                    x += i*i

        procs = []
        for _ in range(multiprocessing.cpu_count()):
            p = multiprocessing.Process(target=busy_loop, args=(duration,))
            p.start()
            procs.append(p)
        start = time.time()
        while time.time() - start < duration:
            cpu = psutil.cpu_percent(interval=5)
            print(f'[cpu_spike] elapsed={int(time.time()-start)} cpu={cpu}%')
        for p in procs:
            p.join()

    cw_log(client, stream, {'chaos_end': {'scenario': 'cpu_spike', 'timestamp': datetime.utcnow().isoformat() + 'Z'}})


def scenario_memory_leak(region):
    client = boto3.client('logs', region_name=region)
    stream = f'memory_leak-{int(time.time())}'
    cw_log(client, stream, {'chaos_start': {'scenario': 'memory_leak', 'timestamp': datetime.utcnow().isoformat() + 'Z', 'expected_signal_impact': 'memory >90%'}})

    for cycle in range(2):
        mem_holder = []
        start = time.time()
        while True:
            mem_holder.append(bytearray(10 * 1024 * 1024))
            mem = psutil.virtual_memory()
            print(f'[memory_leak] cycle={cycle} elapsed={int(time.time()-start)} used={mem.percent}%')
            if mem.percent >= 90:
                print('[memory_leak] threshold reached, releasing memory')
                mem_holder = []
                break
            time.sleep(0.5)

    cw_log(client, stream, {'chaos_end': {'scenario': 'memory_leak', 'timestamp': datetime.utcnow().isoformat() + 'Z'}})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--scenario', required=True, choices=['http_500', 'cpu_spike', 'memory_leak'])
    parser.add_argument('--alb-dns', default='localhost:8000')
    parser.add_argument('--region', default='us-east-1')
    args = parser.parse_args()

    if args.scenario == 'http_500':
        scenario_http_500(args.alb_dns, args.region)
    elif args.scenario == 'cpu_spike':
        scenario_cpu_spike(args.region)
    elif args.scenario == 'memory_leak':
        scenario_memory_leak(args.region)


if __name__ == '__main__':
    main()
