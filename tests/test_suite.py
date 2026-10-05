"""
tests/test_suite.py - Production-Grade Mathematical & Domain Invariant Test Suite.
Enterprise: FinOps & Strategic Consulting Practice - SLA Hazard & Linear Optimization Engine.

Coverage:
  1. Stochastic data generation physics and Weibull hazard bounds.
  2. Linear Programming budget and capacity feasibility invariants.
  3. Mathematical superiority of Linear Programming over static FIFO heuristic.
  4. Pydantic v2 strict contract and value validation bounds.
  5. Dependency Inversion Principle (DIP) in-memory mock isolation (<5ms).
"""

from datetime import datetime, timezone
import os
import tempfile
import pytest
import numpy as np
import polars as pl
from pydantic import ValidationError

from src.data_generator import generate_domain_dataset
from src.core_engine import (
    InMemoryTelemetrySink,
    OptimizationComparisonService,
    PolarsIncidentIngestionAdapter,
    SLALinearOptimizationEngine,
    create_optimization_pipeline,
)
from src.domain.contracts import (
    IncidentDataIngestionProtocol,
    SLAOptimizationEngineProtocol,
    TelemetryStorageProtocol,
)
from src.domain.entities import (
    EngineeringResourceUnit,
    EngineeringSpecialty,
    ExecutiveOptimizationResult,
    IncidentSeverity,
    IncidentSurvivalState,
    SLAResourceAllocation,
    SLAContractProfile,
    ServiceCluster,
)


@pytest.fixture(scope="session")
def sample_dataset(tmp_path_factory):
    """Generates a temporary calibrated dataset for isolated testing."""
    tmp_dir = tmp_path_factory.mktemp("data")
    parquet_path = str(tmp_dir / "test_incidents.parquet")
    df = generate_domain_dataset(num_records=2500, output_path=parquet_path, seed=123)
    return parquet_path


def test_stochastic_generator_invariants(sample_dataset):
    """Verifies physical invariants, column schemas, and bounds of generated telemetry."""
    df = pl.read_parquet(sample_dataset)
    assert len(df) == 2500
    assert sum(df.null_count().row(0)) == 0, "Telemetry contains unexpected null values"

    # Schema column verification
    expected_cols = {
        "incident_id", "event_timestamp", "service_cluster", "severity", "client_tier",
        "client_arr_usd", "max_sla_hours", "elapsed_hours", "remaining_sla_hours",
        "estimated_work_hours", "hourly_penalty_usd", "max_penalty_cap_usd",
        "weibull_shape_k", "weibull_scale_lambda", "instantaneous_hazard_rate",
        "conditional_breach_prob", "expected_penalty_usd", "recommended_specialty",
        "is_active_triage",
    }
    assert expected_cols.issubset(set(df.columns))

    # Physical bounds checks
    assert df["max_sla_hours"].min() >= 2.0
    assert df["hourly_penalty_usd"].min() > 0.0
    assert df["weibull_shape_k"].min() >= 1.0, "Weibull shape k must be >= 1.0 for aging failure processes"
    assert df["instantaneous_hazard_rate"].min() >= 0.0
    assert df["conditional_breach_prob"].min() >= 0.0
    assert df["conditional_breach_prob"].max() <= 1.0


def test_linear_programming_budget_feasibility(sample_dataset):
    """Asserts that optimal LP allocations strictly satisfy budget and capacity constraints."""
    ingestion, solver = create_optimization_pipeline()
    df = ingestion.ingest_records(sample_dataset)
    incidents = ingestion.parse_incident_survival_states(df, limit_triage_batch=60)
    resources = solver.get_default_engineering_pools()

    max_budget = 45000.0
    opt_result = solver.solve_allocation(incidents, resources, max_budget_usd=max_budget)

    # 1. Budget constraint check
    assert opt_result.total_budget_spent_usd <= max_budget + 1.0, (
        f"Budget violation: spent {opt_result.total_budget_spent_usd} > limit {max_budget}"
    )

    # 2. Solver status check
    assert opt_result.solver_status in ["OPTIMAL", "APPROXIMATE"]
    assert opt_result.total_incidents_triaged == len(incidents)
    assert len(opt_result.allocations) == len(incidents)


