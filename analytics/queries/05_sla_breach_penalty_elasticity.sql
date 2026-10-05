-- ==============================================================================
-- 05_sla_breach_penalty_elasticity.sql
-- FinOps & Strategic Consulting Practice - SLA Breach Penalty Elasticity & Shadow Price Derivatives
--
-- Objective:
--   Evaluates the marginal elasticity of financial penalty mitigation with respect
--   to specialized engineering support hours across Service Clusters.
--   Computes finite difference quotients (dPenalty / dHours) to determine the
--   dual shadow prices of engineering shift capacity constraints in the Linear Program.
-- Dialect: PostgreSQL 14+ / 16 (Finite Differences, Window Framing, CTEs)
-- ==============================================================================

WITH cluster_labor_allocations AS (
    -- 1. Aggregate Labor Hours, Capacity Demands, and Associated Penalty Liabilities
    SELECT
        service_cluster,
        severity,
        DATE_TRUNC('month', event_timestamp)::DATE AS operational_month,
        COUNT(incident_id) AS total_incidents,
        SUM(estimated_work_hours) AS total_work_hours_demanded,
        SUM(expected_penalty_usd) AS aggregate_penalty_liability_usd,
        AVG(instantaneous_hazard_rate) AS mean_hazard_rate,
        AVG(conditional_breach_prob) AS mean_breach_probability
    FROM service_incident_telemetry
    WHERE is_active_triage = TRUE
    GROUP BY
        service_cluster,
        severity,
        DATE_TRUNC('month', event_timestamp)::DATE
),

finite_difference_derivatives AS (
    -- 2. First Finite Differences for Labor Elasticity across Sequential Operational Months
    SELECT
        service_cluster,
        severity,
        operational_month,
        total_work_hours_demanded,
        aggregate_penalty_liability_usd,
        mean_hazard_rate,
        mean_breach_probability,
        LAG(total_work_hours_demanded, 1) OVER w_cluster AS prev_work_hours,
        LAG(aggregate_penalty_liability_usd, 1) OVER w_cluster AS prev_penalty_liability,
        -- Marginal Penalty Mitigation per Engineering Hour: d(Penalty) / d(Hours)
        CASE
            WHEN (total_work_hours_demanded - LAG(total_work_hours_demanded, 1) OVER w_cluster) > 0
            THEN (
                aggregate_penalty_liability_usd - LAG(aggregate_penalty_liability_usd, 1) OVER w_cluster
            ) / NULLIF(total_work_hours_demanded - LAG(total_work_hours_demanded, 1) OVER w_cluster, 0)
            ELSE aggregate_penalty_liability_usd / NULLIF(total_work_hours_demanded, 0)
        END AS marginal_penalty_mitigation_rate_usd,
        -- Point Elasticity of Support: (% dPenalty) / (% dHours)
        CASE
            WHEN LAG(total_work_hours_demanded, 1) OVER w_cluster > 0
                 AND LAG(aggregate_penalty_liability_usd, 1) OVER w_cluster > 0
                 AND (total_work_hours_demanded - LAG(total_work_hours_demanded, 1) OVER w_cluster) > 0
            THEN (
                (aggregate_penalty_liability_usd - LAG(aggregate_penalty_liability_usd, 1) OVER w_cluster) /
                NULLIF(LAG(aggregate_penalty_liability_usd, 1) OVER w_cluster, 0)::NUMERIC
            ) / (
                (total_work_hours_demanded - LAG(total_work_hours_demanded, 1) OVER w_cluster) /
                NULLIF(LAG(total_work_hours_demanded, 1) OVER w_cluster, 0)::NUMERIC
            )
            ELSE 1.0000
        END AS labor_penalty_elasticity
    FROM cluster_labor_allocations
    WINDOW w_cluster AS (
        PARTITION BY service_cluster, severity
        ORDER BY operational_month ASC
        ROWS BETWEEN 1 PRECEDING AND CURRENT ROW
    )
),

dual_shadow_price_estimation AS (
    -- 3. Estimation of Mathematical Dual Variables (Shadow Prices)
    -- Under HiGHS LP constraints, the shadow price represents the reduction in residual SLA penalties
    -- achievable by expanding the engineering shift capacity by 1 additional hour.
    SELECT
        service_cluster,
        severity,
        operational_month,
        total_work_hours_demanded,
        aggregate_penalty_liability_usd,
        mean_hazard_rate,
        mean_breach_probability,
        marginal_penalty_mitigation_rate_usd,
        labor_penalty_elasticity,
        -- Shadow Price: Penalty savings achievable per +10 hours of shift capacity
        ROUND(
            ABS(marginal_penalty_mitigation_rate_usd * 10.0),
            2
        ) AS shadow_price_per_10_hours_expansion_usd,
        -- Elasticity Classification Regime
        CASE
            WHEN labor_penalty_elasticity >= 1.25 THEN 'HIGH_RETURN_ELASTIC_ZONE'
            WHEN labor_penalty_elasticity BETWEEN 0.80 AND 1.24 THEN 'CONSTANT_PROPORTIONAL_RETURNS'
            WHEN labor_penalty_elasticity BETWEEN 0.30 AND 0.79 THEN 'INELASTIC_SATURATING_RETURNS'
            ELSE 'CAPITAL_INEFFICIENT_TRAP'
        END AS elasticity_regime
    FROM finite_difference_derivatives
)

-- 4. Final Executive Cluster Elasticity and Capacity Allocation Directive
SELECT
    service_cluster,
    severity,
    COUNT(DISTINCT operational_month) AS observation_periods,
    ROUND(AVG(total_work_hours_demanded), 1) AS avg_monthly_hours_demanded,
    ROUND(AVG(aggregate_penalty_liability_usd), 2) AS avg_monthly_penalty_exposure_usd,
    ROUND(AVG(marginal_penalty_mitigation_rate_usd), 2) AS blended_marginal_mitigation_usd_per_hour,
    ROUND(AVG(shadow_price_per_10_hours_expansion_usd), 2) AS avg_shadow_price_10h_usd,
    ROUND(AVG(labor_penalty_elasticity), 4) AS avg_penalty_elasticity,
    MODE() WITHIN GROUP (ORDER BY elasticity_regime) AS dominant_elasticity_regime,
    -- Strategic C-Level Resource Action
    CASE
        WHEN MODE() WITHIN GROUP (ORDER BY elasticity_regime) = 'HIGH_RETURN_ELASTIC_ZONE'
        THEN 'PRIORITIZE_SHIFT_CAPACITY_EXPANSION'
        WHEN MODE() WITHIN GROUP (ORDER BY elasticity_regime) = 'CONSTANT_PROPORTIONAL_RETURNS'
        THEN 'MAINTAIN_CURRENT_LP_ALLOCATION'
        WHEN MODE() WITHIN GROUP (ORDER BY elasticity_regime) = 'INELASTIC_SATURATING_RETURNS'
        THEN 'CAP_LABOR_HOURS_TO_PREVENT_OVERSPEND'
        ELSE 'RE-ARCHITECT_CLUSTER_SLA_TERMS'
    END AS strategic_capacity_action
FROM dual_shadow_price_estimation
GROUP BY
    service_cluster,
    severity
ORDER BY
    avg_shadow_price_10h_usd DESC,
    blended_marginal_mitigation_usd_per_hour DESC;
