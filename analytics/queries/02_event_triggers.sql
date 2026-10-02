-- ==============================================================================
-- 02_event_triggers.sql
-- Servicelab AI - Event-Driven Telemetry Trigger & Anomaly Audit Engine
--
-- Objective:
--   Automated database trigger that intercepts inserts on service_incident_telemetry
--   and captures critical SLA breach hazards or severe liability surges into the
--   isolated audit log (sla_breach_anomaly_audit_log).
-- Dialect: PL/pgSQL / PostgreSQL 16
-- ==============================================================================

CREATE OR REPLACE FUNCTION fn_detect_sla_breach_surge_and_audit()
RETURNS TRIGGER AS $$
DECLARE
    v_hazard_threshold NUMERIC(10, 4) := 0.7500;
    v_exposure_threshold NUMERIC(14, 2) := 75000.00;
    v_breach_prob_threshold NUMERIC(6, 4) := 0.8500;
    v_anomaly_reason VARCHAR(255);
BEGIN
    -- Check if incident exhibits accelerated aging hazard or extreme liability
    IF NEW.severity = 'CRITICAL_P1' AND NEW.conditional_breach_prob >= v_breach_prob_threshold THEN
        v_anomaly_reason := 'CRITICAL_P1_IMMINENT_SLA_BREACH_SURGE';
    ELSIF NEW.expected_penalty_usd >= v_exposure_threshold THEN
        v_anomaly_reason := 'EXTREME_FINANCIAL_LIABILITY_SPIKE';
    ELSIF NEW.instantaneous_hazard_rate >= v_hazard_threshold AND NEW.remaining_sla_hours <= 1.5 THEN
        v_anomaly_reason := 'ACCELERATED_WEIBULL_HAZARD_CLIFF';
    ELSE
        -- No anomaly condition met; proceed without audit insertion
        RETURN NEW;
    END IF;

    -- Insert anomaly record into the dedicated audit log
    INSERT INTO sla_breach_anomaly_audit_log (
        incident_id,
        service_cluster,
        severity,
        client_tier,
        instantaneous_hazard_rate,
        conditional_breach_prob,
        expected_penalty_usd,
        anomaly_reason,
        detected_at
    ) VALUES (
        NEW.incident_id,
        NEW.service_cluster,
        NEW.severity,
        NEW.client_tier,
        NEW.instantaneous_hazard_rate,
        NEW.conditional_breach_prob,
        NEW.expected_penalty_usd,
        v_anomaly_reason,
        CURRENT_TIMESTAMP
    );

    RETURN NEW;
EXCEPTION
    WHEN OTHERS THEN
        -- Zero-blocking design: never abort ingestion if audit logging encounters a fault
        RAISE WARNING '[SLA Trigger] Failed to log anomaly audit for incident %: %', NEW.incident_id, SQLERRM;
        RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Bind trigger to telemetry table (fires on each row insertion)
DROP TRIGGER IF EXISTS trg_audit_sla_breach_anomaly ON service_incident_telemetry;
CREATE TRIGGER trg_audit_sla_breach_anomaly
    AFTER INSERT ON service_incident_telemetry
    FOR EACH ROW
    EXECUTE FUNCTION fn_detect_sla_breach_surge_and_audit();