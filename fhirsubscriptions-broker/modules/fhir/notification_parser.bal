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

// Notification Parser - Extract patient information from standard FHIR notification Bundles
// Implements standard-compliant parsing of FHIR R4 notification bundles

import ballerina/log;

import wso2healthcare/broker.common;

// ============================================================================
// CONFIGURABLE SYSTEM URI REGISTRY
// Maps FHIR identifier.system URIs to short system IDs for MPI lookup
// Public so modules/mpi/cr_client.bal can reverse-map URIs.
// ============================================================================
public configurable map<string> systemUriRegistry = {};

// ============================================================================
// MAIN ENTRY POINT
// ============================================================================

// Extract patient identification from a FHIR notification Bundle
function extractPatientIdFromNotification(json notification) returns common:ExtractedPatientInfo {
    log:printInfo("[NOTIFICATION_PARSER] Extracting patient ID from notification");

    common:ExtractedPatientInfo result = {};

    // Strategy 1: Look for Patient resource in Bundle entries
    common:PatientIdentifier? identifier = extractPatientIdentifierFromBundle(notification);
    if identifier is common:PatientIdentifier {
        log:printInfo(string `[NOTIFICATION_PARSER] Found Patient identifier: system=${identifier.system}, value=${identifier.value}`);
        result.identifier = identifier;

        // Map system URI to short system ID
        string? systemId = mapSystemUriToId(identifier.system);
        if systemId is string {
            result.systemId = systemId;
            result.systemPatientId = identifier.value;
            log:printInfo(string `[NOTIFICATION_PARSER] Mapped to systemId=${systemId}, patientId=${identifier.value}`);
        } else {
            log:printWarn(string `[NOTIFICATION_PARSER] No mapping found for system URI: ${identifier.system}`);
        }
    }

    // Strategy 2: Extract subject.reference from clinical resources
    string? subjectRef = extractSubjectReferenceFromBundle(notification);
    if subjectRef is string {
        result.subjectReference = subjectRef;
        log:printInfo(string `[NOTIFICATION_PARSER] Found subject reference: ${subjectRef}`);

        string? brokerPatientId = extractPatientIdFromReference(subjectRef);
        if brokerPatientId is string && brokerPatientId.startsWith("UP") {
            result.brokerScopedPatientId = brokerPatientId;
            log:printInfo(string `[NOTIFICATION_PARSER] Detected broker-scoped patient ID: ${brokerPatientId}`);
        }
    }

    return result;
}

// ============================================================================
// BUNDLE PARSING FUNCTIONS
// ============================================================================

// Extract Patient identifier from Bundle entries
function extractPatientIdentifierFromBundle(json bundle) returns common:PatientIdentifier? {
    if bundle !is map<json> {
        return ();
    }

    // Handle wrapped format: { notification: {...}, demographics: {...} }
    json actualBundle = bundle;
    json? notificationField = bundle["notification"];
    if notificationField is map<json> {
        actualBundle = notificationField;
    }

    if actualBundle !is map<json> {
        return ();
    }

    json? resourceType = actualBundle["resourceType"];
    if resourceType != "Bundle" {
        if resourceType == "Patient" {
            return extractIdentifierFromPatient(actualBundle);
        }
        return ();
    }

    json? entriesJson = actualBundle["entry"];
    if entriesJson !is json[] {
        return ();
    }

    foreach json entry in entriesJson {
        if entry !is map<json> {
            continue;
        }

        json? resourceJson = entry["resource"];
        if resourceJson !is map<json> {
            continue;
        }

        json? entryResourceType = resourceJson["resourceType"];
        if entryResourceType == "Patient" {
            common:PatientIdentifier? identifier = extractIdentifierFromPatient(resourceJson);
            if identifier is common:PatientIdentifier {
                return identifier;
            }
        }
    }

    return ();
}

// Extract identifier from a Patient resource
function extractIdentifierFromPatient(json patient) returns common:PatientIdentifier? {
    if patient !is map<json> {
        return ();
    }

    json? identifiersJson = patient["identifier"];
    if identifiersJson !is json[] || identifiersJson.length() == 0 {
        return ();
    }

    foreach json identifierJson in identifiersJson {
        if identifierJson !is map<json> {
            continue;
        }

        json? systemJson = identifierJson["system"];
        json? valueJson = identifierJson["value"];

        if systemJson is string && valueJson is string {
            return {
                system: systemJson,
                value: valueJson
            };
        }
    }

    return ();
}

