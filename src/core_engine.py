"""
src/core_engine.py - Core Algorithmic & Linear Optimization Engine for Servicelab AI.
Architecture: Decoupled Multi-Tier Domain adhering strictly to Dependency Inversion (DIP).
Core Algorithm: Constrained Linear Programming (SciPy HiGHS Simplex & Interior Point Solvers).
Perspective: Causal & Survival Lifecycle Analytics (Weibull Hazard Rate & SLA Breach Mitigation).
"""

from datetime import datetime, timezone
import os
from pathlib import Path
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

import numpy as np
import polars as pl
from scipy.optimize import linprog

# Path resolution for standalone invocation
_project_root = str(Path(__file__).resolve().parent.parent)
if _project_root not in sys.path:
    sys.path.insert(0, _project_root)

if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

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


class PolarsIncidentIngestionAdapter(IncidentDataIngestionProtocol):
    """Concrete infrastructure adapter for high-throughput incident telemetry ingestion."""

    def ingest_records(self, source_path: str) -> pl.DataFrame:
        if not os.path.exists(source_path):
            raise FileNotFoundError(f"[DataIngestion] Parquet source not found at: {source_path}")
        return pl.read_parquet(source_path)

    def parse_incident_survival_states(
        self,
        raw_data: pl.DataFrame,
        limit_triage_batch: int = 120,
    ) -> List[IncidentSurvivalState]:
        """
        Parses active service incident records into strongly-typed domain survival entities.
        Filters for active triage incidents and sorts by hazard rate exposure.
        """
        active_df = (
            raw_data.filter(pl.col("is_active_triage") == True)
            .sort(["expected_penalty_usd", "instantaneous_hazard_rate"], descending=[True, True])
            .head(limit_triage_batch)
        )

        incidents: List[IncidentSurvivalState] = []
        for row in active_df.iter_rows(named=True):
            contract = SLAContractProfile(
                client_id=f"CLI-{row['incident_id'][9:]}",
                client_name=f"Enterprise {row['client_tier']} Corp",
                client_tier=row["client_tier"],
                annual_recurring_revenue_usd=float(row["client_arr_usd"]),
                max_resolution_hours=float(row["max_sla_hours"]),
                hourly_penalty_usd=float(row["hourly_penalty_usd"]),
                max_penalty_cap_usd=float(row["max_penalty_cap_usd"]),
            )

            state = IncidentSurvivalState(
                incident_id=row["incident_id"],
                cluster=ServiceCluster(row["service_cluster"]),
                severity=IncidentSeverity(row["severity"]),
                contract=contract,
                elapsed_hours=float(row["elapsed_hours"]),
                estimated_work_hours_required=float(row["estimated_work_hours"]),
                weibull_shape_k=float(row["weibull_shape_k"]),
                weibull_scale_lambda=float(row["weibull_scale_lambda"]),
            )
            incidents.append(state)

        return incidents


