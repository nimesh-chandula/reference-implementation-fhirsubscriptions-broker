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

// Resolve-or-create-patient flow for the OAuth 2.0 token exchange path.

import ballerina/log;
import ballerina/time;

import wso2healthcare/broker.common;
import wso2healthcare/broker.fhir;
import wso2healthcare/broker.mpi;

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
