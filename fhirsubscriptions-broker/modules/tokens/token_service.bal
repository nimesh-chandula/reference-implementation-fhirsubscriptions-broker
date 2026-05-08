// Token Service - SMART Permission Tickets and OAuth 2.0 Token Exchange (RFC 8693)

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

// Process SMART Permission Tickets token request
public function processTokenRequest(http:Request req) returns json|http:BadRequest {
    log:printInfo("========== SMART TOKEN REQUEST RECEIVED ==========");

    string|error formData = req.getTextPayload();
    if formData is error {
        log:printError("Failed to read request body");
        return createBadRequestResponse("Failed to read request body");
    }

    string? clientAssertion = common:extractFormParameter(formData, "client_assertion");
    if clientAssertion is () {
        log:printError("Missing client_assertion");
        return createBadRequestResponse("Missing client_assertion parameter");
    }

    common:ClientAssertionInfo|error assertionInfo = auth:validateClientAssertion(clientAssertion);
    if assertionInfo is error {
        log:printError("Client assertion validation failed", assertionInfo);
        audit:auditTokenIssue("unknown", false, "Client assertion validation failed: " + assertionInfo.message());
        return createBadRequestResponse(assertionInfo.message());
    }

    map<json> clientAssertionMap = assertionInfo.claims;
    string clientId = assertionInfo.clientId;
    common:ClientRegistration registration = assertionInfo.registration;
    log:printInfo(string `Client: ${clientId}`);

    common:ClientDemographics? demographics = parseDemographicsFromJwtClaims(clientAssertionMap);

    if demographics is () {
        log:printError("Missing or invalid demographics in client assertion");
        log:printError(string `Full JWT claims: ${clientAssertionMap.toJsonString()}`);
        audit:auditTokenIssue(clientId, false, "Missing or invalid demographics in client assertion");
        return createBadRequestResponse("Missing or invalid demographics in client_assertion");
    }

    log:printInfo(string `Demographics: ${demographics.family}, ${demographics.given.toString()}, DOB: ${demographics.birthDate}`);

    json? systemIdJson = clientAssertionMap["systemId"];
    if systemIdJson !is string || systemIdJson.trim() == "" {
        log:printError("Missing systemId in client assertion");
        audit:auditTokenIssue(clientId, false, "Missing systemId in client assertion");
        return createBadRequestResponse("Missing 'systemId' in client_assertion. systemId is required to identify the source system (e.g., 'H001').");
    }
    string systemId = systemIdJson;

    if !clientAssertionMap.hasKey("authorization_details") && !clientAssertionMap.hasKey("permission_tickets") {
        log:printError("Missing authorization_details or permission_tickets in client assertion");
        audit:auditTokenIssue(clientId, false, "Missing authorization_details or permission_tickets");
        return createBadRequestResponse("Missing authorization_details or permission_tickets in client_assertion");
    }

    boolean|error isValidResult = auth:validateSmartPermissionTicket(clientAssertionMap);
    if isValidResult is error {
        log:printError("Invalid permission ticket", isValidResult);
        audit:auditTokenIssue(clientId, false, "Invalid permission ticket: " + isValidResult.message());
        return createBadRequestResponse(isValidResult.message());
    }
    if !isValidResult {
        log:printError("Permission ticket validation failed");
        audit:auditTokenIssue(clientId, false, "Permission ticket validation failed");
        return createBadRequestResponse("Invalid or expired permission ticket");
    }

    common:AuthorizationDetail[]|error authDetails = auth:extractSmartAuthorizationDetails(clientAssertionMap);
    if authDetails is error {
        log:printError("Failed to extract authorization details", authDetails);
        audit:auditTokenIssue(clientId, false, "Failed to extract authorization details: " + authDetails.message());
        return createBadRequestResponse(authDetails.message());
    }
    if authDetails.length() == 0 {
        log:printError("No authorization details found");
        audit:auditTokenIssue(clientId, false, "No authorization details found");
        return createBadRequestResponse("No authorization details found");
    }

    string[] allowedScopes = registration.allowedScopes ?: [];
    error? scopeValidationResult = auth:validateAllowedScopes(authDetails, allowedScopes);
    if scopeValidationResult is error {
        log:printError("Requested scope not allowed", scopeValidationResult);
        audit:auditTokenIssue(clientId, false, "Scope not allowed: " + scopeValidationResult.message());
        return createBadRequestResponse(scopeValidationResult.message());
    }

    string|error resolveResult = resolveOrCreatePatient(demographics, systemId);
    if resolveResult is error {
        audit:auditTokenIssue(clientId, false, "Failed to resolve patient: " + resolveResult.message());
        return createBadRequestResponse("Failed to create patient record");
    }
    string brokerScopedPatientId = resolveResult;

    common:trackClientSubscription(clientId, brokerScopedPatientId);

    string|error accessToken = auth:generateSmartAccessToken(brokerScopedPatientId, authDetails, clientId);
    if accessToken is error {
        log:printError("Failed to generate SMART access token", accessToken);
        audit:auditTokenIssue(clientId, false, "Failed to generate access token: " + accessToken.message());
        return createBadRequestResponse("Failed to generate access token");
    }

    string scope = auth:generateSmartScopes(authDetails);

    json response = {
        "access_token": accessToken,
        "token_type": "bearer",
        "expires_in": common:TOKEN_EXPIRY_SECONDS,
        "scope": scope,
        "patient": brokerScopedPatientId
    };

    log:printInfo(string `SMART TOKEN ISSUED: patient=${brokerScopedPatientId}, client=${clientId}, scope=${scope}`);
    log:printInfo("================================================");

    audit:auditTokenIssue(clientId, true);
    return response;
}

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
        return createInvalidTokenResponse(validationResult.message());
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

    log:printInfo(string `[TOKEN EXCHANGE] Using demographics: ${demographics.family}, DOB: ${demographics.birthDate}`);

    string|error resolveResult = resolveOrCreatePatient(demographics, "https://asgardeo.io/users");
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

    log:printInfo(string `[TOKEN EXCHANGE] Asgardeo token issued: patient=${brokerScopedPatientId}, subject=${validationResult.subject}`);
    log:printInfo("===============================================");

    audit:auditTokenIssue(clientId, true);
    return response;
}

// Check if the request is a token exchange request
public function isTokenExchangeRequest(string formData) returns boolean {
    log:printInfo(string `[TOKEN ROUTING] Form data received: ${formData.substring(0, formData.length() < 200 ? formData.length() : 200)}...`);

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
