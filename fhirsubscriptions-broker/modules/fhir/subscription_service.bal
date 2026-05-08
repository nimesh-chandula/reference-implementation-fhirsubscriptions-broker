// Subscription Service - FHIR Server interaction for Subscription resources
// Owns the FHIR server HTTP client used by every module that talks to FHIR.

import ballerina/http;
import ballerina/log;

import wso2healthcare/broker.audit;
import wso2healthcare/broker.common;

// ============================================================================
// FHIR SERVER CLIENT
// `public` so other modules (auth, mpi, tokens, root handlers) can reuse it
// without redeclaring the URL or duplicating Config.toml entries.
// ============================================================================

public configurable string fhirServerUrl = "http://localhost:9090/fhir/r4";

// Broker base URL used when building FHIR resource references.
public configurable string brokerBaseUrl = "https://broker.example.org/fhir";

public final http:Client fhirServerClient = check new (fhirServerUrl);

// ============================================================================
// SUBSCRIPTION CRUD OPERATIONS
// ============================================================================

// Create a Subscription resource in the FHIR server
public function createSubscriptionInFhirServer(http:Client fhirClient, json subscription) returns string|error {
    log:printInfo("[SUBSCRIPTION_SERVICE] Creating subscription in FHIR server");

    http:Request req = new;
    req.setJsonPayload(subscription);
    req.setHeader("Content-Type", "application/fhir+json");
    req.setHeader("Accept", "application/fhir+json");

    http:Response response = check fhirClient->/Subscription.post(req);

    if response.statusCode != 201 && response.statusCode != 200 {
        string|error errorBody = response.getTextPayload();
        string errorMsg = errorBody is string ? errorBody : "Unknown error";
        log:printError(string `[SUBSCRIPTION_SERVICE] FHIR server returned status ${response.statusCode}: ${errorMsg}`);
        audit:auditFhirServerOperation("subscription-create", "Subscription", false, errorMsg);
        return error(string `Failed to create subscription: ${errorMsg}`);
    }

    string|http:HeaderNotFoundError locationHeader = response.getHeader("Location");
    if locationHeader is string {
        log:printInfo(string `[SUBSCRIPTION_SERVICE] Location header: ${locationHeader}`);
        string subscriptionId = extractIdFromLocation(locationHeader);
        log:printInfo(string `[SUBSCRIPTION_SERVICE] Created subscription with ID: ${subscriptionId}`);
        audit:auditFhirServerOperation("subscription-create", string `Subscription/${subscriptionId}`, true);
        return subscriptionId;
    }

    json|error responseBody = response.getJsonPayload();
    if responseBody is map<json> {
        json? idField = responseBody["id"];
        if idField is string {
            log:printInfo(string `[SUBSCRIPTION_SERVICE] Extracted subscription ID from body: ${idField}`);
            audit:auditFhirServerOperation("subscription-create", string `Subscription/${idField}`, true);
            return idField;
        }
    }

    return error("Could not extract subscription ID from response");
}

// Get a Subscription resource from the FHIR server by ID.
// Returns the resource on 2xx, () on 404 (NotFound), or an error for any other failure.
public function getSubscriptionFromFhirServer(http:Client fhirClient, string subscriptionId) returns map<json>?|error {
    log:printInfo(string `[SUBSCRIPTION_SERVICE] Retrieving subscription: ${subscriptionId}`);

    map<string|string[]> headers = {"Accept": "application/fhir+json"};
    http:Response response = check fhirClient->/Subscription/[subscriptionId].get(headers);

    if response.statusCode >= 200 && response.statusCode < 300 {
        json payload = check response.getJsonPayload();
        if payload !is map<json> {
            return error(string `Subscription/${subscriptionId} response is not a JSON object`);
        }
        log:printInfo(string `[SUBSCRIPTION_SERVICE] Retrieved subscription: ${subscriptionId}`);
        return payload;
    }

    if response.statusCode == 404 {
        log:printInfo(string `[SUBSCRIPTION_SERVICE] Subscription/${subscriptionId} not found (404)`);
        return ();
    }

    string|error body = response.getTextPayload();
    string reason = body is string ? body : "unknown";
    log:printWarn(string `[SUBSCRIPTION_SERVICE] Subscription/${subscriptionId} GET returned ${response.statusCode}: ${reason}`);
    return error(string `Subscription GET failed for ${subscriptionId} (status: ${response.statusCode}): ${reason}`);
}

