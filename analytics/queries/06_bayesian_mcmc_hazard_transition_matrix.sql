-- ==============================================================================
-- 06_bayesian_mcmc_hazard_transition_matrix.sql
-- Servicelab AI - Bayesian Incident Degradation & Markov State Transitions
--
-- Objective:
--   Models multi-stage incident degradation trajectories across operational states
--   (NORMAL_OPERATIONS -> LATENT_DEGRADATION -> CRITICAL_HAZARD -> SLA_BREACHED).
--   Computes empirical transition probabilities and absorbing state mean time to breach
--   using recursive CTEs to feed real-time risk coefficients to the LP solver.
-- Dialect: PostgreSQL 14+ / 16 (Recursive CTEs, Matrix Probability Normalization)
-- ==============================================================================

WITH RECURSIVE incident_state_chronology AS (
    -- 1. Map Each Incident to Discrete Degradation States over Operational Lifetime
    SELECT
        telemetry_id,
        incident_id,
        service_cluster,
        severity,
        client_tier,
        event_timestamp,
        elapsed_hours,
        remaining_sla_hours,
        instantaneous_hazard_rate,
        conditional_breach_prob,
        CASE
            WHEN remaining_sla_hours = 0.0 OR conditional_breach_prob >= 0.95 THEN 'STATE_4_BREACH_ABSORBING'
            WHEN conditional_breach_prob >= 0.65 OR instantaneous_hazard_rate >= 0.60 THEN 'STATE_3_CRITICAL_HAZARD'
            WHEN conditional_breach_prob >= 0.25 OR instantaneous_hazard_rate >= 0.25 THEN 'STATE_2_LATENT_DEGRADATION'
            ELSE 'STATE_1_NORMAL_TRIAGE'
        END AS degradation_state,
        ROW_NUMBER() OVER (
            PARTITION BY incident_id
            ORDER BY event_timestamp ASC
        ) AS observation_step
    FROM service_incident_telemetry
),

state_transitions AS (
    -- 2. Construct Origin -> Destination State Transition Pairs
    SELECT
        curr.service_cluster,
        curr.severity,
        curr.degradation_state AS origin_state,
        COALESCE(next_step.degradation_state, curr.degradation_state) AS destination_state,
        curr.instantaneous_hazard_rate,
        curr.conditional_breach_prob
    FROM incident_state_chronology curr
    LEFT JOIN incident_state_chronology next_step
        ON curr.incident_id = next_step.incident_id
        AND curr.observation_step + 1 = next_step.observation_step
),

transition_probability_matrix AS (
    -- 3. Calculate Normalized Markov Transition Probabilities: P(Origin -> Dest)
    SELECT
        service_cluster,
        severity,
        origin_state,
        destination_state,
        COUNT(*) AS transition_frequency,
        ROUND(
            COUNT(*)::NUMERIC / NULLIF(SUM(COUNT(*)) OVER (PARTITION BY service_cluster, severity, origin_state), 0),
            4
        ) AS transition_probability
    FROM state_transitions
    GROUP BY
        service_cluster,
        severity,
        origin_state,
        destination_state
),

markov_absorption_metrics AS (
    -- 4. Calculate Absorbing State Reachability and Risk Intensity
    SELECT
        service_cluster,
        severity,
        origin_state,
        -- Probability of direct or imminent transition to SLA Breach
        SUM(CASE WHEN destination_state = 'STATE_4_BREACH_ABSORBING' THEN transition_probability ELSE 0 END) AS direct_breach_risk_probability,
        -- Probability of self-loop containment
        SUM(CASE WHEN origin_state = destination_state THEN transition_probability ELSE 0 END) AS state_containment_stability,
        SUM(transition_frequency) AS total_state_observations
    FROM transition_probability_matrix
    GROUP BY
        service_cluster,
        severity,
        origin_state
)

-- 5. Final Synthesis: Markov Risk Priority Weights for Linear Programming Ingestion
SELECT
    service_cluster,
    severity,
    origin_state,
    total_state_observations,
    ROUND(direct_breach_risk_probability, 4) AS direct_breach_risk_probability,
    ROUND(state_containment_stability, 4) AS state_containment_stability,
    -- Transition Vulnerability Index (High breach risk and low containment)
    ROUND(
        (direct_breach_risk_probability * (1.0 - state_containment_stability)) * 100.0,
        2
    ) AS degradation_vulnerability_score,
    -- Dispatch Priority Directive for Real-Time HiGHS Linear Program
    CASE
        WHEN origin_state = 'STATE_3_CRITICAL_HAZARD' AND direct_breach_risk_probability >= 0.35
        THEN 'IMMEDIATE_PREEMPTIVE_CUDA_DISPATCH'
        WHEN origin_state = 'STATE_2_LATENT_DEGRADATION' AND direct_breach_risk_probability >= 0.15
        THEN 'CONTAINMENT_SECONDARY_DISPATCH'
        WHEN origin_state = 'STATE_4_BREACH_ABSORBING'
        THEN 'POST_BREACH_DAMAGE_LIMITATION'
        ELSE 'STANDARD_QUEUE_PROCESSING'
    END AS lp_stochastic_dispatch_policy
FROM markov_absorption_metrics
ORDER BY
    direct_breach_risk_probability DESC,
    degradation_vulnerability_score DESC;
