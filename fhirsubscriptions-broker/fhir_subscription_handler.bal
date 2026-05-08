// FHIR Subscription handler and helper functions

import ballerina/http;
import ballerina/log;

import nimesh_chandula/broker.audit;
import nimesh_chandula/broker.auth;
import nimesh_chandula/broker.common;
import nimesh_chandula/broker.fhir;
import nimesh_chandula/broker.websub;

// Handle FHIR Subscription creation request
function handleFhirSubscriptionRequest(http:Request req, string? authorization) returns json|http:BadRequest|http:InternalServerError {
    log:printInfo("========== FHIR SUBSCRIPTION REQUEST RECEIVED ==========");

    if authorization is () {
        audit:auditTokenValidationFailure("unknown", "Subscription request: missing Authorization header");
        return <http:BadRequest>{
            body: {"error": "invalid_request", "error_description": "Missing Authorization header"}
        };
    }

    string|error accessToken = auth:extractBearerToken(authorization);
    if accessToken is error {
        audit:auditTokenValidationFailure("unknown", "Subscription request: invalid bearer token: " + accessToken.message());
        return <http:BadRequest>{
            body: {"error": "invalid_request", "error_description": accessToken.message()}
        };
    }

    common:ValidatedSubscriptionToken|error validated = auth:validateSubscriptionAccessToken(accessToken);
    if validated is error {
        audit:auditTokenValidationFailure("unknown", "Subscription request: token validation failed: " + validated.message());
        return <http:BadRequest>{
            body: {"error": "invalid_token", "error_description": validated.message()}
        };
    }
    string clientId = validated.clientId;

    json|error payload = req.getJsonPayload();
    if payload is error || payload !is map<json> {
        audit:auditSubscriptionCreated(clientId, "unknown", false, "Invalid Subscription payload");
        return <http:BadRequest>{
            body: {"error": "invalid_request", "error_description": "Invalid Subscription payload"}
        };
    }

    map<json> subscriptionMap = <map<json>>payload;

    json? channelJson = subscriptionMap["channel"];
    if channelJson is () || channelJson !is map<json> {
        audit:auditSubscriptionCreated(clientId, "unknown", false, "Missing channel in Subscription");
        return <http:BadRequest>{
            body: {"error": "invalid_request", "error_description": "Missing channel in Subscription"}
        };
    }

    map<json> channelMap = <map<json>>channelJson;
    json? endpointJson = channelMap["endpoint"];
    if endpointJson !is string {
        audit:auditSubscriptionCreated(clientId, "unknown", false, "Missing channel.endpoint");
        return <http:BadRequest>{
            body: {"error": "invalid_request", "error_description": "Missing channel.endpoint"}
        };
    }

    string callbackUrl = endpointJson;
    if !isValidCallbackEndpoint(callbackUrl) {
        string errorMsg = fhir:allowHttpCallbacks
            ? "channel.endpoint must be http or https"
            : "channel.endpoint must be https (set allowHttpCallbacks=true in Config.toml for local development)";
        audit:auditSubscriptionCreated(clientId, "unknown", false, "Invalid callback endpoint: " + callbackUrl);
        return <http:BadRequest>{
            body: {"error": "invalid_request", "error_description": errorMsg}
        };
    }

    string|error filterValue = extractFilterValueString(subscriptionMap);
    if filterValue is error {
        audit:auditSubscriptionCreated(clientId, "unknown", false, "Invalid filter criteria: " + filterValue.message());
        return <http:BadRequest>{
            body: {"error": "invalid_request", "error_description": filterValue.message()}
        };
    }

    int? triggerIndex = filterValue.indexOf("trigger=feed-event");
    if triggerIndex is () {
        audit:auditSubscriptionCreated(clientId, "unknown", false, "Missing trigger=feed-event in filter");
        return <http:BadRequest>{
            body: {"error": "invalid_request", "error_description": "Missing trigger=feed-event in filter"}
        };
    }

    string|error brokerScopedPatientId = extractBrokerScopedPatientIdFromFilter(filterValue);
    if brokerScopedPatientId is error {
        audit:auditSubscriptionCreated(clientId, "unknown", false, "Invalid patient in filter: " + brokerScopedPatientId.message());
        return <http:BadRequest>{
            body: {"error": "invalid_request", "error_description": brokerScopedPatientId.message()}
        };
    }

    error? patientAccessResult = auth:validatePatientSubscriptionAccess(validated.claims, brokerScopedPatientId);
    if patientAccessResult is error {
        audit:auditSubscriptionCreated(clientId, brokerScopedPatientId, false, "Patient access denied: " + patientAccessResult.message());
        return <http:BadRequest>{
            body: {"error": "access_denied", "error_description": patientAccessResult.message()}
        };
    }

    string[]|error headerValues = extractHeaderValues(channelMap);
    if headerValues is error {
        audit:auditSubscriptionCreated(clientId, brokerScopedPatientId, false, "Invalid headers: " + headerValues.message());
        return <http:BadRequest>{
            body: {"error": "invalid_request", "error_description": headerValues.message()}
        };
    }

    string[] resourceTypes = extractResourceTypesFromCriteria(subscriptionMap);
    if resourceTypes.length() == 0 {
        resourceTypes = common:RESOURCE_TYPE_GROUP_SUFFIXES.keys();
        log:printInfo(string `[FHIR SUBSCRIPTION] No specific resource types in filter, using all: ${resourceTypes.toString()}`);
    }

    log:printInfo(string `[FHIR SUBSCRIPTION] Resource types: ${resourceTypes.toString()}, patient: ${brokerScopedPatientId}, client: ${clientId}`);

    error? patientSyncResult = fhir:ensurePatientInFhirServer(fhir:fhirServerClient, brokerScopedPatientId);
    if patientSyncResult is error {
        log:printWarn(string `[FHIR SUBSCRIPTION] Patient sync failed (non-fatal): ${patientSyncResult.message()}`);
    }

    foreach string resourceType in resourceTypes {
        string|error groupId = fhir:getOrCreateResourceGroup(fhir:fhirServerClient, clientId, resourceType);
        if groupId is error {
            log:printWarn(string `[FHIR SUBSCRIPTION] Failed to create group for ${resourceType}: ${groupId.message()}`);
            continue;
        }
        error? addResult = fhir:addPatientToGroup(fhir:fhirServerClient, groupId, brokerScopedPatientId);
        if addResult is error {
            log:printWarn(string `[FHIR SUBSCRIPTION] Failed to add patient to Group/${groupId}: ${addResult.message()}`);
        }
    }

    string|error subscriptionResult = fhir:getOrCreateClientSubscription(
        fhir:fhirServerClient, clientId, resourceTypes, callbackUrl, headerValues
    );
    if subscriptionResult is error {
        log:printError("[FHIR SUBSCRIPTION] Failed to create/get subscription", subscriptionResult);
        audit:auditSubscriptionCreated(clientId, brokerScopedPatientId, false, "Failed to create subscription: " + subscriptionResult.message());
        return <http:InternalServerError>{
            body: {"error": "server_error", "error_description": string `Failed to create subscription: ${subscriptionResult.message()}`}
        };
    }
    string subscriptionId = subscriptionResult;

    error? eventStateResult = fhir:createEventStateInFhirServer(fhir:fhirServerClient, clientId);
    if eventStateResult is error {
        log:printWarn(string `[FHIR SUBSCRIPTION] Event state creation failed (non-fatal): ${eventStateResult.message()}`);
    }

    error? registerResult = websub:registerWebSubTopic(clientId, webSubHubUrl);
    if registerResult is error {
        log:printWarn(string `[FHIR SUBSCRIPTION] WebSub registration failed: ${registerResult.message()}`);
    }

    string? sharedSecret = extractSharedSecret(headerValues);
    error? subscribeResult = websub:subscribeToWebSubHub(clientId, callbackUrl, sharedSecret, webSubHubUrl);
    if subscribeResult is error {
        log:printWarn(string `[FHIR SUBSCRIPTION] WebSub subscription failed: ${subscribeResult.message()}`);
    }

    common:addTopicSubscriber(clientId, callbackUrl);

    if headerValues.length() > 0 {
        common:clientNotificationHeaders[clientId] = headerValues;
    }

    common:addClientSubscription(brokerScopedPatientId, clientId);

    log:printInfo(string `FHIR Subscription created: client=${clientId}, patient=${brokerScopedPatientId}, subscriptionId=${subscriptionId}`);

    audit:auditSubscriptionCreated(clientId, brokerScopedPatientId, true);

    json response = {
        "resourceType": "Subscription",
        "id": subscriptionId,
        "status": "active",
        "reason": string `Subscription for client ${clientId}`,
        "patient": brokerScopedPatientId,
        "resourceTypes": resourceTypes,
        "channel": {
            "type": "rest-hook",
            "endpoint": callbackUrl
        }
    };

    return response;
}

