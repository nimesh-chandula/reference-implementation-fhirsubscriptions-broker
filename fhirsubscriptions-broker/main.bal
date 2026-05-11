// Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).

// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at

// http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.


// FHIR Notification Broker - Main service definition
// Endpoint handlers delegate to handler files for business logic

import ballerina/http;
import ballerina/log;

import wso2healthcare/broker.audit;
import wso2healthcare/broker.auth;
import wso2healthcare/broker.common;
import wso2healthcare/broker.fhir;
import wso2healthcare/broker.tokens;

// Configurable port for the broker service
configurable int brokerPort = 9090;

// Configurable WebSub hub URL — passed through to fhir publishers
configurable string webSubHubUrl = "https://websubhuburl.com/hub";

// Allowed CORS origins for browser-based clients
configurable string[] allowedCorsOrigins = [];

// TLS for local dev. Empty paths → plain HTTP (Choreo gateway terminates TLS upstream).
configurable string tlsCertPath = "";
configurable string tlsKeyPath = "";

final http:ListenerConfiguration listenerConfig =
    (tlsCertPath != "" && tlsKeyPath != "")
        ? { secureSocket: { key: { certFile: tlsCertPath, keyFile: tlsKeyPath } } }
        : {};

listener http:Listener brokerListener = check new (brokerPort, listenerConfig);

// CORS configuration for browser-based clients.
// Wildcard origin '*' is incompatible with allowCredentials=true per the CORS
// spec; reject it at startup so we fail fast instead of returning headers the
// browser will silently drop.
function buildValidatedCorsConfig() returns http:CorsConfig {
    foreach string origin in allowedCorsOrigins {
        if origin == "*" {
            log:printError("[CORS] '*' is not allowed in allowedCorsOrigins when allowCredentials=true");
            panic error("CORS misconfigured: wildcard '*' origin is incompatible with allowCredentials=true");
        }
    }
    return {
        allowOrigins: allowedCorsOrigins,
        allowCredentials: true,
        allowHeaders: ["Content-Type", "Authorization", "X-Requested-With", "Accept"],
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS", "PATCH"],
        exposeHeaders: ["Content-Type", "Authorization"],
        maxAge: 86400
    };
}

final http:CorsConfig corsConfig = buildValidatedCorsConfig();

