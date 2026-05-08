// Audit Service Client for FHIR Notification Broker
// =================================================
// Integrates with FHIR Audit Service for ITI-20 ATNA compliance

import ballerina/http;
import ballerina/log;
import ballerina/time;
import ballerina/uuid;
import ballerinax/health.fhir.r4;
import ballerinax/health.fhir.r4.international401;

// ============================================================
// CONFIGURATION
// ============================================================

// Audit service URL
configurable string auditServiceUrl = "http://localhost:9098";
configurable boolean auditEnabled = true;
configurable string sourceObserverName = "fhir-notification-broker";

// HTTP client for audit service
final http:Client auditClient = check new (auditServiceUrl);

// ============================================================
// AUDIT HELPER FUNCTIONS
// ============================================================

# Send audit event to the audit service
#
# + auditEvent - The audit event to send
isolated function sendAuditEvent(international401:AuditEvent auditEvent) {
    if !auditEnabled {
        return;
    }

    do {
        string auditId = auditEvent.id is string ? <string>auditEvent.id : "";
        log:printInfo(string `[AUDIT] Sending audit event: ${auditId}`);

        // Convert to JSON explicitly to avoid FHIR record serialization issues
        json auditJson = auditEvent.toJson();
        http:Request req = new;
        req.setJsonPayload(auditJson);
        req.setHeader("Content-Type", "application/json");

        http:Response|http:ClientError response = auditClient->post("/audits", req);
        if response is http:ClientError {
            log:printWarn(string `[AUDIT] Failed to send audit event: ${response.message()}`, auditId = auditId);
        } else if response.statusCode >= 400 {
            string|error body = response.getTextPayload();
            string bodyStr = body is string ? body : "unknown";
            log:printWarn(string `[AUDIT] Audit service returned ${response.statusCode}: ${bodyStr}`, auditId = auditId);
        } else {
            log:printInfo(string `[AUDIT] Audit event sent successfully: ${auditId} (status: ${response.statusCode})`);
        }
    } on fail error e {
        // Log but don't fail the main operation
        log:printWarn(string `[AUDIT] Exception sending audit event: ${e.message()}`);
    }
}

# Get current timestamp in ISO format
# + return - Current time as ISO 8601 string
isolated function getCurrentTimestamp() returns string {
    return time:utcToString(time:utcNow());
}

isolated function auditGetCoding(string system, string code) returns r4:Coding => {
    system: system,
    code: code
};

isolated function auditGetAgent(string agentName) returns international401:AuditEventAgent {
    return {
        'type: {
            coding: [auditGetCoding("http://terminology.hl7.org/CodeSystem/extra-security-role-type", "humanuser")]
        },
        who: {
            display: agentName
        },
        requestor: true
    };
}

isolated function auditGetEntity(string entityType, string entityRole, string entityWhatReference)
        returns international401:AuditEventEntity {
    return {
        'type: auditGetCoding("http://terminology.hl7.org/CodeSystem/audit-entity-type", entityType),
        role: auditGetCoding("http://terminology.hl7.org/CodeSystem/object-role", entityRole),
        what: {
            reference: entityWhatReference
        }
    };
}

isolated function buildAuditEvent(string subTypeCode, string actionCode, boolean success, string outcomeDesc,
        string agentName, international401:AuditEventEntity[] entities) returns international401:AuditEvent => {
    resourceType: "AuditEvent",
    id: uuid:createType1AsString(),
    'type: auditGetCoding("http://terminology.hl7.org/CodeSystem/audit-event-type", "rest"),
    subtype: [auditGetCoding("http://hl7.org/fhir/restful-interaction", subTypeCode)],
    action: actionCode,
    outcome: success ? "0" : "4",
    outcomeDesc: outcomeDesc != "" ? outcomeDesc : (),
    recorded: getCurrentTimestamp(),
    agent: [auditGetAgent(agentName)],
    entity: entities,
    'source: {
        observer: {
            display: sourceObserverName
        },
        'type: [auditGetCoding("http://terminology.hl7.org/CodeSystem/security-source-type", "4")]
    }
};

// ============================================================
// AUDIT EVENT BUILDERS
// ============================================================

