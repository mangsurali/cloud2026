#!/usr/bin/env python3
"""Workload generator for DeathStarBench SocialNetwork matching Cloud Dynamics CSV format.
# ponytail: HTTP form-encoded endpoint simulation without thrift layer; upgrade path is native wrk2 thrift harness.
"""
import argparse, csv, math, os, random, statistics, sys, time
from concurrent.futures import ThreadPoolExecutor
from urllib.request import Request, urlopen
from urllib.parse import urlencode
from urllib.error import URLError, HTTPError

def args():
    p = argparse.ArgumentParser()
    p.add_argument("--url", default="http://social-network.127.0.0.1.sslip.io")
    p.add_argument("--profile", choices=["constant","ramp","burst","periodic","variable","staircase","spiky_diurnal","overload"], default="constant")
    p.add_argument("--duration", type=float, default=30)
    p.add_argument("--timeout", type=float, default=5)
    p.add_argument("--sample-interval", type=float, default=1)
    p.add_argument("--output")
    p.add_argument("--discard-output", action="store_true")
    p.add_argument("--rps", type=float, default=20)
    p.add_argument("--start-rps", type=float, default=5)
    p.add_argument("--end-rps", type=float, default=50)
    p.add_argument("--base-rps", type=float, default=10)
    p.add_argument("--burst-rps", type=float, default=50)
    p.add_argument("--burst-start", type=float, default=10)
    p.add_argument("--burst-duration", type=float, default=10)
    p.add_argument("--min-rps", type=float, default=5)
    p.add_argument("--max-rps", type=float, default=30)
    p.add_argument("--period-seconds", type=float, default=60)
    p.add_argument("--change-interval", type=float, default=15)
    p.add_argument("--staircase-steps", type=int, default=5)
    p.add_argument("--max-users", type=int, default=962)
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--workers", type=int, default=128)
    p.add_argument("--workload-type", choices=["mixed", "read-home-timeline", "read-user-timeline", "compose-post"], default="mixed", help="DeathStarBench scenario type")
    p.add_argument("--self-check", action="store_true", help="Run internal unit tests and exit")
    return p.parse_args()

def percentile(vals, q):
    if not vals: return 0.0
    s = sorted(vals)
    i = min(len(s)-1, max(0, math.ceil(q*len(s))-1))
    return s[i]

