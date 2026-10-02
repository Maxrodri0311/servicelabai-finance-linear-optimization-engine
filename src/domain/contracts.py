"""
src/domain/contracts.py - Inversion of Dependencies (DIP) Protocols.
Architecture: Anti-Buried Dependencies & Clean Architecture Policy.
All business services depend strictly on these abstract interface protocols.
"""

from typing import Any, Dict, List, Optional, Protocol
import pandas as pd

from .entities import (
    EngineeringResourceUnit,
    ExecutiveOptimizationResult,
    IncidentSurvivalState,
    SLAResourceAllocation,
)


class IncidentDataIngestionProtocol(Protocol):
    """Abstract data ingestion interface for incident and SLA telemetry."""

    def ingest_records(self, source_path: str) -> Any:
        """Loads raw telemetry dataset from storage path."""
        ...

    def parse_incident_survival_states(self, raw_data: Any) -> List[IncidentSurvivalState]:
        """Maps tabular dataframe records into strongly-typed domain survival entities."""
        ...


class SLAOptimizationEngineProtocol(Protocol):
    """Abstract mathematical decision engine implementing Constrained Linear Programming."""

    def solve_allocation(
        self,
        incidents: List[IncidentSurvivalState],
        resources: List[EngineeringResourceUnit],
        max_budget_usd: float,
    ) -> ExecutiveOptimizationResult:
        """Solves optimal engineering resource dispatch via HiGHS Simplex/Interior Point."""
        ...

    def evaluate_static_heuristic(
        self,
        incidents: List[IncidentSurvivalState],
        resources: List[EngineeringResourceUnit],
        max_budget_usd: float,
    ) -> Dict[str, Any]:
        """Calculates benchmark metrics using unconstrained FIFO / static severity heuristic."""
        ...


class ExecutiveWorkbookProtocol(Protocol):
    """Abstract reporting contract for DeliveryParadigm.C_LEVEL_EXECUTIVE_SUITE."""

    def generate_executive_suite(
        self,
        result: ExecutiveOptimizationResult,
        output_path: str = "data/ServicelabAI_Executive_SLA_Optimization_Suite.xlsx",
    ) -> str:
        """Renders an institutional C-Level financial workbook with live formulas and DAX rollups."""
        ...


class TelemetryStorageProtocol(Protocol):
    """Abstract analytical storage contract for telemetry and audit logging."""

    def record_optimization_telemetry(self, result: ExecutiveOptimizationResult) -> bool:
        """Persists optimization telemetry into analytical store (PostgreSQL / Lakehouse)."""
        ...