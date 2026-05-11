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

// Authentication and JWT utilities
// (Asgardeo token exchange and refresh logic live in modules/tokens.)

import ballerina/http;
import ballerina/lang.'array;

import ballerina/jwt;
import ballerina/log;

import wso2healthcare/broker.common;
import wso2healthcare/broker.fhir;

// Static client registry, retained for the /broker/registry admin endpoints.
public configurable map<common:ClientRegistration> clientRegistry = {};

// Dynamic client registry for runtime-registered clients (via admin API).
public map<common:ClientRegistration> dynamicClientRegistry = {};

public configurable boolean requireNotificationAuthz = true;

// ============================================================================
// SUBSCRIPTION AUTHORIZATION ASGARDEO APP CONFIGURATION
// ============================================================================
configurable string subscriptionAuthzJwksUrl = "https://api.asgardeo.io/t/fhirbroker/oauth2/jwks";
configurable string subscriptionAuthzIssuer = "https://api.asgardeo.io/t/fhirbroker/oauth2/token";

// ============================================================================
// AUTHORIZATION CONFIGURATION
// ============================================================================
public configurable boolean authzEnabled = true;

// ============================================================================
// ASGARDEO ID TOKEN VALIDATION (1st Asgardeo app)
// ============================================================================
public configurable string asgardeoJwksUrl = "https://api.asgardeo.io/t/fhirbroker/oauth2/jwks";
public configurable string asgardeoIssuer = "https://api.asgardeo.io/t/fhirbroker/oauth2/token";
public configurable string asgardeoUserInfoUrl = "https://api.asgardeo.io/t/fhirbroker/oauth2/userinfo";

// ============================================================================
// JWT UTILITIES
// ============================================================================

// Decode JWT payload without cryptographic validation.
// Callers MUST only invoke this on tokens that were already verified upstream
// (e.g. Asgardeo token-endpoint responses, or after `validateResourceAccess`).
public function decodeJWTPayload(string jwtToken) returns json|error {
    string:RegExp dotPattern = re `\.`;
    string[] parts = dotPattern.split(jwtToken);

    if parts.length() != 3 {
        return error("Invalid JWT format");
    }

    string base64Payload = parts[1];
    int paddingNeeded = (4 - (base64Payload.length() % 4)) % 4;
    foreach int i in 0 ..< paddingNeeded {
        base64Payload = base64Payload + "=";
    }
    string:RegExp minusPattern = re `-`;
    base64Payload = minusPattern.replaceAll(base64Payload, "+");
    string:RegExp underscorePattern = re `_`;
    base64Payload = underscorePattern.replaceAll(base64Payload, "/");

    byte[] decoded = check 'array:fromBase64(base64Payload);
    string jsonStr = check string:fromBytes(decoded);
    json payload = check jsonStr.fromJsonString();

    return payload;
}

// Extract bearer token from Authorization header
public function extractBearerToken(string authorization) returns string|error {
    if !authorization.startsWith("Bearer ") {
        return error("Authorization must use Bearer scheme");
    }
    return authorization.substring(7);
}

// ============================================================================
// TOKEN EXCHANGE - ASGARDEO ID TOKEN VALIDATION
// ============================================================================

