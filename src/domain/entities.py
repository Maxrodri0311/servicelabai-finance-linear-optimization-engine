"""
src/domain/entities.py - Pure Domain Models for FinOps & Strategic Consulting Practice SLA Hazard Optimization.
Architecture: Clean Architecture & Strict Pydantic Contracts.
Zero external I/O or vendor infrastructure dependencies.
"""

from datetime import datetime, timezone
from enum import Enum
import math
from typing import Dict, List, Optional
from pydantic import BaseModel, Field, field_validator


class IncidentSeverity(str, Enum):
    """SLA Incident Severity Classes."""
    CRITICAL_P1 = "CRITICAL_P1"
    HIGH_P2 = "HIGH_P2"
    MEDIUM_P3 = "MEDIUM_P3"
    LOW_P4 = "LOW_P4"


class ServiceCluster(str, Enum):
    """FinOps & Strategic Consulting Practice Enterprise Infrastructure Clusters."""
    GPU_INFERENCE_CLUSTER = "GPU Inference Cluster"
    DISTRIBUTED_TRAINING_NODE = "Distributed Training Node"
    API_GATEWAY_ROUTER = "API Gateway Router"
    DATA_LAKE_STORAGE = "Data Lake Storage"
    MLOPS_PIPELINE_ORCHESTRATOR = "MLOps Pipeline Orchestrator"


class EngineeringSpecialty(str, Enum):
    """Specialized engineering roles available for dispatch."""
    NVIDIA_CUDA_SRE = "NVIDIA CUDA SRE"
    DISTRIBUTED_SYSTEMS_ARCHITECT = "Distributed Systems Architect"
    MLOPS_PLATFORM_ENGINEER = "MLOps Platform Engineer"
    L2_OPERATIONS_SPECIALIST = "L2 Operations Specialist"


class SLAContractProfile(BaseModel):
    """Client SLA contractual financial terms."""
    client_id: str
    client_name: str
    client_tier: str = Field(..., description="Enterprise Tier (Tier-1 Global, Strategic, ScaleUp)")
    annual_recurring_revenue_usd: float = Field(..., gt=0.0)
    max_resolution_hours: float = Field(..., gt=0.0, description="Guaranteed SLA resolution window")
    hourly_penalty_usd: float = Field(..., gt=0.0, description="Penalty credit per hour past SLA window")
    max_penalty_cap_usd: float = Field(..., gt=0.0, description="Maximum contractual liability ceiling")


class IncidentSurvivalState(BaseModel):
    """
    Parametric survival state of an active service incident.
    Models the temporal hazard rate h(t) and conditional breach probability P(Breach | T > t).
    """
    incident_id: str
    cluster: ServiceCluster
    severity: IncidentSeverity
    contract: SLAContractProfile
    elapsed_hours: float = Field(..., ge=0.0)
    estimated_work_hours_required: float = Field(..., gt=0.0)
    weibull_shape_k: float = Field(..., gt=0.0, description="Weibull shape parameter (k > 1 indicates aging hazard)")
    weibull_scale_lambda: float = Field(..., gt=0.0, description="Weibull scale parameter (characteristic life in hours)")

    @property
    def remaining_sla_hours(self) -> float:
        """Remaining operational window before contractual SLA breach begins."""
        return max(0.0, self.contract.max_resolution_hours - self.elapsed_hours)

    @property
    def instantaneous_hazard_rate(self) -> float:
        """
        Instantaneous failure hazard rate h(t) under Weibull survival distribution:
        h(t) = (k / lambda) * (t / lambda)^(k - 1)
        """
        t = max(0.01, self.elapsed_hours)
        k = self.weibull_shape_k
        lam = self.weibull_scale_lambda
        return (k / lam) * math.pow(t / lam, k - 1.0)

    @property
    def conditional_breach_probability(self) -> float:
        """
        Conditional probability that the incident breaches SLA before resolution:
        P(T > SLA_max | T > elapsed) = exp(- (SLA_max / lambda)^k + (elapsed / lambda)^k)
        """
        sla_target = self.contract.max_resolution_hours
        lam = self.weibull_scale_lambda
        k = self.weibull_shape_k
        if self.elapsed_hours >= sla_target:
            return 1.0
        
        cumulative_hazard_elapsed = math.pow(self.elapsed_hours / lam, k)
        cumulative_hazard_sla = math.pow(sla_target / lam, k)
        # Survival past SLA given survived to elapsed:
        surv_ratio = math.exp(-(cumulative_hazard_sla - cumulative_hazard_elapsed))
        breach_prob = 1.0 - surv_ratio
        return min(max(breach_prob, 0.0), 1.0)

    @property
    def expected_sla_penalty_usd(self) -> float:
        """Expected baseline financial penalty without expedited engineering intervention."""
        prob_breach = self.conditional_breach_probability
        overrun_hours = max(0.0, (self.elapsed_hours + self.estimated_work_hours_required) - self.contract.max_resolution_hours)
        unmitigated_penalty = overrun_hours * self.contract.hourly_penalty_usd
        penalty = prob_breach * min(unmitigated_penalty, self.contract.max_penalty_cap_usd)
        return round(penalty, 2)


class EngineeringResourceUnit(BaseModel):
    """Capacity and labor economics of specialized engineering support pools."""
    specialty: EngineeringSpecialty
    hourly_rate_usd: float = Field(..., gt=0.0)
    available_hours_shift: float = Field(..., gt=0.0)
    cluster_efficiency_weights: Dict[ServiceCluster, float] = Field(
        default_factory=dict,
        description="Speedup multiplier per cluster (e.g. CUDA SRE on GPU Inference = 1.8x)",
    )


class SLAResourceAllocation(BaseModel):
    """Decision variable allocation outcome for an incident."""
    incident_id: str
    specialty: EngineeringSpecialty
    allocated_hours: float = Field(..., ge=0.0)
    operational_cost_usd: float = Field(..., ge=0.0)
    penalty_mitigated_usd: float = Field(..., ge=0.0)
    residual_penalty_usd: float = Field(..., ge=0.0)
    net_financial_gain_usd: float = Field(..., description="Mitigated penalty minus operational cost")


class ExecutiveOptimizationResult(BaseModel):
    """C-Level aggregate decision suite output."""
    optimization_id: str
    solver_status: str
    total_budget_spent_usd: float = Field(..., ge=0.0)
    total_incidents_triaged: int = Field(..., ge=0)
    naive_heuristic_penalties_usd: float = Field(..., ge=0.0)
    optimal_linear_penalties_usd: float = Field(..., ge=0.0)
    net_penalty_avoidance_usd: float = Field(..., ge=0.0)
    efficiency_gain_pct: float = Field(..., description="Percentage reduction in total financial penalties")
    allocations: List[SLAResourceAllocation] = Field(default_factory=list)
    solve_time_ms: float = Field(..., ge=0.0)
    solved_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))