class SLALinearOptimizationEngine(SLAOptimizationEngineProtocol):
    """
    Mathematical Optimization Engine for SLA Incident Triage & Engineer Dispatch.
    Formulates a Primal Linear Program solved via SciPy HiGHS (Dual Simplex / Interior Point).
    """

    @staticmethod
    def get_default_engineering_pools() -> List[EngineeringResourceUnit]:
        """Standard shift capacity and specialty efficiency matrix."""
        return [
            EngineeringResourceUnit(
                specialty=EngineeringSpecialty.NVIDIA_CUDA_SRE,
                hourly_rate_usd=185.0,
                available_hours_shift=120.0,
                cluster_efficiency_weights={
                    ServiceCluster.GPU_INFERENCE_CLUSTER: 1.85,
                    ServiceCluster.DISTRIBUTED_TRAINING_NODE: 1.50,
                    ServiceCluster.API_GATEWAY_ROUTER: 0.80,
                    ServiceCluster.DATA_LAKE_STORAGE: 0.90,
                    ServiceCluster.MLOPS_PIPELINE_ORCHESTRATOR: 1.20,
                },
            ),
            EngineeringResourceUnit(
                specialty=EngineeringSpecialty.DISTRIBUTED_SYSTEMS_ARCHITECT,
                hourly_rate_usd=165.0,
                available_hours_shift=140.0,
                cluster_efficiency_weights={
                    ServiceCluster.GPU_INFERENCE_CLUSTER: 1.30,
                    ServiceCluster.DISTRIBUTED_TRAINING_NODE: 1.90,
                    ServiceCluster.API_GATEWAY_ROUTER: 1.40,
                    ServiceCluster.DATA_LAKE_STORAGE: 1.70,
                    ServiceCluster.MLOPS_PIPELINE_ORCHESTRATOR: 1.30,
                },
            ),
            EngineeringResourceUnit(
                specialty=EngineeringSpecialty.MLOPS_PLATFORM_ENGINEER,
                hourly_rate_usd=140.0,
                available_hours_shift=160.0,
                cluster_efficiency_weights={
                    ServiceCluster.GPU_INFERENCE_CLUSTER: 1.15,
                    ServiceCluster.DISTRIBUTED_TRAINING_NODE: 1.25,
                    ServiceCluster.API_GATEWAY_ROUTER: 1.10,
                    ServiceCluster.DATA_LAKE_STORAGE: 1.30,
                    ServiceCluster.MLOPS_PIPELINE_ORCHESTRATOR: 1.95,
                },
            ),
            EngineeringResourceUnit(
                specialty=EngineeringSpecialty.L2_OPERATIONS_SPECIALIST,
                hourly_rate_usd=85.0,
                available_hours_shift=220.0,
                cluster_efficiency_weights={
                    ServiceCluster.GPU_INFERENCE_CLUSTER: 0.70,
                    ServiceCluster.DISTRIBUTED_TRAINING_NODE: 0.75,
                    ServiceCluster.API_GATEWAY_ROUTER: 1.35,
                    ServiceCluster.DATA_LAKE_STORAGE: 1.10,
                    ServiceCluster.MLOPS_PIPELINE_ORCHESTRATOR: 1.00,
                },
            ),
        ]

    def solve_allocation(
        self,
        incidents: List[IncidentSurvivalState],
        resources: List[EngineeringResourceUnit],
        max_budget_usd: float = 75000.0,
    ) -> ExecutiveOptimizationResult:
        """
        Solves optimal engineer dispatch to minimize total financial SLA penalties.
        Decision variables: x[i, j] = hours of resource pool j assigned to incident i.
        """
        t0 = time.perf_counter()
        N = len(incidents)
        M = len(resources)

        if N == 0 or M == 0:
            return ExecutiveOptimizationResult(
                optimization_id="OPT-EMPTY",
                solver_status="NO_INCIDENTS",
                total_budget_spent_usd=0.0,
                total_incidents_triaged=0,
                naive_heuristic_penalties_usd=0.0,
                optimal_linear_penalties_usd=0.0,
                net_penalty_avoidance_usd=0.0,
                efficiency_gain_pct=0.0,
                allocations=[],
                solve_time_ms=0.0,
            )

        num_vars = N * M

        # Objective Function:
        # Maximize Net Value = Mitigated Penalty - Labor Cost
        # Equivalent to Minimizing: sum_{i, j} (r_j - R_i * E_ij / W_i) * x_{i, j}
        c = np.zeros(num_vars)
        for i, inc in enumerate(incidents):
            risk = inc.expected_sla_penalty_usd
            w_req = inc.estimated_work_hours_required
            for j, res in enumerate(resources):
                eff = res.cluster_efficiency_weights.get(inc.cluster, 1.0)
                marginal_penalty_mitigation_rate = (risk * eff) / max(w_req, 0.1)
                cost_rate = res.hourly_rate_usd
                idx = i * M + j
                # Objective coefficient for minimization:
                c[idx] = cost_rate - marginal_penalty_mitigation_rate

        # Constraints:
        A_ub_list = []
        b_ub_list = []

        # 1. Total Shift Hours Capacity per Engineering Pool (M constraints)
        for j, res in enumerate(resources):
            row = np.zeros(num_vars)
            for i in range(N):
                row[i * M + j] = 1.0
            A_ub_list.append(row)
            b_ub_list.append(res.available_hours_shift)

        # 2. Incident Work Demand Ceiling: sum_j E_ij * x_ij <= W_i (N constraints)
        for i, inc in enumerate(incidents):
            row = np.zeros(num_vars)
            for j, res in enumerate(resources):
                eff = res.cluster_efficiency_weights.get(inc.cluster, 1.0)
                row[i * M + j] = eff
            A_ub_list.append(row)
            b_ub_list.append(inc.estimated_work_hours_required)

        # 3. Total Operational Budget Ceiling: sum_{i, j} r_j * x_ij <= max_budget_usd (1 constraint)
        row_budget = np.zeros(num_vars)
        for i in range(N):
            for j, res in enumerate(resources):
                row_budget[i * M + j] = res.hourly_rate_usd
        A_ub_list.append(row_budget)
        b_ub_list.append(max_budget_usd)

        # 4. Critical P1 Guaranteed Work Allocation:
        # sum_j E_ij * x_ij >= 0.80 * W_i  =>  - sum_j E_ij * x_ij <= - 0.80 * W_i
        for i, inc in enumerate(incidents):
            if inc.severity == IncidentSeverity.CRITICAL_P1:
                row_p1 = np.zeros(num_vars)
                for j, res in enumerate(resources):
                    eff = res.cluster_efficiency_weights.get(inc.cluster, 1.0)
                    row_p1[i * M + j] = -eff
                A_ub_list.append(row_p1)
                b_ub_list.append(-0.80 * inc.estimated_work_hours_required)

        A_ub = np.array(A_ub_list)
        b_ub = np.array(b_ub_list)

        # Decision Variable Bounds: x_ij >= 0
        bounds = [(0.0, None) for _ in range(num_vars)]

        # Solve LP via HiGHS
        res_opt = linprog(
            c=c,
            A_ub=A_ub,
            b_ub=b_ub,
            bounds=bounds,
            method="highs",
            options={"presolve": True},
        )

        solve_time_ms = (time.perf_counter() - t0) * 1000.0

        if not res_opt.success:
            # Fallback relaxation if P1 guarantees conflict with budget
            res_opt = linprog(
                c=c,
                A_ub=A_ub[: M + N + 1],
                b_ub=b_ub[: M + N + 1],
                bounds=bounds,
                method="highs",
            )

        sol_x = res_opt.x if res_opt.x is not None else np.zeros(num_vars)

        # Reconstruct Allocations and Financial Metrics
        allocations: List[SLAResourceAllocation] = []
        total_spent = 0.0
        total_mitigated = 0.0
        total_unmitigated = sum(inc.expected_sla_penalty_usd for inc in incidents)

        for i, inc in enumerate(incidents):
            total_effective_work = 0.0
            inc_cost = 0.0
            primary_specialty = EngineeringSpecialty.L2_OPERATIONS_SPECIALIST
            max_assigned_hours = 0.0

            for j, res in enumerate(resources):
                h = float(sol_x[i * M + j])
                if h > 0.001:
                    eff = res.cluster_efficiency_weights.get(inc.cluster, 1.0)
                    total_effective_work += h * eff
                    inc_cost += h * res.hourly_rate_usd
                    if h > max_assigned_hours:
                        max_assigned_hours = h
                        primary_specialty = res.specialty

            fraction_resolved = min(1.0, total_effective_work / max(inc.estimated_work_hours_required, 0.1))
            penalty_mitigated = round(fraction_resolved * inc.expected_sla_penalty_usd, 2)
            residual_penalty = round(max(0.0, inc.expected_sla_penalty_usd - penalty_mitigated), 2)
            net_gain = round(penalty_mitigated - inc_cost, 2)

            allocations.append(
                SLAResourceAllocation(
                    incident_id=inc.incident_id,
                    specialty=primary_specialty,
                    allocated_hours=round(max_assigned_hours, 2),
                    operational_cost_usd=round(inc_cost, 2),
                    penalty_mitigated_usd=penalty_mitigated,
                    residual_penalty_usd=residual_penalty,
                    net_financial_gain_usd=net_gain,
                )
            )

            total_spent += inc_cost
            total_mitigated += penalty_mitigated

        optimal_penalties = max(0.0, total_unmitigated - total_mitigated)

        # Compute Naive Heuristic benchmark
        naive_metrics = self.evaluate_static_heuristic(incidents, resources, max_budget_usd)
        naive_penalties = naive_metrics["total_residual_penalties_usd"]

        penalty_reduction = max(0.0, naive_penalties - optimal_penalties)
        efficiency_gain = (
            round((penalty_reduction / max(naive_penalties, 1.0)) * 100.0, 2)
            if naive_penalties > 0
            else 0.0
        )

        return ExecutiveOptimizationResult(
            optimization_id=f"OPT-{int(time.time())}",
            solver_status="OPTIMAL" if res_opt.success else "APPROXIMATE",
            total_budget_spent_usd=round(total_spent, 2),
            total_incidents_triaged=len(incidents),
            naive_heuristic_penalties_usd=round(naive_penalties, 2),
            optimal_linear_penalties_usd=round(optimal_penalties, 2),
            net_penalty_avoidance_usd=round(penalty_reduction, 2),
            efficiency_gain_pct=efficiency_gain,
            allocations=allocations,
            solve_time_ms=round(solve_time_ms, 2),
            solved_at=datetime.now(timezone.utc),
        )

    def evaluate_static_heuristic(
        self,
        incidents: List[IncidentSurvivalState],
        resources: List[EngineeringResourceUnit],
        max_budget_usd: float = 75000.0,
    ) -> Dict[str, Any]:
        """
        Evaluates the traditional Static Severity / FIFO greedy assignment heuristic:
        Sorts purely by severity (P1 -> P2 -> P3 -> P4), dispatches first available engineer
        without factoring in Weibull hazard rate h(t) or specialty efficiency speedups.
        """
        severity_order = {
            IncidentSeverity.CRITICAL_P1: 0,
            IncidentSeverity.HIGH_P2: 1,
            IncidentSeverity.MEDIUM_P3: 2,
            IncidentSeverity.LOW_P4: 3,
        }
        sorted_incidents = sorted(incidents, key=lambda inc: severity_order[inc.severity])

        remaining_pool_hours = {r.specialty: r.available_hours_shift for r in resources}
        total_cost = 0.0
        total_mitigated = 0.0
        total_unmitigated = sum(inc.expected_sla_penalty_usd for inc in incidents)

        for inc in sorted_incidents:
            work_needed = inc.estimated_work_hours_required
            # Naive assignment: picks first pool with remaining hours
            assigned = False
            for res in resources:
                if remaining_pool_hours[res.specialty] > 0 and (total_cost + res.hourly_rate_usd * 2.0) <= max_budget_usd:
                    hours_to_assign = min(remaining_pool_hours[res.specialty], work_needed)
                    cost = hours_to_assign * res.hourly_rate_usd
                    if total_cost + cost <= max_budget_usd:
                        remaining_pool_hours[res.specialty] -= hours_to_assign
                        total_cost += cost
                        # In naive assignment, efficiency is 1.0 (generic dispatch)
                        frac = min(1.0, hours_to_assign / max(work_needed, 0.1))
                        total_mitigated += frac * inc.expected_sla_penalty_usd
                        assigned = True
                        break
            if not assigned:
                continue

        residual_penalties = max(0.0, total_unmitigated - total_mitigated)
        return {
            "total_spent_usd": round(total_cost, 2),
            "total_mitigated_usd": round(total_mitigated, 2),
            "total_residual_penalties_usd": round(residual_penalties, 2),
        }


