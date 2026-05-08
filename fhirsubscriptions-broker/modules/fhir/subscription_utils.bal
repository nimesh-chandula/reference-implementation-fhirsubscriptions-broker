// FHIR Subscription publishing utilities (WebSub side)

import ballerina/http;
import ballerina/log;
import ballerina/time;

import nimesh_chandula/broker.common;
import nimesh_chandula/broker.websub;

// Allow HTTP callback endpoints for Subscription.channel.endpoint.
// Public so root handlers can validate callback URLs against this flag.
public configurable boolean allowHttpCallbacks = false;

// Publish notification to a specific topic with FHIR server storage.
// Stores the clinical resource with deterministic ID, creates a Communication
// resource as persistent event index, then publishes via WebSub.
public function publishToTopic(
    string topicId,
    json notification,
    string brokerBaseUrl,
    string webSubHubUrl,
    map<string[]> clientNotificationHeaders,
    http:Client fhirServerClient,
    map<common:ClientEventState> clientEventCounters
) returns error? {
    string clientId = topicId;

    map<json>? clinicalResource = ();
    string? clinicalResourceType = ();
    string? clinicalResourceId = ();
    map<json>? patientResource = ();
    string? patientId = ();

    if notification is map<json> {
        json? entriesJson = notification["entry"];
        if entriesJson is json[] {
            foreach json entry in entriesJson {
                if entry is map<json> {
                    json? resourceJson = entry["resource"];
                    if resourceJson is map<json> {
                        json? resTypeJson = resourceJson["resourceType"];
                        json? resIdJson = resourceJson["id"];
                        if resTypeJson is string && resIdJson is string {
                            if resTypeJson == "Patient" {
                                patientResource = resourceJson;
                                patientId = resIdJson;
                            } else {
                                clinicalResource = resourceJson;
                                clinicalResourceType = resTypeJson;
                                clinicalResourceId = resIdJson;
                            }
                        }
                    }
                }
            }
        }
    }

    if clinicalResource is () || clinicalResourceType is () || clinicalResourceId is () {
        log:printWarn("[PUBLISH] No clinical resource found in notification bundle - skipping");
        return;
    }

    log:printInfo(string `[PUBLISH] Processing ${clinicalResourceType}/${clinicalResourceId} for client ${clientId}`);

    common:ClientEventState eventState;
    common:ClientEventState? existingState = ensureEventState(clientId);
    if existingState is common:ClientEventState {
        eventState = existingState;
    } else {
        eventState = {
            lastEventNumber: 0,
            totalEventsSinceStart: 0
        };
    }

    int newEventNumber = eventState.lastEventNumber + 1;
    int newTotalEvents = eventState.totalEventsSinceStart + 1;

    string storedResourceId = string `${clientId}-${newEventNumber}`;

    log:printInfo(string `[PUBLISH] Assigning event number ${newEventNumber} for client ${clientId}, resourceId=${storedResourceId}`);

    string timestamp = time:utcToString(time:utcNow());

    map<string|string[]> fhirHeaders = {"Content-Type": "application/fhir+json"};

    if patientResource is map<json> && patientId is string {
        map<json> patientToStore = patientResource.clone();
        patientToStore["id"] = patientId;
        patientToStore["meta"] = { "lastUpdated": timestamp };

        http:Response|error patientStoreResponse = fhirServerClient->/Patient/[patientId].put(patientToStore, fhirHeaders);

        if patientStoreResponse is error {
            log:printWarn(string `[PUBLISH] Failed to store Patient/${patientId}: ${patientStoreResponse.message()}`);
        } else {
            http:Response patResp = patientStoreResponse;
            if patResp.statusCode >= 200 && patResp.statusCode < 300 {
                log:printInfo(string `[PUBLISH] Stored Patient/${patientId}`);
            } else {
                string|error body = patResp.getTextPayload();
                log:printWarn(string `[PUBLISH] Patient storage returned ${patResp.statusCode}: ${body is string ? body : "unknown"}`);
            }
        }
    }

    map<json> resourceToStore = (<map<json>>clinicalResource).clone();
    resourceToStore["id"] = storedResourceId;
    resourceToStore["meta"] = { "lastUpdated": timestamp };

    string resourcePath = string `/${clinicalResourceType}`;
    log:printInfo(string `[PUBLISH] Storing ${clinicalResourceType}/${storedResourceId} in FHIR server via POST`);

    http:Response|error storeResponse = fhirServerClient->post(resourcePath, resourceToStore, fhirHeaders);

    if storeResponse is error {
        log:printError(string `[PUBLISH] Failed to store ${clinicalResourceType}/${storedResourceId}: ${storeResponse.message()}`);
        return error(string `Failed to store resource: ${storeResponse.message()}`);
    }

    http:Response resp = storeResponse;
    int statusCode = resp.statusCode;

    if statusCode >= 200 && statusCode < 300 {
        log:printInfo(string `[PUBLISH] Successfully stored ${clinicalResourceType}/${storedResourceId}`);
    } else {
        string|error body = resp.getTextPayload();
        string bodyStr = body is string ? body : "unknown";
        log:printError(string `[PUBLISH] FHIR server rejected resource storage: status=${statusCode}, body=${bodyStr}`);
        return error(string `FHIR server rejected storage: ${bodyStr}`);
    }

    string clinicalReference = string `${clinicalResourceType}/${storedResourceId}`;
    json communicationResource = {
        "resourceType": "Communication",
        "id": storedResourceId,
        "status": "completed",
        "subject": patientId is string ? { "reference": string `Patient/${patientId}` } : null,
        "category": [{
            "coding": [{
                "system": "http://terminology.hl7.org/CodeSystem/communication-category",
                "code": "notification"
            }]
        }],
        "identifier": [{
            "system": "https://broker.example.org/event-sequence",
            "value": newEventNumber.toString()
        }],
        "payload": [{
            "contentReference": { "reference": clinicalReference }
        }]
    };

    string communicationPath = string `/Communication`;
    http:Response|error commResponse = fhirServerClient->post(communicationPath, communicationResource, fhirHeaders);

    if commResponse is error {
        log:printWarn(string `[PUBLISH] Failed to store Communication/${storedResourceId}: ${commResponse.message()}`);
    } else {
        http:Response commResp = commResponse;
        if commResp.statusCode >= 200 && commResp.statusCode < 300 {
            log:printInfo(string `[PUBLISH] Stored Communication/${storedResourceId} -> ${clinicalReference}`);
        } else {
            string|error body = commResp.getTextPayload();
            log:printWarn(string `[PUBLISH] Communication storage returned ${commResp.statusCode}: ${body is string ? body : "unknown"}`);
        }
    }

    eventState.lastEventNumber = newEventNumber;
    eventState.totalEventsSinceStart = newTotalEvents;
    clientEventCounters[clientId] = eventState;
    updateEventStateInFhirServer(fhirServerClient, clientId, newEventNumber, newTotalEvents);

    websub:SubscriptionNotificationBundle bundle = websub:createSubscriptionNotificationBundle(
        topicId,
        newEventNumber,
        newTotalEvents,
        <string>clinicalResourceType,
        storedResourceId,
        brokerBaseUrl
    );

    log:printInfo(string `[PUBLISH] Focus reference: ${brokerBaseUrl}/${clinicalResourceType}/${storedResourceId}`);

    error? result = websub:publishToWebSubHub(topicId, bundle, webSubHubUrl, clientNotificationHeaders);

    if result is error {
        log:printError(string `Failed to publish to WebSub hub for topic: ${topicId}`, result);
        return result;
    }

    log:printInfo(string `[PUBLISH] Successfully published ${clinicalResourceType}/${storedResourceId} (event ${newEventNumber}) to WebSub hub for topic: ${topicId}`);
    return;
}