// ============================================================================
// BROKER SERVICE
// ============================================================================
@http:ServiceConfig {
    cors: corsConfig
}
service /broker on brokerListener {

    // Receive FHIR notifications with demographics
    resource function post notification(@http:Payload json payload) returns http:Ok|http:BadRequest|http:InternalServerError {
        return handleNotificationRequest(payload);
    }

    // Subscribe to a topic (broker scoped patient ID) with client ID
    resource function post subscribe(@http:Payload common:SubscriptionRequest subscriptionRequest, @http:Header string? clientId = ()) returns common:SubscriptionResponse|http:BadRequest {
        string topicId = subscriptionRequest.brokerScopedPatientId;
        string callbackUrl = subscriptionRequest.callbackUrl;

        common:addTopicSubscriber(topicId, callbackUrl);

        if clientId is string {
            common:addClientSubscription(topicId, clientId);
            log:printInfo(string `Client ${clientId} subscribed to patient ${topicId}`);
            audit:auditSubscriptionCreated(clientId, topicId, true);
        }

        log:printInfo(string `Subscriber ${callbackUrl} subscribed to topic: ${topicId}`);
        audit:auditWebSubOperation("manual-subscribe", topicId, true);
        return {
            message: "Subscription successful",
            topic: topicId
        };
    }

    // ------------------------------------------------------------------
    // Internal-only admin endpoints (the next three GETs).
    //
    // The following three resources are intentionally unauthenticated and
    // MUST be reachable only via an internal/private network. The deployment
    // is responsible for blocking them from public traffic at the gateway,
    // WAF, or network-policy layer — see deployment/README.md ("Network
    // exposure"). Note: .choreo/component.yaml currently lists the broker-api
    // endpoint as networkVisibilities: [Public]; operators fronting this
    // broker with any public ingress must restrict these paths externally.
    //
    // The "system-admin" string passed to audit:auditDataAccess is a
    // deliberate marker for an internal/system caller, not a placeholder.
    // ------------------------------------------------------------------

    // Get all subscriptions for a topic — internal-only (see block above).
    resource function get subscriptions/[string brokerScopedPatientId]() returns string[]|http:NotFound {
        string[]? subscribers = common:topicSubscribers[brokerScopedPatientId];

        if subscribers is () {
            return <http:NotFound>{
                body: string `No subscriptions found for topic: ${brokerScopedPatientId}`
            };
        }

        audit:auditDataAccess("system-admin", string `subscriptions/${brokerScopedPatientId}`, true);
        return subscribers;
    }

    // Token endpoint - OAuth 2.0 Token Exchange (RFC 8693) & Refresh Token
    resource function post auth/token(http:Request req) returns json|http:BadRequest|http:Unauthorized {
        log:printInfo("========== TOKEN REQUEST RECEIVED ==========");

        string|error formData = req.getTextPayload();
        if formData is error {
            log:printError("Failed to read request body");
            return <http:BadRequest>{
                body: { "error": "invalid_request", "error_description": "Failed to read request body" }
            };
        }

        if tokens:isTokenExchangeRequest(formData) {
            log:printInfo("[TOKEN] Processing as Token Exchange request");
            req.setTextPayload(formData, "application/x-www-form-urlencoded");
            return tokens:processTokenExchangeRequest(req);
        }

        if tokens:isRefreshTokenRequest(formData) {
            log:printInfo("[TOKEN] Processing as Refresh Token request");
            req.setTextPayload(formData, "application/x-www-form-urlencoded");
            return tokens:processRefreshTokenRequest(req);
        }

        log:printError("[TOKEN] Unsupported grant_type — only token-exchange and refresh_token are accepted");
        return <http:BadRequest>{
            body: {
                "error": "unsupported_grant_type",
                "error_description": "grant_type must be 'urn:ietf:params:oauth:grant-type:token-exchange' or 'refresh_token'"
            }
        };
    }

    // Get clients subscribed to a broker-scoped patient ID — internal-only.
    resource function get clients/[string brokerScopedPatientId]() returns string[]|http:NotFound {
        string[]? clients = common:clientSubscriptions[brokerScopedPatientId];

        if clients is () {
            return <http:NotFound>{
                body: string `No clients found for patient: ${brokerScopedPatientId}`
            };
        }

        audit:auditDataAccess("system-admin", string `clients/${brokerScopedPatientId}`, true);
        return clients;
    }

    // List all registered clients — internal-only.
    resource function get registry() returns json {
        audit:auditDataAccess("system-admin", "registry-list", true);
        return handleListRegistry();
    }

    // Register a new client dynamically
    resource function post registry/'register(http:Request req) returns json|http:BadRequest {
        return handleRegisterClient(req);
    }

    // Delete a dynamically registered client
    resource function delete registry/[string clientName]() returns json|http:NotFound|http:BadRequest {
        return handleDeleteClient(clientName);
    }
}