// Extract subject.reference from clinical resources in Bundle
function extractSubjectReferenceFromBundle(json bundle) returns string? {
    if bundle !is map<json> {
        return ();
    }

    json actualBundle = bundle;
    json? notificationField = bundle["notification"];
    if notificationField is map<json> {
        actualBundle = notificationField;
    }

    if actualBundle !is map<json> {
        return ();
    }

    json? resourceType = actualBundle["resourceType"];
    if resourceType != "Bundle" {
        return extractSubjectFromResource(actualBundle);
    }

    json? entriesJson = actualBundle["entry"];
    if entriesJson !is json[] {
        return ();
    }

    string[] clinicalResourceTypes = ["Encounter", "Observation", "Condition", "Procedure",
        "MedicationRequest", "DiagnosticReport", "AllergyIntolerance", "Immunization"];

    foreach json entry in entriesJson {
        if entry !is map<json> {
            continue;
        }

        json? resourceJson = entry["resource"];
        if resourceJson !is map<json> {
            continue;
        }

        json? entryResourceType = resourceJson["resourceType"];
        if entryResourceType !is string {
            continue;
        }

        boolean isClinical = false;
        foreach string clinicalType in clinicalResourceTypes {
            if entryResourceType == clinicalType {
                isClinical = true;
                break;
            }
        }

        if isClinical {
            string? subjectRef = extractSubjectFromResource(resourceJson);
            if subjectRef is string {
                return subjectRef;
            }
        }
    }

    return ();
}

// Extract subject.reference from a single FHIR resource
function extractSubjectFromResource(json resourceJson) returns string? {
    if resourceJson !is map<json> {
        return ();
    }

    json? subjectJson = resourceJson["subject"];
    if subjectJson is map<json> {
        json? referenceJson = subjectJson["reference"];
        if referenceJson is string {
            return referenceJson;
        }
    }

    json? patientJson = resourceJson["patient"];
    if patientJson is map<json> {
        json? referenceJson = patientJson["reference"];
        if referenceJson is string {
            return referenceJson;
        }
    }

    return ();
}

// Extract resource types from Bundle entries
function extractResourceTypesFromBundleMap(map<json> bundle) returns string[] {
    string[] resourceTypes = [];

    log:printInfo(string `[NOTIFICATION_PARSER] extractResourceTypesFromBundleMap called`);
    log:printInfo(string `[NOTIFICATION_PARSER] Bundle keys: ${bundle.keys().toString()}`);

    map<json> actualBundle = bundle;
    json? notificationField = bundle["notification"];
    if notificationField is map<json> {
        actualBundle = notificationField;
        log:printInfo("[NOTIFICATION_PARSER] Using wrapped notification field");
    }

    json? entriesJson = actualBundle["entry"];
    if entriesJson !is json[] {
        log:printWarn(string `[NOTIFICATION_PARSER] No entry array found in bundle. Keys: ${actualBundle.keys().toString()}`);
        return resourceTypes;
    }

    log:printInfo(string `[NOTIFICATION_PARSER] Found ${entriesJson.length()} entries in bundle`);

    foreach json entry in entriesJson {
        if entry !is map<json> {
            continue;
        }

        json? resourceJson = entry["resource"];
        if resourceJson !is map<json> {
            continue;
        }

        json? resourceType = resourceJson["resourceType"];
        if resourceType is string {
            if resourceType == "Patient" || resourceType == "SubscriptionStatus" {
                log:printInfo(string `[NOTIFICATION_PARSER] Skipping metadata resource type: ${resourceType}`);
                continue;
            }

            boolean exists = false;
            foreach string existing in resourceTypes {
                if existing == resourceType {
                    exists = true;
                    break;
                }
            }
            if !exists {
                resourceTypes.push(resourceType);
                log:printInfo(string `[NOTIFICATION_PARSER] Found clinical resource type: ${resourceType}`);
            }
        }
    }

    log:printInfo(string `[NOTIFICATION_PARSER] Extracted clinical resource types: ${resourceTypes.toString()}`);
    return resourceTypes;
}