// ============================================================================
// PATIENT SYNC TO FHIR SERVER
// ============================================================================

// Ensure a minimal Patient resource exists in the FHIR server (for Group member references)
public function ensurePatientInFhirServer(http:Client fhirClient, string brokerScopedPatientId, common:ClientDemographics? demographics = ()) returns error? {
    log:printInfo(string `[FHIR PATIENT SYNC] Ensuring Patient/${brokerScopedPatientId} exists in FHIR server`);

    json patientResource;
    if demographics is common:ClientDemographics {
        patientResource = {
            "resourceType": "Patient",
            "id": brokerScopedPatientId,
            "name": [{"family": demographics.family, "given": demographics.given}],
            "birthDate": demographics.birthDate
        };
        if demographics.gender is string {
            patientResource = check patientResource.mergeJson({"gender": demographics.gender});
        }
    } else {
        patientResource = {
            "resourceType": "Patient",
            "id": brokerScopedPatientId
        };
    }

    map<string|string[]> headers = {"Content-Type": "application/fhir+json"};
    http:Response|error getResponse = fhirClient->/Patient/[brokerScopedPatientId].get();

    if getResponse is error {
        audit:auditFhirServerOperation("patient-sync", string `Patient/${brokerScopedPatientId}`, false, getResponse.message());
        return error(string `Patient GET failed for Patient/${brokerScopedPatientId}: ${getResponse.message()}`);
    }

    if getResponse.statusCode >= 200 && getResponse.statusCode < 300 {
        http:Response|error putResponse = fhirClient->/Patient/[brokerScopedPatientId].put(patientResource, headers);
        if putResponse is error {
            audit:auditFhirServerOperation("patient-update", string `Patient/${brokerScopedPatientId}`, false, putResponse.message());
            return error(string `Patient update failed for Patient/${brokerScopedPatientId}: ${putResponse.message()}`);
        }
        if putResponse.statusCode < 200 || putResponse.statusCode >= 300 {
            string|error body = putResponse.getTextPayload();
            string reason = body is string ? body : "unknown";
            log:printWarn(string `[FHIR PATIENT SYNC] Patient update returned ${putResponse.statusCode}: ${reason}`);
            audit:auditFhirServerOperation("patient-update", string `Patient/${brokerScopedPatientId}`, false, reason);
            return error(string `Patient update failed (status: ${putResponse.statusCode}): ${reason}`);
        }
        log:printInfo(string `[FHIR PATIENT SYNC] Patient/${brokerScopedPatientId} updated (status: ${putResponse.statusCode})`);
        audit:auditFhirServerOperation("patient-update", string `Patient/${brokerScopedPatientId}`, true);
        return;
    }

    if getResponse.statusCode == 404 {
        http:Response|error postResponse = fhirClient->/Patient.post(patientResource, headers);
        if postResponse is error {
            audit:auditFhirServerOperation("patient-create", string `Patient/${brokerScopedPatientId}`, false, postResponse.message());
            return error(string `Patient create failed for Patient/${brokerScopedPatientId}: ${postResponse.message()}`);
        }
        if postResponse.statusCode < 200 || postResponse.statusCode >= 300 {
            string|error body = postResponse.getTextPayload();
            string reason = body is string ? body : "unknown";
            log:printWarn(string `[FHIR PATIENT SYNC] Patient create returned ${postResponse.statusCode}: ${reason}`);
            audit:auditFhirServerOperation("patient-create", string `Patient/${brokerScopedPatientId}`, false, reason);
            return error(string `Patient create failed (status: ${postResponse.statusCode}): ${reason}`);
        }
        log:printInfo(string `[FHIR PATIENT SYNC] Patient/${brokerScopedPatientId} created (status: ${postResponse.statusCode})`);
        audit:auditFhirServerOperation("patient-create", string `Patient/${brokerScopedPatientId}`, true);
        return;
    }

    string|error body = getResponse.getTextPayload();
    string reason = body is string ? body : "unknown";
    log:printWarn(string `[FHIR PATIENT SYNC] Patient GET returned ${getResponse.statusCode}: ${reason}`);
    audit:auditFhirServerOperation("patient-sync", string `Patient/${brokerScopedPatientId}`, false, reason);
    return error(string `Patient GET failed (status: ${getResponse.statusCode}): ${reason}`);
}

