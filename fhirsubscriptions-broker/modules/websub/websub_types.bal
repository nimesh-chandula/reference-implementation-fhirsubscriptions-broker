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