class OptimizationComparisonService:
    """Enterprise Decision Support Service comparing LP vs. Status Quo Heuristics."""

    @classmethod
    def evaluate_tradeoff(
        cls,
        incidents: List[IncidentSurvivalState],
        resources: List[EngineeringResourceUnit],
        max_budget_usd: float = 75000.0,
    ) -> Dict[str, Any]:
        engine = SLALinearOptimizationEngine()
        opt_result = engine.solve_allocation(incidents, resources, max_budget_usd)
        naive_result = engine.evaluate_static_heuristic(incidents, resources, max_budget_usd)

        total_unmitigated = sum(inc.expected_sla_penalty_usd for inc in incidents)
        savings = naive_result["total_residual_penalties_usd"] - opt_result.optimal_linear_penalties_usd

        return {
            "total_incidents": len(incidents),
            "max_budget_usd": max_budget_usd,
            "total_unmitigated_financial_risk_usd": round(total_unmitigated, 2),
            "naive_heuristic_residual_penalties_usd": naive_result["total_residual_penalties_usd"],
            "optimal_linear_residual_penalties_usd": opt_result.optimal_linear_penalties_usd,
            "net_penalty_reduction_usd": round(savings, 2),
            "efficiency_gain_pct": opt_result.efficiency_gain_pct,
            "solver_latency_ms": opt_result.solve_time_ms,
            "conclusion": (
                f"Constrained Linear Programming with Weibull hazard analytics compresses SLA breach "
                f"penalties by {opt_result.efficiency_gain_pct:.1f}% (${savings:,.2f} net savings) "
                f"compared to static FIFO triage under identical operational budgets."
            ),
        }