// Add or update Asgardeo sub and client app ID identifiers on a Patient resource
public function addIdentifiersToPatient(http:Client fhirClient, string brokerScopedPatientId,
    string asgardeoSub, string clientAppId) returns error? {
    log:printInfo(string `[FHIR IDENTIFIERS] Adding identifiers to Patient/${brokerScopedPatientId}`);

    http:Response|error getResponse = fhirClient->/Patient/[brokerScopedPatientId].get();
    if getResponse is error {
        return error(string `Failed to GET Patient/${brokerScopedPatientId}: ${getResponse.message()}`);
    }

    if getResponse.statusCode < 200 || getResponse.statusCode >= 300 {
        return error(string `Patient/${brokerScopedPatientId} not found (status: ${getResponse.statusCode})`);
    }

    json|error bodyJson = getResponse.getJsonPayload();
    if bodyJson is error || bodyJson !is map<json> {
        return error("Failed to parse Patient resource");
    }

    map<json> patientResource = <map<json>>bodyJson;

    json[] identifiers = [];
    json? existingIds = patientResource["identifier"];
    if existingIds is json[] {
        identifiers = existingIds.clone();
    }

    identifiers = addOrUpdateIdentifier(identifiers, "urn:broker:asgardeo-sub", asgardeoSub);
    identifiers = addOrUpdateIdentifier(identifiers, "urn:broker:client-app-id", clientAppId);

    patientResource["identifier"] = identifiers;

    map<string|string[]> headers = {"Content-Type": "application/fhir+json"};
    http:Response putResponse = check fhirClient->/Patient/[brokerScopedPatientId].put(patientResource, headers);
    if putResponse.statusCode >= 200 && putResponse.statusCode < 300 {
        log:printInfo(string `[FHIR IDENTIFIERS] Patient/${brokerScopedPatientId} identifiers updated`);
        audit:auditFhirServerOperation("patient-identifier-update", string `Patient/${brokerScopedPatientId}`, true);
    } else {
        string|error body = putResponse.getTextPayload();
        string reason = body is string ? body : "unknown";
        log:printWarn(string `[FHIR IDENTIFIERS] PUT failed (${putResponse.statusCode}): ${reason}`);
        audit:auditFhirServerOperation("patient-identifier-update", string `Patient/${brokerScopedPatientId}`, false);
        return error(string `Patient identifier update failed (status: ${putResponse.statusCode}): ${reason}`);
    }
}

// Add or update a single identifier in a json[] by system URI
function addOrUpdateIdentifier(json[] identifiers, string system, string value) returns json[] {
    foreach int i in 0 ..< identifiers.length() {
        json id = identifiers[i];
        if id is map<json> {
            json? sys = id["system"];
            if sys is string && sys == system {
                map<json> updated = id.clone();
                updated["value"] = value;
                identifiers[i] = updated;
                return identifiers;
            }
        }
    }
    identifiers.push({"system": system, "value": value});
    return identifiers;
}

// Resolve broker-scoped patient ID and client app ID from the 2nd Asgardeo app's sub claim
public function resolvePatientBySub(http:Client fhirClient, string asgardeoSub) returns [string, string?]|error {
    log:printInfo(string `[FHIR LOOKUP] Resolving patient by sub: ${asgardeoSub}`);

    string searchPath = string `/Patient?identifier=${asgardeoSub}`;
    json|error result = fhirClient->get(searchPath);

    if result is error {
        return resolvePatientFromCache(asgardeoSub, result.message());
    }

    if result !is map<json> {
        return resolvePatientFromCache(asgardeoSub, "Invalid FHIR search response");
    }

    json? totalJson = result["total"];
    if totalJson is int && totalJson == 0 {
        return resolvePatientFromCache(asgardeoSub, string `No Patient found for sub: ${asgardeoSub}`);
    }

    json? entryJson = result["entry"];
    if entryJson !is json[] || entryJson.length() == 0 {
        return resolvePatientFromCache(asgardeoSub, string `No Patient entries found for sub: ${asgardeoSub}`);
    }

    json firstEntry = entryJson[0];
    if firstEntry !is map<json> {
        return error("Invalid Bundle entry");
    }
    json? resourceJson = firstEntry["resource"];
    if resourceJson !is map<json> {
        return error("Missing resource in Bundle entry");
    }

    json? idJson = resourceJson["id"];
    if idJson !is string {
        return error("Missing id in Patient resource");
    }
    string brokerScopedPatientId = idJson;

    string? clientAppId = ();
    json? idsJson = resourceJson["identifier"];
    if idsJson is json[] {
        foreach json id in idsJson {
            if id is map<json> {
                json? sys = id["system"];
                json? val = id["value"];
                if sys is string && sys == "urn:broker:client-app-id" && val is string {
                    clientAppId = val;
                    break;
                }
            }
        }
    }

    common:setUserPatient(asgardeoSub, brokerScopedPatientId);

    log:printInfo(string `[FHIR LOOKUP] Resolved: patient=${brokerScopedPatientId}, clientApp=${clientAppId ?: "none"}`);
    return [brokerScopedPatientId, clientAppId];
}