// Validate callback endpoint URL
function isValidCallbackEndpoint(string endpoint) returns boolean {
    if fhir:allowHttpCallbacks {
        return endpoint.startsWith("https://") || endpoint.startsWith("http://");
    }
    return endpoint.startsWith("https://");
}

// Extract filter value string from FHIR Subscription _criteria extension
function extractFilterValueString(map<json> subscriptionMap) returns string|error {
    json? criteriaJson = subscriptionMap["_criteria"];
    if criteriaJson is () || criteriaJson !is map<json> {
        return error("Missing _criteria extension");
    }

    map<json> criteriaMap = <map<json>>criteriaJson;
    json? extensionJson = criteriaMap["extension"];
    if extensionJson is () || extensionJson !is json[] {
        return error("Missing _criteria.extension array");
    }

    foreach json ext in extensionJson {
        if ext is map<json> {
            json? valueStringJson = ext["valueString"];
            if valueStringJson is string {
                return valueStringJson;
            }
        }
    }

    return error("Missing _criteria.extension.valueString");
}

// Extract broker-scoped patient ID from filter value string
function extractBrokerScopedPatientIdFromFilter(string filterValue) returns string|error {
    string marker = "patient=Patient/";
    int? startIndexOpt = filterValue.indexOf(marker);
    if startIndexOpt is () {
        return error("Filter must include patient=Patient/{id}");
    }

    int idStart = startIndexOpt + marker.length();
    string remainder = filterValue.substring(idStart);
    int? ampIndexOpt = remainder.indexOf("&");
    string patientId = ampIndexOpt is int ? remainder.substring(0, ampIndexOpt) : remainder;

    if patientId.trim() == "" {
        return error("Patient ID is empty in filter");
    }

    return patientId;
}

