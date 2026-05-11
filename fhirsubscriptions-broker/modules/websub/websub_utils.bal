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

// WebSub Hub Integration Utilities

import ballerina/http;
import ballerina/log;
import ballerina/time;
import ballerina/uuid;

import wso2healthcare/broker.audit;
import wso2healthcare/broker.common;

// Disables TLS certificate verification for the WebSub hub client. Defaults to
// false so HTTPS hubs are verified; only set to true for local/dev hubs with
// self-signed certs.
configurable boolean disableHubTlsVerification = false;

function buildHubClient(string webSubHubUrl) returns http:Client|error {
    if disableHubTlsVerification {
        return new (webSubHubUrl, {
            secureSocket: {
                enable: false
            }
        });
    }
    return new (webSubHubUrl);
}

// Register a topic with the WebSub hub
public function registerWebSubTopic(string topicId, string webSubHubUrl) returns error? {
    log:printInfo(string `[WEBSUB REGISTER] Attempting to register topic: ${topicId} at ${webSubHubUrl}`);

    http:Client hubClient = check buildHubClient(webSubHubUrl);

    string body = string `hub.mode=register&hub.topic=${common:urlEncode(topicId)}`;
    log:printInfo(string `[WEBSUB REGISTER] Request body: ${body}`);

    http:Response|error responseResult = hubClient->post("", body, headers = {
        "Content-Type": "application/x-www-form-urlencoded"
    });

    if responseResult is error {
        log:printError(string `[WEBSUB REGISTER] Failed: ${responseResult.message()}`, responseResult);
        audit:auditWebSubOperation("topic-register", topicId, false, responseResult.message());
        return error(string `Failed to register topic: ${responseResult.message()}`);
    }

    http:Response response = responseResult;
    string|error responseBody = response.getTextPayload();
    if responseBody is string {
        log:printInfo(string `[WEBSUB REGISTER] status=${response.statusCode}, body=${responseBody}`);
    } else {
        log:printInfo(string `[WEBSUB REGISTER] status=${response.statusCode}, body=<unavailable>`);
    }

    if response.statusCode != 200 && response.statusCode != 201 && response.statusCode != 202 && response.statusCode != 204 && response.statusCode != 409 {
        string errorMsg = responseBody is string ? responseBody : "Unknown error";
        log:printError(string `[WEBSUB REGISTER] Hub rejected registration: status=${response.statusCode}`);
        audit:auditWebSubOperation("topic-register", topicId, false, string `Hub rejected: ${errorMsg}`);
        return error(string `WebSub hub rejected registration: ${errorMsg}`);
    }

    log:printInfo(string `[WEBSUB REGISTER] Topic '${topicId}' registered successfully`);
    audit:auditWebSubOperation("topic-register", topicId, true);
    return;
}

// Subscribe to a topic on the WebSub hub
public function subscribeToWebSubHub(string topicId, string callbackUrl, string? sharedSecret, string webSubHubUrl) returns error? {
    log:printInfo(string `[WEBSUB SUBSCRIBE] Attempting to subscribe topic: ${topicId}, callback: ${callbackUrl}`);

    http:Client hubClient = check buildHubClient(webSubHubUrl);

    string secret = (sharedSecret is string && sharedSecret.trim() != "") ? sharedSecret : uuid:createType4AsString();
    string body = string `hub.mode=subscribe&hub.topic=${common:urlEncode(topicId)}&hub.callback=${common:urlEncode(callbackUrl)}&hub.secret=${common:urlEncode(secret)}`;
    string redactedBody = string `hub.mode=subscribe&hub.topic=${common:urlEncode(topicId)}&hub.callback=${common:urlEncode(callbackUrl)}&hub.secret=[REDACTED]`;
    log:printInfo(string `[WEBSUB SUBSCRIBE] Request body: ${redactedBody}`);

    http:Response|error responseResult = hubClient->post("", body, headers = {
        "Content-Type": "application/x-www-form-urlencoded"
    });

    if responseResult is error {
        log:printError(string `[WEBSUB SUBSCRIBE] Failed: ${responseResult.message()}`, responseResult);
        audit:auditWebSubOperation("topic-subscribe", topicId, false, responseResult.message());
        return error(string `Failed to subscribe: ${responseResult.message()}`);
    }

    http:Response response = responseResult;
    string|error responseBody = response.getTextPayload();
    if responseBody is string {
        log:printInfo(string `[WEBSUB SUBSCRIBE] status=${response.statusCode}, body=${responseBody}`);
    } else {
        log:printInfo(string `[WEBSUB SUBSCRIBE] status=${response.statusCode}, body=<unavailable>`);
    }

    if response.statusCode != 200 && response.statusCode != 202 && response.statusCode != 204 {
        string errorMsg = responseBody is string ? responseBody : "Unknown error";
        log:printError(string `[WEBSUB SUBSCRIBE] Hub rejected subscription: status=${response.statusCode}`);
        audit:auditWebSubOperation("topic-subscribe", topicId, false, string `Hub rejected: ${errorMsg}`);
        return error(string `WebSub hub rejected subscription: ${errorMsg}`);
    }

    log:printInfo(string `[WEBSUB SUBSCRIBE] Successfully subscribed to topic '${topicId}'`);
    audit:auditWebSubOperation("topic-subscribe", topicId, true);
    return;
}