// Fall back to in-memory cache when FHIR identifier lookup fails
function resolvePatientFromCache(string asgardeoSub, string fhirError) returns [string, string?]|error {
    string? cachedPatient = common:getUserPatient(asgardeoSub);
    if cachedPatient is string {
        string? cachedClientApp = common:getUserClientApp(asgardeoSub);
        log:printInfo(string `[FHIR LOOKUP] FHIR lookup failed, resolved from in-memory cache: patient=${cachedPatient}`);
        return [cachedPatient, cachedClientApp];
    }
    return error(fhirError);
}

// ============================================================================
// GROUP-BASED SUBSCRIPTION CRUD
// ============================================================================

// Build a group ID from clientId and resource type (e.g., "client101-encounters")
function buildGroupId(string clientId, string resourceType) returns string|error {
    string? suffix = common:RESOURCE_TYPE_GROUP_SUFFIXES[resourceType];
    if suffix is () {
        return error(string `Unsupported resource type for group: ${resourceType}`);
    }
    return string `${clientId}-${suffix}`;
}

// Parse a group ID to extract clientId and resourceType
function parseGroupId(string groupId) returns [string, string]|error {
    foreach string resourceType in common:RESOURCE_TYPE_GROUP_SUFFIXES.keys() {
        string suffix = common:RESOURCE_TYPE_GROUP_SUFFIXES.get(resourceType);
        string expectedEnding = string `-${suffix}`;
        if groupId.endsWith(expectedEnding) {
            string clientId = groupId.substring(0, groupId.length() - expectedEnding.length());
            if clientId.length() > 0 {
                return [clientId, resourceType];
            }
        }
    }
    return error(string `Cannot parse group ID: ${groupId}`);
}

// Get or create a FHIR Group for a client's resource type subscription
public function getOrCreateResourceGroup(http:Client fhirClient, string clientId, string resourceType) returns string|error {
    string groupId = check buildGroupId(clientId, resourceType);
    log:printInfo(string `[GROUP] Getting or creating Group/${groupId}`);

    http:Response|error getResponse = fhirClient->/Group/[groupId].get();

    if getResponse is http:Response && getResponse.statusCode >= 200 && getResponse.statusCode < 300 {
        log:printInfo(string `[GROUP] Group/${groupId} already exists`);
        return groupId;
    }

    log:printInfo(string `[GROUP] Creating new Group/${groupId}`);
    json groupResource = {
        "resourceType": "Group",
        "id": groupId,
        "type": "person",
        "actual": true,
        "name": string `${clientId} ${resourceType} subscribers`,
        "member": []
    };

    map<string|string[]> headers = {"Content-Type": "application/fhir+json"};
    http:Response postResponse = check fhirClient->/Group.post(groupResource, headers);

    if postResponse.statusCode >= 200 && postResponse.statusCode < 300 {
        log:printInfo(string `[GROUP] Group/${groupId} created successfully`);
        audit:auditFhirServerOperation("group-create", string `Group/${groupId}`, true);
        return groupId;
    }

    string|error body = postResponse.getTextPayload();
    audit:auditFhirServerOperation("group-create", string `Group/${groupId}`, false, body is string ? body : "unknown");
    return error(string `Failed to create Group/${groupId}: ${body is string ? body : "unknown"}`);
}

