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

// Global state management for the broker application
// In-memory caches and accessor functions
// Note: FHIR server is the source of truth for Groups and Subscriptions

import ballerina/log;

// WebSub hub clients for each topic (clientId -> list of subscriber callback URLs)
public map<string[]> topicSubscribers = {};

// Client subscription tracking (broker scoped patient ID -> list of client IDs)
// Cache for quick lookups; source of truth is FHIR Group membership
public map<string[]> clientSubscriptions = {};

// Notification headers per client topic (clientId -> list of header strings)
public map<string[]> clientNotificationHeaders = {};

// Client subscription ID cache: clientId -> FHIR Subscription resource ID
// One subscription per client in the Group-based architecture
public map<string> clientSubscriptionIds = {};

// Event counter tracking: clientId -> ClientEventState
// Tracks incremental event numbers per client for notification retrieval
public map<ClientEventState> clientEventCounters = {};

// User to client app mapping (user sub from identity token → client app ID from azp)
// Populated during token exchange, used to resolve client app from Asgardeo access tokens
// Interim fallback until 2nd Asgardeo app includes client_app_id claim in access tokens
map<string> userClientAppMapping = {};

// User sub to broker-scoped patient ID mapping
// Populated during token exchange, used as in-memory fallback when FHIR identifier lookup fails
map<string> userPatientMapping = {};

// Store mapping from user sub to client app ID
public function setUserClientApp(string userSub, string clientAppId) {
    lock {
        userClientAppMapping[userSub] = clientAppId;
    }
    log:printInfo(string `[CLIENT MAPPING] Mapped user ${userSub} to client app ${clientAppId}`);
}

// Look up client app ID for a user sub
public function getUserClientApp(string userSub) returns string? {
    lock {
        return userClientAppMapping[userSub];
    }
}

// Store mapping from user sub to broker-scoped patient ID
public function setUserPatient(string userSub, string brokerScopedPatientId) {
    lock {
        userPatientMapping[userSub] = brokerScopedPatientId;
    }
    log:printInfo(string `[PATIENT MAPPING] Mapped user ${userSub} to patient ${brokerScopedPatientId}`);
}

// Look up broker-scoped patient ID for a user sub
public function getUserPatient(string userSub) returns string? {
    lock {
        return userPatientMapping[userSub];
    }
}

// Generic helper to add a value to a string array map if not already present
function addToStringArrayMap(map<string[]> targetMap, string key, string value) {
    string[]? existing = targetMap[key];
    if existing is () {
        targetMap[key] = [value];
    } else {
        foreach string item in existing {
            if item == value {
                return;
            }
        }
        existing.push(value);
        targetMap[key] = existing;
    }
}

// Add a subscriber URL to a topic
public function addTopicSubscriber(string topicId, string callbackUrl) {
    addToStringArrayMap(topicSubscribers, topicId, callbackUrl);
}

// Add a client subscription for a broker-scoped patient ID
public function addClientSubscription(string brokerScopedPatientId, string clientId) {
    addToStringArrayMap(clientSubscriptions, brokerScopedPatientId, clientId);
}

// Track client subscription with locking (used during token issuance)
public function trackClientSubscription(string clientId, string brokerScopedPatientId) {
    lock {
        addToStringArrayMap(clientSubscriptions, brokerScopedPatientId, clientId);
    }
    log:printInfo(string `[CLIENT TRACKING] Subscription tracked: client=${clientId}, patient=${brokerScopedPatientId}`);
}