# Create audit event for token issuance (SMART on FHIR or token exchange)
#
# + clientId - The client ID requesting the token
# + success - Whether the operation succeeded
# + reason - Optional failure reason
# + return - Configured audit event
public isolated function auditTokenIssueEvent(string clientId, boolean success, string reason = "")
        returns international401:AuditEvent {
    string outcomeDesc = reason != "" ? reason : (success ? "Token issued successfully" : "");
    return buildAuditEvent("operation", "E", success, outcomeDesc, clientId, [
        auditGetEntity("2", "24", string `Token/${clientId}`)
    ]);
}

# Create audit event for token validation failure
#
# + clientId - The client ID that failed validation
# + reason - Failure reason
# + return - Configured audit event
public isolated function auditTokenValidationFailureEvent(string clientId, string reason)
        returns international401:AuditEvent {
    return buildAuditEvent("operation", "E", false, reason, clientId, [
        auditGetEntity("2", "24", string `Token/${clientId}`)
    ]);
}

# Create audit event for notification received
#
# + sourceSystem - The source system sending the notification
# + patientCount - Number of patients in the notification
# + success - Whether the operation succeeded
# + reason - Optional failure reason
# + return - Configured audit event
public isolated function auditNotificationReceivedEvent(string sourceSystem, int patientCount, boolean success,
        string reason = "") returns international401:AuditEvent {
    string outcomeDesc = reason != "" ? reason : (success ? string `Notification received with ${patientCount} patient(s)` : "");
    return buildAuditEvent("create", "C", success, outcomeDesc, sourceSystem, [
        auditGetEntity("2", "20", "Bundle/notification")
    ]);
}

# Create audit event for notification routed to a client
#
# + clientId - The client receiving the notification
# + patientId - The broker-scoped patient ID
# + resourceType - The type of clinical resource routed
# + success - Whether the operation succeeded
# + reason - Optional failure reason
# + return - Configured audit event
public isolated function auditNotificationRoutedEvent(string clientId, string patientId, string resourceType,
        boolean success, string reason = "") returns international401:AuditEvent {
    string outcomeDesc = reason != "" ? reason : (success ? string `${resourceType} routed for Patient/${patientId}` : "");
    return buildAuditEvent("read", "R", success, outcomeDesc, clientId, [
        auditGetEntity("1", "1", string `Patient/${patientId}`),
        auditGetEntity("2", "4", string `${resourceType}/notification`)
    ]);
}

# Create audit event for patient resolution via MPI
#
# + patientRef - The patient reference being resolved
# + method - Resolution method (direct, demographics, register)
# + success - Whether the operation succeeded
# + reason - Optional failure reason
# + return - Configured audit event
public isolated function auditPatientResolutionEvent(string patientRef, string method, boolean success,
        string reason = "") returns international401:AuditEvent {
    string outcomeDesc = reason != "" ? reason : (success ? string `Patient resolved via ${method}` : "");
    return buildAuditEvent("operation", "E", success, outcomeDesc, "mpi-client", [
        auditGetEntity("1", "1", string `Patient/${patientRef}`)
    ]);
}

# Create audit event for subscription creation
#
# + clientId - The client creating the subscription
# + patientId - The broker-scoped patient ID
# + success - Whether the operation succeeded
# + reason - Optional failure reason
# + return - Configured audit event
public isolated function auditSubscriptionCreatedEvent(string clientId, string patientId, boolean success,
        string reason = "") returns international401:AuditEvent {
    string outcomeDesc = reason != "" ? reason : (success ? string `Subscription created for Patient/${patientId}` : "");
    return buildAuditEvent("create", "C", success, outcomeDesc, clientId, [
        auditGetEntity("2", "4", string `Subscription/${clientId}`),
        auditGetEntity("1", "1", string `Patient/${patientId}`)
    ]);
}