def test_linear_programming_superiority_over_heuristic(sample_dataset):
    """Validates that Constrained LP achieves equal or lower financial loss than naive FIFO heuristic."""
    ingestion, solver = create_optimization_pipeline()
    df = ingestion.ingest_records(sample_dataset)
    incidents = ingestion.parse_incident_survival_states(df, limit_triage_batch=80)
    resources = solver.get_default_engineering_pools()

    tradeoff = OptimizationComparisonService.evaluate_tradeoff(incidents, resources, max_budget_usd=50000.0)

    naive_loss = tradeoff["naive_heuristic_residual_penalties_usd"]
    optimal_loss = tradeoff["optimal_linear_residual_penalties_usd"]

    # Mathematical Superiority: LP residual penalty must be <= naive heuristic
    assert optimal_loss <= naive_loss + 1e-5, (
        f"HiGHS LP failed to beat naive heuristic: optimal {optimal_loss} vs naive {naive_loss}"
    )
    assert tradeoff["efficiency_gain_pct"] >= 0.0
    assert tradeoff["solver_latency_ms"] < 250.0


def test_domain_entity_validation():
    """Asserts Pydantic validation rejects negative values and enforces contracts."""
    contract = SLAContractProfile(
        client_id="CLI-TEST-001",
        client_name="Test Enterprise Corp",
        client_tier="Tier-1 Global Financial",
        annual_recurring_revenue_usd=1500000.0,
        max_resolution_hours=4.0,
        hourly_penalty_usd=5000.0,
        max_penalty_cap_usd=50000.0,
    )

    incident = IncidentSurvivalState(
        incident_id="INC-UNIT-01",
        cluster=ServiceCluster.GPU_INFERENCE_CLUSTER,
        severity=IncidentSeverity.CRITICAL_P1,
        contract=contract,
        elapsed_hours=2.5,
        estimated_work_hours_required=3.0,
        weibull_shape_k=2.1,
        weibull_scale_lambda=3.5,
    )

    assert incident.remaining_sla_hours == 1.5
    assert incident.instantaneous_hazard_rate > 0.0
    assert 0.0 <= incident.conditional_breach_probability <= 1.0
    assert incident.expected_sla_penalty_usd > 0.0

    # Negative ARR must raise ValidationError
    with pytest.raises(ValidationError):
        SLAContractProfile(
            client_id="CLI-FAIL",
            client_name="Fail Corp",
            client_tier="Standard",
            annual_recurring_revenue_usd=-50000.0,
            max_resolution_hours=4.0,
            hourly_penalty_usd=100.0,
            max_penalty_cap_usd=1000.0,
        )


def test_core_engine_dependency_inversion_mock():
    """Verifies that core domain logic runs against in-memory mock adapters without disk or network I/O."""
    class MockDataIngestion(IncidentDataIngestionProtocol):
        def ingest_records(self, source_path: str):
            return None

        def parse_incident_survival_states(self, raw_data, limit_triage_batch: int = 5):
            contract = SLAContractProfile(
                client_id="CLI-MOCK",
                client_name="Mock Corp",
                client_tier="Enterprise",
                annual_recurring_revenue_usd=1000000.0,
                max_resolution_hours=6.0,
                hourly_penalty_usd=2000.0,
                max_penalty_cap_usd=20000.0,
            )
            return [
                IncidentSurvivalState(
                    incident_id=f"INC-MOCK-{i}",
                    cluster=ServiceCluster.GPU_INFERENCE_CLUSTER,
                    severity=IncidentSeverity.CRITICAL_P1,
                    contract=contract,
                    elapsed_hours=1.0,
                    estimated_work_hours_required=2.0,
                    weibull_shape_k=2.0,
                    weibull_scale_lambda=4.0,
                )
                for i in range(5)
            ]

    mock_ingestion = MockDataIngestion()
    mock_incidents = mock_ingestion.parse_incident_survival_states(None)
    assert len(mock_incidents) == 5

    solver = SLALinearOptimizationEngine()
    resources = solver.get_default_engineering_pools()
    sink = InMemoryTelemetrySink()

    opt_result = solver.solve_allocation(mock_incidents, resources, max_budget_usd=15000.0)
    persisted = sink.record_optimization_telemetry(opt_result)

    assert persisted is True
    assert len(sink.records) == 1
    assert sink.records[0].total_incidents_triaged == 5
    assert sink.records[0].solve_time_ms < 50.0