// Extract header values from FHIR Subscription channel
function extractHeaderValues(map<json> channelMap) returns string[]|error {
    json? headerJson = channelMap["header"];
    if headerJson is () {
        return [];
    }

    if headerJson is json[] {
        string[] headers = [];
        foreach json headerItem in headerJson {
            if headerItem is string {
                headers.push(headerItem);
            } else {
                return error("channel.header must be an array of strings");
            }
        }
        return headers;
    }

    return error("channel.header must be an array of strings");
}

// Extract shared secret from subscription header values
function extractSharedSecret(string[] headerValues) returns string? {
    foreach string headerLine in headerValues {
        int? separatorIndexOpt = headerLine.indexOf(":");
        if separatorIndexOpt is int && separatorIndexOpt > 0 {
            string headerName = headerLine.substring(0, separatorIndexOpt).trim();
            if headerName.toLowerAscii() == "x-subscription-token" {
                return headerLine.substring(separatorIndexOpt + 1).trim();
            }
        }
    }

    return ();
}

// Extract resource types from _criteria.extension[].valueString
function extractResourceTypesFromCriteria(map<json> subscriptionMap) returns string[] {
    string[] resourceTypes = [];

    json? criteriaJson = subscriptionMap["_criteria"];
    if criteriaJson !is map<json> {
        return resourceTypes;
    }

    json? extensionJson = criteriaJson["extension"];
    if extensionJson !is json[] {
        return resourceTypes;
    }

    foreach json ext in extensionJson {
        if ext !is map<json> {
            continue;
        }
        json? valueStringJson = ext["valueString"];
        if valueStringJson !is string {
            continue;
        }

        string valueString = valueStringJson;
        int? questionIndex = valueString.indexOf("?");
        if questionIndex is int && questionIndex > 0 {
            string resourceType = valueString.substring(0, questionIndex);
            if common:RESOURCE_TYPE_GROUP_SUFFIXES.hasKey(resourceType) {
                boolean alreadyAdded = false;
                foreach string existing in resourceTypes {
                    if existing == resourceType {
                        alreadyAdded = true;
                        break;
                    }
                }
                if !alreadyAdded {
                    resourceTypes.push(resourceType);
                }
            }
        }
    }

    return resourceTypes;
}