// Extract resource types from Bundle entries (legacy - takes json)
function extractResourceTypesFromBundle(json bundle) returns string[] {
    string[] resourceTypes = [];

    if bundle !is map<json> {
        log:printWarn("[NOTIFICATION_PARSER] Bundle is not a map<json>");
        return resourceTypes;
    }

    return extractResourceTypesFromBundleMap(bundle);
}

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

// Map FHIR identifier.system URI to short system ID using configurable registry
public function mapSystemUriToId(string systemUri) returns string? {
    string? systemId = systemUriRegistry[systemUri];

    if systemId is string {
        return systemId;
    }

    string quotedUri = string `"${systemUri}"`;
    systemId = systemUriRegistry[quotedUri];

    if systemId is string {
        log:printInfo(string `[NOTIFICATION_PARSER] Found mapping using quoted key: ${systemUri} -> ${systemId}`);
        return systemId;
    }

    foreach string key in systemUriRegistry.keys() {
        string normalizedKey = key;
        if key.startsWith("\"") && key.endsWith("\"") && key.length() > 2 {
            normalizedKey = key.substring(1, key.length() - 1);
        }

        if normalizedKey == systemUri {
            string? value = systemUriRegistry[key];
            if value is string {
                log:printInfo(string `[NOTIFICATION_PARSER] Found mapping via normalized key: ${systemUri} -> ${value}`);
                return value;
            }
        }
    }

    log:printWarn(string `[NOTIFICATION_PARSER] No mapping found for system URI: ${systemUri}`);
    log:printInfo(string `[NOTIFICATION_PARSER] Available mappings: ${systemUriRegistry.keys().toString()}`);

    return ();
}

// Extract patient ID from a reference string (e.g., "Patient/123" -> "123")
function extractPatientIdFromReference(string reference) returns string? {
    if !reference.startsWith("Patient/") {
        return ();
    }
    return reference.substring(8);
}

// Extract demographics from the notification payload (if provided in wrapper format)
function extractDemographicsFromPayload(json payload) returns common:ClientDemographics? {
    if payload !is map<json> {
        return ();
    }

    json? demographicsJson = payload["demographics"];
    if demographicsJson is () {
        return ();
    }

    common:ClientDemographics|error result = demographicsJson.cloneWithType();
    if result is common:ClientDemographics {
        log:printInfo(string `[NOTIFICATION_PARSER] Extracted demographics: ${result.family}, ${result.given.toString()}`);
        return result;
    }

    log:printWarn("[NOTIFICATION_PARSER] Failed to parse demographics from payload");
    return ();
}

// ============================================================================
// MULTI-PATIENT NOTIFICATION GROUPING
// ============================================================================

