import argparse
import concurrent.futures
import time
import requests
import boto3
import subprocess
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
    client.put_log_events(
        logGroupName=LOG_GROUP,
        logStreamName=stream_name,
        logEvents=[{'timestamp': int(time.time() * 1000), 'message': json.dumps(message)}]
    )


def scenario_http_500(alb_dns, region, duration=180):
    client = boto3.client('logs', region_name=region)
    stream = f'http_500-{int(time.time())}'
    cw_log(client, stream, {
        'chaos_start': {
            'scenario': 'http_500',
            'timestamp': datetime.utcnow().isoformat() + 'Z',
            'target_endpoint': f'http://{alb_dns}/api/v1/ingest',
            'expected_signal_impact': '5xx increase >10%'
        }
    })

    url = f'http://{alb_dns}/api/v1/ingest'
    stop_time = time.time() + duration
    error_count = 0
    total_count = 0

    def worker(_):
        try:
            r = requests.post(url, json={'malformed': True}, timeout=5)
            return 1 if r.status_code >= 500 else 0
        except Exception:
            return 1

    with concurrent.futures.ThreadPoolExecutor(max_workers=50) as pool:
        futures = []
        while time.time() < stop_time:
            batch = [pool.submit(worker, None) for _ in range(50)]
            futures.extend(batch)
            time.sleep(1)
            done = [f for f in futures if f.done()]
            for f in done:
                result = f.result()
                error_count += result
                total_count += 1
            futures = [f for f in futures if not f.done()]
            print(f'[http_500] elapsed={int(stop_time - time.time())}s remaining  errors={error_count}  total={total_count}')

        for f in concurrent.futures.as_completed(futures):
            result = f.result()
            error_count += result
            total_count += 1

    cw_log(client, stream, {
        'chaos_end': {
            'scenario': 'http_500',
            'timestamp': datetime.utcnow().isoformat() + 'Z',
            'total_requests': total_count,
            'error_requests': error_count
        }
    })


def scenario_cpu_spike(region, duration=120):
    client = boto3.client('logs', region_name=region)
    stream = f'cpu_spike-{int(time.time())}'
    cw_log(client, stream, {
        'chaos_start': {
            'scenario': 'cpu_spike',
            'timestamp': datetime.utcnow().isoformat() + 'Z',
            'expected_signal_impact': 'CPU >85%'
        }
    })

    try:
        subprocess.check_call(['which', 'stress-ng'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        proc = subprocess.Popen(['stress-ng', '--cpu', '4', '--timeout', f'{duration}s'])
        start = time.time()
        while time.time() - start < duration:
            cpu = psutil.cpu_percent(interval=5)
            print(f'[cpu_spike] elapsed={int(time.time()-start)}s  cpu={cpu}%')
        proc.wait()
    except Exception:
        def busy_loop(sec):
            end = time.time() + sec
            while time.time() < end:
                x = sum(i * i for i in range(100000))

        procs = [multiprocessing.Process(target=busy_loop, args=(duration,)) for _ in range(multiprocessing.cpu_count())]
        for p in procs:
            p.start()
        start = time.time()
        while time.time() - start < duration:
            cpu = psutil.cpu_percent(interval=5)
            print(f'[cpu_spike] elapsed={int(time.time()-start)}s  cpu={cpu}%')
        for p in procs:
            p.join()

    cw_log(client, stream, {
        'chaos_end': {'scenario': 'cpu_spike', 'timestamp': datetime.utcnow().isoformat() + 'Z'}
    })


def scenario_memory_leak(region, target_pct=90, max_duration=300):
    client = boto3.client('logs', region_name=region)
    stream = f'memory_leak-{int(time.time())}'
    cw_log(client, stream, {
        'chaos_start': {
            'scenario': 'memory_leak',
            'timestamp': datetime.utcnow().isoformat() + 'Z',
            'expected_signal_impact': f'memory >{target_pct}%'
        }
    })

    mem_holder = []
    start = time.time()
    reached = False
    while time.time() - start < max_duration:
        mem_holder.append(bytearray(10 * 1024 * 1024))
        mem = psutil.virtual_memory()
        print(f'[memory_leak] elapsed={int(time.time()-start)}s  used={mem.percent}%')
        if mem.percent >= target_pct:
            reached = True
            print(f'[memory_leak] threshold {target_pct}% reached — holding for 30s')
            time.sleep(30)
            break
        time.sleep(0.5)

    mem_holder.clear()
    cw_log(client, stream, {
        'chaos_end': {
            'scenario': 'memory_leak',
            'timestamp': datetime.utcnow().isoformat() + 'Z',
            'threshold_reached': reached
        }
    })


def main():
    parser = argparse.ArgumentParser(description='TechStream chaos injection tool')
    parser.add_argument('--scenario', required=True, choices=['http_500', 'cpu_spike', 'memory_leak'])
    parser.add_argument('--alb-dns', default='localhost:8000')
    parser.add_argument('--region', default='us-east-1')
    parser.add_argument('--duration', type=int, default=180)
    args = parser.parse_args()

    if args.scenario == 'http_500':
        scenario_http_500(args.alb_dns, args.region, args.duration)
    elif args.scenario == 'cpu_spike':
        scenario_cpu_spike(args.region, args.duration)
    elif args.scenario == 'memory_leak':
        scenario_memory_leak(args.region)


if __name__ == '__main__':
    main()