// ============================================================================
// PERSISTENT EVENT STATE (Basic resource in FHIR server)
// ============================================================================

function buildEventStateId(string clientId) returns string {
    return string `state-${clientId}`;
}

function buildEventStateResource(string clientId, int lastEventNumber, int totalEventsSinceStart) returns json {
    string stateId = buildEventStateId(clientId);
    return {
        "resourceType": "Basic",
        "id": stateId,
        "code": {
            "coding": [{
                "system": common:EVENT_STATE_SYSTEM,
                "code": common:EVENT_STATE_CODE
            }]
        },
        "extension": [
            {
                "url": common:EVENT_STATE_SEQUENCE_URL,
                "valueInteger": lastEventNumber
            },
            {
                "url": common:EVENT_STATE_TOTAL_URL,
                "valueInteger": totalEventsSinceStart
            }
        ]
    };
}

// Create the initial Basic event state resource (called during subscription creation)
public function createEventStateInFhirServer(http:Client fhirClient, string clientId) returns error? {
    string stateId = buildEventStateId(clientId);
    log:printInfo(string `[EVENT STATE] Creating Basic/${stateId} for client ${clientId}`);

    json|error existing = fhirClient->get(string `/Basic/${stateId}`);
    if existing is map<json> {
        json? resType = existing["resourceType"];
        if resType is string && resType == "Basic" {
            log:printInfo(string `[EVENT STATE] Basic/${stateId} already exists, skipping creation`);
            return;
        }
    }

    json stateResource = buildEventStateResource(clientId, 0, 0);
    map<string|string[]> fhirHeaders = {"Content-Type": "application/fhir+json"};

    http:Response|error response = fhirClient->post("/Basic", stateResource, fhirHeaders);
    if response is error {
        log:printWarn(string `[EVENT STATE] Failed to create Basic/${stateId}: ${response.message()}`);
        return response;
    }

    http:Response resp = response;
    if resp.statusCode >= 200 && resp.statusCode < 300 {
        log:printInfo(string `[EVENT STATE] Created Basic/${stateId}`);
    } else if resp.statusCode == 409 {
        log:printInfo(string `[EVENT STATE] Basic/${stateId} already exists`);
    } else {
        string|error body = resp.getTextPayload();
        log:printWarn(string `[EVENT STATE] Basic creation returned ${resp.statusCode}: ${body is string ? body : "unknown"}`);
    }
}