// Group notification Bundle resources by patient
public function groupResourcesByPatient(map<json> bundle) returns map<common:PatientResourceGroup> {
    map<common:PatientResourceGroup> patientGroups = {};

    log:printInfo("[NOTIFICATION_PARSER] Grouping resources by patient");

    map<json> actualBundle = bundle;
    json? notificationField = bundle["notification"];
    if notificationField is map<json> {
        actualBundle = notificationField;
        log:printInfo("[NOTIFICATION_PARSER] Using wrapped notification field");
    }

    json? entriesJson = actualBundle["entry"];
    if entriesJson !is json[] {
        log:printWarn("[NOTIFICATION_PARSER] No entry array found in bundle");
        return patientGroups;
    }

    log:printInfo(string `[NOTIFICATION_PARSER] Processing ${entriesJson.length()} bundle entries`);

    // First pass: Extract Patient resources and create groups
    foreach json entry in entriesJson {
        if entry !is map<json> {
            continue;
        }

        json? resourceJson = entry["resource"];
        if resourceJson !is map<json> {
            continue;
        }

        json? resourceType = resourceJson["resourceType"];
        if resourceType == "Patient" {
            json? fullUrl = entry["fullUrl"];
            string localRef = "";

            if fullUrl is string {
                localRef = fullUrl;
            } else {
                json? patientId = resourceJson["id"];
                if patientId is string {
                    localRef = string `Patient/${patientId}`;
                }
            }

            if localRef != "" {
                common:PatientIdentifier? identifier = extractIdentifierFromPatient(resourceJson);
                common:ClientDemographics? demographics = extractDemographicsFromPatientResource(resourceJson);

                common:PatientResourceGroup group = {
                    localPatientRef: localRef,
                    patientResource: resourceJson,
                    clinicalResources: [],
                    identifier: identifier,
                    demographics: demographics
                };
                patientGroups[localRef] = group;

                log:printInfo(string `[NOTIFICATION_PARSER] Created patient group for: ${localRef}`);

                if identifier is common:PatientIdentifier {
                    log:printInfo(string `[NOTIFICATION_PARSER] Patient identifier: system=${identifier.system}, value=${identifier.value}`);
                }
            }
        }
    }

    // Second pass: Associate clinical resources with patients
    string[] clinicalResourceTypes = ["Encounter", "Observation", "Condition", "Procedure",
        "MedicationRequest", "DiagnosticReport", "AllergyIntolerance", "Immunization",
        "CarePlan", "CareTeam", "Goal", "ServiceRequest", "DocumentReference"];

    foreach json entry in entriesJson {
        if entry !is map<json> {
            continue;
        }

        json? resourceJson = entry["resource"];
        if resourceJson !is map<json> {
            continue;
        }

        json? resourceType = resourceJson["resourceType"];
        if resourceType !is string {
            continue;
        }

        boolean isClinical = false;
        foreach string clinicalType in clinicalResourceTypes {
            if resourceType == clinicalType {
                isClinical = true;
                break;
            }
        }

        if !isClinical {
            continue;
        }

        string? patientRef = extractPatientReferenceFromResource(resourceJson);

        if patientRef is string {
            common:PatientResourceGroup? group = findMatchingPatientGroup(patientGroups, patientRef);

            if group is common:PatientResourceGroup {
                group.clinicalResources.push(resourceJson);
                log:printInfo(string `[NOTIFICATION_PARSER] Added ${resourceType} to patient group: ${group.localPatientRef}`);
            } else {
                log:printWarn(string `[NOTIFICATION_PARSER] No patient group found for reference: ${patientRef}`);
            }
        }
    }

    log:printInfo(string `[NOTIFICATION_PARSER] Created ${patientGroups.length()} patient groups`);
    foreach string localRef in patientGroups.keys() {
        common:PatientResourceGroup? group = patientGroups[localRef];
        if group is common:PatientResourceGroup {
            log:printInfo(string `[NOTIFICATION_PARSER] Patient ${localRef}: ${group.clinicalResources.length()} clinical resources`);
        }
    }

    return patientGroups;
}

// Extract patient reference from a clinical resource (subject or patient field)
function extractPatientReferenceFromResource(map<json> resourceJson) returns string? {
    json? subjectJson = resourceJson["subject"];
    if subjectJson is map<json> {
        json? referenceJson = subjectJson["reference"];
        if referenceJson is string {
            return referenceJson;
        }
    }

    json? patientJson = resourceJson["patient"];
    if patientJson is map<json> {
        json? referenceJson = patientJson["reference"];
        if referenceJson is string {
            return referenceJson;
        }
    }

    return ();
}

// Find matching patient group for a patient reference
function findMatchingPatientGroup(map<common:PatientResourceGroup> patientGroups, string patientRef) returns common:PatientResourceGroup? {
    common:PatientResourceGroup? directMatch = patientGroups[patientRef];
    if directMatch is common:PatientResourceGroup {
        return directMatch;
    }

    foreach string localRef in patientGroups.keys() {
        if localRef.endsWith(patientRef) {
            return patientGroups[localRef];
        }
        if localRef.endsWith(string `/${patientRef}`) {
            return patientGroups[localRef];
        }
    }

    return ();
}

// Extract demographics from Patient resource for member matching
function extractDemographicsFromPatientResource(map<json> patientResource) returns common:ClientDemographics? {
    string family = "";
    string[] given = [];
    string birthDate = "";
    string? gender = ();

    json? nameJson = patientResource["name"];
    if nameJson is json[] && nameJson.length() > 0 {
        json firstName = nameJson[0];
        if firstName is map<json> {
            json? familyJson = firstName["family"];
            if familyJson is string {
                family = familyJson;
            }

            json? givenJson = firstName["given"];
            if givenJson is json[] {
                foreach json g in givenJson {
                    if g is string {
                        given.push(g);
                    }
                }
            }
        }
    }

    json? birthDateJson = patientResource["birthDate"];
    if birthDateJson is string {
        birthDate = birthDateJson;
    }

    json? genderJson = patientResource["gender"];
    if genderJson is string {
        gender = genderJson;
    }

    if family == "" || birthDate == "" {
        log:printWarn("[NOTIFICATION_PARSER] Missing required demographics (family or birthDate)");
        return ();
    }

    common:ClientDemographics demographics = {
        family: family,
        given: given,
        birthDate: birthDate,
        gender: gender
    };

    log:printInfo(string `[NOTIFICATION_PARSER] Extracted demographics: ${family}, ${given.toString()}, DOB: ${birthDate}`);
    return demographics;
}

