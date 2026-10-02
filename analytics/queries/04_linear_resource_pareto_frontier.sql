-- ==============================================================================
-- 04_linear_resource_pareto_frontier.sql
-- Servicelab AI - Multi-Objective Pareto Optimal Frontier & MRTS Engine
--
-- Objective:
--   Computes the non-dominated Pareto frontier trading off operational support
--   labor expenditure ($) against mitigated SLA breach penalties ($).
--   Calculates the Marginal Rate of Technical Substitution (MRTS) across
--   specialized engineering pools (CUDA SRE vs Distributed Systems Architect).
-- Dialect: PostgreSQL 14+ / 16 (Analytical CTEs, Self-Joins, Window Functions)
-- ==============================================================================

WITH resource_cluster_combinations AS (
    -- 1. Base Aggregations of Labor Cost and Mitigated Penalty Potential
    SELECT
        service_cluster,
        severity,
        recommended_specialty,
        COUNT(incident_id) AS incident_count,
        SUM(estimated_work_hours) AS total_work_hours,
        SUM(expected_penalty_usd) AS total_penalty_liability_usd,
        -- Specialized Labor Rates ($/Hour)
        CASE recommended_specialty
            WHEN 'NVIDIA CUDA SRE' THEN 185.00
            WHEN 'Distributed Systems Architect' THEN 165.00
            WHEN 'MLOps Platform Engineer' THEN 140.00
            ELSE 85.00
        END AS specialty_hourly_rate_usd,
        -- Cluster Speedup Efficiency Multipliers
        CASE
            WHEN recommended_specialty = 'NVIDIA CUDA SRE' AND service_cluster = 'GPU Inference Cluster' THEN 1.85
            WHEN recommended_specialty = 'Distributed Systems Architect' AND service_cluster = 'Distributed Training Node' THEN 1.90
            WHEN recommended_specialty = 'MLOps Platform Engineer' AND service_cluster = 'MLOps Pipeline Orchestrator' THEN 1.95
            ELSE 1.10
        END AS cluster_efficiency_multiplier
    FROM service_incident_telemetry
    WHERE is_active_triage = TRUE
    GROUP BY
        service_cluster,
        severity,
        recommended_specialty
),

economic_tradeoff_matrix AS (
    -- 2. Derive Effective Operational Cost and Financial ROI per Unit
    SELECT
        service_cluster,
        severity,
        recommended_specialty,
        incident_count,
        total_work_hours,
        total_penalty_liability_usd,
        specialty_hourly_rate_usd,
        cluster_efficiency_multiplier,
        -- Effective Labor Cost: (Hours / Efficiency) * Rate
        ROUND(
            (total_work_hours / cluster_efficiency_multiplier) * specialty_hourly_rate_usd,
            2
        ) AS effective_labor_cost_usd,
        -- Net Mitigated Value: Penalty Liability - Labor Cost
        ROUND(
            total_penalty_liability_usd - ((total_work_hours / cluster_efficiency_multiplier) * specialty_hourly_rate_usd),
            2
        ) AS net_mitigated_value_usd,
        -- Benefit-to-Cost Ratio (BCR)
        ROUND(
            total_penalty_liability_usd /
            NULLIF(((total_work_hours / cluster_efficiency_multiplier) * specialty_hourly_rate_usd), 0),
            4
        ) AS benefit_cost_ratio
    FROM resource_cluster_combinations
),

pareto_dominance_audit AS (
    -- 3. Pareto Non-Dominated Set Identification
    -- A point A is dominated by B if Cost(B) <= Cost(A) AND NetValue(B) >= NetValue(A) with at least one strict inequality
    SELECT
        a.*,
        NOT EXISTS (
            SELECT 1
            FROM economic_tradeoff_matrix b
            WHERE b.effective_labor_cost_usd <= a.effective_labor_cost_usd
              AND b.net_mitigated_value_usd >= a.net_mitigated_value_usd
              AND (
                  b.effective_labor_cost_usd < a.effective_labor_cost_usd
                  OR b.net_mitigated_value_usd > a.net_mitigated_value_usd
              )
        ) AS is_pareto_optimal
    FROM economic_tradeoff_matrix a
)

-- 4. Final Pareto Frontier & Marginal Rate of Technical Substitution (MRTS)
SELECT
    service_cluster,
    severity,
    recommended_specialty,
    incident_count,
    effective_labor_cost_usd,
    total_penalty_liability_usd,
    net_mitigated_value_usd,
    benefit_cost_ratio,
    is_pareto_optimal,
    -- Marginal Rate of Technical Substitution (MRTS): d(NetValue) / d(LaborCost)
    ROUND(
        (
            net_mitigated_value_usd - LAG(net_mitigated_value_usd, 1) OVER (
                PARTITION BY service_cluster
                ORDER BY effective_labor_cost_usd ASC
            )
        ) /
        NULLIF(
            (
                effective_labor_cost_usd - LAG(effective_labor_cost_usd, 1) OVER (
                    PARTITION BY service_cluster
                    ORDER BY effective_labor_cost_usd ASC
                )
            ),
            0
        ),
        4
    ) AS marginal_rate_of_technical_substitution,
    -- Linear Programming Dispatch Priority Recommendation
    CASE
        WHEN is_pareto_optimal AND benefit_cost_ratio >= 15.0
        THEN 'TOP_PRIORITY_EXPEDITED_DISPATCH'
        WHEN is_pareto_optimal AND benefit_cost_ratio BETWEEN 5.0 AND 14.99
        THEN 'SECONDARY_OPTIMAL_ALLOCATION'
        WHEN NOT is_pareto_optimal AND benefit_cost_ratio >= 3.0
        THEN 'FEASIBLE_SUB_OPTIMAL_BUFFER'
        ELSE 'REJECT_INEFFICIENT_DISPATCH'
    END AS lp_dispatch_strategy
FROM pareto_dominance_audit
ORDER BY
    is_pareto_optimal DESC,
    benefit_cost_ratio DESC;
