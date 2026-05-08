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

// CORS configuration for browser-based clients
final http:CorsConfig corsConfig = {
    allowOrigins: allowedCorsOrigins,
    allowCredentials: true,
    allowHeaders: ["Content-Type", "Authorization", "X-Requested-With", "Accept"],
    allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS", "PATCH"],
    exposeHeaders: ["Content-Type", "Authorization"],
    maxAge: 84900
};

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

    // Get all subscriptions for a topic
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

    // Get clients subscribed to a broker-scoped patient ID
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

    // List all registered clients
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
        returns json|http:NotFound|http:Unauthorized|http:Forbidden|http:BadRequest|http:InternalServerError {
        log:printInfo(string `[RESOURCE RETRIEVAL] GET /fhir/${resourceType}/${resourceId}`);

        common:ValidatedSubscriptionToken|http:Unauthorized|http:Forbidden authResult = auth:validateResourceAccess(authorization, ());
        if authResult is http:Unauthorized {
            audit:auditAuthzDecision("unknown", "", false, (), "Missing or invalid token on FHIR proxy");
            return authResult;
        }
        if authResult is http:Forbidden {
            audit:auditAuthzDecision("unknown", "", false, (), "Forbidden on FHIR proxy");
            return authResult;
        }

        string fhirPath = string `/${resourceType}/${resourceId}`;
        log:printInfo(string `[RESOURCE RETRIEVAL] Proxying to FHIR server: ${fhirPath}`);

        json|error result = fhir:fhirServerClient->get(fhirPath);

        if result is error {
            log:printError(string `[RESOURCE RETRIEVAL] FHIR server error: ${result.message()}`);
            audit:auditDataAccess("fhir-proxy", string `${resourceType}/${resourceId}`, false, result.message());
            return <http:NotFound>{
                body: {
                    "resourceType": "OperationOutcome",
                    "issue": [{
                        "severity": "error",
                        "code": "not-found",
                        "diagnostics": string `Resource ${resourceType}/${resourceId} not found`
                    }]
                }
            };
        }

        // Patient-level authorization check via authz service
        if auth:requireNotificationAuthz && auth:authzEnabled && authorization is string && result is map<json> {
            string|error tokenStr = auth:extractBearerToken(authorization);
            if tokenStr is string {
                json|error payload = auth:decodeJWTPayload(tokenStr);
                if payload is map<json> {
                    json? existingPatient = payload["patient"];
                    if existingPatient is () {
                        json? subClaim = payload["sub"];
                        if subClaim is string {
                            [string, string?]|error resolved = fhir:resolvePatientBySub(fhir:fhirServerClient, subClaim);
                            if resolved is [string, string?] {
                                payload["patient"] = resolved[0];
                                log:printInfo(string `[RESOURCE RETRIEVAL] Enriched JWT with patient=${resolved[0]} from FHIR lookup`);
                            } else {
                                log:printWarn(string `[RESOURCE RETRIEVAL] Could not resolve patient from sub: ${resolved.message()}`);
                            }
                        }
                    }

                    string? resourcePatientId = auth:extractPatientFromResource(result);
                    if resourcePatientId is string {
                        common:AuthzResult authzResult = auth:checkAuthorization(payload, resourcePatientId);
                        string validatedClientId = authResult is common:ValidatedSubscriptionToken ? authResult.clientId : "unknown";
                        if !authzResult.isAuthorized {
                            log:printWarn(string `[RESOURCE RETRIEVAL] Authorization denied for patient=${resourcePatientId}`);
                            audit:auditAuthzDecision(validatedClientId, resourcePatientId, false, authzResult.scope, "Patient-level access denied");
                            return <http:Forbidden>{
                                body: {
                                    "resourceType": "OperationOutcome",
                                    "issue": [{
                                        "severity": "error",
                                        "code": "forbidden",
                                        "diagnostics": "You are not authorized to access this patient's resources"
                                    }]
                                }
                            };
                        }
                        audit:auditAuthzDecision(validatedClientId, resourcePatientId, true, authzResult.scope);
                    }
                }
            }
        }

        log:printInfo(string `[RESOURCE RETRIEVAL] Returning resource from FHIR server`);
        audit:auditDataAccess("fhir-proxy", string `${resourceType}/${resourceId}`, true);
        return result;
    }
}
