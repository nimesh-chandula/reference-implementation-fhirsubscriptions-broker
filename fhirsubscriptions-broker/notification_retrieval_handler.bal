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

// Notification retrieval handlers
// Uses Communication resources as persistent event index for notification retrieval
// Communication/{clientId}-{eventNumber} contains contentReference pointing to the clinical resource

import ballerina/http;
import ballerina/log;
import ballerina/time;

import wso2healthcare/broker.audit;
import wso2healthcare/broker.auth;
import wso2healthcare/broker.common;
import wso2healthcare/broker.fhir;

// FHIR R5 $events operation handler with pagination
function handleEventsOperation(
    string subscriptionId,
    int? eventsSinceNumber,
    int? eventsUntilNumber,
    int? countParam,
    string? authorization
) returns json|http:NotFound|http:Unauthorized|http:Forbidden|http:BadRequest|http:InternalServerError {

    string clientId = subscriptionId;

    common:ValidatedSubscriptionToken|http:Unauthorized|http:Forbidden authResult = auth:validateResourceAccess(authorization, clientId);
    if authResult is http:Unauthorized {
        audit:auditAuthzDecision(clientId, "", false, (), "Missing or invalid token on $events");
        return authResult;
    }
    if authResult is http:Forbidden {
        audit:auditAuthzDecision(clientId, "", false, (), "Client mismatch on $events");
        return authResult;
    }
    common:ValidatedSubscriptionToken validatedToken = <common:ValidatedSubscriptionToken>authResult;

    log:printInfo(string `[EVENTS] $events request for subscription=${subscriptionId}, since=${eventsSinceNumber.toString()}, until=${eventsUntilNumber.toString()}, count=${countParam.toString()}`);

    common:ClientEventState? state = fhir:ensureEventState(clientId);
    if state is () || state.lastEventNumber == 0 {
        return <http:NotFound>{
            body: {
                "resourceType": "OperationOutcome",
                "issue": [{
                    "severity": "error",
                    "code": "not-found",
                    "diagnostics": string `No events found for subscription ${subscriptionId}`
                }]
            }
        };
    }

    int sinceNumber = eventsSinceNumber ?: 0;
    int untilNumber = eventsUntilNumber ?: state.lastEventNumber;
    int pageSize = countParam ?: common:DEFAULT_EVENTS_PAGE_SIZE;

    if sinceNumber < 0 || untilNumber < sinceNumber {
        return <http:BadRequest>{
            body: {
                "resourceType": "OperationOutcome",
                "issue": [{
                    "severity": "error",
                    "code": "invalid",
                    "diagnostics": "Invalid event range"
                }]
            }
        };
    }

    NotificationEventLite[] notificationEvents = [];
    int n = sinceNumber + 1;
    int lastScannedEvent = sinceNumber;
    boolean hasMore = false;

    while n <= untilNumber {
        if notificationEvents.length() >= pageSize {
            hasMore = true;
            break;
        }

        string communicationId = string `${clientId}-${n}`;
        CommunicationDetails|http:NotFound|http:InternalServerError commDetails = fetchCommunicationDetails(communicationId);

        if commDetails is CommunicationDetails {
            boolean authorized = true;
            if auth:authzEnabled && validatedToken.patient != "" && commDetails.patientId is string {
                string eventPatientId = <string>commDetails.patientId;
                map<json> jwtClaims = {"patient": validatedToken.patient};
                common:AuthzResult authzResult = auth:checkAuthorization(jwtClaims, eventPatientId);
                authorized = authzResult.isAuthorized;
            }

            if authorized {
                string resourceType = extractResourceTypeFromReference(commDetails.contentReference);
                string currentTimestamp = time:utcToString(time:utcNow());
                notificationEvents.push({
                    eventNumber: n,
                    timestamp: currentTimestamp,
                    focusReference: string `${fhir:brokerBaseUrl}/${commDetails.contentReference}`,
                    focusType: resourceType
                });
            }
        }
        lastScannedEvent = n;
        n += 1;
    }

    if !hasMore && lastScannedEvent < untilNumber {
        hasMore = true;
    }
    int effectiveUntil = lastScannedEvent;

    string responseTimestamp = time:utcToString(time:utcNow());

    json bundleJson = {
        "resourceType": "Bundle",
        "type": "subscription-notification",
        "timestamp": responseTimestamp,
        "entry": [
            {
                "fullUrl": string `urn:uuid:events-response-${subscriptionId}`,
                "resource": {
                    "resourceType": "SubscriptionStatus",
                    "status": "active",
                    "type": "query-event",
                    "eventsSinceSubscriptionStart": state.totalEventsSinceStart,
                    "notificationEvent": buildNotificationEventJson(notificationEvents),
                    "subscription": {
                        "reference": string `${fhir:brokerBaseUrl}/Subscription/${subscriptionId}`
                    },
                    "topic": string `http://hl7.org/fhir/SubscriptionTopic/${subscriptionId}`
                }
            }
        ]
    };

    if hasMore {
        string nextUrl = string `${fhir:brokerBaseUrl}/Subscription/${subscriptionId}/$events?eventsSinceNumber=${effectiveUntil}&_count=${pageSize}`;
        if eventsUntilNumber is int {
            nextUrl = string `${nextUrl}&eventsUntilNumber=${eventsUntilNumber}`;
        }
        json linkArray = [
            { "relation": "next", "url": nextUrl },
            { "relation": "self", "url": string `${fhir:brokerBaseUrl}/Subscription/${subscriptionId}/$events?eventsSinceNumber=${sinceNumber}&eventsUntilNumber=${effectiveUntil}&_count=${pageSize}` }
        ];
        if bundleJson is map<json> {
            bundleJson["link"] = linkArray;
        }
    }

    log:printInfo(string `[EVENTS] Returning ${notificationEvents.length()} events for subscription ${subscriptionId}${hasMore ? " (more available)" : ""}`);
    audit:auditDataAccess(clientId, string `Subscription/${subscriptionId}/$events`, true);
    return bundleJson;
}

