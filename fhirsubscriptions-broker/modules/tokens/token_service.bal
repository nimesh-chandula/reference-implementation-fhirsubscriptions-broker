// Token Service - OAuth 2.0 Token Exchange (RFC 8693) and Refresh Token grants

import ballerina/http;
import ballerina/log;

import nimesh_chandula/broker.audit;
import nimesh_chandula/broker.auth;
import nimesh_chandula/broker.common;
import nimesh_chandula/broker.fhir;

// Grant type constants for token exchange
const string TOKEN_EXCHANGE_GRANT_TYPE = "urn:ietf:params:oauth:grant-type:token-exchange";
const string ID_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:id_token";
const string REFRESH_TOKEN_GRANT_TYPE = "refresh_token";

// Default scopes granted on token issuance
configurable string tokenExchangeDefaultScopes = "system/Subscription.crud system/Patient.read";

// FHIR Identifier system used to namespace patient IDs sourced from the Asgardeo identity registry.
configurable string asgardeoUserSystemId = "https://asgardeo.io/users";

// Process OAuth 2.0 Token Exchange request (RFC 8693)
public function processTokenExchangeRequest(http:Request req) returns json|http:BadRequest|http:Unauthorized {
    log:printInfo("========== TOKEN EXCHANGE REQUEST ==========");

    string|error formData = req.getTextPayload();
    if formData is error {
        log:printError("[TOKEN EXCHANGE] Failed to read request body");
        return createTokenExchangeErrorResponse("invalid_request", "Failed to read request body");
    }

    string? grantTypeRaw = common:extractFormParameter(formData, "grant_type");
    if grantTypeRaw is () {
        log:printError("[TOKEN EXCHANGE] Missing grant_type");
        audit:auditTokenIssue("unknown", false, "Token exchange: missing grant_type");
        return createTokenExchangeErrorResponse("unsupported_grant_type",
            "grant_type must be 'urn:ietf:params:oauth:grant-type:token-exchange'");
    }
    string grantType = common:decodeUrlComponent(grantTypeRaw);
    if grantType != TOKEN_EXCHANGE_GRANT_TYPE {
        log:printError(string `[TOKEN EXCHANGE] Invalid grant_type: ${grantType}`);
        audit:auditTokenIssue("unknown", false, string `Token exchange: invalid grant_type: ${grantType}`);
        return createTokenExchangeErrorResponse("unsupported_grant_type",
            "grant_type must be 'urn:ietf:params:oauth:grant-type:token-exchange'");
    }
    log:printInfo("[TOKEN EXCHANGE] Grant type validated");

    string? subjectTokenTypeRaw = common:extractFormParameter(formData, "subject_token_type");
    if subjectTokenTypeRaw is () {
        log:printError("[TOKEN EXCHANGE] Missing subject_token_type");
        audit:auditTokenIssue("unknown", false, "Token exchange: missing subject_token_type");
        return createTokenExchangeErrorResponse("invalid_request",
            "subject_token_type must be 'urn:ietf:params:oauth:token-type:id_token'");
    }
    string subjectTokenType = common:decodeUrlComponent(subjectTokenTypeRaw);
    if subjectTokenType != ID_TOKEN_TYPE {
        log:printError(string `[TOKEN EXCHANGE] Invalid subject_token_type: ${subjectTokenType}`);
        audit:auditTokenIssue("unknown", false, string `Token exchange: invalid subject_token_type: ${subjectTokenType}`);
        return createTokenExchangeErrorResponse("invalid_request",
            "subject_token_type must be 'urn:ietf:params:oauth:token-type:id_token'");
    }
    log:printInfo("[TOKEN EXCHANGE] Subject token type validated");

    string? subjectToken = common:extractFormParameter(formData, "subject_token");
    if subjectToken is () {
        log:printError("[TOKEN EXCHANGE] Missing subject_token");
        audit:auditTokenIssue("unknown", false, "Token exchange: missing subject_token");
        return createTokenExchangeErrorResponse("invalid_request", "Missing subject_token parameter");
    }

    string decodedSubjectToken = common:decodeUrlComponent(subjectToken);
    log:printInfo("[TOKEN EXCHANGE] Subject token extracted");

    common:ValidatedIdTokenInfo|error validationResult = auth:validateAsgardeoIdToken(decodedSubjectToken);
    if validationResult is error {
        log:printError("[TOKEN EXCHANGE] ID token validation failed", validationResult);
        audit:auditTokenIssue("unknown", false, "ID token validation failed: " + validationResult.message());
        return createInvalidTokenResponse("Invalid or expired token");
    }

    log:printInfo(string `[TOKEN EXCHANGE] ID token validated for subject: ${validationResult.subject}`);

    common:ClientDemographics? demographics = ();

    common:ClientDemographics|error tokenDemographics = auth:extractDemographicsFromIdToken(validationResult.claims);
    if tokenDemographics is common:ClientDemographics {
        log:printInfo("[TOKEN EXCHANGE] Demographics extracted from ID token claims");
        demographics = tokenDemographics;
    } else {
        log:printInfo(string `[TOKEN EXCHANGE] Could not extract demographics from ID token: ${tokenDemographics.message()}`);
    }

    string? demographicsParam = common:extractFormParameter(formData, "demographics");
    if demographicsParam is string && demographicsParam.length() > 0 {
        string decodedDemographics = common:decodeUrlComponent(demographicsParam);
        common:ClientDemographics|error providedDemographics = auth:parseDemographicsFromJson(decodedDemographics);
        if providedDemographics is common:ClientDemographics {
            if demographics is () {
                log:printInfo("[TOKEN EXCHANGE] Using client-provided demographics");
                demographics = providedDemographics;
            } else {
                log:printInfo("[TOKEN EXCHANGE] Client-provided demographics available but using ID token claims");
            }
        } else {
            log:printWarn(string `[TOKEN EXCHANGE] Failed to parse client-provided demographics: ${providedDemographics.message()}`);
        }
    }

    if demographics is () {
        log:printError("[TOKEN EXCHANGE] No demographics available from ID token or client request");
        audit:auditTokenIssue(validationResult.subject, false, "Token exchange: no demographics available");
        return createTokenExchangeErrorResponse("invalid_request",
            "Demographics not available. Configure Asgardeo to include family_name, given_name, and birthdate claims in ID token, or provide demographics parameter.");
    }

    string birthYear = demographics.birthDate.length() >= 4 ? demographics.birthDate.substring(0, 4) : "****";
    log:printInfo(string `[TOKEN EXCHANGE] Using demographics: familyPresent=true, givenCount=${demographics.given.length()}, birthYear=${birthYear}`);

    string|error resolveResult = resolveOrCreatePatient(demographics, asgardeoUserSystemId);
    if resolveResult is error {
        audit:auditTokenIssue(validationResult.subject, false, "Token exchange: failed to resolve patient: " + resolveResult.message());
        return createTokenExchangeErrorResponse("server_error", "Failed to create patient record");
    }
    string brokerScopedPatientId = resolveResult;

    json? azpJson = validationResult.claims["azp"];
    if azpJson !is string || azpJson.trim() == "" {
        log:printError("[TOKEN EXCHANGE] Missing azp claim in ID token — cannot identify client app");
        audit:auditTokenIssue(validationResult.subject, false, "Token exchange: missing azp claim");
        return createTokenExchangeErrorResponse("invalid_request",
            "ID token must include 'azp' (authorized party) claim to identify the client application");
    }
    string clientId = azpJson;
    log:printInfo(string `[TOKEN EXCHANGE] Client app: ${clientId}, user: ${validationResult.subject}`);

    common:setUserClientApp(validationResult.subject, clientId);
    common:trackClientSubscription(clientId, brokerScopedPatientId);

    error? earlyIdentifierResult = fhir:addIdentifiersToPatient(
        fhir:fhirServerClient, brokerScopedPatientId, validationResult.subject, clientId
    );
    if earlyIdentifierResult is error {
        log:printWarn(string `[TOKEN EXCHANGE] Early identifier storage failed (non-fatal): ${earlyIdentifierResult.message()}`);
    }

    json|error asgardeoResponse = exchangeTokenWithAsgardeo(decodedSubjectToken, clientId, brokerScopedPatientId);
    if asgardeoResponse is error {
        log:printError("[TOKEN EXCHANGE] Asgardeo token exchange failed", asgardeoResponse);
        audit:auditTokenIssue(clientId, false, "Token exchange: Asgardeo token exchange failed: " + asgardeoResponse.message());
        audit:auditAsgardeoTokenExchange(clientId, false, asgardeoResponse.message());
        return createTokenExchangeErrorResponse("server_error", "Failed to obtain access token from authorization server");
    }

    audit:auditAsgardeoTokenExchange(clientId, true);

    string accessToken = "";
    int expiresIn = common:TOKEN_EXPIRY_SECONDS;
    string scope = tokenExchangeDefaultScopes;
    string? refreshToken = ();

    if asgardeoResponse is map<json> {
        json? atJson = asgardeoResponse["access_token"];
        if atJson is string {
            accessToken = atJson;
        } else {
            log:printError("[TOKEN EXCHANGE] No access_token in Asgardeo response");
            audit:auditTokenIssue(clientId, false, "Token exchange: no access_token in Asgardeo response");
            return createTokenExchangeErrorResponse("server_error", "Invalid response from authorization server");
        }

        json? expiresJson = asgardeoResponse["expires_in"];
        if expiresJson is int {
            expiresIn = expiresJson;
        }

        json? scopeJson = asgardeoResponse["scope"];
        if scopeJson is string {
            scope = scopeJson;
        }

        json? refreshJson = asgardeoResponse["refresh_token"];
        if refreshJson is string {
            refreshToken = refreshJson;
            log:printInfo("[TOKEN EXCHANGE] Refresh token received from Asgardeo");
        }
    }

    common:setUserPatient(validationResult.subject, brokerScopedPatientId);

    json|error secondAppPayload = auth:decodeJWTPayload(accessToken);
    if secondAppPayload is map<json> {
        json? secondAppSub = secondAppPayload["sub"];
        if secondAppSub is string {
            log:printInfo(string `[TOKEN EXCHANGE] 2nd app sub: ${secondAppSub}`);
            common:setUserClientApp(secondAppSub, clientId);
            common:setUserPatient(secondAppSub, brokerScopedPatientId);

            int maxRetries = 3;
            error? identifierResult = ();
            foreach int attempt in 1 ... maxRetries {
                identifierResult = fhir:addIdentifiersToPatient(
                    fhir:fhirServerClient, brokerScopedPatientId, secondAppSub, clientId
                );
                if identifierResult is () {
                    break;
                }
                log:printWarn(string `[TOKEN EXCHANGE] Identifier storage attempt ${attempt}/${maxRetries} failed: ${identifierResult.message()}`);
            }
            if identifierResult is error {
                log:printError(string `[TOKEN EXCHANGE] Failed to store 2nd app identifiers after ${maxRetries} attempts — failing token exchange`);
                audit:auditTokenIssue(clientId, false, "Token exchange: failed to persist sub→patient mapping");
                return createTokenExchangeErrorResponse("server_error",
                    "Failed to establish patient identity mapping. Please retry.");
            }
        }
    }

    map<json> response = {
        "access_token": accessToken,
        "token_type": "bearer",
        "expires_in": expiresIn,
        "scope": scope,
        "patient": brokerScopedPatientId
    };
    if refreshToken is string {
        response["refresh_token"] = refreshToken;
    }

    log:printInfo(string `[TOKEN EXCHANGE] Asgardeo token issued: patient=${brokerScopedPatientId}`);
    log:printInfo("===============================================");

    audit:auditTokenIssue(clientId, true);
    return response;
}