# Create audit event for subscription deletion
#
# + clientId - The client whose subscription is being deleted
# + success - Whether the operation succeeded
# + reason - Optional failure reason
# + return - Configured audit event
public isolated function auditSubscriptionDeletedEvent(string clientId, boolean success, string reason = "")
        returns international401:AuditEvent {
    string outcomeDesc = reason != "" ? reason : (success ? "Subscription deleted" : "");
    return buildAuditEvent("delete", "D", success, outcomeDesc, clientId, [
        auditGetEntity("2", "4", string `Subscription/${clientId}`)
    ]);
}

# Create audit event for FHIR resource data access
#
# + clientId - The client accessing data
# + resourceRef - The resource reference being accessed
# + success - Whether the operation succeeded
# + reason - Optional failure reason
# + return - Configured audit event
public isolated function auditDataAccessEvent(string clientId, string resourceRef, boolean success,
        string reason = "") returns international401:AuditEvent {
    string outcomeDesc = reason != "" ? reason : (success ? string `Accessed ${resourceRef}` : "");
    return buildAuditEvent("read", "R", success, outcomeDesc, clientId, [
        auditGetEntity("2", "4", resourceRef)
    ]);
}

# Create audit event for dynamic client registration
#
# + clientName - The name of the client being registered
# + success - Whether the operation succeeded
# + reason - Optional failure reason
# + return - Configured audit event
public isolated function auditClientRegisteredEvent(string clientName, boolean success, string reason = "")
        returns international401:AuditEvent {
    string outcomeDesc = reason != "" ? reason : (success ? string `Client ${clientName} registered` : "");
    return buildAuditEvent("create", "C", success, outcomeDesc, clientName, [
        auditGetEntity("2", "4", string `ClientRegistry/${clientName}`)
    ]);
}

# Create audit event for client deletion
#
# + clientName - The name of the client being deleted
# + success - Whether the operation succeeded
# + reason - Optional failure reason
# + return - Configured audit event
public isolated function auditClientDeletedEvent(string clientName, boolean success, string reason = "")
        returns international401:AuditEvent {
    string outcomeDesc = reason != "" ? reason : (success ? string `Client ${clientName} deleted` : "");
    return buildAuditEvent("delete", "D", success, outcomeDesc, clientName, [
        auditGetEntity("2", "4", string `ClientRegistry/${clientName}`)
    ]);
}

# Create audit event for WebSub hub operations (register, subscribe, publish)
#
# + operation - The WebSub operation (topic-register, topic-subscribe, topic-publish)
# + topicId - The topic ID involved
# + success - Whether the operation succeeded
# + reason - Optional failure reason
# + return - Configured audit event
public isolated function auditWebSubOperationEvent(string operation, string topicId, boolean success,
        string reason = "") returns international401:AuditEvent {
    string outcomeDesc = reason != "" ? reason : (success ? string `WebSub ${operation} for topic ${topicId}` : "");
    return buildAuditEvent("operation", "E", success, outcomeDesc, "websub-hub", [
        auditGetEntity("2", "4", string `WebSub/${operation}/${topicId}`)
    ]);
}

# Create audit event for FHIR server operations (patient, group, subscription CRUD)
#
# + operation - The FHIR operation (patient-create, patient-update, group-create, group-add-member, subscription-create, subscription-update)
# + resourceRef - The FHIR resource reference (e.g., Patient/123, Group/abc)
# + success - Whether the operation succeeded
# + reason - Optional failure reason
# + return - Configured audit event
public isolated function auditFhirServerOperationEvent(string operation, string resourceRef, boolean success,
        string reason = "") returns international401:AuditEvent {
    string actionCode = "E";
    string subTypeCode = "operation";
    if operation.startsWith("create") || operation.endsWith("-create") {
        actionCode = "C";
        subTypeCode = "create";
    } else if operation.startsWith("update") || operation.endsWith("-update") || operation.endsWith("-add-member") {
        actionCode = "U";
        subTypeCode = "update";
    }
    string outcomeDesc = reason != "" ? reason : (success ? string `FHIR server ${operation}: ${resourceRef}` : "");
    return buildAuditEvent(subTypeCode, actionCode, success, outcomeDesc, "fhir-server", [
        auditGetEntity("2", "4", resourceRef)
    ]);
}