// Lightweight event record used internally to assemble the response
type NotificationEventLite record {|
    int eventNumber;
    string timestamp;
    string focusReference;
    string focusType;
|};

// Convert internal NotificationEventLite[] to json[] for the $events response
function buildNotificationEventJson(NotificationEventLite[] events) returns json[] {
    json[] result = [];
    foreach NotificationEventLite event in events {
        result.push({
            "eventNumber": event.eventNumber,
            "timestamp": event.timestamp,
            "focus": {
                "reference": event.focusReference,
                "type": event.focusType
            }
        });
    }
    return result;
}

// Communication details extracted from a Communication resource
type CommunicationDetails record {|
    string contentReference;
    string? patientId;
|};

// Fetch a Communication resource and extract contentReference and subject patient
function fetchCommunicationDetails(string communicationId)
    returns CommunicationDetails|http:NotFound|http:InternalServerError {

    string commPath = string `/Communication/${communicationId}`;
    json|error commResult = fhir:fhirServerClient->get(commPath);

    if commResult is error {
        log:printWarn(string `[NOTIFICATION RETRIEVAL] Communication/${communicationId} not found: ${commResult.message()}`);
        return <http:NotFound>{
            body: {
                "resourceType": "OperationOutcome",
                "issue": [{
                    "severity": "error",
                    "code": "not-found",
                    "diagnostics": string `Notification not found: Communication/${communicationId}`
                }]
            }
        };
    }

    if commResult is map<json> {
        string? eventPatientId = ();
        json? subjectJson = commResult["subject"];
        if subjectJson is map<json> {
            json? subjectRef = subjectJson["reference"];
            if subjectRef is string && subjectRef.startsWith("Patient/") {
                eventPatientId = subjectRef.substring(8);
            }
        }

        json? payloadJson = commResult["payload"];
        if payloadJson is json[] && payloadJson.length() > 0 {
            json? firstPayload = payloadJson[0];
            if firstPayload is map<json> {
                json? contentRefJson = firstPayload["contentReference"];
                if contentRefJson is map<json> {
                    json? refJson = contentRefJson["reference"];
                    if refJson is string {
                        return {contentReference: refJson, patientId: eventPatientId};
                    }
                }
            }
        }
    }

    log:printError(string `[NOTIFICATION RETRIEVAL] Invalid Communication/${communicationId}: missing contentReference`);
    return <http:InternalServerError>{
        body: {
            "resourceType": "OperationOutcome",
            "issue": [{
                "severity": "error",
                "code": "exception",
                "diagnostics": string `Invalid Communication resource: missing payload.contentReference`
            }]
        }
    };
}

// Extract resource type from a FHIR reference string (e.g., "Encounter/clientA-3" → "Encounter")
function extractResourceTypeFromReference(string reference) returns string {
    int? slashIndex = reference.indexOf("/");
    if slashIndex is int && slashIndex > 0 {
        return reference.substring(0, slashIndex);
    }
    return "Unknown";
}
