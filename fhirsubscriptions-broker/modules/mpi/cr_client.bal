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

// CR (Client Registry) MPI Provider
// Implements MPI operations using an OpenHIE-compliant Client Registry (FHIR R4)
// Endpoints: ITI-78 (Search), ITI-104 (Create/Update), ITI-119 ($match)

import ballerina/http;
import ballerina/log;

import wso2healthcare/broker.audit;
import wso2healthcare/broker.common;
import wso2healthcare/broker.fhir;

// Configurable CR service URL and auth token
configurable string crServiceUrl = "http://localhost:9093/fhir/r4";
configurable string crAuthToken = "";

// ============================================================================
// CR MPI OPERATIONS
// ============================================================================

// Resolve patient by system identifier → broker-scoped patient ID (CRUID)
// Uses ITI-78: GET /Patient?identifier=system|value
function crResolveToBrokerScopedId(string systemId, string systemPatientId) returns string|error {
    log:printInfo(string `[CR] Resolving patient: ${systemId}:${systemPatientId}`);

    http:Client crClient = check new (crServiceUrl);

    string systemUri = check resolveSystemUri(systemId);

    string identifierParam = string `${systemUri}|${systemPatientId}`;
    map<string|string[]> headers = crAuthHeaders();

    json response = check crClient->/Patient.get(identifier = identifierParam, headers = headers);

    if response !is map<json> {
        return error("Invalid response from CR");
    }

    json? totalJson = response["total"];
    if totalJson is int && totalJson == 0 {
        audit:auditPatientResolution(string `${systemId}:${systemPatientId}`, "cr-resolve", false, "Patient not found in CR");
        return error(string `Patient not found in CR: ${systemId}:${systemPatientId}`);
    }

    json? entriesJson = response["entry"];
    if entriesJson !is json[] || entriesJson.length() == 0 {
        audit:auditPatientResolution(string `${systemId}:${systemPatientId}`, "cr-resolve", false, "Patient not found in CR");
        return error(string `Patient not found in CR: ${systemId}:${systemPatientId}`);
    }

    string? cruid = extractCruidFromBundleEntry(entriesJson[0]);
    if cruid is () {
        return error("Could not extract patient ID from CR response");
    }

    log:printInfo(string `[CR] Resolved ${systemId}:${systemPatientId} to CRUID: ${cruid}`);
    audit:auditPatientResolution(cruid, "cr-resolve", true);
    return cruid;
}

// Search CR for patient by demographics using ITI-119: POST /Patient/$match
function crSearchByDemographics(common:ClientDemographics demographics) returns string|error {
    log:printInfo(string `[CR] Searching by demographics: ${demographics.family}, ${demographics.given.toString()}, DOB: ${demographics.birthDate}`);

    http:Client crClient = check new (crServiceUrl);

    json patientResource = {
        "resourceType": "Patient",
        "name": [
            {
                "family": demographics.family,
                "given": demographics.given
            }
        ],
        "birthDate": demographics.birthDate
    };

    if demographics.gender is string {
        patientResource = check patientResource.mergeJson({"gender": demographics.gender});
    }

    json matchRequest = {
        "resourceType": "Parameters",
        "parameter": [
            {
                "name": "resource",
                "resource": patientResource
            },
            {
                "name": "onlyCertainMatches",
                "valueBoolean": false
            },
            {
                "name": "count",
                "valueInteger": 1
            }
        ]
    };

    http:Request req = new;
    req.setJsonPayload(matchRequest);
    req.setHeader("Content-Type", "application/fhir+json");
    setCrAuthHeaders(req);

    http:Response response = check crClient->/Patient/["$match"].post(req);
    json responseJson = check response.getJsonPayload();

    if responseJson !is map<json> {
        return error("Invalid response from CR $match");
    }

    json? entriesJson = responseJson["entry"];
    if entriesJson !is json[] || entriesJson.length() == 0 {
        log:printInfo("[CR] No match found via $match");
        audit:auditPatientResolution(demographics.family, "cr-demographics-match", false, "No matching patient found in CR");
        return error("No matching patient found in CR");
    }

    string? cruid = extractCruidFromBundleEntry(entriesJson[0]);
    if cruid is () {
        return error("Could not extract patient ID from CR match response");
    }

    log:printInfo(string `[CR] Match found: ${cruid}`);
    audit:auditPatientResolution(cruid, "cr-demographics-match", true);
    return cruid;
}

// Create patient in CR using ITI-104: PUT /Patient?identifier=system|value
function crCreatePatient(common:ClientDemographics demographics, string systemId, string systemPatientId) returns string|error {
    log:printInfo(string `[CR] Creating patient: ${demographics.family}, DOB: ${demographics.birthDate}`);

    http:Client crClient = check new (crServiceUrl);

    string systemUri = check resolveSystemUri(systemId);

    string patientId = string `${systemId}-${systemPatientId}`;

    json patientResource = {
        "resourceType": "Patient",
        "id": patientId,
        "identifier": [
            {
                "use": "official",
                "system": systemUri,
                "value": systemPatientId
            }
        ],
        "active": true,
        "name": [
            {
                "use": "official",
                "family": demographics.family,
                "given": demographics.given
            }
        ],
        "birthDate": demographics.birthDate
    };

    if demographics.gender is string {
        patientResource = check patientResource.mergeJson({"gender": demographics.gender});
    }

    string identifierQuery = string `${systemUri}|${systemPatientId}`;
    http:Request req = new;
    req.setJsonPayload(patientResource);
    req.setHeader("Content-Type", "application/fhir+json");
    setCrAuthHeaders(req);

    http:Response response = check crClient->/Patient.put(req, identifier = identifierQuery);

    int statusCode = response.statusCode;
    if statusCode < 200 || statusCode >= 300 {
        string|error body = response.getTextPayload();
        audit:auditFhirServerOperation("cr-patient-create", string `Patient/${systemId}:${systemPatientId}`, false, body is string ? body : "unknown");
        return error(string `CR patient creation failed (${statusCode}): ${body is string ? body : "unknown"}`);
    }

    string|http:HeaderNotFoundError locationHeader = response.getHeader("Location");
    if locationHeader is string {
        string cruid = extractIdFromLocation(locationHeader);
        log:printInfo(string `[CR] Patient created with CRUID: ${cruid}`);
        audit:auditFhirServerOperation("cr-patient-create", string `Patient/${cruid}`, true);
        return cruid;
    }

    json|error responseBody = response.getJsonPayload();
    if responseBody is map<json> {
        json? idField = responseBody["id"];
        if idField is string {
            log:printInfo(string `[CR] Patient created with CRUID: ${idField}`);
            audit:auditFhirServerOperation("cr-patient-create", string `Patient/${idField}`, true);
            return idField;
        }
    }

    return error("Could not extract patient ID from CR create response");
}