// Update the persistent event state after each notification
function updateEventStateInFhirServer(http:Client fhirClient, string clientId, int lastEventNumber, int totalEventsSinceStart) {
    string stateId = buildEventStateId(clientId);
    json stateResource = buildEventStateResource(clientId, lastEventNumber, totalEventsSinceStart);
    map<string|string[]> fhirHeaders = {"Content-Type": "application/fhir+json"};

    http:Response|error response = fhirClient->put(string `/Basic/${stateId}`, stateResource, fhirHeaders);
    if response is error {
        log:printWarn(string `[EVENT STATE] Failed to update Basic/${stateId}: ${response.message()}`);
    } else {
        http:Response resp = response;
        if resp.statusCode >= 200 && resp.statusCode < 300 {
            log:printInfo(string `[EVENT STATE] Updated Basic/${stateId}: lastEvent=${lastEventNumber}, total=${totalEventsSinceStart}`);
        } else {
            string|error body = resp.getTextPayload();
            log:printWarn(string `[EVENT STATE] Basic update returned ${resp.statusCode}: ${body is string ? body : "unknown"}`);
        }
    }
}

// Recover event state from the FHIR server Basic resource (after restart)
function recoverEventStateFromFhirServer(http:Client fhirClient, string clientId) returns common:ClientEventState? {
    string stateId = buildEventStateId(clientId);
    log:printInfo(string `[EVENT STATE] Recovering state from Basic/${stateId}`);

    json|error result = fhirClient->get(string `/Basic/${stateId}`);
    if result is error {
        log:printInfo(string `[EVENT STATE] No persisted state found for ${clientId}`);
        return ();
    }

    if result !is map<json> {
        return ();
    }

    int lastEventNumber = 0;
    int totalEventsSinceStart = 0;

    json? extensionsJson = result["extension"];
    if extensionsJson is json[] {
        foreach json ext in extensionsJson {
            if ext is map<json> {
                json? urlJson = ext["url"];
                json? valueJson = ext["valueInteger"];
                if urlJson is string && valueJson is int {
                    if urlJson == common:EVENT_STATE_SEQUENCE_URL {
                        lastEventNumber = valueJson;
                    } else if urlJson == common:EVENT_STATE_TOTAL_URL {
                        totalEventsSinceStart = valueJson;
                    }
                }
            }
        }
    }

    if lastEventNumber > 0 {
        log:printInfo(string `[EVENT STATE] Recovered: lastEvent=${lastEventNumber}, total=${totalEventsSinceStart}`);
        return {
            lastEventNumber: lastEventNumber,
            totalEventsSinceStart: totalEventsSinceStart
        };
    }

    return ();
}

// Ensure event state is loaded for a client (check in-memory first, then FHIR server)
public function ensureEventState(string clientId) returns common:ClientEventState? {
    common:ClientEventState? state = common:clientEventCounters[clientId];
    if state is common:ClientEventState {
        return state;
    }

    common:ClientEventState? recovered = recoverEventStateFromFhirServer(fhirServerClient, clientId);
    if recovered is common:ClientEventState {
        common:clientEventCounters[clientId] = recovered;
        log:printInfo(string `[EVENT STATE] Restored in-memory state for ${clientId} from FHIR server`);
        return recovered;
    }

    return ();
}