// Add a patient to a FHIR Group (idempotent, with optimistic-concurrency retry).
// Concurrent token-exchange flows for the same client/resourceType race on the same Group.
// Capture the version (ETag, falling back to meta.versionId), PUT with If-Match, and on
// 412/409 re-fetch and retry — the existing patientRef dedupe doubles as the merge step.
public function addPatientToGroup(http:Client fhirClient, string groupId, string brokerScopedPatientId) returns error? {
    log:printInfo(string `[GROUP] Adding Patient/${brokerScopedPatientId} to Group/${groupId}`);

    string patientRef = string `Patient/${brokerScopedPatientId}`;
    int maxRetries = 3;
    int conflictStatus = 0;
    string conflictBody = "";

    foreach int attempt in 1 ... maxRetries {
        http:Response getResponse = check fhirClient->/Group/[groupId].get();
        if getResponse.statusCode < 200 || getResponse.statusCode >= 300 {
            string|error body = getResponse.getTextPayload();
            return error(string `Failed to GET Group/${groupId} (status: ${getResponse.statusCode}): ${body is string ? body : "unknown"}`);
        }

        json bodyJson = check getResponse.getJsonPayload();
        if bodyJson !is map<json> {
            return error(string `Group/${groupId} response is not a valid JSON object`);
        }
        map<json> groupJson = bodyJson;

        string? ifMatchValue = ();
        string|http:HeaderNotFoundError etagHeader = getResponse.getHeader("ETag");
        if etagHeader is string {
            ifMatchValue = etagHeader;
        } else {
            json? metaJson = groupJson["meta"];
            if metaJson is map<json> {
                json? versionIdJson = metaJson["versionId"];
                if versionIdJson is string {
                    ifMatchValue = string `W/"${versionIdJson}"`;
                }
            }
        }
        if ifMatchValue is () {
            log:printWarn(string `[GROUP] No ETag/versionId on Group/${groupId} — PUT will skip If-Match (OCC bypassed)`);
        }

        json? membersJson = groupJson["member"];
        json[] members = [];

        if membersJson is json[] {
            members = membersJson.clone();
            foreach json member in members {
                if member is map<json> {
                    json? entity = member["entity"];
                    if entity is map<json> {
                        json? reference = entity["reference"];
                        if reference is string && reference == patientRef {
                            log:printInfo(string `[GROUP] Patient/${brokerScopedPatientId} already in Group/${groupId}`);
                            return;
                        }
                    }
                }
            }
        }

        members.push({"entity": {"reference": patientRef}});

        map<json> updatedGroup = groupJson.clone();
        updatedGroup["member"] = members;

        map<string|string[]> headers = {"Content-Type": "application/fhir+json"};
        if ifMatchValue is string {
            headers["If-Match"] = ifMatchValue;
        }
        http:Response putResponse = check fhirClient->/Group/[groupId].put(updatedGroup, headers);

        if putResponse.statusCode >= 200 && putResponse.statusCode < 300 {
            log:printInfo(string `[GROUP] Patient/${brokerScopedPatientId} added to Group/${groupId}`);
            audit:auditFhirServerOperation("group-add-member", string `Group/${groupId}/Patient/${brokerScopedPatientId}`, true);
            return;
        }

        if putResponse.statusCode == 409 || putResponse.statusCode == 412 {
            string|error body = putResponse.getTextPayload();
            conflictStatus = putResponse.statusCode;
            conflictBody = body is string ? body : "unknown";
            log:printWarn(string `[GROUP] Concurrent update on Group/${groupId} (status: ${putResponse.statusCode}, attempt ${attempt}/${maxRetries}) — re-fetching and retrying`);
            continue;
        }

        string|error body = putResponse.getTextPayload();
        audit:auditFhirServerOperation("group-add-member", string `Group/${groupId}/Patient/${brokerScopedPatientId}`, false, body is string ? body : "unknown");
        return error(string `Failed to update Group/${groupId}: ${body is string ? body : "unknown"}`);
    }

    audit:auditFhirServerOperation("group-add-member", string `Group/${groupId}/Patient/${brokerScopedPatientId}`, false, string `concurrent updates after ${maxRetries} attempts`);
    return error(string `Failed to update Group/${groupId} after ${maxRetries} attempts due to concurrent updates (last status: ${conflictStatus}): ${conflictBody}`);
}