// Validate Asgardeo ID token using JWKS
public function validateAsgardeoIdToken(string idToken) returns common:ValidatedIdTokenInfo|error {
    log:printInfo("[TOKEN EXCHANGE] Starting Asgardeo ID token validation");

    [jwt:Header, jwt:Payload] [header, preliminaryPayload] = check jwt:decode(idToken);

    if header.alg is () || header.alg != jwt:RS256 {
        log:printError("[TOKEN EXCHANGE] Unsupported JWT algorithm");
        return error("Unsupported JWT algorithm; RS256 is required");
    }

    string? kidOpt = header.kid;
    if kidOpt is () {
        log:printWarn("[TOKEN EXCHANGE] No kid in JWT header, proceeding with JWKS validation");
    } else {
        log:printInfo(string `[TOKEN EXCHANGE] Key ID (kid): ${kidOpt}`);
    }

    string? issuerOpt = preliminaryPayload.iss;
    if issuerOpt is () {
        log:printError("[TOKEN EXCHANGE] Missing iss claim in ID token");
        return error("Missing iss claim in ID token");
    }

    if issuerOpt != asgardeoIssuer {
        log:printError(string `[TOKEN EXCHANGE] Invalid issuer: ${issuerOpt}, expected: ${asgardeoIssuer}`);
        return error(string `Invalid token issuer. Expected: ${asgardeoIssuer}`);
    }

    log:printInfo(string `[TOKEN EXCHANGE] Issuer verified: ${issuerOpt}`);

    jwt:ValidatorConfig validatorConfig = {
        issuer: asgardeoIssuer,
        clockSkew: common:JWT_CLOCK_SKEW,
        signatureConfig: {
            jwksConfig: {
                url: asgardeoJwksUrl,
                cacheConfig: {
                    capacity: common:JWKS_CACHE_CAPACITY,
                    evictionFactor: <float>common:JWKS_CACHE_EVICTION_FACTOR,
                    evictionPolicy: common:JWKS_CACHE_EVICTION_POLICY,
                    defaultMaxAge: <decimal>common:JWKS_CACHE_MAX_AGE
                }
            }
        }
    };

    log:printInfo(string `[TOKEN EXCHANGE] Validating signature with JWKS: ${asgardeoJwksUrl}`);
    jwt:Payload validatedPayload = check jwt:validate(idToken, validatorConfig);
    log:printInfo("[TOKEN EXCHANGE] ID token signature validated successfully");

    map<json> claims = {};
    json payloadJson = validatedPayload.toJson();
    if payloadJson is map<json> {
        claims = payloadJson.clone();
    }

    string? subOpt = validatedPayload.sub;
    if subOpt is () {
        log:printError("[TOKEN EXCHANGE] Missing sub claim in ID token");
        return error("Missing sub claim in ID token");
    }

    log:printInfo(string `[TOKEN EXCHANGE] Token validated for subject: ${subOpt}`);

    return {
        subject: subOpt,
        issuer: issuerOpt,
        claims: claims
    };
}

// Extract demographics from Asgardeo ID token claims
public function extractDemographicsFromIdToken(map<json> tokenClaims) returns common:ClientDemographics|error {
    log:printInfo("[TOKEN EXCHANGE] Attempting to extract demographics from ID token claims");

    string? familyName = ();
    json? familyNameJson = tokenClaims["family_name"];
    if familyNameJson is string && familyNameJson.length() > 0 {
        familyName = familyNameJson;
    }

    string[] givenNames = [];
    json? givenNameJson = tokenClaims["given_name"];
    if givenNameJson is string && givenNameJson.length() > 0 {
        givenNames = [givenNameJson];
    } else if givenNameJson is json[] {
        foreach json name in givenNameJson {
            if name is string {
                givenNames.push(name);
            }
        }
    }

    if givenNames.length() == 0 || familyName is () {
        json? nameJson = tokenClaims["name"];
        if nameJson is string && nameJson.length() > 0 {
            string:RegExp spacePattern = re `\s+`;
            string[] nameParts = spacePattern.split(nameJson);
            if nameParts.length() >= 2 {
                if givenNames.length() == 0 {
                    givenNames = [nameParts[0]];
                }
                if familyName is () {
                    familyName = nameParts[nameParts.length() - 1];
                }
            }
        }
    }

    string? birthDate = ();
    json? birthdateJson = tokenClaims["birthdate"];
    if birthdateJson is string && birthdateJson.length() > 0 {
        birthDate = birthdateJson;
    }
    if birthDate is () {
        json? birthDateAltJson = tokenClaims["birth_date"];
        if birthDateAltJson is string && birthDateAltJson.length() > 0 {
            birthDate = birthDateAltJson;
        }
    }

    string? gender = ();
    json? genderJson = tokenClaims["gender"];
    if genderJson is string && genderJson.length() > 0 {
        gender = genderJson;
    }

    if familyName is () {
        log:printInfo("[TOKEN EXCHANGE] family_name not found in ID token claims");
        return error("ID token missing required claim: family_name");
    }

    if givenNames.length() == 0 {
        log:printInfo("[TOKEN EXCHANGE] given_name not found in ID token claims");
        return error("ID token missing required claim: given_name");
    }

    if birthDate is () {
        log:printInfo("[TOKEN EXCHANGE] birthdate not found in ID token claims");
        return error("ID token missing required claim: birthdate");
    }

    common:ClientDemographics demographics = {
        family: familyName,
        given: givenNames,
        birthDate: birthDate,
        gender: gender
    };

    string birthYear = demographics.birthDate.length() >= 4 ? demographics.birthDate.substring(0, 4) : "****";
    log:printInfo(string `[TOKEN EXCHANGE] Demographics extracted from ID token: givenCount=${demographics.given.length()}, familyPresent=true, birthYear=${birthYear}`);

    return demographics;
}

