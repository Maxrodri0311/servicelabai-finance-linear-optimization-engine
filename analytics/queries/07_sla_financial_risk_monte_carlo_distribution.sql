-- ==============================================================================
-- 07_sla_financial_risk_monte_carlo_distribution.sql
-- FinOps & Strategic Consulting Practice - Financial Risk Exposure Distribution & Value at Risk (VaR)
--
-- Objective:
--   Evaluates tail-risk distributions of contractual SLA financial penalties.
--   Computes Parametric Value at Risk (VaR 95%, VaR 99%) and Conditional Value at
--   Risk (CVaR / Expected Shortfall) across Enterprise Client Tiers to set the
--   maximum operational budget ceiling (B_max) in the Linear Program.
-- Dialect: PostgreSQL 14+ / 16 (Percentile Cont, Window Filtering, Tail Integrals)
-- ==============================================================================

WITH active_portfolio_exposures AS (
    -- 1. Base Financial Risk Exposures across Active Triage Cohorts
    SELECT
        client_tier,
        service_cluster,
        severity,
        incident_id,
        expected_penalty_usd,
        conditional_breach_prob,
        hourly_penalty_usd,
        max_penalty_cap_usd,
        client_arr_usd
    FROM service_incident_telemetry
    WHERE is_active_triage = TRUE
),

tier_percentile_benchmarks AS (
    -- 2. Parametric & Empirical Quantile Approximations (p50, p90, p95, p99)
    SELECT
        client_tier,
        service_cluster,
        COUNT(incident_id) AS active_incidents_count,
        SUM(expected_penalty_usd) AS aggregate_gross_risk_usd,
        AVG(expected_penalty_usd) AS mean_incident_penalty_usd,
        STDDEV(expected_penalty_usd) AS stddev_incident_penalty_usd,
        -- Value at Risk (VaR) at 90th, 95th, and 99th Confidence Levels
        PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY expected_penalty_usd) AS median_var_50_usd,
        PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY expected_penalty_usd) AS var_90_usd,
        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY expected_penalty_usd) AS var_95_usd,
        PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY expected_penalty_usd) AS var_99_usd
    FROM active_portfolio_exposures
    GROUP BY
        client_tier,
        service_cluster
),

conditional_tail_shortfall AS (
    -- 3. Compute Expected Shortfall (CVaR 95% and CVaR 99%)
    -- Average financial loss given that loss exceeds the respective VaR threshold
    SELECT
        p.client_tier,
        p.service_cluster,
        -- Conditional Value at Risk 95%
        AVG(CASE WHEN e.expected_penalty_usd >= p.var_95_usd THEN e.expected_penalty_usd END) AS cvar_95_expected_shortfall_usd,
        -- Conditional Value at Risk 99%
        AVG(CASE WHEN e.expected_penalty_usd >= p.var_99_usd THEN e.expected_penalty_usd END) AS cvar_99_expected_shortfall_usd
    FROM active_portfolio_exposures e
    JOIN tier_percentile_benchmarks p
        ON e.client_tier = p.client_tier
        AND e.service_cluster = p.service_cluster
    GROUP BY
        p.client_tier,
        p.service_cluster
)

-- 4. Final Executive Capital Adequacy & Linear Programming Budget Ceiling Recommendation
SELECT
    b.client_tier,
    b.service_cluster,
    b.active_incidents_count,
    ROUND(b.aggregate_gross_risk_usd, 2) AS aggregate_gross_risk_usd,
    ROUND(b.mean_incident_penalty_usd, 2) AS mean_incident_penalty_usd,
    ROUND(b.var_95_usd::NUMERIC, 2) AS var_95_incident_exposure_usd,
    ROUND(b.var_99_usd::NUMERIC, 2) AS var_99_incident_exposure_usd,
    ROUND(COALESCE(c.cvar_95_expected_shortfall_usd, b.var_95_usd)::NUMERIC, 2) AS cvar_95_tail_risk_usd,
    ROUND(COALESCE(c.cvar_99_expected_shortfall_usd, b.var_99_usd)::NUMERIC, 2) AS cvar_99_tail_risk_usd,
    -- Recommended LP Budget Buffer (Ensures 95% of Tail Risk Penalties can be Mitigated)
    ROUND(
        (b.active_incidents_count * b.mean_incident_penalty_usd * 0.15)::NUMERIC,
        2
    ) AS recommended_lp_budget_buffer_usd,
    -- Strategic SLA Exposure Class
    CASE
        WHEN b.var_95_usd >= 25000.0 THEN 'EXTREME_TAIL_EXPOSURE_TIER'
        WHEN b.var_95_usd BETWEEN 10000.0 AND 24999.0 THEN 'ELEVATED_FINANCIAL_VOLATILITY'
        ELSE 'STANDARD_CONTROLLED_EXPOSURE'
    END AS capital_exposure_risk_tier
FROM tier_percentile_benchmarks b
LEFT JOIN conditional_tail_shortfall c
    ON b.client_tier = c.client_tier
    AND b.service_cluster = c.service_cluster
ORDER BY
    aggregate_gross_risk_usd DESC,
    var_95_incident_exposure_usd DESC;