// Build a notification Bundle for a specific patient containing only their resources
public function buildPatientNotificationBundle(common:PatientResourceGroup patientGroup, string brokerScopedPatientId) returns map<json> {
    json[] entries = [];

    map<json> patientResource = patientGroup.patientResource.clone();
    patientResource["id"] = brokerScopedPatientId;

    entries.push({
        "fullUrl": string `Patient/${brokerScopedPatientId}`,
        "resource": patientResource
    });

    foreach map<json> clinicalResource in patientGroup.clinicalResources {
        map<json> updatedResource = clinicalResource.clone();

        json? subjectJson = updatedResource["subject"];
        if subjectJson is map<json> {
            subjectJson["reference"] = string `Patient/${brokerScopedPatientId}`;
            updatedResource["subject"] = subjectJson;
        }

        json? patientJson = updatedResource["patient"];
        if patientJson is map<json> {
            patientJson["reference"] = string `Patient/${brokerScopedPatientId}`;
            updatedResource["patient"] = patientJson;
        }

        json? resourceId = updatedResource["id"];
        string fullUrl = "";
        if resourceId is string {
            json? resourceType = updatedResource["resourceType"];
            if resourceType is string {
                fullUrl = string `${resourceType}/${resourceId}`;
            }
        }

        entries.push({
            "fullUrl": fullUrl,
            "resource": updatedResource
        });
    }

    map<json> notificationBundle = {
        "resourceType": "Bundle",
        "type": "history",
        "entry": entries
    };

    log:printInfo(string `[NOTIFICATION_PARSER] Built notification bundle for ${brokerScopedPatientId} with ${entries.length()} entries`);

    return notificationBundle;
}

// Build individual notification bundles for each clinical resource
public function buildPerResourceNotificationBundles(common:PatientResourceGroup patientGroup, string brokerScopedPatientId) returns map<json>[] {
    map<json>[] resourceBundles = [];

    map<json> patientResource = patientGroup.patientResource.clone();
    patientResource["id"] = brokerScopedPatientId;

    json patientEntry = {
        "fullUrl": string `Patient/${brokerScopedPatientId}`,
        "resource": patientResource
    };

    foreach map<json> clinicalResource in patientGroup.clinicalResources {
        map<json> updatedResource = clinicalResource.clone();

        json? subjectJson = updatedResource["subject"];
        if subjectJson is map<json> {
            subjectJson["reference"] = string `Patient/${brokerScopedPatientId}`;
            updatedResource["subject"] = subjectJson;
        }

        json? patientJson = updatedResource["patient"];
        if patientJson is map<json> {
            patientJson["reference"] = string `Patient/${brokerScopedPatientId}`;
            updatedResource["patient"] = patientJson;
        }

        json? resourceId = updatedResource["id"];
        string fullUrl = "";
        if resourceId is string {
            json? resourceType = updatedResource["resourceType"];
            if resourceType is string {
                fullUrl = string `${resourceType}/${resourceId}`;
            }
        }

        json clinicalEntry = {
            "fullUrl": fullUrl,
            "resource": updatedResource
        };

        map<json> singleResourceBundle = {
            "resourceType": "Bundle",
            "type": "history",
            "entry": [patientEntry, clinicalEntry]
        };

        resourceBundles.push(singleResourceBundle);
    }

    if patientGroup.clinicalResources.length() == 0 {
        map<json> patientOnlyBundle = {
            "resourceType": "Bundle",
            "type": "history",
            "entry": [patientEntry]
        };
        resourceBundles.push(patientOnlyBundle);
    }

    log:printInfo(string `[NOTIFICATION_PARSER] Built ${resourceBundles.length()} per-resource bundles for ${brokerScopedPatientId}`);

    return resourceBundles;
}