// Parse demographics JSON string for token exchange
public function parseDemographicsFromJson(string demographicsJson) returns common:ClientDemographics|error {
    log:printInfo("[TOKEN EXCHANGE] Parsing demographics JSON");

    json demJson = check demographicsJson.fromJsonString();

    if demJson !is map<json> {
        return error("Demographics must be a JSON object");
    }

    map<json> demMap = demJson;

    json? nameJson = demMap["name"];
    json? birthDateJson = demMap["birthDate"];
    json? genderJson = demMap["gender"];

    if nameJson !is json[] || nameJson.length() == 0 {
        return error("Demographics must contain 'name' array with at least one entry");
    }

    if birthDateJson !is string {
        return error("Demographics must contain 'birthDate' as string (YYYY-MM-DD)");
    }

    json firstNameEntry = nameJson[0];
    if firstNameEntry !is map<json> {
        return error("Name entry must be a JSON object");
    }

    map<json> nameMap = firstNameEntry;
    json? familyJson = nameMap["family"];
    json? givenJson = nameMap["given"];

    if familyJson !is string {
        return error("Name must contain 'family' as string");
    }

    if givenJson !is json[] || givenJson.length() == 0 {
        return error("Name must contain 'given' as array with at least one entry");
    }

    string[] givenNames = [];
    foreach json givenItem in givenJson {
        if givenItem is string {
            givenNames.push(givenItem);
        }
    }

    if givenNames.length() == 0 {
        return error("Given names array must contain string values");
    }

    common:ClientDemographics demographics = {
        family: familyJson,
        given: givenNames,
        birthDate: birthDateJson,
        gender: genderJson is string ? genderJson : ()
    };

    string birthYear2 = demographics.birthDate.length() >= 4 ? demographics.birthDate.substring(0, 4) : "****";
    log:printInfo(string `[TOKEN EXCHANGE] Parsed demographics: givenCount=${demographics.given.length()}, familyPresent=true, birthYear=${birthYear2}`);

    return demographics;
}

// ============================================================================
// SUBSCRIPTION ACCESS TOKEN VALIDATION (Asgardeo App 2)
// ============================================================================

