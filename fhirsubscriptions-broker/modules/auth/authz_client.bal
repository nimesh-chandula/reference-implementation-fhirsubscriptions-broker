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

// Authorization service client for patient-level access control
// Calls the prebuilt authz-fhirr4-service to enforce that patients
// can only access their own data

import ballerina/log;
import ballerinax/health.fhir.r4;
import ballerinax/health.fhir.r4.authz;

import wso2healthcare/broker.common;
import wso2healthcare/broker.fhir;

// Check authorization via the prebuilt authz-fhirr4-service
public function checkAuthorization(map<json> jwtClaims, string? patientId) returns common:AuthzResult {
    if !authzEnabled {
        return {isAuthorized: true, scope: "BYPASSED"};
    }

    json authzRequestJson = {
        "fhirSecurity": {
            "securedAPICall": true,
            "fhirUser": null,
            "jwt": {
                "header": {"alg": "RS256", "typ": "JWT"},
                "payload": jwtClaims
            }
        },
        "patientId": patientId,
        "privilegedClaimUrl": "http://wso2.org/claims/privileged"
    };

    r4:AuthzRequest|error authzRequest = authzRequestJson.cloneWithType();
    if authzRequest is error {
        log:printError(string `[AUTHZ] Failed to build typed authz request: ${authzRequest.message()}`);
        return {isAuthorized: false, scope: ()};
    }

    r4:AuthzRequest & readonly readonlyRequest = authzRequest.cloneReadOnly();

    r4:AuthzResponse result = authz:authorize(readonlyRequest);

    string? scope = result.scope;
    log:printInfo(string `[AUTHZ] Authorization decision: authorized=${result.isAuthorized}, scope=${scope ?: "none"}, patient=${patientId ?: "all"}`);
    return {isAuthorized: result.isAuthorized, scope: scope};
}

// Validate patient-level access for subscription creation.
// Takes already JWKS-validated claims (from validateSubscriptionAccessToken)
// instead of the raw Authorization header — never trust unverified payloads
// for auth decisions.
public function validatePatientSubscriptionAccess(map<json> validatedClaims, string targetPatientId) returns error? {
    if !requireNotificationAuthz {
        return ();
    }

    map<json> claims = validatedClaims;

    json? patientClaim = claims["patient"];
    if patientClaim is () {
        json? subClaim = claims["sub"];
        if subClaim is string {
            [string, string?]|error resolved = fhir:resolvePatientBySub(fhir:fhirServerClient, subClaim);
            if resolved is [string, string?] {
                claims["patient"] = resolved[0];
                patientClaim = resolved[0];
                log:printInfo(string `[AUTHZ] Enriched JWT with patient=${resolved[0]} from FHIR lookup`);
            } else {
                log:printWarn(string `[AUTHZ] Could not resolve patient from sub: ${resolved.message()}`);
            }
        }
    }

    if patientClaim is string && patientClaim != targetPatientId {
        log:printWarn(string `[AUTHZ] Patient mismatch: token patient=${patientClaim}, target=${targetPatientId}`);
        return error(string `Cannot subscribe to another patient's data. Token patient=${patientClaim}, requested=${targetPatientId}`);
    }

    if authzEnabled {
        common:AuthzResult authzResult = checkAuthorization(claims, targetPatientId);
        if !authzResult.isAuthorized {
            return error(string `Authorization denied for patient ${targetPatientId}`);
        }
    }

    return ();
}

// Extract patient ID from a FHIR resource
public function extractPatientFromResource(map<json> fhirResource) returns string? {
    json? subjectJson = fhirResource["subject"];
    if subjectJson is map<json> {
        json? refJson = subjectJson["reference"];
        if refJson is string && refJson.startsWith("Patient/") {
            return refJson.substring(8);
        }
    }

    json? patientJson = fhirResource["patient"];
    if patientJson is map<json> {
        json? refJson = patientJson["reference"];
        if refJson is string && refJson.startsWith("Patient/") {
            return refJson.substring(8);
        }
    }

    return ();
}
