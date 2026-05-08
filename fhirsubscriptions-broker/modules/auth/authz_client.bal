// Authorization service client for patient-level access control
// Calls the prebuilt authz-fhirr4-service to enforce that patients
// can only access their own data

import ballerina/log;
import ballerinax/health.fhir.r4;
import ballerinax/health.fhir.r4.authz;

import nimesh_chandula/broker.common;
import nimesh_chandula/broker.fhir;

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

// Validate patient-level access for subscription creation
public function validatePatientSubscriptionAccess(string? authorization, string targetPatientId) returns error? {
    if !requireNotificationAuthz || authorization is () {
        return ();
    }

    string|error tokenResult = extractBearerToken(authorization);
    if tokenResult is error {
        return tokenResult;
    }

    json|error payload = decodeJWTPayload(tokenResult);
    if payload is error {
        return payload;
    }

    if payload is map<json> {
        json? patientClaim = payload["patient"];
        if patientClaim is () {
            json? subClaim = payload["sub"];
            if subClaim is string {
                [string, string?]|error resolved = fhir:resolvePatientBySub(fhir:fhirServerClient, subClaim);
                if resolved is [string, string?] {
                    payload["patient"] = resolved[0];
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
            common:AuthzResult authzResult = checkAuthorization(payload, targetPatientId);
            if !authzResult.isAuthorized {
                return error(string `Authorization denied for patient ${targetPatientId}`);
            }
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