// Validate an access token presented to subscription/notification endpoints
// against the Asgardeo App 2 JWKS. Returns the resolved client identity, the
// patient (resolved from claims or from FHIR via `sub` lookup), and the full
// verified claims for downstream patient-level checks.
public function validateSubscriptionAccessToken(string token) returns common:ValidatedSubscriptionToken|error {
    jwt:ValidatorConfig asgardeoConfig = {
        issuer: subscriptionAuthzIssuer,
        clockSkew: common:JWT_CLOCK_SKEW,
        signatureConfig: {
            jwksConfig: {
                url: subscriptionAuthzJwksUrl,
                cacheConfig: {
                    capacity: common:JWKS_CACHE_CAPACITY,
                    evictionFactor: <float>common:JWKS_CACHE_EVICTION_FACTOR,
                    evictionPolicy: common:JWKS_CACHE_EVICTION_POLICY,
                    defaultMaxAge: <decimal>common:JWKS_CACHE_MAX_AGE
                }
            }
        }
    };

    jwt:Payload validatedPayload = check jwt:validate(token, asgardeoConfig);

    map<json> claims = {};
    json payloadJson = validatedPayload.toJson();
    if payloadJson is map<json> {
        claims = payloadJson.clone();
    }

    string? clientId = ();
    json? clientAppIdJson = claims["client_app_id"];
    if clientAppIdJson is string {
        clientId = clientAppIdJson;
    }
    if clientId is () {
        json? clientIdJson = claims["client_id"];
        if clientIdJson is string {
            clientId = clientIdJson;
        }
    }
    if clientId is () {
        json? azpJson = claims["azp"];
        if azpJson is string {
            clientId = azpJson;
        }
    }
    if clientId is () {
        json? subJson = claims["sub"];
        if subJson is string {
            string? mappedApp = common:getUserClientApp(subJson);
            if mappedApp is string {
                clientId = mappedApp;
            } else {
                [string, string?]|error fhirResult = fhir:resolvePatientBySub(fhir:fhirServerClient, subJson);
                if fhirResult is [string, string?] {
                    string? resolvedClientAppId = fhirResult[1];
                    if resolvedClientAppId is string {
                        common:setUserClientApp(subJson, resolvedClientAppId);
                        clientId = resolvedClientAppId;
                    } else {
                        clientId = subJson;
                    }
                } else {
                    clientId = subJson;
                }
            }
        }
    }

    if clientId is () {
        return error("Token missing client identifier (client_id, azp, or sub)");
    }

    string? patient = ();
    json? patientJson = claims["patient"];
    if patientJson is string {
        patient = patientJson;
    }

    if patient is () || patient == "" {
        json? subJson = claims["sub"];
        if subJson is string {
            [string, string?]|error fhirResult = fhir:resolvePatientBySub(fhir:fhirServerClient, subJson);
            if fhirResult is [string, string?] {
                patient = fhirResult[0];
                claims["patient"] = patient;
                log:printInfo(string `[SUBSCRIPTION AUTH] Resolved patient from FHIR: ${patient ?: ""}`);
            }
        }
    }

    log:printInfo(string `[SUBSCRIPTION AUTH] Asgardeo token validated: client=${clientId}`);
    return {
        clientId: clientId,
        subscriptionId: "",
        patient: patient ?: "",
        claims: claims
    };
}

// Validate resource access authorization
public function validateResourceAccess(string? authorization, string? expectedClientId) returns common:ValidatedSubscriptionToken|http:Unauthorized|http:Forbidden {
    if !requireNotificationAuthz {
        string clientId = expectedClientId ?: "anonymous";
        return {clientId: clientId, subscriptionId: "", patient: ""};
    }

    if authorization is () || authorization == "" {
        log:printWarn("[AUTHZ] Missing Authorization header on protected endpoint");
        return <http:Unauthorized>{
            body: {
                "error": "unauthorized",
                "error_description": "Authorization header required"
            }
        };
    }

    string|error tokenResult = extractBearerToken(authorization);
    if tokenResult is error {
        log:printWarn(string `[AUTHZ] Bearer token extraction failed: ${tokenResult.message()}`);
        return <http:Unauthorized>{
            body: {
                "error": "unauthorized",
                "error_description": "Invalid Authorization header"
            }
        };
    }

    common:ValidatedSubscriptionToken|error validationResult = validateSubscriptionAccessToken(tokenResult);
    if validationResult is error {
        log:printWarn(string `[AUTHZ] Token validation failed: ${validationResult.message()}`);
        return <http:Unauthorized>{
            body: {
                "error": "invalid_token",
                "error_description": "Token validation failed"
            }
        };
    }

    if expectedClientId is string && validationResult.clientId != expectedClientId {
        log:printWarn(string `[AUTHZ] Client mismatch: token=${validationResult.clientId}, expected=${expectedClientId}`);
        return <http:Forbidden>{
            body: {
                "error": "forbidden",
                "error_description": "Token client does not match requested resource owner"
            }
        };
    }

    log:printInfo(string `[AUTHZ] Access authorized for client=${validationResult.clientId}, patient=${validationResult.patient}`);
    return validationResult;
}