// Publish notification to WebSub hub
public function publishToWebSubHub(string topicId, SubscriptionNotificationBundle bundle, string webSubHubUrl, map<string[]> clientNotificationHeaders) returns error? {
    http:Client hubClient = check buildHubClient(webSubHubUrl);

    string hubUrl = string `?hub.mode=publish&hub.topic=${common:urlEncode(topicId)}`;

    // Build headers (content type + optional client headers)
    map<string> requestHeaders = {
        "Content-Type": "application/json"
    };

    string[]? clientHeaders = clientNotificationHeaders[topicId];
    if clientHeaders is string[] {
        foreach string headerLine in clientHeaders {
            int? separatorIndexOpt = headerLine.indexOf(":");
            if separatorIndexOpt is int && separatorIndexOpt > 0 {
                string headerName = headerLine.substring(0, separatorIndexOpt).trim();
                string headerValue = headerLine.substring(separatorIndexOpt + 1).trim();
                if headerName != "" {
                    requestHeaders[headerName] = headerValue;
                }
            }
        }
    }

    http:Response|error responseResult = hubClient->post(hubUrl, bundle, headers = requestHeaders);

    if responseResult is error {
        log:printError(string `[WEBSUB PUBLISH] Failed: ${responseResult.message()}`, responseResult);
        audit:auditWebSubOperation("topic-publish", topicId, false, responseResult.message());
        return error(string `Failed to publish notification: ${responseResult.message()}`);
    }

    http:Response response = responseResult;

    if response.statusCode != 200 && response.statusCode != 202 && response.statusCode != 204 {
        audit:auditWebSubOperation("topic-publish", topicId, false, string `Hub returned status: ${response.statusCode}`);
        return error(string `WebSub hub returned status code: ${response.statusCode}`);
    }

    audit:auditWebSubOperation("topic-publish", topicId, true);
    return;
}

// Create FHIR subscription notification bundle with reference to stored notification
// Focus reference format: https://broker.example.org/fhir/{resourceType}/{resourceId}
public function createSubscriptionNotificationBundle(
    string topicId,
    int eventNumber,
    int eventsSinceStart,
    string resourceType,
    string resourceId,
    string brokerBaseUrl
) returns SubscriptionNotificationBundle {
    string currentTimestamp = time:utcToString(time:utcNow());

    // Focus reference points directly to the resource via broker's FHIR endpoint
    string focusReference = string `${brokerBaseUrl}/${resourceType}/${resourceId}`;

    SubscriptionNotificationBundle bundle = {
        resourceType: "Bundle",
        'type: "subscription-notification",
        timestamp: currentTimestamp,
        entry: [
            {
                fullUrl: string `urn:uuid:notification-status-${eventNumber}`,
                'resource: {
                    resourceType: "SubscriptionStatus",
                    status: "active",
                    'type: "event-notification",
                    eventsSinceSubscriptionStart: eventsSinceStart,
                    notificationEvent: [
                        {
                            eventNumber: eventNumber,
                            timestamp: currentTimestamp,
                            focus: {
                                reference: focusReference,
                                'type: resourceType
                            }
                        }
                    ],
                    subscription: {
                        reference: string `${brokerBaseUrl}/Subscription/${topicId}`
                    },
                    topic: string `http://hl7.org/fhir/SubscriptionTopic/${topicId}`
                }
            }
        ]
    };

    return bundle;
}