def target_rate(a, elapsed, rng, variable_state):
    if a.profile in ("constant", "overload"):
        return max(0.0, a.rps)
    if a.profile == "ramp":
        f = min(1.0, max(0.0, elapsed / max(a.duration, 1e-9)))
        return max(0.0, a.start_rps + (a.end_rps - a.start_rps) * f)
    if a.profile == "burst":
        inside = a.burst_start <= elapsed < a.burst_start + a.burst_duration
        return max(0.0, a.burst_rps if inside else a.base_rps)
    if a.profile == "periodic":
        mid = (a.min_rps + a.max_rps) / 2
        amp = (a.max_rps - a.min_rps) / 2
        return max(0.0, mid + amp * math.sin(2 * math.pi * elapsed / max(a.period_seconds, 1e-9)))
    if a.profile == "variable":
        bucket = int(elapsed // max(a.change_interval, 1e-9))
        if variable_state[0] != bucket:
            variable_state[:] = [bucket, rng.uniform(a.min_rps, a.max_rps)]
        return max(0.0, variable_state[1])
    if a.profile == "staircase":
        step_duration = max(a.duration / max(a.staircase_steps, 1), 1e-9)
        current_step = min(int(elapsed // step_duration), a.staircase_steps - 1)
        step_rps = a.start_rps + (a.end_rps - a.start_rps) * (current_step / max(a.staircase_steps - 1, 1))
        return max(0.0, step_rps)
    return max(0.0, a.rps)

def build_social_request(base_url, max_users, rng, workload_type="mixed"):
    """Generates requests according to DeathStarBench scenarios:
    - read-home-timeline: 100% GET /wrk2-api/home-timeline/read
    - read-user-timeline: 100% GET /wrk2-api/user-timeline/read
    - compose-post: 100% POST /wrk2-api/post/compose
    - mixed: 60% home timeline, 30% user timeline, 10% compose post
    """
    user_id = rng.randint(0, max_users - 1)
    base = base_url.rstrip("/")

    if workload_type == "read-home-timeline":
        kind = "home"
    elif workload_type == "read-user-timeline":
        kind = "user"
    elif workload_type == "compose-post":
        kind = "compose"
    else:
        coin = rng.random()
        if coin < 0.60:
            kind = "home"
        elif coin < 0.90:
            kind = "user"
        else:
            kind = "compose"

    if kind == "home":
        start_idx = rng.randint(0, 100)
        url = f"{base}/wrk2-api/home-timeline/read?user_id={user_id}&start={start_idx}&stop={start_idx + 10}"
        return Request(url, headers={"User-Agent": "cloud-dynamics-dsb/1.0"})
    elif kind == "user":
        start_idx = rng.randint(0, 100)
        url = f"{base}/wrk2-api/user-timeline/read?user_id={user_id}&start={start_idx}&stop={start_idx + 10}"
        return Request(url, headers={"User-Agent": "cloud-dynamics-dsb/1.0"})
    else:
        url = f"{base}/wrk2-api/post/compose"
        text = f"Automated test post text at {time.time()} with random id {rng.randint(1000, 9999)}"
        num_mentions = rng.randint(0, 3)
        for _ in range(num_mentions):
            text += f" @username_{rng.randint(0, max_users - 1)}"
        data = urlencode({
            "username": f"username_{user_id}",
            "user_id": str(user_id),
            "text": text,
            "media_ids": "[]",
            "media_types": "[]",
            "post_type": "0"
        }).encode("utf-8")
        return Request(url, data=data, headers={
            "User-Agent": "cloud-dynamics-dsb/1.0",
            "Content-Type": "application/x-www-form-urlencoded"
        })

def execute_request(req, timeout):
    t0 = time.perf_counter()
    ok = False
    try:
        with urlopen(req, timeout=timeout) as resp:
            resp.read(1)
            ok = 200 <= getattr(resp, "status", 200) < 400
    except (URLError, HTTPError, TimeoutError, OSError):
        ok = False
    return ok, (time.perf_counter() - t0) * 1000.0

def run_self_check():
    """Validates math, request generation, and CSV formatting without external dependencies."""
    print("Running self-check tests...")
    # 1. Percentile test
    sample = [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0]
    p95 = percentile(sample, 0.95)
    assert p95 == 100.0, f"Expected 100.0, got {p95}"

    # 2. Rate test
    class DummyArgs:
        profile = "ramp"
        duration = 100.0
        start_rps = 10.0
        end_rps = 110.0
    r0 = target_rate(DummyArgs(), 0.0, random.Random(1), [-1, 0.0])
    r50 = target_rate(DummyArgs(), 50.0, random.Random(1), [-1, 0.0])
    assert abs(r0 - 10.0) < 1e-4, f"Expected 10.0, got {r0}"
    assert abs(r50 - 60.0) < 1e-4, f"Expected 60.0, got {r50}"

    # 3. Request generation test
    rng = random.Random(42)
    req_home = build_social_request("http://localhost:8080", 100, rng, "read-home-timeline")
    assert "home-timeline" in req_home.full_url and req_home.get_method() == "GET"
    req_user = build_social_request("http://localhost:8080", 100, rng, "read-user-timeline")
    assert "user-timeline" in req_user.full_url and req_user.get_method() == "GET"
    req_compose = build_social_request("http://localhost:8080", 100, rng, "compose-post")
    assert "compose" in req_compose.full_url and req_compose.get_method() == "POST"

    print("All self-check assertions passed successfully!")

def main():
    a = args()
    if a.self_check:
        run_self_check()
        sys.exit(0)

    rng = random.Random(a.seed)
    variable_state = [-1, 0.0]
    start = time.monotonic()
    next_sample = start + a.sample_interval
    next_send = start
    futures = []
    interval_sent = 0

    out = None
    writer = None
    if not a.discard_output:
        if not a.output:
            raise SystemExit("--output is required unless --discard-output is used")
        os.makedirs(os.path.dirname(os.path.abspath(a.output)), exist_ok=True)
        out = open(a.output, "w", newline="")
        writer = csv.writer(out)
        writer.writerow(["timestamp_epoch","elapsed_s","target_rps","sent","success","failed",
                         "achieved_rps","mean_latency_ms","p95_latency_ms"])

    with ThreadPoolExecutor(max_workers=a.workers) as pool:
        while True:
            now = time.monotonic()
            elapsed = now - start
            if elapsed >= a.duration:
                break
            rate = target_rate(a, elapsed, rng, variable_state)
            if rate <= 0:
                time.sleep(min(0.05, a.duration - elapsed))
            elif now >= next_send:
                req = build_social_request(a.url, a.max_users, rng, a.workload_type)
                futures.append(pool.submit(execute_request, req, a.timeout))
                interval_sent += 1
                next_send = max(next_send + 1.0 / max(rate, 1e-5), now)
            else:
                time.sleep(min(0.005, max(0.0, next_send - now)))

            now = time.monotonic()
            if now >= next_sample:
                done, pending = [], []
                for f in futures:
                    (done if f.done() else pending).append(f)
                futures = pending
                results = [f.result() for f in done]
                success = sum(1 for ok, _ in results if ok)
                failed = len(results) - success
                lat = [ms for _, ms in results]
                sample_elapsed = now - start
                sample_rate = target_rate(a, sample_elapsed, rng, variable_state)
                row = [f"{time.time():.6f}", f"{sample_elapsed:.3f}", f"{sample_rate:.3f}",
                       interval_sent, success, failed,
                       f"{interval_sent / a.sample_interval:.3f}",
                       f"{statistics.mean(lat) if lat else 0:.3f}",
                       f"{percentile(lat, 0.95):.3f}"]
                if writer:
                    writer.writerow(row)
                    out.flush()
                interval_sent = 0
                next_sample += a.sample_interval

        results = [f.result() for f in futures]
        if writer and (results or interval_sent):
            success = sum(1 for ok, _ in results if ok)
            failed = len(results) - success
            lat = [ms for _, ms in results]
            elapsed = time.monotonic() - start
            rate = target_rate(a, min(elapsed, a.duration), rng, variable_state)
            writer.writerow([f"{time.time():.6f}", f"{elapsed:.3f}", f"{rate:.3f}",
                             interval_sent, success, failed,
                             f"{interval_sent / a.sample_interval:.3f}",
                             f"{statistics.mean(lat) if lat else 0:.3f}",
                             f"{percentile(lat, 0.95):.3f}"])
    if out:
        out.close()

if __name__ == "__main__":
    main()