// Search FHIR Groups that contain a specific patient as a member
public function searchGroupsByPatient(http:Client fhirClient, string brokerScopedPatientId) returns common:GroupMembershipResult[]|error {
    log:printInfo(string `[GROUP] Searching groups for Patient/${brokerScopedPatientId}`);

    http:Response response = check fhirClient->/Group.get(member = brokerScopedPatientId);

    if response.statusCode < 200 || response.statusCode >= 300 {
        json|error errorJson = response.getJsonPayload();
        string reason;
        if errorJson is json {
            reason = errorJson.toJsonString();
        } else {
            string|error textBody = response.getTextPayload();
            reason = textBody is string ? textBody : "unknown";
        }
        log:printWarn(string `[GROUP] Group search returned ${response.statusCode} for Patient/${brokerScopedPatientId}: ${reason}`);
        return error(string `Group search failed for Patient/${brokerScopedPatientId} (status: ${response.statusCode}): ${reason}`);
    }

    json responseJson = check response.getJsonPayload();

    if responseJson !is map<json> {
        return [];
    }

    common:GroupMembershipResult[] results = [];
    json? entriesJson = responseJson["entry"];

    if entriesJson !is json[] {
        log:printInfo(string `[GROUP] No groups found for Patient/${brokerScopedPatientId}`);
        return results;
    }

    foreach json entry in entriesJson {
        if entry !is map<json> {
            continue;
        }
        json? resourceJson = entry["resource"];
        if resourceJson !is map<json> {
            continue;
        }
        json? idJson = resourceJson["id"];
        if idJson !is string {
            continue;
        }

        string groupId = idJson;
        [string, string]|error parsed = parseGroupId(groupId);
        if parsed is [string, string] {
            results.push({
                clientId: parsed[0],
                resourceType: parsed[1],
                groupId: groupId
            });
            log:printInfo(string `[GROUP] Found: Group/${groupId} → client=${parsed[0]}, resourceType=${parsed[1]}`);
        }
    }

    log:printInfo(string `[GROUP] Found ${results.length()} group memberships for Patient/${brokerScopedPatientId}`);
    return results;
}

// Get or create a single FHIR Subscription for a client
public function getOrCreateClientSubscription(
    http:Client fhirClient,
    string clientId,
    string[] resourceTypes,
    string callbackUrl,
    string[]? headers = ()
) returns string|error {
    log:printInfo(string `[CLIENT SUB] Getting or creating subscription for client: ${clientId}`);

    string? cachedSubId;
    lock {
        cachedSubId = common:clientSubscriptionIds[clientId];
    }

    if cachedSubId is string {
        map<json>?|error existing = getSubscriptionFromFhirServer(fhirClient, cachedSubId);
        if existing is error {
            return existing;
        }
        if existing is map<json> {
            log:printInfo(string `[CLIENT SUB] Found existing subscription: ${cachedSubId}`);
            map<json> updated = mergeResourceTypeCriteria(existing, clientId, resourceTypes);
            map<string|string[]> fhirHeaders = {"Content-Type": "application/fhir+json"};
            http:Response putResponse = check fhirClient->/Subscription/[cachedSubId].put(updated, fhirHeaders);
            if putResponse.statusCode >= 200 && putResponse.statusCode < 300 {
                log:printInfo(string `[CLIENT SUB] Updated subscription with merged criteria: ${cachedSubId}`);
                audit:auditFhirServerOperation("subscription-update", string `Subscription/${cachedSubId}`, true);
                return cachedSubId;
            }
            string|error body = putResponse.getTextPayload();
            string reason = body is string ? body : "unknown";
            log:printWarn(string `[CLIENT SUB] Subscription update failed (${putResponse.statusCode}): ${reason}`);
            audit:auditFhirServerOperation("subscription-update", string `Subscription/${cachedSubId}`, false, reason);
            return error(string `Subscription update failed for ${cachedSubId} (status: ${putResponse.statusCode})`);
        }
        log:printInfo(string `[CLIENT SUB] Cached subscription ${cachedSubId} no longer exists, creating new`);
    } else {
        map<json>?|error existing = getSubscriptionFromFhirServer(fhirClient, clientId);
        if existing is error {
            return existing;
        }
        if existing is map<json> {
            log:printInfo(string `[CLIENT SUB] Subscription already exists on FHIR server: ${clientId}`);
            map<json> updated = mergeResourceTypeCriteria(existing, clientId, resourceTypes);
            map<string|string[]> fhirHeaders = {"Content-Type": "application/fhir+json"};
            http:Response putResponse = check fhirClient->/Subscription/[clientId].put(updated, fhirHeaders);
            if putResponse.statusCode >= 200 && putResponse.statusCode < 300 {
                log:printInfo(string `[CLIENT SUB] Updated subscription with merged criteria: ${clientId}`);
                audit:auditFhirServerOperation("subscription-update", string `Subscription/${clientId}`, true);
                lock {
                    common:clientSubscriptionIds[clientId] = clientId;
                }
                return clientId;
            }
            string|error body = putResponse.getTextPayload();
            string reason = body is string ? body : "unknown";
            log:printWarn(string `[CLIENT SUB] Subscription update failed (${putResponse.statusCode}): ${reason}`);
            audit:auditFhirServerOperation("subscription-update", string `Subscription/${clientId}`, false, reason);
            return error(string `Subscription update failed for ${clientId} (status: ${putResponse.statusCode})`);
        }
    }

    json[] filterExtensions = [];
    foreach string resourceType in resourceTypes {
        string|error groupId = buildGroupId(clientId, resourceType);
        if groupId is string {
            filterExtensions.push({
                "url": "http://hl7.org/fhir/uv/subscriptions-backport/StructureDefinition/backport-filter-criteria",
                "valueString": string `${resourceType}?patient:in=Group/${groupId}&trigger=feed-event`
            });
        }
    }

    json[] channelHeaders = [];
    if headers is string[] {
        foreach string h in headers {
            channelHeaders.push(h);
        }
    }

    json subscriptionResource = {
        "resourceType": "Subscription",
        "status": "requested",
        "reason": string `Subscription for client ${clientId}`,
        "criteria": "http://hl7.org/fhir/us/core/SubscriptionTopic/patient-data-feed",
        "_criteria": {
            "extension": filterExtensions
        },
        "channel": {
            "type": "rest-hook",
            "endpoint": callbackUrl,
            "payload": "application/fhir+json",
            "header": channelHeaders,
            "_payload": {
                "extension": [{
                    "url": "http://hl7.org/fhir/uv/subscriptions-backport/StructureDefinition/backport-payload-content",
                    "valueCode": "id-only"
                }]
            }
        }
    };

    string serverSubscriptionId = check createSubscriptionInFhirServer(fhirClient, subscriptionResource);
    log:printInfo(string `[CLIENT SUB] Created new subscription: ${serverSubscriptionId} for client: ${clientId}`);

    lock {
        common:clientSubscriptionIds[clientId] = serverSubscriptionId;
    }

    return serverSubscriptionId;
}