class InMemoryTelemetrySink(TelemetryStorageProtocol):
    """Zero-I/O in-memory telemetry sink for isolated sub-5ms testing."""

    def __init__(self):
        self.records: List[ExecutiveOptimizationResult] = []

    def record_optimization_telemetry(self, result: ExecutiveOptimizationResult) -> bool:
        self.records.append(result)
        return True


def create_optimization_pipeline() -> Tuple[PolarsIncidentIngestionAdapter, SLALinearOptimizationEngine]:
    """Composition root."""
    return PolarsIncidentIngestionAdapter(), SLALinearOptimizationEngine()


if __name__ == "__main__":
    data_file = "data/raw_dataset.parquet"
    if not os.path.exists(data_file):
        from src.data_generator import generate_domain_dataset
        generate_domain_dataset(num_records=50000, output_path=data_file)

    ingestion, solver = create_optimization_pipeline()
    df = ingestion.ingest_records(data_file)
    incidents = ingestion.parse_incident_survival_states(df, limit_triage_batch=120)
    resources = solver.get_default_engineering_pools()

    tradeoff = OptimizationComparisonService.evaluate_tradeoff(incidents, resources, max_budget_usd=75000.0)

    print("\n" + "=" * 76)
    print(" [*] SERVICELAB AI - SLA HAZARD & LINEAR OPTIMIZATION BENCHMARK")
    print("=" * 76)
    print(f" Incidents in Triage Queue      : {tradeoff['total_incidents']} critical/high incidents")
    print(f" Total Unmitigated Exposure     : ${tradeoff['total_unmitigated_financial_risk_usd']:,.2f}")
    print(f" Maximum Operational Budget     : ${tradeoff['max_budget_usd']:,.2f}")
    print(f" Solver Latency (HiGHS)         : {tradeoff['solver_latency_ms']:.2f} ms")
    print("-" * 76)
    print(f" 1. Static FIFO Heuristic Loss  : ${tradeoff['naive_heuristic_residual_penalties_usd']:,.2f} in SLA Penalties")
    print(f" 2. Optimal Linear Programming  : ${tradeoff['optimal_linear_residual_penalties_usd']:,.2f} in SLA Penalties")
    print("-" * 76)
    print(f" Net Penalty Reduction (Savings): +${tradeoff['net_penalty_reduction_usd']:,.2f} (-{tradeoff['efficiency_gain_pct']}%)")
    print(f"\n Verdict: {tradeoff['conclusion']}")
    print("=" * 76 + "\n")