// Check if the request is a token exchange request
public function isTokenExchangeRequest(string formData) returns boolean {
    log:printInfo(string `[TOKEN ROUTING] Form data received (length=${formData.length()})`);

    string? grantType = common:extractFormParameter(formData, "grant_type");
    log:printInfo(string `[TOKEN ROUTING] Extracted grant_type: ${grantType ?: "null"}`);

    if grantType is () {
        log:printInfo("[TOKEN ROUTING] No grant_type found, routing to SMART");
        return false;
    }
    string decodedGrantType = common:decodeUrlComponent(grantType);
    log:printInfo(string `[TOKEN ROUTING] Decoded grant_type: ${decodedGrantType}`);
    log:printInfo(string `[TOKEN ROUTING] Match: ${decodedGrantType == TOKEN_EXCHANGE_GRANT_TYPE}`);

    return decodedGrantType == TOKEN_EXCHANGE_GRANT_TYPE;
}

// Check if the request is a refresh token request
public function isRefreshTokenRequest(string formData) returns boolean {
    string? grantType = common:extractFormParameter(formData, "grant_type");
    if grantType is () {
        return false;
    }
    string decodedGrantType = common:decodeUrlComponent(grantType);
    return decodedGrantType == REFRESH_TOKEN_GRANT_TYPE;
}