# Create audit event for patient mapping operations
#
# + operation - The mapping operation (mapping-create, mapping-read, mapping-read-all)
# + resourceRef - The patient/mapping reference
# + success - Whether the operation succeeded
# + reason - Optional failure reason
# + return - Configured audit event
public isolated function auditMappingOperationEvent(string operation, string resourceRef, boolean success,
        string reason = "") returns international401:AuditEvent {
    string actionCode = operation == "mapping-create" ? "C" : "R";
    string subTypeCode = operation == "mapping-create" ? "create" : "read";
    string outcomeDesc = reason != "" ? reason : (success ? string `Mapping ${operation}: ${resourceRef}` : "");
    return buildAuditEvent(subTypeCode, actionCode, success, outcomeDesc, "system", [
        auditGetEntity("1", "1", resourceRef)
    ]);
}

# Create audit event for system/admin operations (JWKS cache, registry list)
#
# + actor - Who performed the operation
# + operation - The system operation
# + success - Whether the operation succeeded
# + reason - Optional failure reason
# + return - Configured audit event
public isolated function auditSystemOperationEvent(string actor, string operation, boolean success,
        string reason = "") returns international401:AuditEvent {
    string outcomeDesc = reason != "" ? reason : (success ? string `System operation: ${operation}` : "");
    return buildAuditEvent("operation", "E", success, outcomeDesc, actor, [
        auditGetEntity("2", "4", string `System/${operation}`)
    ]);
}

// ============================================================
// SUBSCRIPTION TOKEN & AUTHORIZATION AUDIT EVENTS
// ============================================================

# Create audit event for subscription token generation
#
# + clientId - The client ID receiving the token
# + subscriptionId - The subscription ID the token is for
# + success - Whether the operation succeeded
# + reason - Optional failure reason
# + return - Configured audit event
public isolated function auditSubscriptionTokenGeneratedEvent(string clientId, string subscriptionId, boolean success,
        string reason = "") returns international401:AuditEvent {
    string outcomeDesc = reason != "" ? reason : (success ? string `Subscription token generated for ${subscriptionId}` : "");
    return buildAuditEvent("operation", "E", success, outcomeDesc, clientId, [
        auditGetEntity("2", "24", string `SubscriptionToken/${subscriptionId}`),
        auditGetEntity("2", "4", string `Subscription/${clientId}`)
    ]);
}

# Create audit event for authorization decision
#
# + clientId - The client requesting access
# + patientId - The patient ID being accessed
# + authorized - Whether access was granted
# + scope - The authorization scope (PATIENT, PRACTITIONER, PRIVILEGED)
# + reason - Optional reason for the decision
# + return - Configured audit event
public isolated function auditAuthzDecisionEvent(string clientId, string patientId, boolean authorized,
        string? scope = (), string reason = "") returns international401:AuditEvent {
    string scopeStr = scope ?: "none";
    string outcomeDesc = reason != "" ? reason : (authorized
        ? string `Access granted (scope=${scopeStr}) for Patient/${patientId}`
        : string `Access denied for Patient/${patientId}`);
    return buildAuditEvent("operation", "E", authorized, outcomeDesc, clientId, [
        auditGetEntity("1", "1", string `Patient/${patientId}`),
        auditGetEntity("2", "4", string `AuthzDecision/${clientId}`)
    ]);
}

// ============================================================
// CONVENIENCE FUNCTIONS (Fire-and-forget)
// ============================================================

# Audit a token issuance operation (fire-and-forget)
public function auditTokenIssue(string clientId, boolean success, string reason = "") {
    _ = start sendAuditEvent(auditTokenIssueEvent(clientId, success, reason));
}

# Audit a token validation failure (fire-and-forget)
public function auditTokenValidationFailure(string clientId, string reason) {
    _ = start sendAuditEvent(auditTokenValidationFailureEvent(clientId, reason));
}

# Audit a notification received (fire-and-forget)
public function auditNotificationReceived(string sourceSystem, int patientCount, boolean success, string reason = "") {
    _ = start sendAuditEvent(auditNotificationReceivedEvent(sourceSystem, patientCount, success, reason));
}

