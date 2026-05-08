// Resolve-or-create-patient flow for the OAuth 2.0 token exchange path.

import ballerina/log;
import ballerina/time;

import nimesh_chandula/broker.common;
import nimesh_chandula/broker.fhir;
import nimesh_chandula/broker.mpi;

// Resolve or create patient in MPI (used by the token exchange flow)
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