// Add identifier mapping to existing patient in CR
function crAddMapping(string systemId, string systemPatientId, string brokerScopedPatientId, common:ClientDemographics demographics) returns error? {
    log:printInfo(string `[CR] Adding identifier mapping: ${systemId}:${systemPatientId} -> ${brokerScopedPatientId}`);

    http:Client crClient = check new (crServiceUrl);

    string systemUri = check resolveSystemUri(systemId);

    map<string|string[]> headers = crAuthHeaders();
    json|error getResponse = crClient->/Patient/[brokerScopedPatientId].get(headers);

    if getResponse is error {
        log:printWarn(string `[CR] Could not fetch Patient/${brokerScopedPatientId} to add mapping: ${getResponse.message()}`);
        return;
    }

    if getResponse !is map<json> {
        return error("Invalid response fetching patient from CR");
    }

    json? identifiersJson = getResponse["identifier"];
    json[] identifiers = [];
    if identifiersJson is json[] {
        identifiers = identifiersJson.clone();
        foreach json existingId in identifiers {
            if existingId is map<json> {
                json? sys = existingId["system"];
                json? val = existingId["value"];
                if sys is string && sys == systemUri && val is string && val == systemPatientId {
                    log:printInfo("[CR] Identifier already exists on patient, skipping");
                    return;
                }
            }
        }
    }

    identifiers.push({
        "system": systemUri,
        "value": systemPatientId
    });

    map<json> updatedPatient = getResponse.clone();
    updatedPatient["identifier"] = identifiers;

    http:Request req = new;
    req.setJsonPayload(updatedPatient);
    req.setHeader("Content-Type", "application/fhir+json");
    setCrAuthHeaders(req);

    http:Response putResponse = check crClient->/Patient/[brokerScopedPatientId].put(req);

    if putResponse.statusCode >= 200 && putResponse.statusCode < 300 {
        log:printInfo(string `[CR] Identifier mapping added successfully`);
        audit:auditMappingOperation("mapping-create", string `Patient/${brokerScopedPatientId}/${systemId}:${systemPatientId}`, true);
    } else {
        string|error body = putResponse.getTextPayload();
        log:printWarn(string `[CR] Mapping update returned ${putResponse.statusCode}: ${body is string ? body : "unknown"}`);
        audit:auditMappingOperation("mapping-create", string `Patient/${brokerScopedPatientId}/${systemId}:${systemPatientId}`, false, body is string ? body : "unknown");
    }
}

// ============================================================================
// CR UTILITY FUNCTIONS
// ============================================================================

function crAuthHeaders() returns map<string|string[]> {
    if crAuthToken.trim() != "" {
        return {"Authorization": string `Bearer ${crAuthToken}`};
    }
    return {};
}

function setCrAuthHeaders(http:Request req) {
    if crAuthToken.trim() != "" {
        req.setHeader("Authorization", string `Bearer ${crAuthToken}`);
    }
}

function extractCruidFromBundleEntry(json entry) returns string? {
    if entry !is map<json> {
        return ();
    }
    json? resourceJson = entry["resource"];
    if resourceJson !is map<json> {
        return ();
    }
    json? idField = resourceJson["id"];
    if idField is string {
        return idField;
    }
    return ();
}

// Resolve systemId to a system URI for CR operations
function resolveSystemUri(string systemId) returns string|error {
    if systemId.startsWith("http://") || systemId.startsWith("https://") || systemId.startsWith("urn:") {
        return systemId;
    }
    string? systemUri = mapSystemIdToUri(systemId);
    if systemUri is string {
        return systemUri;
    }
    return error(string `No system URI mapping found for systemId: ${systemId}`);
}

// Reverse-map short system ID to full FHIR system URI using fhir:systemUriRegistry
function mapSystemIdToUri(string systemId) returns string? {
    foreach string key in fhir:systemUriRegistry.keys() {
        string? value = fhir:systemUriRegistry[key];
        if value is string && value == systemId {
            string normalizedKey = key;
            if key.startsWith("\"") && key.endsWith("\"") && key.length() > 2 {
                normalizedKey = key.substring(1, key.length() - 1);
            }
            return normalizedKey;
        }
    }
    return ();
}

function extractIdFromLocation(string location) returns string {
    string:RegExp slashPattern = re `/`;
    string[] parts = slashPattern.split(location);
    if parts.length() > 0 {
        return parts[parts.length() - 1];
    }
    return location;
}
