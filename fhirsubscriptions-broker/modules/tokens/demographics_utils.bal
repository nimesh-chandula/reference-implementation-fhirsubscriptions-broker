// Demographics parsing utilities and the resolve-or-create-patient flow
// shared by the SMART token endpoint and the OAuth 2.0 token exchange flow.

import ballerina/log;
import ballerina/time;

import nimesh_chandula/broker.common;
import nimesh_chandula/broker.fhir;
import nimesh_chandula/broker.mpi;

// Parse demographics from JWT claims (top-level or nested in permission_tickets)
function parseDemographicsFromJwtClaims(map<json> claims) returns common:ClientDemographics? {
    json? demographicsJson = claims["demographics"];

    log:printInfo(string `[DEMOGRAPHICS] Top-level demographics present: ${!(demographicsJson is ())}`);

    if demographicsJson is () {
        return parseDemographicsFromPermissionTickets(claims);
    }

    if demographicsJson is map<json> {
        return parseDemographicsFromMap(demographicsJson);
    }

    return ();
}

// Parse demographics from permission_tickets JWT structure
function parseDemographicsFromPermissionTickets(map<json> claims) returns common:ClientDemographics? {
    json? permissionTicketsJson = claims["permission_tickets"];
    if permissionTicketsJson !is json[] || permissionTicketsJson.length() == 0 {
        return ();
    }

    json firstTicket = permissionTicketsJson[0];
    if firstTicket !is map<json> {
        return ();
    }

    json? ticketContext = firstTicket["ticket_context"];
    if ticketContext !is map<json> {
        return ();
    }

    json? subject = ticketContext["subject"];
    if subject !is map<json> {
        return ();
    }

    json? traits = subject["traits"];
    if traits !is map<json> {
        return ();
    }

    json? nameJson = traits["name"];
    json? birthDateJson = traits["birthDate"];
    if nameJson !is json[] || nameJson.length() == 0 || birthDateJson !is string {
        return ();
    }

    common:ClientDemographics? result = parseFhirNameArray(nameJson, birthDateJson, traits["gender"]);
    if result is common:ClientDemographics {
        log:printInfo("[DEMOGRAPHICS] Successfully parsed from permission_tickets");
    }
    return result;
}

// Parse demographics from a map (FHIR format or flat format)
function parseDemographicsFromMap(map<json> demographicsJson) returns common:ClientDemographics? {
    log:printInfo("[DEMOGRAPHICS] Parsing demographics map");

    json? nameJson = demographicsJson["name"];
    json? birthDateJson = demographicsJson["birthDate"];
    json? genderJson = demographicsJson["gender"];

    if nameJson is json[] && nameJson.length() > 0 && birthDateJson is string {
        common:ClientDemographics? result = parseFhirNameArray(nameJson, birthDateJson, genderJson);
        if result is common:ClientDemographics {
            log:printInfo("[DEMOGRAPHICS] Successfully parsed as FHIR format");
            return result;
        }
    }

    log:printInfo("[DEMOGRAPHICS] Trying flat format");
    common:ClientDemographics|error demoResult = demographicsJson.cloneWithType();
    if demoResult is common:ClientDemographics {
        log:printInfo("[DEMOGRAPHICS] Successfully parsed as flat format");
        return demoResult;
    }

    log:printInfo(string `[DEMOGRAPHICS] Flat format failed: ${demoResult.message()}`);
    return ();
}

// Parse FHIR-style name array into ClientDemographics
function parseFhirNameArray(json[] nameArray, string birthDate, json? genderJson) returns common:ClientDemographics? {
    if nameArray.length() == 0 {
        return ();
    }

    json firstNameEntry = nameArray[0];
    if firstNameEntry !is map<json> {
        return ();
    }

    json? familyJson = firstNameEntry["family"];
    json? givenJsonRaw = firstNameEntry["given"];

    if familyJson !is string || givenJsonRaw !is json[] {
        return ();
    }

    string[] givenNames = [];
    foreach json givenItem in givenJsonRaw {
        if givenItem is string {
            givenNames.push(givenItem);
        }
    }

    if givenNames.length() == 0 {
        return ();
    }

    return {
        family: familyJson,
        given: givenNames,
        birthDate: birthDate,
        gender: genderJson is string ? genderJson : ()
    };
}

// Resolve or create patient in MPI (shared by SMART token and token exchange flows)
function resolveOrCreatePatient(common:ClientDemographics demographics, string systemId) returns string|error {
    log:printInfo("[MPI RESOLUTION] Searching MPI for patient match");
    string|error patientSearchResult = mpi:searchPatientByDemographics(demographics);

    if patientSearchResult is string {
        log:printInfo(string `[MPI RESOLUTION] Patient found: ${patientSearchResult}`);

        error? syncResult = fhir:ensurePatientInFhirServer(fhir:fhirServerClient, patientSearchResult, demographics);
        if syncResult is error {
            log:printWarn(string `[MPI RESOLUTION] Failed to sync patient to FHIR server (non-fatal): ${syncResult.message()}`);
        }

        return patientSearchResult;
    }

    log:printInfo("[MPI RESOLUTION] No match found, creating new patient");
    string systemPatientId = string `${systemId}-${time:utcNow()[0]}`;

    string|error createResult = mpi:createPatientInMPI(demographics, systemId, systemPatientId);

    if createResult is error {
        log:printError("[MPI RESOLUTION] Failed to create patient in MPI", createResult);
        return createResult;
    }

    log:printInfo(string `[MPI RESOLUTION] New patient created: ${createResult}`);

    error? syncResult = fhir:ensurePatientInFhirServer(fhir:fhirServerClient, createResult, demographics);
    if syncResult is error {
        log:printWarn(string `[MPI RESOLUTION] Failed to sync patient to FHIR server (non-fatal): ${syncResult.message()}`);
    }

    return createResult;
}
