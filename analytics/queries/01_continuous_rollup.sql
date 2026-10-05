-- ==============================================================================
-- 01_continuous_rollup.sql
-- FinOps & Strategic Consulting Practice - Continuous Rollup Materialized View & Window Aggregations
--
-- Objective:
--   Computes rolling 7-day moving averages, p95 breach probabilities, and SLA
--   exposure quadrants across Service Clusters and Severities.
-- Dialect: PostgreSQL 14+ / 16 (Window Functions, Window Framing, CTEs)
-- ==============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_incident_hazard_daily_summary AS
WITH daily_cluster_metrics AS (
    -- 1. Daily Aggregations by Cluster and Severity
    SELECT
        DATE_TRUNC('day', event_timestamp)::DATE AS rollup_date,
        service_cluster,
        severity,
        COUNT(telemetry_id) AS total_incidents,
        SUM(expected_penalty_usd) AS daily_penalty_exposure_usd,
        AVG(expected_penalty_usd) AS avg_penalty_exposure_usd,
        AVG(instantaneous_hazard_rate) AS mean_hazard_rate,
        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY conditional_breach_prob) AS p95_breach_prob,
        AVG(remaining_sla_hours) AS mean_remaining_sla_hours,
        SUM(estimated_work_hours) AS total_work_hours_demand
    FROM service_incident_telemetry
    GROUP BY
        DATE_TRUNC('day', event_timestamp)::DATE,
        service_cluster,
        severity
),

rolling_window_derivatives AS (
    -- 2. Rolling 7-Day Window Moving Averages and Trends
    SELECT
        rollup_date,
        service_cluster,
        severity,
        total_incidents,
        daily_penalty_exposure_usd,
        avg_penalty_exposure_usd,
        mean_hazard_rate,
        p95_breach_prob,
        mean_remaining_sla_hours,
        total_work_hours_demand,
        -- 7-Day Rolling Moving Average of Penalty Exposure
        AVG(daily_penalty_exposure_usd) OVER w_rolling_7d AS rolling_7d_avg_exposure_usd,
        -- 7-Day Moving Sum of Total Incidents
        SUM(total_incidents) OVER w_rolling_7d AS rolling_7d_incident_volume,
        -- Previous Day Penalty Exposure for Trend Velocity
        LAG(daily_penalty_exposure_usd, 1) OVER (
            PARTITION BY service_cluster, severity
            ORDER BY rollup_date ASC
        ) AS prev_day_exposure_usd
    FROM daily_cluster_metrics
    WINDOW w_rolling_7d AS (
        PARTITION BY service_cluster, severity
        ORDER BY rollup_date ASC
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    )
)

-- 3. Risk Quadrant Classification & Executive Metric Presentation
SELECT
    rollup_date,
    service_cluster,
    severity,
    total_incidents,
    ROUND(daily_penalty_exposure_usd, 2) AS daily_penalty_exposure_usd,
    ROUND(rolling_7d_avg_exposure_usd, 2) AS rolling_7d_avg_exposure_usd,
    ROUND(mean_hazard_rate, 4) AS mean_hazard_rate,
    ROUND(p95_breach_prob::NUMERIC, 4) AS p95_breach_prob,
    ROUND(mean_remaining_sla_hours, 2) AS mean_remaining_sla_hours,
    ROUND(total_work_hours_demand, 1) AS total_work_hours_demand,
    -- Daily Exposure Velocity Quotient: (Today - Yesterday) / Yesterday
    CASE
        WHEN prev_day_exposure_usd > 0
        THEN ROUND(((daily_penalty_exposure_usd - prev_day_exposure_usd) / prev_day_exposure_usd) * 100.0, 2)
        ELSE 0.00
    END AS exposure_growth_rate_pct,
    -- Strategic Risk Quadrant Tagging
    CASE
        WHEN p95_breach_prob >= 0.70 AND rolling_7d_avg_exposure_usd >= 50000.0
        THEN 'CRITICAL_HAZARD_MASSIVE_LIABILITY'
        WHEN p95_breach_prob >= 0.70 AND rolling_7d_avg_exposure_usd < 50000.0
        THEN 'HIGH_HAZARD_CONTAINED_LIABILITY'
        WHEN p95_breach_prob < 0.70 AND rolling_7d_avg_exposure_usd >= 50000.0
        THEN 'MODERATE_HAZARD_HIGH_CAPITAL_EXPOSURE'
        ELSE 'STABLE_OPERATIONAL_CORRIDOR'
    END AS risk_quadrant_tag
FROM rolling_window_derivatives;

-- Unique composite index for fast concurrent refresh
CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_incident_hazard_rollup
    ON mv_incident_hazard_daily_summary (rollup_date, service_cluster, severity);