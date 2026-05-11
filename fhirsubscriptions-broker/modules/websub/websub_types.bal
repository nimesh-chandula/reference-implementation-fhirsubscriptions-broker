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

// WebSub and FHIR Subscription Notification types

// FHIR Subscription Notification Bundle types
public type SubscriptionNotificationBundle record {|
    string resourceType;
    string 'type;
    string timestamp;
    BundleEntry[] entry;
|};

public type BundleEntry record {|
    string fullUrl;
    SubscriptionStatus 'resource;
|};

public type SubscriptionStatus record {|
    string resourceType;
    string status;
    string 'type;
    int eventsSinceSubscriptionStart;
    NotificationEvent[] notificationEvent;
    SubscriptionReference subscription;
    string topic;
|};

public type NotificationEvent record {|
    int eventNumber;
    string timestamp;
    FocusReference focus;
|};

public type FocusReference record {|
    string reference;
    string 'type;
|};

public type SubscriptionReference record {|
    string reference;
|};