// ============================================================================
// FHIR SERVICE
// ============================================================================
@http:ServiceConfig {
    cors: corsConfig
}
service /fhir on brokerListener {

    // Create FHIR Subscription
    resource function post Subscription(http:Request req, @http:Header string? authorization = ()) returns json|http:BadRequest|http:InternalServerError {
        return handleFhirSubscriptionRequest(req, authorization);
    }

    // FHIR R5 $events operation — retrieve missed/historical notification events
    resource function get Subscription/[string subscriptionId]/[string operation](
        @http:Header {name: "Authorization"} string? authorization = (),
        int? eventsSinceNumber = (),
        int? eventsUntilNumber = (),
        int? _count = ()
    ) returns json|http:NotFound|http:Unauthorized|http:Forbidden|http:BadRequest|http:InternalServerError {
        if operation != "$events" {
            return <http:NotFound>{body: {"error": "not_found", "error_description": string `Unknown operation: ${operation}`}};
        }
        return handleEventsOperation(subscriptionId, eventsSinceNumber, eventsUntilNumber, _count, authorization);
    }

    // Proxy resource retrieval to FHIR server (with authorization validation)
    resource function get [string resourceType]/[string resourceId](http:Request req, @http:Header string? authorization = ())
        returns json|http:NotFound|http:Unauthorized|http:Forbidden|http:BadRequest|http:BadGateway|http:GatewayTimeout|http:InternalServerError {
        log:printInfo(string `[RESOURCE RETRIEVAL] GET /fhir/${resourceType}/${resourceId}`);

        common:ValidatedSubscriptionToken|http:Unauthorized|http:Forbidden authResult = auth:validateResourceAccess(authorization, ());
        if authResult !is common:ValidatedSubscriptionToken {
            if authResult is http:Unauthorized {
                audit:auditAuthzDecision("unknown", "", false, (), "Missing or invalid token on FHIR proxy");
            } else {
                audit:auditAuthzDecision("unknown", "", false, (), "Forbidden on FHIR proxy");
            }
            return authResult;
        }
        string callerId = authResult.clientId;
        string resourceRef = string `${resourceType}/${resourceId}`;

        string fhirPath = string `/${resourceType}/${resourceId}`;
        log:printInfo(string `[RESOURCE RETRIEVAL] Proxying to FHIR server: ${fhirPath}`);

        // Inspect upstream response so transport, 4xx, and 5xx errors get
        // mapped to distinct broker statuses instead of all collapsing to 404.
        http:Response|error response = fhir:fhirServerClient->get(fhirPath);
        if response is error {
            log:printError(string `[RESOURCE RETRIEVAL] FHIR server transport error: ${response.message()}`);
            audit:auditDataAccess(callerId, resourceRef, false, "transport: " + response.message());
            string msg = response.message().toLowerAscii();
            if msg.includes("timeout") || msg.includes("timed out") {
                return <http:GatewayTimeout>{
                    body: buildOperationOutcome("timeout", "Upstream FHIR server timed out")
                };
            }
            return <http:BadGateway>{
                body: buildOperationOutcome("transient", "Upstream FHIR server unreachable")
            };
        }

        int statusCode = response.statusCode;
        if statusCode == 404 {
            audit:auditDataAccess(callerId, resourceRef, false, "upstream 404");
            return <http:NotFound>{
                body: buildOperationOutcome("not-found", string `Resource ${resourceType}/${resourceId} not found`)
            };
        }
        if statusCode == 401 {
            audit:auditDataAccess(callerId, resourceRef, false, "upstream 401");
            return <http:Unauthorized>{
                body: buildOperationOutcome("login", "Upstream FHIR server rejected the request as unauthenticated")
            };
        }
        if statusCode == 403 {
            audit:auditDataAccess(callerId, resourceRef, false, "upstream 403");
            return <http:Forbidden>{
                body: buildOperationOutcome("forbidden", "Upstream FHIR server forbade the request")
            };
        }
        if statusCode >= 500 {
            audit:auditDataAccess(callerId, resourceRef, false, string `upstream ${statusCode}`);
            return <http:BadGateway>{
                body: buildOperationOutcome("transient", string `Upstream FHIR server returned ${statusCode}`)
            };
        }
        if statusCode < 200 || statusCode >= 300 {
            audit:auditDataAccess(callerId, resourceRef, false, string `upstream ${statusCode}`);
            return <http:BadGateway>{
                body: buildOperationOutcome("transient", string `Upstream FHIR server returned unexpected status ${statusCode}`)
            };
        }

        json|error body = response.getJsonPayload();
        if body is error {
            log:printError(string `[RESOURCE RETRIEVAL] Failed to parse upstream JSON: ${body.message()}`);
            audit:auditDataAccess(callerId, resourceRef, false, "invalid upstream JSON");
            return <http:BadGateway>{
                body: buildOperationOutcome("structure", "Upstream FHIR server returned an invalid JSON payload")
            };
        }
        json result = body;

        // Patient-level authorization check via authz service.
        // Fail-closed: when both gates are on, every failure path below
        // audits the denial and returns a non-2xx response — no falling
        // through to a 200 with the resource body.
        if auth:requireNotificationAuthz && auth:authzEnabled && authorization is string {
            if result !is map<json> {
                log:printWarn("[RESOURCE RETRIEVAL] Resource is not a JSON object — denying");
                audit:auditAuthzDecision(callerId, "", false, (), "resource not inspectable");
                return <http:Forbidden>{
                    body: buildOperationOutcome("forbidden", "Resource cannot be evaluated for patient-level authorization")
                };
            }
            map<json> resourceMap = result;

            string|error tokenStr = auth:extractBearerToken(authorization);
            if tokenStr is error {
                log:printWarn(string `[RESOURCE RETRIEVAL] Bearer token malformed: ${tokenStr.message()}`);
                audit:auditAuthzDecision(callerId, "", false, (), "bearer token malformed");
                return <http:Unauthorized>{
                    body: buildOperationOutcome("login", "Authorization header is malformed")
                };
            }

            json|error payloadJson = auth:decodeJWTPayload(tokenStr);
            if payloadJson !is map<json> {
                log:printWarn("[RESOURCE RETRIEVAL] JWT payload could not be decoded as JSON object");
                audit:auditAuthzDecision(callerId, "", false, (), "jwt payload invalid");
                return <http:Unauthorized>{
                    body: buildOperationOutcome("login", "JWT payload could not be decoded")
                };
            }
            map<json> payload = payloadJson;

            json? existingPatient = payload["patient"];
            if existingPatient is () {
                json? subClaim = payload["sub"];
                if subClaim !is string {
                    log:printWarn("[RESOURCE RETRIEVAL] No patient claim and no sub claim — cannot resolve patient context");
                    audit:auditAuthzDecision(callerId, "", false, (), "could not resolve patient context");
                    return <http:Forbidden>{
                        body: buildOperationOutcome("forbidden", "Patient context could not be resolved from token")
                    };
                }
                [string, string?]|error resolved = fhir:resolvePatientBySub(fhir:fhirServerClient, subClaim);
                if resolved is error {
                    log:printWarn(string `[RESOURCE RETRIEVAL] Could not resolve patient from sub: ${resolved.message()}`);
                    audit:auditAuthzDecision(callerId, "", false, (), "could not resolve patient context");
                    return <http:Forbidden>{
                        body: buildOperationOutcome("forbidden", "Patient context could not be resolved from token")
                    };
                }
                payload["patient"] = resolved[0];
                log:printInfo(string `[RESOURCE RETRIEVAL] Enriched JWT with patient=${resolved[0]} from FHIR lookup`);
            }

            string? resourcePatientId = auth:extractPatientFromResource(resourceMap);
            if resourcePatientId is () {
                log:printWarn("[RESOURCE RETRIEVAL] Resource has no patient reference — denying");
                audit:auditAuthzDecision(callerId, "", false, (), "resource has no patient reference");
                return <http:Forbidden>{
                    body: buildOperationOutcome("forbidden", "Resource has no patient reference for authorization")
                };
            }

            common:AuthzResult authzResult = auth:checkAuthorization(payload, resourcePatientId);
            if !authzResult.isAuthorized {
                log:printWarn(string `[RESOURCE RETRIEVAL] Authorization denied for patient=${resourcePatientId}`);
                audit:auditAuthzDecision(callerId, resourcePatientId, false, authzResult.scope, "Patient-level access denied");
                return <http:Forbidden>{
                    body: buildOperationOutcome("forbidden", "You are not authorized to access this patient's resources")
                };
            }
            audit:auditAuthzDecision(callerId, resourcePatientId, true, authzResult.scope);
        }

        log:printInfo(string `[RESOURCE RETRIEVAL] Returning resource from FHIR server`);
        audit:auditDataAccess(callerId, resourceRef, true);
        return result;
    }
}

isolated function buildOperationOutcome(string code, string diagnostics) returns map<json> {
    return {
        "resourceType": "OperationOutcome",
        "issue": [{
            "severity": "error",
            "code": code,
            "diagnostics": diagnostics
        }]
    };
}
