"""
tests/benchmark.py - Production Quantitative Latency & Heap Memory Benchmark.
Enterprise: Servicelab AI - SLA Hazard & Linear Optimization Engine.

Measures:
  1. Columnar Ingestion & Hazard Filtering (Polars, SLA p95 < 50.0 ms).
  2. Constrained Linear Programming Solver (SciPy HiGHS, SLA p95 < 150.0 ms).
  3. System Throughput (optimizations / sec).
  4. Peak Heap Memory Allocation (tracemalloc, SLA < 15.0 MB).
"""

import os
from pathlib import Path
import sys
import tempfile
import time
import tracemalloc
import numpy as np

# Path resolution for standalone invocation
_project_root = str(Path(__file__).resolve().parent.parent)
if _project_root not in sys.path:
    sys.path.insert(0, _project_root)

if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

from src.data_generator import generate_domain_dataset
from src.core_engine import create_optimization_pipeline


def run_benchmarks(iterations: int = 30, num_records: int = 10000):
    print(f"[*] [Benchmark] Synthesizing calibrated dataset ({num_records:,} observations)...")
    with tempfile.NamedTemporaryFile(suffix=".parquet", delete=False) as tmp:
        tmp_path = tmp.name

    try:
        generate_domain_dataset(num_records=num_records, output_path=tmp_path, seed=42)
        ingestion, solver = create_optimization_pipeline()
        resources = solver.get_default_engineering_pools()

        # Isolated memory profiling during initial warmup pass
        tracemalloc.start()
        warmup_df = ingestion.ingest_records(tmp_path)
        warmup_incidents = ingestion.parse_incident_survival_states(warmup_df, limit_triage_batch=80)
        solver.solve_allocation(warmup_incidents, resources, max_budget_usd=60000.0)
        _, peak_bytes = tracemalloc.get_traced_memory()
        tracemalloc.stop()
        peak_mb = peak_bytes / (1024 * 1024)

        # Quantitative latency measurement passes
        ingestion_latencies = []
        solver_latencies = []

        for _ in range(iterations):
            # Stage 1: Columnar Ingestion & Hazard Filtering
            t_ingest_0 = time.perf_counter()
            df = ingestion.ingest_records(tmp_path)
            incidents = ingestion.parse_incident_survival_states(df, limit_triage_batch=80)
            t_ingest_1 = time.perf_counter()
            ingestion_latencies.append((t_ingest_1 - t_ingest_0) * 1000.0)

            # Stage 2: Primal Linear Programming Solver
            t_solver_0 = time.perf_counter()
            solver.solve_allocation(incidents, resources, max_budget_usd=60000.0)
            t_solver_1 = time.perf_counter()
            solver_latencies.append((t_solver_1 - t_solver_0) * 1000.0)

        ing_p50 = float(np.percentile(ingestion_latencies, 50))
        ing_p95 = float(np.percentile(ingestion_latencies, 95))
        ing_p99 = float(np.percentile(ingestion_latencies, 99))

        sol_p50 = float(np.percentile(solver_latencies, 50))
        sol_p95 = float(np.percentile(solver_latencies, 95))
        sol_p99 = float(np.percentile(solver_latencies, 99))

        total_mean_sec = (ing_p50 + sol_p50) / 1000.0
        throughput_ops = round(1.0 / max(total_mean_sec, 0.001), 1)

        print("\n" + "=" * 74)
        print("  SERVICELAB AI LINEAR OPTIMIZATION ENGINE - QUANTITATIVE BENCHMARK REPORT")
        print("=" * 74)
        print(f"  Dataset Population       : {num_records:,} total historical observations")
        print(f"  Profiling Iterations     : {iterations} passes")
        print(f"  Triage Queue Batch Size  : {len(incidents)} active incidents")
        print("-" * 74)
        print("  1. Columnar Ingestion & Hazard Filtering (Polars):")
        print(f"     -> p50: {ing_p50:.2f} ms | p95: {ing_p95:.2f} ms | p99: {ing_p99:.2f} ms")
        print(f"     -> Production SLA Target : p95 < 50.0 ms [{'PASS' if ing_p95 < 50.0 else 'FAIL'}]")
        print("-" * 74)
        print("  2. Constrained Linear Programming Solver (HiGHS Simplex):")
        print(f"     -> p50: {sol_p50:.2f} ms | p95: {sol_p95:.2f} ms | p99: {sol_p99:.2f} ms")
        print(f"     -> Solver Throughput     : {throughput_ops:.1f} optimizations/sec")
        print(f"     -> Production SLA Target : p95 < 150.0 ms [{'PASS' if sol_p95 < 150.0 else 'FAIL'}]")
        print("-" * 74)
        print("  3. Memory Footprint Profile:")
        print(f"     -> Peak Heap Allocation  : {peak_mb:.2f} MB [SLA < 15.0 MB: {'PASS' if peak_mb < 15.0 else 'FAIL'}]")
        print("=" * 74)

        assert ing_p95 < 50.0, f"Ingestion SLA breach: {ing_p95:.2f}ms >= 50.0ms"
        assert sol_p95 < 150.0, f"Solver SLA breach: {sol_p95:.2f}ms >= 150.0ms"
        assert peak_mb < 15.0, f"Memory SLA breach: {peak_mb:.2f}MB >= 15.0MB"
        print("  [+] All quantitative SLA and memory constraints verified successfully.\n")

    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)


if __name__ == "__main__":
    run_benchmarks(iterations=30, num_records=10000)