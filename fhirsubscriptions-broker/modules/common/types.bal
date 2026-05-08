// Type definitions shared across modules

// Patient ID mapping between FHIR and broker-scoped IDs
public type PatientIdMapping record {|
    string fhirPatientId;
    string brokerScopedPatientId;
|};

// Request to create a patient ID mapping via MPI
public type MPIMappingRequest record {|
    string systemId;
    string systemPatientId;
    string brokerScopedPatientId;
|};

// Response for a mapping operation
public type MappingResponse record {|
    string message;
    PatientIdMapping mapping;
|};

// Demographics information for patient matching
public type ClientDemographics record {|
    string family;
    string[] given;
    string birthDate;
    string? gender = ();
|};

// Client registration information for OAuth/SMART authentication
public type ClientRegistration record {|
    string issuer;
    string jwksUri;
    string[]? allowedScopes = ();
|};

// Information extracted from validated client assertion (JWT)
public type ClientAssertionInfo record {|
    string clientId;
    map<json> claims;
    ClientRegistration registration;
|};

// FHIR authorization detail for SMART on FHIR
public type AuthorizationDetail record {|
    string 'type;
    json[] fhirContext;
    string[] actions;
    string resourceType;
|};

// Subscription request payload
public type SubscriptionRequest record {|
    string brokerScopedPatientId;
    string callbackUrl;
|};

// Subscription response
public type SubscriptionResponse record {|
    string message;
    string topic;
|};

// ============================================================================
// GROUP-BASED SUBSCRIPTION TYPES
// ============================================================================

// Result of querying FHIR Groups for a patient's memberships
public type GroupMembershipResult record {|
    string clientId;        // Client ID extracted from group ID prefix
    string resourceType;    // Resource type (e.g., "Encounter") extracted from group ID suffix
    string groupId;         // Full group ID (e.g., "client101-encounters")
|};

// ============================================================================
// STANDARD FHIR NOTIFICATION TYPES
// ============================================================================

// Patient identifier extracted from FHIR resources
public type PatientIdentifier record {|
    string system;      // FHIR identifier.system URI (e.g., "http://hospital-h1.org/patient-ids")
    string value;       // FHIR identifier.value (e.g., "444222222")
|};

// Extracted patient information from notification Bundle
public type ExtractedPatientInfo record {|
    string? systemId = ();                  // Short system ID (e.g., "H001") mapped from URI
    string? systemPatientId = ();           // Patient ID in that system
    string? brokerScopedPatientId = ();     // Resolved broker-scoped patient ID
    PatientIdentifier? identifier = ();     // Original FHIR identifier
    string? subjectReference = ();          // Original subject.reference (e.g., "Patient/123")
|};

// Single filter criterion parsed from _criteria.extension[].valueString
// Format: "ResourceType?patient=Patient/ID&trigger=feed-event"
public type FilterCriterion record {|
    string? resourceType = ();      // Resource type filter (e.g., "Encounter", "Observation")
    string? patientReference = ();  // Patient reference (e.g., "Patient/UP001")
    string? trigger = ();           // Trigger type (e.g., "feed-event")
|};

// Subscription criteria parsed from FHIR Subscription resource
// Supports multi-resource topic architecture with multiple filter criteria
public type SubscriptionCriteria record {|
    string subscriptionId;              // FHIR Subscription resource ID
    FilterCriterion[] filterCriteria;   // Array of filter criteria (supports multiple resource types)
    string callbackUrl;                 // Client callback endpoint
    string[]? headers = ();             // Optional headers to include in notifications
    string? payloadContent = ();        // Payload content type (e.g., "id-only", "full-resource")
    string? clientId = ();              // Client ID (from broker's local tracking)
|};

// Result of validating a notification against subscription criteria
public type NotificationValidationResult record {|
    boolean isValid;                        // Whether notification matches subscription
    string? subscriptionId = ();            // ID of the matching subscription
    string[]? matchedResourceTypes = ();    // Resource types that matched
    string? reason = ();                    // Reason for validation result
|};

