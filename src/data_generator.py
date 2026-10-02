"""
src/data_generator.py - Calibrated Stochastic SLA Hazard & Incident Telemetry Generator.
Enterprise: Servicelab AI - High-Performance Incident Lifecycle & SLA Survival Physics.

Generates 50,000+ realistic enterprise service telemetry records with Weibull hazard rates,
contractual SLA terms, multi-cluster complexities, and financial penalty liabilities.

Architecture: Columnar Polars/NumPy vectorization (sub-second generation).
Zero internal leak tokens.
"""

from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import sys
import time
from typing import Dict, List, Optional

import numpy as np
import polars as pl

# Path resolution for standalone invocation
_project_root = str(Path(__file__).resolve().parent.parent)
if _project_root not in sys.path:
    sys.path.insert(0, _project_root)

from src.domain.entities import (
    EngineeringSpecialty,
    IncidentSeverity,
    ServiceCluster,
)


def generate_domain_dataset(
    num_records: int = 50000,
    output_path: str = "data/raw_dataset.parquet",
    seed: int = 42,
) -> pl.DataFrame:
    """
    Generates high-fidelity stochastic incident telemetry calibrated to enterprise AIOps.
    Includes parametric Weibull survival curves, SLA breach liabilities, and engineer requirements.
    """
    print(f"[*] [Data Generator] Simulating {num_records:,} calibrated SLA incident records for Servicelab AI...")
    start_time = time.perf_counter()
    rng = np.random.default_rng(seed)

    # 1. Incident Identifiers & Timestamp Trajectories
    base_time = datetime(2026, 1, 1, 0, 0, 0, tzinfo=timezone.utc)
    incident_ids = [f"INC-SLAB-{i:06d}" for i in range(1, num_records + 1)]
    random_offsets = rng.uniform(0, 90 * 86400, num_records)
    event_timestamps = [base_time + timedelta(seconds=float(s)) for s in random_offsets]

    # 2. Service Clusters & Infrastructure Topology
    clusters = [
        ServiceCluster.GPU_INFERENCE_CLUSTER.value,
        ServiceCluster.DISTRIBUTED_TRAINING_NODE.value,
        ServiceCluster.API_GATEWAY_ROUTER.value,
        ServiceCluster.DATA_LAKE_STORAGE.value,
        ServiceCluster.MLOPS_PIPELINE_ORCHESTRATOR.value,
    ]
    cluster_weights = [0.30, 0.25, 0.18, 0.15, 0.12]
    assigned_clusters = rng.choice(clusters, size=num_records, p=cluster_weights)

    # 3. Incident Severity Classes
    severities = [
        IncidentSeverity.CRITICAL_P1.value,
        IncidentSeverity.HIGH_P2.value,
        IncidentSeverity.MEDIUM_P3.value,
        IncidentSeverity.LOW_P4.value,
    ]
    severity_weights = [0.12, 0.28, 0.42, 0.18]
    assigned_severities = rng.choice(severities, size=num_records, p=severity_weights)

    # 4. Enterprise Client Contracts & SLA Financial Terms
    client_tiers = ["Tier-1 Global Financial", "Strategic Autonomous AI", "Enterprise SaaS Core", "ScaleUp Platform"]
    tier_weights = [0.25, 0.35, 0.25, 0.15]
    assigned_tiers = rng.choice(client_tiers, size=num_records, p=tier_weights)

    client_arr = np.where(
        assigned_tiers == "Tier-1 Global Financial",
        rng.uniform(2500000.0, 5000000.0, num_records),
        np.where(
            assigned_tiers == "Strategic Autonomous AI",
            rng.uniform(1200000.0, 2400000.0, num_records),
            rng.uniform(400000.0, 1000000.0, num_records),
        ),
    )

    # Guaranteed Resolution Windows (Hours)
    max_sla_hours = np.where(
        assigned_severities == "CRITICAL_P1",
        rng.uniform(2.0, 4.0, num_records),
        np.where(
            assigned_severities == "HIGH_P2",
            rng.uniform(6.0, 10.0, num_records),
            np.where(
                assigned_severities == "MEDIUM_P3",
                rng.uniform(18.0, 24.0, num_records),
                rng.uniform(48.0, 72.0, num_records),
            ),
        ),
    )

    # Hourly Penalty Liability for Overrun ($/Hour)
    hourly_penalty_usd = np.where(
        assigned_severities == "CRITICAL_P1",
        rng.uniform(5000.0, 15000.0, num_records),
        np.where(
            assigned_severities == "HIGH_P2",
            rng.uniform(2000.0, 4500.0, num_records),
            np.where(
                assigned_severities == "MEDIUM_P3",
                rng.uniform(600.0, 1500.0, num_records),
                rng.uniform(150.0, 400.0, num_records),
            ),
        ),
    )

    max_penalty_cap_usd = hourly_penalty_usd * rng.uniform(8.0, 16.0, num_records)

    # 5. Temporal Survival Physics (Weibull Distribution Parameters)
    # k > 1 represents aging/wear-out failure where breach probability accelerates as time passes
    weibull_shape_k = np.where(
        assigned_severities == "CRITICAL_P1",
        rng.uniform(1.85, 2.60, num_records),
        np.where(
            assigned_severities == "HIGH_P2",
            rng.uniform(1.50, 2.10, num_records),
            rng.uniform(1.15, 1.65, num_records),
        ),
    )

    # Scale parameter lambda (characteristic time in hours)
    weibull_scale_lambda = max_sla_hours * rng.uniform(0.75, 1.25, num_records)

    # Elapsed Time (Hours already spent since incident trigger)
    elapsed_ratio = rng.beta(2.0, 3.0, num_records)
    elapsed_hours = np.round(max_sla_hours * elapsed_ratio, 2)
    remaining_sla_hours = np.maximum(0.0, max_sla_hours - elapsed_hours)

    # Estimated Engineering Work Required (Hours)
    estimated_work_hours = np.round(rng.lognormal(mean=0.85, sigma=0.45, size=num_records), 2)
    estimated_work_hours = np.clip(estimated_work_hours, 0.5, 36.0)

    # 6. Actuarial Hazard & Conditional Breach Probability
    # h(t) = (k / lambda) * (t / lambda)^(k - 1)
    safe_elapsed = np.maximum(0.01, elapsed_hours)
    hazard_rate = (weibull_shape_k / weibull_scale_lambda) * np.power(
        safe_elapsed / weibull_scale_lambda, weibull_shape_k - 1.0
    )

    # Conditional breach probability before resolution: P(T > SLA | T > elapsed)
    cum_hazard_elapsed = np.power(safe_elapsed / weibull_scale_lambda, weibull_shape_k)
    cum_hazard_sla = np.power(max_sla_hours / weibull_scale_lambda, weibull_shape_k)
    conditional_breach_prob = np.where(
        elapsed_hours >= max_sla_hours,
        1.0,
        np.clip(1.0 - np.exp(-(cum_hazard_sla - cum_hazard_elapsed)), 0.0, 1.0),
    )

    # Projected unmitigated overrun penalty ($)
    unmitigated_overrun_hours = np.maximum(0.0, (elapsed_hours + estimated_work_hours) - max_sla_hours)
    expected_penalty_usd = np.round(
        conditional_breach_prob * np.minimum(unmitigated_overrun_hours * hourly_penalty_usd, max_penalty_cap_usd),
        2,
    )

    # 7. Primary Recommended Engineering Specialty
    specialties = [
        EngineeringSpecialty.NVIDIA_CUDA_SRE.value,
        EngineeringSpecialty.DISTRIBUTED_SYSTEMS_ARCHITECT.value,
        EngineeringSpecialty.MLOPS_PLATFORM_ENGINEER.value,
        EngineeringSpecialty.L2_OPERATIONS_SPECIALIST.value,
    ]
    recommended_specialty = np.where(
        assigned_clusters == ServiceCluster.GPU_INFERENCE_CLUSTER.value,
        EngineeringSpecialty.NVIDIA_CUDA_SRE.value,
        np.where(
            assigned_clusters == ServiceCluster.DISTRIBUTED_TRAINING_NODE.value,
            EngineeringSpecialty.DISTRIBUTED_SYSTEMS_ARCHITECT.value,
            np.where(
                assigned_clusters == ServiceCluster.MLOPS_PIPELINE_ORCHESTRATOR.value,
                EngineeringSpecialty.MLOPS_PLATFORM_ENGINEER.value,
                EngineeringSpecialty.L2_OPERATIONS_SPECIALIST.value,
            ),
        ),
    )

    # Build High-Speed Columnar DataFrame
    df = pl.DataFrame({
        "incident_id": incident_ids,
        "event_timestamp": event_timestamps,
        "service_cluster": assigned_clusters,
        "severity": assigned_severities,
        "client_tier": assigned_tiers,
        "client_arr_usd": np.round(client_arr, 2),
        "max_sla_hours": np.round(max_sla_hours, 2),
        "elapsed_hours": elapsed_hours,
        "remaining_sla_hours": np.round(remaining_sla_hours, 2),
        "estimated_work_hours": estimated_work_hours,
        "hourly_penalty_usd": np.round(hourly_penalty_usd, 2),
        "max_penalty_cap_usd": np.round(max_penalty_cap_usd, 2),
        "weibull_shape_k": np.round(weibull_shape_k, 3),
        "weibull_scale_lambda": np.round(weibull_scale_lambda, 3),
        "instantaneous_hazard_rate": np.round(hazard_rate, 4),
        "conditional_breach_prob": np.round(conditional_breach_prob, 4),
        "expected_penalty_usd": expected_penalty_usd,
        "recommended_specialty": recommended_specialty,
        "is_active_triage": (elapsed_hours < max_sla_hours * 1.5),
    })

    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    df.write_parquet(output_path)

    elapsed_ms = (time.perf_counter() - start_time) * 1000.0
    mean_penalty = df["expected_penalty_usd"].mean()
    p1_count = df.filter(pl.col("severity") == "CRITICAL_P1").shape[0]

    print(f"[*] [Data Generator] Successfully synthesized {len(df):,} records in {elapsed_ms:.1f}ms -> {output_path}")
    print(f"    Critical P1 Incidents: {p1_count:,} ({p1_count / num_records * 100:.1f}%) | Mean Financial Risk Exposure: ${mean_penalty:,.2f}")
    return df


if __name__ == "__main__":
    generate_domain_dataset(num_records=50000, output_path="data/raw_dataset.parquet")