// Merge new resource type criteria into an existing subscription
function mergeResourceTypeCriteria(map<json> existingSubscription, string clientId, string[] resourceTypes) returns map<json> {
    map<json> merged = existingSubscription.clone();

    json[] existingFilters = [];
    json? existingCriteria = existingSubscription["_criteria"];
    if existingCriteria is map<json> {
        json? existingExtensions = existingCriteria["extension"];
        if existingExtensions is json[] {
            existingFilters = existingExtensions.clone();
        }
    }

    foreach string resourceType in resourceTypes {
        string|error groupId = buildGroupId(clientId, resourceType);
        if groupId is error {
            continue;
        }
        string newFilterValue = string `${resourceType}?patient:in=Group/${groupId}&trigger=feed-event`;

        boolean exists = false;
        foreach json existingFilter in existingFilters {
            if existingFilter is map<json> {
                json? valueString = existingFilter["valueString"];
                if valueString is string && valueString == newFilterValue {
                    exists = true;
                    break;
                }
            }
        }

        if !exists {
            existingFilters.push({
                "url": "http://hl7.org/fhir/uv/subscriptions-backport/StructureDefinition/backport-filter-criteria",
                "valueString": newFilterValue
            });
            log:printInfo(string `[CLIENT SUB] Added new filter for ${resourceType}`);
        }
    }

    merged["_criteria"] = {"extension": existingFilters};
    return merged;
}

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

function extractIdFromLocation(string location) returns string {
    string normalized = location;
    int? historyIdx = normalized.indexOf("/_history");
    if historyIdx is int {
        normalized = normalized.substring(0, historyIdx);
    }
    string:RegExp slashPattern = re `/`;
    string[] parts = slashPattern.split(normalized);
    int i = parts.length() - 1;
    while i >= 0 {
        if parts[i].length() > 0 {
            return parts[i];
        }
        i -= 1;
    }
    return location;
}
