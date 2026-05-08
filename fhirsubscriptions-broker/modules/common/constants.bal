// Application-wide constants shared across modules

// Token expiry duration in seconds (1 hour)
public const int TOKEN_EXPIRY_SECONDS = 3600;

// JWKS cache configuration
public const int JWKS_CACHE_CAPACITY = 10;
public const decimal JWKS_CACHE_EVICTION_FACTOR = 0.25;
public const string JWKS_CACHE_EVICTION_POLICY = "LRU";
public const int JWKS_CACHE_MAX_AGE = 3600;

// JWT clock skew allowance in seconds
public const decimal JWT_CLOCK_SKEW = 60;

// Subscription token configuration
public const int SUBSCRIPTION_TOKEN_EXPIRY_SECONDS = 86400; // 24 hours
public const string SUBSCRIPTION_TOKEN_HEADER = "X-Subscription-Token";

// Basic resource for persistent event counter state
// ID format: state-{clientId}, stores current sequence number
public const string EVENT_STATE_SYSTEM = "https://broker.example.org/codes";
public const string EVENT_STATE_CODE = "sequence-counter";
public const string EVENT_STATE_SEQUENCE_URL = "https://broker.example.org/fhir/StructureDefinition/current-sequence";
public const string EVENT_STATE_TOTAL_URL = "https://broker.example.org/fhir/StructureDefinition/total-events";

// Default page size for $events pagination
public const int DEFAULT_EVENTS_PAGE_SIZE = 20;

// Group-based subscription architecture: resource type to group ID suffix mapping
// Group ID format: {clientId}-{suffix} (e.g., "client101-encounters")
public final readonly & map<string> RESOURCE_TYPE_GROUP_SUFFIXES = {
    "Encounter": "encounters",
    "Observation": "observations",
    "DiagnosticReport": "diagnosticreports",
    "MedicationRequest": "medicationrequests",
    "Condition": "conditions",
    "AllergyIntolerance": "allergyintolerances",
    "Procedure": "procedures",
    "Immunization": "immunizations",
    "CarePlan": "careplans",
    "CareTeam": "careteams",
    "DocumentReference": "documentreferences"
};
