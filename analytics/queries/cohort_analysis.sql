-- ==============================================================================
-- cohort_analysis.sql
-- Servicelab AI - Enterprise Client SLA Cohort Retention & Breach Analysis
--
-- Objective:
--   Evaluates client contract cohorts grouped by initial incident onboarding month.
--   Tracks longitudinal SLA breach rates, penalty exposure dynamics, and contract
--   stability across quarterly operational periods.
-- Dialect: PostgreSQL 14+ / 16 (Window Functions: NTILE, LAG, LEAD, FIRST_VALUE)
-- ==============================================================================

WITH client_first_onboarding AS (
    -- 1. Determine Initial Onboarding Month for Each Enterprise Client
    SELECT
        client_tier,
        DATE_TRUNC('month', MIN(event_timestamp))::DATE AS cohort_month
    FROM service_incident_telemetry
    GROUP BY client_tier
),

client_monthly_activity AS (
    -- 2. Aggregate Monthly Financial Exposure and Incident Volume per Cohort
    SELECT
        t.client_tier,
        c.cohort_month,
        DATE_TRUNC('month', t.event_timestamp)::DATE AS activity_month,
        COUNT(t.telemetry_id) AS total_monthly_incidents,
        SUM(CASE WHEN t.conditional_breach_prob >= 0.50 THEN 1 ELSE 0 END) AS high_risk_incidents,
        SUM(t.expected_penalty_usd) AS monthly_penalty_exposure_usd,
        AVG(t.conditional_breach_prob) AS avg_breach_probability,
        AVG(t.client_arr_usd) AS cohort_avg_arr_usd
    FROM service_incident_telemetry t
    JOIN client_first_onboarding c
        ON t.client_tier = c.client_tier
    GROUP BY
        t.client_tier,
        c.cohort_month,
        DATE_TRUNC('month', t.event_timestamp)::DATE
),

cohort_period_indexing AS (
    -- 3. Calculate Normalized Operational Period (Months Since Initial Ingestion)
    SELECT
        client_tier,
        cohort_month,
        activity_month,
        (EXTRACT(YEAR FROM activity_month) - EXTRACT(YEAR FROM cohort_month)) * 12 +
        (EXTRACT(MONTH FROM activity_month) - EXTRACT(MONTH FROM cohort_month)) AS period_index,
        total_monthly_incidents,
        high_risk_incidents,
        monthly_penalty_exposure_usd,
        avg_breach_probability,
        cohort_avg_arr_usd,
        -- Initial Baseline Exposure (Period 0) via FIRST_VALUE Window Function
        FIRST_VALUE(monthly_penalty_exposure_usd) OVER (
            PARTITION BY client_tier
            ORDER BY activity_month ASC
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS baseline_period_exposure_usd,
        -- Previous Period Exposure for Sequential Delta Calculation
        LAG(monthly_penalty_exposure_usd, 1) OVER (
            PARTITION BY client_tier
            ORDER BY activity_month ASC
        ) AS prev_period_exposure_usd,
        -- Subsequent Period Exposure for Predictive Trending
        LEAD(monthly_penalty_exposure_usd, 1) OVER (
            PARTITION BY client_tier
            ORDER BY activity_month ASC
        ) AS next_period_exposure_usd,
        -- Exposure Quartile Distribution within the Entire Cohort Lifecycle
        NTILE(4) OVER (
            PARTITION BY client_tier
            ORDER BY monthly_penalty_exposure_usd ASC
        ) AS exposure_quartile
    FROM client_monthly_activity
)

-- 4. Final Cohort Retention & SLA Degradation Synthesis
SELECT
    client_tier,
    cohort_month,
    activity_month,
    period_index,
    total_monthly_incidents,
    high_risk_incidents,
    ROUND(monthly_penalty_exposure_usd, 2) AS monthly_penalty_exposure_usd,
    ROUND(avg_breach_probability::NUMERIC, 4) AS avg_breach_probability,
    ROUND(cohort_avg_arr_usd, 2) AS cohort_avg_arr_usd,
    exposure_quartile,
    -- Retention Index: Current Exposure vs Baseline Exposure (Normalized Delta)
    ROUND(
        (monthly_penalty_exposure_usd / NULLIF(baseline_period_exposure_usd, 0)) * 100.0,
        2
    ) AS exposure_retention_index_pct,
    -- Period-over-Period Exposure Velocity
    CASE
        WHEN prev_period_exposure_usd > 0
        THEN ROUND(((monthly_penalty_exposure_usd - prev_period_exposure_usd) / prev_period_exposure_usd) * 100.0, 2)
        ELSE 0.00
    END AS period_over_period_delta_pct,
    -- Longitudinal Cohort SLA Stability Status
    CASE
        WHEN (monthly_penalty_exposure_usd / NULLIF(baseline_period_exposure_usd, 0)) <= 0.70
        THEN 'SLA_SIGNIFICANT_IMPROVEMENT'
        WHEN (monthly_penalty_exposure_usd / NULLIF(baseline_period_exposure_usd, 0)) BETWEEN 0.71 AND 1.15
        THEN 'SLA_STABLE_PERFORMANCE'
        WHEN (monthly_penalty_exposure_usd / NULLIF(baseline_period_exposure_usd, 0)) > 1.15
        THEN 'SLA_DEGRADING_EXPOSURE_RISK'
        ELSE 'BASELINE_PERIOD'
    END AS cohort_stability_tier
FROM cohort_period_indexing
ORDER BY
    client_tier,
    period_index ASC;