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

// MPI Client - Orchestrator for the patient resolution chain
// Routes through the configured MPI provider (CR) via mpi_provider.bal

import ballerina/log;

import wso2healthcare/broker.audit;
import wso2healthcare/broker.common;
import wso2healthcare/broker.fhir;

// ============================================================================
// FULL PATIENT RESOLUTION CHAIN
// Resolve → Member Match → Register
// ============================================================================

// Resolve a patient through the full MPI resolution chain.
public function resolvePatientThroughMPI(common:PatientResourceGroup patientGroup) returns common:PatientResolutionResult {
    string localRef = patientGroup.localPatientRef;
    common:PatientIdentifier? identifier = patientGroup.identifier;
    common:ClientDemographics? demographics = patientGroup.demographics;

    log:printInfo(string `[MPI_CLIENT] Starting resolution chain for: ${localRef}`);

    common:PatientResolutionResult result = {
        localPatientRef: localRef,
        status: "failed",
        clinicalResources: patientGroup.clinicalResources
    };

    string? systemId = ();
    string? systemPatientId = ();

    if identifier is common:PatientIdentifier {
        systemPatientId = identifier.value;
        systemId = fhir:mapSystemUriToId(identifier.system);

        if systemId is () {
            log:printInfo(string `[MPI_CLIENT] No registry mapping for URI: ${identifier.system}, using raw URI as systemId`);
            systemId = identifier.system;
        }
    }

    if systemId is string && systemPatientId is string {
        log:printInfo(string `[MPI_CLIENT] Step 1: Trying direct MPI lookup: ${systemId}:${systemPatientId}`);

        string|error resolveResult = resolveToBrokerScopedId(systemId, systemPatientId);

        if resolveResult is string {
            log:printInfo(string `[MPI_CLIENT] Direct lookup SUCCESS: ${resolveResult}`);
            audit:auditPatientResolution(resolveResult, "direct", true);
            error? syncResult = fhir:ensurePatientInFhirServer(fhir:fhirServerClient, resolveResult, demographics);
            if syncResult is error {
                log:printWarn(string `[MPI_CLIENT] Failed to sync patient to FHIR server (non-fatal): ${syncResult.message()}`);
            }
            result.brokerScopedPatientId = resolveResult;
            result.status = "resolved";
            result.message = "Resolved via direct MPI lookup";
            return result;
        }

        log:printInfo("[MPI_CLIENT] Direct lookup failed, trying member matching...");
    } else {
        log:printWarn("[MPI_CLIENT] Cannot do direct lookup - missing systemId or systemPatientId");
    }

    if demographics is common:ClientDemographics {
        log:printInfo(string `[MPI_CLIENT] Step 2: Trying member match: ${demographics.family}, ${demographics.given.toString()}`);

        string|error matchResult = searchPatientByDemographics(demographics);

        if matchResult is string {
            log:printInfo(string `[MPI_CLIENT] Member match SUCCESS: ${matchResult}`);
            audit:auditPatientResolution(matchResult, "demographics", true);
            error? syncResult = fhir:ensurePatientInFhirServer(fhir:fhirServerClient, matchResult, demographics);
            if syncResult is error {
                log:printWarn(string `[MPI_CLIENT] Failed to sync patient to FHIR server (non-fatal): ${syncResult.message()}`);
            }

            if systemId is string && systemPatientId is string {
                error? mappingResult = addMPIMapping(systemId, systemPatientId, matchResult, demographics);
                if mappingResult is error {
                    log:printWarn(string `[MPI_CLIENT] Failed to add mapping: ${mappingResult.message()}`);
                } else {
                    log:printInfo("[MPI_CLIENT] Added identifier mapping for future lookups");
                }
            }

            result.brokerScopedPatientId = matchResult;
            result.status = "matched";
            result.message = "Resolved via demographic member matching";
            return result;
        }

        log:printInfo("[MPI_CLIENT] Member matching failed, registering new patient...");

        if systemId is string && systemPatientId is string {
            log:printInfo(string `[MPI_CLIENT] Step 3: Registering new patient in MPI`);

            string|error createResult = createPatientInMPI(demographics, systemId, systemPatientId);

            if createResult is string {
                log:printInfo(string `[MPI_CLIENT] New patient registered: ${createResult}`);
                audit:auditPatientResolution(createResult, "register", true);
                error? syncResult = fhir:ensurePatientInFhirServer(fhir:fhirServerClient, createResult, demographics);
                if syncResult is error {
                    log:printWarn(string `[MPI_CLIENT] Failed to sync patient to FHIR server (non-fatal): ${syncResult.message()}`);
                }
                result.brokerScopedPatientId = createResult;
                result.status = "registered";
                result.message = "Registered as new patient in MPI";
                return result;
            }

            log:printError(string `[MPI_CLIENT] Failed to register patient: ${createResult.message()}`);
            audit:auditPatientResolution(localRef, "register", false, "Failed to register: " + createResult.message());
            result.message = string `Failed to register patient: ${createResult.message()}`;
        } else {
            result.message = "Cannot register patient - missing systemId or systemPatientId from identifier";
        }
    } else {
        log:printWarn("[MPI_CLIENT] No demographics available for member matching or registration");
        result.status = "demographics_required";
        result.message = "Demographics required for patient resolution";
    }

    return result;
}