# Audit a notification routed to client (fire-and-forget)
public function auditNotificationRouted(string clientId, string patientId, string resourceType, boolean success, string reason = "") {
    _ = start sendAuditEvent(auditNotificationRoutedEvent(clientId, patientId, resourceType, success, reason));
}

# Audit a patient resolution via MPI (fire-and-forget)
public function auditPatientResolution(string patientRef, string method, boolean success, string reason = "") {
    _ = start sendAuditEvent(auditPatientResolutionEvent(patientRef, method, success, reason));
}

# Audit a subscription creation (fire-and-forget)
public function auditSubscriptionCreated(string clientId, string patientId, boolean success, string reason = "") {
    _ = start sendAuditEvent(auditSubscriptionCreatedEvent(clientId, patientId, success, reason));
}

# Audit a subscription deletion (fire-and-forget)
public function auditSubscriptionDeleted(string clientId, boolean success, string reason = "") {
    _ = start sendAuditEvent(auditSubscriptionDeletedEvent(clientId, success, reason));
}

# Audit data access (fire-and-forget)
public function auditDataAccess(string clientId, string resourceRef, boolean success, string reason = "") {
    _ = start sendAuditEvent(auditDataAccessEvent(clientId, resourceRef, success, reason));
}

# Audit client registration (fire-and-forget)
public function auditClientRegistered(string clientName, boolean success, string reason = "") {
    _ = start sendAuditEvent(auditClientRegisteredEvent(clientName, success, reason));
}

# Audit client deletion (fire-and-forget)
public function auditClientDeleted(string clientName, boolean success, string reason = "") {
    _ = start sendAuditEvent(auditClientDeletedEvent(clientName, success, reason));
}

# Audit WebSub hub operation (fire-and-forget)
public function auditWebSubOperation(string operation, string topicId, boolean success, string reason = "") {
    _ = start sendAuditEvent(auditWebSubOperationEvent(operation, topicId, success, reason));
}

# Audit FHIR server operation (fire-and-forget)
public function auditFhirServerOperation(string operation, string resourceRef, boolean success, string reason = "") {
    _ = start sendAuditEvent(auditFhirServerOperationEvent(operation, resourceRef, success, reason));
}

# Audit patient mapping operation (fire-and-forget)
public function auditMappingOperation(string operation, string resourceRef, boolean success, string reason = "") {
    _ = start sendAuditEvent(auditMappingOperationEvent(operation, resourceRef, success, reason));
}

# Audit system/admin operation (fire-and-forget)
public function auditSystemOperation(string actor, string operation, boolean success, string reason = "") {
    _ = start sendAuditEvent(auditSystemOperationEvent(actor, operation, success, reason));
}

# Audit subscription token generation (fire-and-forget)
public function auditSubscriptionTokenGenerated(string clientId, string subscriptionId, boolean success, string reason = "") {
    _ = start sendAuditEvent(auditSubscriptionTokenGeneratedEvent(clientId, subscriptionId, success, reason));
}

# Audit authorization decision (fire-and-forget)
public function auditAuthzDecision(string clientId, string patientId, boolean authorized, string? scope = (), string reason = "") {
    _ = start sendAuditEvent(auditAuthzDecisionEvent(clientId, patientId, authorized, scope, reason));
}

# Create audit event for Asgardeo token exchange (broker → 2nd Asgardeo app)
#
# + clientId - The client ID on whose behalf the exchange is performed
# + success - Whether the token exchange succeeded
# + reason - Optional failure reason
# + return - Configured audit event
public isolated function auditAsgardeoTokenExchangeEvent(string clientId, boolean success, string reason = "")
        returns international401:AuditEvent {
    string outcomeDesc = reason != "" ? reason : (success ? "Asgardeo token exchange successful" : "Asgardeo token exchange failed");
    return buildAuditEvent("operation", "E", success, outcomeDesc, clientId, [
        auditGetEntity("2", "24", string `AsgardeoTokenExchange/${clientId}`)
    ]);
}

# Audit Asgardeo token exchange (fire-and-forget)
public function auditAsgardeoTokenExchange(string clientId, boolean success, string reason = "") {
    _ = start sendAuditEvent(auditAsgardeoTokenExchangeEvent(clientId, success, reason));
}
