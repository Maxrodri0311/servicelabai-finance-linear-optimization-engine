-- ==============================================================================
-- 03_weibull_survival_hazard_distribution.sql
-- FinOps & Strategic Consulting Practice - Parametric Weibull Survival & Actuarial Life Tables
--
-- Objective:
--   Constructs empirical and parametric survival curves S(t), Nelson-Aalen
--   cumulative hazard functions H(t), and Kaplan-Meier product-limit estimators
--   across Service Clusters and Severities to inform Linear Optimization weights.
-- Dialect: PostgreSQL 14+ / 16 (Window Aggregations, Mathematical Functions, CTEs)
-- ==============================================================================

WITH interval_binned_incidents AS (
    -- 1. Discretize Incident Lifetime into 1-Hour Operational Intervals
    SELECT
        service_cluster,
        severity,
        FLOOR(elapsed_hours) AS lifetime_hour_bucket,
        COUNT(telemetry_id) AS total_at_risk,
        SUM(CASE WHEN conditional_breach_prob >= 0.90 THEN 1 ELSE 0 END) AS breach_events_observed,
        AVG(weibull_shape_k) AS avg_weibull_k,
        AVG(weibull_scale_lambda) AS avg_weibull_lambda,
        SUM(expected_penalty_usd) AS bucket_penalty_exposure_usd
    FROM service_incident_telemetry
    GROUP BY
        service_cluster,
        severity,
        FLOOR(elapsed_hours)
),

actuarial_life_table AS (
    -- 2. Compute Kaplan-Meier Survival Probabilities & Nelson-Aalen Hazard
    SELECT
        service_cluster,
        severity,
        lifetime_hour_bucket,
        total_at_risk,
        breach_events_observed,
        avg_weibull_k,
        avg_weibull_lambda,
        bucket_penalty_exposure_usd,
        -- Interval Conditional Hazard Rate: q_t = d_t / n_t
        ROUND(
            breach_events_observed::NUMERIC / NULLIF(total_at_risk, 0),
            4
        ) AS interval_hazard_rate,
        -- Interval Survival Probability: p_t = 1 - q_t
        ROUND(
            1.0 - (breach_events_observed::NUMERIC / NULLIF(total_at_risk, 0)),
            4
        ) AS interval_survival_prob,
        -- Nelson-Aalen Cumulative Hazard Contribution: sum(d_t / n_t)
        SUM(
            breach_events_observed::NUMERIC / NULLIF(total_at_risk, 0)
        ) OVER (
            PARTITION BY service_cluster, severity
            ORDER BY lifetime_hour_bucket ASC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS nelson_aalen_cum_hazard
    FROM interval_binned_incidents
),

parametric_weibull_comparison AS (
    -- 3. Calculate Analytical Closed-Form Weibull Survival and Hazard Functions
    SELECT
        service_cluster,
        severity,
        lifetime_hour_bucket,
        total_at_risk,
        breach_events_observed,
        interval_hazard_rate,
        nelson_aalen_cum_hazard,
        bucket_penalty_exposure_usd,
        -- Theoretical Weibull Survival Function: S(t) = exp(-(t / lambda)^k)
        ROUND(
            EXP(
                -POWER(
                    NULLIF(lifetime_hour_bucket, 0) / NULLIF(avg_weibull_lambda, 0),
                    avg_weibull_k
                )
            )::NUMERIC,
            4
        ) AS theoretical_weibull_survival_prob,
        -- Theoretical Instantaneous Hazard Rate: h(t) = (k / lambda) * (t / lambda)^(k - 1)
        ROUND(
            (
                (avg_weibull_k / NULLIF(avg_weibull_lambda, 0)) *
                POWER(
                    NULLIF(lifetime_hour_bucket, 0) / NULLIF(avg_weibull_lambda, 0),
                    avg_weibull_k - 1.0
                )
            )::NUMERIC,
            4
        ) AS theoretical_hazard_rate
    FROM actuarial_life_table
)

-- 4. Final Actuarial Curve and Linear Optimization Weight Synthesis
SELECT
    service_cluster,
    severity,
    lifetime_hour_bucket,
    total_at_risk,
    breach_events_observed,
    interval_hazard_rate,
    ROUND(nelson_aalen_cum_hazard, 4) AS nelson_aalen_cum_hazard,
    COALESCE(theoretical_weibull_survival_prob, 1.0000) AS theoretical_weibull_survival_prob,
    COALESCE(theoretical_hazard_rate, 0.0000) AS theoretical_hazard_rate,
    ROUND(bucket_penalty_exposure_usd, 2) AS bucket_penalty_exposure_usd,
    -- Urgency Priority Weight for LP Solver
    CASE
        WHEN COALESCE(theoretical_hazard_rate, 0) >= 0.50 OR interval_hazard_rate >= 0.40
        THEN 'TIER_1_EXPEDITED_DISPATCH'
        WHEN COALESCE(theoretical_hazard_rate, 0) BETWEEN 0.20 AND 0.49
        THEN 'TIER_2_SCHEDULED_CONTAINMENT'
        ELSE 'TIER_3_ROUTINE_MONITORING'
    END AS lp_triage_urgency_tier
FROM parametric_weibull_comparison
ORDER BY
    service_cluster,
    severity,
    lifetime_hour_bucket ASC;