// Response when demographics are required for patient identification
public type DemographicsRequiredResponse record {|
    string status = "demographics_required";
    string message;
    PatientIdentifier? extractedIdentifier = ();
    string submitTo;
    string[] requiredFields;
|};

// ============================================================================
// TOKEN EXCHANGE TYPES (OAuth 2.0 Token Exchange - RFC 8693)
// ============================================================================

// Token exchange request parameters
public type TokenExchangeRequest record {|
    string grant_type;           // "urn:ietf:params:oauth:grant-type:token-exchange"
    string subject_token;        // The ID token to exchange (JWT from Asgardeo)
    string subject_token_type;   // "urn:ietf:params:oauth:token-type:id_token"
    string demographics;         // JSON string with patient demographics
|};

// Token exchange success response
public type TokenExchangeResponse record {|
    string access_token;         // Broker-issued JWT
    string token_type;           // "bearer"
    int expires_in;              // Token lifetime in seconds
    string scope;                // Granted scopes
    string patient;              // Matched patient ID
|};

// Token exchange error response
public type TokenExchangeErrorResponse record {|
    string 'error;               // Error code (e.g., "invalid_token")
    string error_description;    // Human-readable error description
|};

// Validated ID token information from Asgardeo
public type ValidatedIdTokenInfo record {|
    string subject;              // User subject (sub claim)
    string issuer;               // Token issuer (iss claim)
    map<json> claims;            // All token claims
|};

// ============================================================================
// SUBSCRIPTION TOKEN TYPES
// ============================================================================

// Subscription token metadata stored per client
public type SubscriptionTokenInfo record {|
    string subscriptionId;           // FHIR Subscription resource ID
    string clientId;                 // Client that owns the subscription
    string token;                    // The signed JWT subscription token
    string brokerScopedPatientId;    // Patient this subscription covers
    int issuedAt;                    // Unix timestamp (seconds)
    int expiresAt;                   // Unix timestamp (seconds)
|};

// Result of validating a subscription access token
public type ValidatedSubscriptionToken record {|
    string clientId;                 // Client ID from token
    string subscriptionId;           // Subscription ID from token
    string patient;                  // Broker-scoped patient ID from token
    string[]? resourceTypes = ();    // Allowed resource types
    map<json> claims = {};           // Verified token claims (JWKS-validated)
|};

// Authorization decision result from authz service
public type AuthzResult record {|
    boolean isAuthorized;            // Whether access is granted
    string? scope = ();              // Scope level: PATIENT, PRACTITIONER, PRIVILEGED
|};

// ============================================================================
// MULTI-PATIENT NOTIFICATION TYPES
// ============================================================================

// Patient group containing the Patient resource and all associated clinical resources
public type PatientResourceGroup record {|
    string localPatientRef;             // Local patient reference (e.g., "Patient/local-patient-1")
    map<json> patientResource;          // The Patient resource itself
    map<json>[] clinicalResources;      // Clinical resources (Encounter, Observation, etc.) for this patient
    PatientIdentifier? identifier = (); // Extracted identifier from Patient resource
    ClientDemographics? demographics = ();  // Extracted demographics for member matching
|};

// Result of resolving a patient through MPI
public type PatientResolutionResult record {|
    string localPatientRef;             // Original local reference
    string? brokerScopedPatientId = (); // Resolved broker-scoped ID (null if resolution failed)
    string status;                      // "resolved" | "matched" | "registered" | "failed" | "demographics_required"
    string? message = ();               // Additional details
    map<json>[] clinicalResources = []; // Clinical resources to forward
|};

// ============================================================================
// EVENT STATE TYPES (used by broker_state and modules/fhir)
// ============================================================================

// Event counter state for a client
public type ClientEventState record {|
    int lastEventNumber;                // Last event number assigned for this client
    int totalEventsSinceStart;          // Total events since subscription started
|};