// Process OAuth 2.0 Refresh Token request
public function processRefreshTokenRequest(http:Request req) returns json|http:BadRequest|http:Unauthorized {
    log:printInfo("========== REFRESH TOKEN REQUEST ==========");

    string|error formData = req.getTextPayload();
    if formData is error {
        return createTokenExchangeErrorResponse("invalid_request", "Failed to read request body");
    }

    string? refreshTokenRaw = common:extractFormParameter(formData, "refresh_token");
    if refreshTokenRaw is () {
        return createTokenExchangeErrorResponse("invalid_request", "Missing refresh_token parameter");
    }
    string refreshToken = common:decodeUrlComponent(refreshTokenRaw);

    json|error asgardeoResponse = refreshAsgardeoToken(refreshToken);
    if asgardeoResponse is error {
        log:printError("[REFRESH] Asgardeo refresh failed", asgardeoResponse);
        audit:auditTokenIssue("unknown", false, "Refresh failed: " + asgardeoResponse.message());
        return createTokenExchangeErrorResponse("invalid_grant", "Refresh token expired or invalid");
    }

    if asgardeoResponse !is map<json> {
        return createTokenExchangeErrorResponse("server_error", "Invalid response from authorization server");
    }

    json? atJson = asgardeoResponse["access_token"];
    if atJson !is string {
        return createTokenExchangeErrorResponse("server_error", "No access_token in refresh response");
    }
    string newAccessToken = atJson;

    int newExpiresIn = common:TOKEN_EXPIRY_SECONDS;
    json? expiresJson = asgardeoResponse["expires_in"];
    if expiresJson is int {
        newExpiresIn = expiresJson;
    }

    string newScope = tokenExchangeDefaultScopes;
    json? scopeJson = asgardeoResponse["scope"];
    if scopeJson is string {
        newScope = scopeJson;
    }

    string? newRefreshToken = ();
    json? newRtJson = asgardeoResponse["refresh_token"];
    if newRtJson is string {
        newRefreshToken = newRtJson;
    }

    string? resolvedPatient = ();
    string? resolvedClientAppId = ();

    json|error newPayload = auth:decodeJWTPayload(newAccessToken);
    if newPayload is map<json> {
        json? subJson = newPayload["sub"];
        if subJson is string {
            [string, string?]|error fhirResult = fhir:resolvePatientBySub(fhir:fhirServerClient, subJson);
            if fhirResult is [string, string?] {
                resolvedPatient = fhirResult[0];
                resolvedClientAppId = fhirResult[1];
                common:setUserPatient(subJson, fhirResult[0]);
                if resolvedClientAppId is string {
                    common:setUserClientApp(subJson, resolvedClientAppId);
                }
            } else {
                log:printWarn(string `[REFRESH] Could not resolve patient from sub: ${fhirResult.message()}`);
            }
        }
    }

    map<json> response = {
        "access_token": newAccessToken,
        "token_type": "bearer",
        "expires_in": newExpiresIn,
        "scope": newScope
    };
    if resolvedPatient is string {
        response["patient"] = resolvedPatient;
    }
    if newRefreshToken is string {
        response["refresh_token"] = newRefreshToken;
    }

    log:printInfo(string `[REFRESH] Token refreshed: patient=${resolvedPatient ?: "unknown"}`);
    log:printInfo("===========================================");
    audit:auditTokenIssue(resolvedClientAppId ?: "unknown", true);
    return response;
}

// Helper to create BadRequest response
function createBadRequestResponse(string description) returns http:BadRequest {
    return <http:BadRequest>{
        body: { "error": "invalid_request", "error_description": description }
    };
}

// Create invalid_token error response (401 Unauthorized)
function createInvalidTokenResponse(string description) returns http:Unauthorized {
    return <http:Unauthorized>{
        body: { "error": "invalid_token", "error_description": description }
    };
}

// Create token exchange error response (400 Bad Request)
function createTokenExchangeErrorResponse(string errorCode, string description) returns http:BadRequest {
    return <http:BadRequest>{
        body: { "error": errorCode, "error_description": description }
    };
}
