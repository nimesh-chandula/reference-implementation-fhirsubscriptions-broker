// Authentication and JWT utilities
// (Asgardeo token exchange and refresh logic live in modules/tokens.)

import ballerina/http;
import ballerina/lang.'array;

import ballerina/jwt;
import ballerina/log;
import ballerina/time;

import nimesh_chandula/broker.common;
import nimesh_chandula/broker.fhir;

// Static client registry for JWT validation (from Config.toml).
// Public so the root registry handler can list both static and dynamic entries.
public configurable map<common:ClientRegistration> clientRegistry = {};

// Dynamic client registry for runtime-registered clients (via admin API).
public map<common:ClientRegistration> dynamicClientRegistry = {};

// Expected audience for client assertions (MUST be HTTPS in production)
configurable string tokenAudience = "https://localhost:9090/broker/auth/token";

// ============================================================================
// SUBSCRIPTION TOKEN SIGNING CONFIGURATION (RSA-SHA256)
// ============================================================================
configurable string subscriptionTokenPrivateKeyPath = "/etc/choreo-secrets/broker-private.key";
configurable string subscriptionTokenCertPath = "/etc/choreo-secrets/broker-public.crt";
configurable string subscriptionTokenIssuer = "https://broker.example.org";
public configurable boolean requireNotificationAuthz = false;

// ============================================================================
// SUBSCRIPTION AUTHORIZATION ASGARDEO APP CONFIGURATION
// ============================================================================
configurable string subscriptionAuthzJwksUrl = "https://api.asgardeo.io/t/fhirbroker/oauth2/jwks";
configurable string subscriptionAuthzIssuer = "https://api.asgardeo.io/t/fhirbroker/oauth2/token";

// ============================================================================
// AUTHORIZATION CONFIGURATION
// ============================================================================
public configurable boolean authzEnabled = false;

// ============================================================================
// ASGARDEO ID TOKEN VALIDATION (1st Asgardeo app)
// ============================================================================
public configurable string asgardeoJwksUrl = "https://api.asgardeo.io/t/fhirbroker/oauth2/jwks";
public configurable string asgardeoIssuer = "https://api.asgardeo.io/t/fhirbroker/oauth2/token";
public configurable string asgardeoUserInfoUrl = "https://api.asgardeo.io/t/fhirbroker/oauth2/userinfo";

// ============================================================================
// JWT UTILITIES
// ============================================================================

// Validate client assertion (RS256) using JWKS with kid matching
public function validateClientAssertion(string clientAssertion) returns common:ClientAssertionInfo|error {
    log:printInfo("[JWT VALIDATION] Starting client assertion validation");

    [jwt:Header, jwt:Payload] [header, preliminaryPayload] = check jwt:decode(clientAssertion);

    if header.alg is () || header.alg != jwt:RS256 {
        return error("Unsupported JWT algorithm; RS256 is required");
    }
    log:printInfo("[JWT VALIDATION] Algorithm: RS256");

    string? kidOpt = header.kid;
    if kidOpt is () {
        return error("Missing kid (Key ID) in JWT header. JWKS implementation requires kid.");
    }
    string kid = kidOpt;
    log:printInfo(string `[JWT VALIDATION] Key ID (kid): ${kid}`);

    string? issuerOpt = preliminaryPayload.iss;
    if issuerOpt is () {
        return error("Missing iss claim in JWT");
    }
    string issuer = issuerOpt;
    log:printInfo(string `[JWT VALIDATION] Issuer: ${issuer}`);

    common:ClientRegistration? registration = ();
    string registrationKey = "";
    foreach var [key, reg] in clientRegistry.entries() {
        if reg.issuer == issuer {
            registration = reg;
            registrationKey = key;
            break;
        }
    }
    if registration is () {
        foreach var [key, reg] in dynamicClientRegistry.entries() {
            if reg.issuer == issuer {
                registration = reg;
                registrationKey = key;
                break;
            }
        }
    }

    if registration is () {
        string availableIssuers = "";
        foreach var reg in clientRegistry {
            availableIssuers = availableIssuers + reg.issuer + ", ";
        }
        foreach var reg in dynamicClientRegistry {
            availableIssuers = availableIssuers + reg.issuer + ", ";
        }
        log:printError(string `[JWT VALIDATION] Unknown issuer: ${issuer}`);
        return error(string `Unknown client issuer: '${issuer}'. Registered issuers: ${availableIssuers}`);
    }
    log:printInfo(string `[JWT VALIDATION] Found registration: ${registrationKey}`);

    log:printInfo(string `[JWT VALIDATION] Configuring validator with JWKS URI: ${registration.jwksUri}`);

    jwt:ValidatorConfig validatorConfig = {
        issuer: registration.issuer,
        audience: tokenAudience,
        clockSkew: common:JWT_CLOCK_SKEW,
        signatureConfig: {
            jwksConfig: {
                url: registration.jwksUri,
                cacheConfig: {
                    capacity: 10,
                    evictionFactor: 0.25,
                    evictionPolicy: "LRU",
                    defaultMaxAge: 3600
                }
            }
        }
    };

    log:printInfo("[JWT VALIDATION] Validating JWT signature with JWKS from URI");
    jwt:Payload validatedPayload = check jwt:validate(clientAssertion, validatorConfig);
    log:printInfo("[JWT VALIDATION] JWT signature validated successfully");

    log:printInfo(string `[JWT VALIDATION] Validated payload keys: ${validatedPayload.keys().toString()}`);
    json payloadJson = validatedPayload.toJson();
    log:printInfo(string `[JWT VALIDATION] Full validated payload: ${payloadJson.toJsonString()}`);

    map<json> claims = {};

    anydata customClaimsData = validatedPayload["customClaims"];
    if customClaimsData is map<json> {
        claims = customClaimsData.clone();
        log:printInfo(string `[JWT VALIDATION] Extracted custom claims from customClaims field: ${claims.keys().toString()}`);
    } else {
        log:printInfo("[JWT VALIDATION] No customClaims field found, extracting from payload root");

        json payloadJsonData = validatedPayload.toJson();
        if payloadJsonData is map<json> {
            foreach [string, json] [key, value] in payloadJsonData.entries() {
                if key != "iss" && key != "sub" && key != "aud" && key != "exp" &&
                   key != "iat" && key != "nbf" && key != "jti" {
                    claims[key] = value;
                }
            }
            log:printInfo(string `[JWT VALIDATION] Extracted custom claims from payload root: ${claims.keys().toString()}`);
        }
    }

    if validatedPayload.iss is string {
        claims["iss"] = validatedPayload.iss;
    }
    if validatedPayload.sub is string {
        claims["sub"] = validatedPayload.sub;
    }
    if validatedPayload.aud is string || validatedPayload.aud is string[] {
        claims["aud"] = validatedPayload.aud;
    }
    if validatedPayload.exp is int {
        claims["exp"] = validatedPayload.exp;
    }
    if validatedPayload.iat is int {
        claims["iat"] = validatedPayload.iat;
    }

    log:printInfo(string `[JWT VALIDATION] Total claims extracted: ${claims.keys().toString()}`);
    log:printInfo(string `[JWT VALIDATION] Validation complete for client: ${issuer}`);
    return {
        clientId: issuer,
        claims: claims,
        registration: registration
    };
}

// Decode JWT payload without cryptographic validation
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

// Convert bytes to base64url encoding (used in JWTs)
function toBase64Url(byte[] data) returns string {
    string base64Value = 'array:toBase64(data);
    string:RegExp plusPattern = re `\+`;
    string result1 = plusPattern.replaceAll(base64Value, "-");
    string:RegExp slashPattern = re `/`;
    string result2 = slashPattern.replaceAll(result1, "_");
    string:RegExp paddingPattern = re `=+$`;
    string finalResult = paddingPattern.replaceAll(result2, "");
    return finalResult;
}

// Generate SMART-compliant access token with FHIR context
public function generateSmartAccessToken(string patientId, common:AuthorizationDetail[] authDetails, string clientId) returns string|error {
    log:printInfo(string `[TOKEN GEN] Generating SMART access token for patient: ${patientId}`);

    json fhirContextClaim = {
        "reference": string `Patient/${patientId}`,
        "resourceType": "Patient"
    };

    string scopeStr = generateSmartScopes(authDetails);

    json tokenPayload = {
        "sub": patientId,
        "patient": patientId,
        "client_id": clientId,
        "scope": scopeStr,
        "aud": "https://fhir-server/",
        "iat": time:utcNow()[0],
        "exp": time:utcNow()[0] + common:TOKEN_EXPIRY_SECONDS,
        "fhirContext": [fhirContextClaim]
    };

    string headerJson = string `{"alg":"none","typ":"JWT"}`;
    string header = toBase64Url(headerJson.toBytes());
    string payload = toBase64Url(tokenPayload.toJsonString().toBytes());

    string accessToken = string `${header}.${payload}.mock-sig`;
    log:printInfo(string `[TOKEN GEN] Access token generated with scope: ${scopeStr}`);

    return accessToken;
}

// Generate SMART-compliant scope strings from authorization details
public function generateSmartScopes(common:AuthorizationDetail[] authDetails) returns string {
    string[] scopes = [];
    foreach common:AuthorizationDetail detail in authDetails {
        foreach string action in detail.actions {
            string resourceType = detail.resourceType;
            string scope = string `system/${resourceType}.${action}`;
            scopes.push(scope);
        }
    }
    return string:'join(" ", ...scopes);
}

// Validate requested scopes against the registered client allow-list
public function validateAllowedScopes(common:AuthorizationDetail[] authDetails, string[] allowedScopes) returns error? {
    if allowedScopes.length() == 0 {
        return ();
    }

    map<boolean> allowedSet = {};
    foreach string scope in allowedScopes {
        allowedSet[scope] = true;
    }

    string requestedScopes = generateSmartScopes(authDetails);
    string:RegExp splitPattern = re `\s+`;
    string[] requested = splitPattern.split(requestedScopes);

    foreach string scope in requested {
        if scope.length() == 0 {
            continue;
        }
        if !allowedSet.hasKey(scope) {
            return error(string `Requested scope not allowed: ${scope}`);
        }
    }

    return ();
}

// Extract bearer token from Authorization header
public function extractBearerToken(string authorization) returns string|error {
    if !authorization.startsWith("Bearer ") {
        return error("Authorization must use Bearer scheme");
    }
    return authorization.substring(7);
}

// Extract client ID from access token
// Priority: client_app_id (2nd Asgardeo app custom claim) → client_id (SMART tokens)
//           → sub with mapping lookup (interim fallback) → sub → iss
public function extractClientIdFromAccessToken(string accessToken) returns string|error {
    json|error payload = decodeJWTPayload(accessToken);
    if payload is error || payload !is map<json> {
        return error("Invalid access token");
    }

    map<json> tokenMap = <map<json>>payload;

    json? clientAppIdJson = tokenMap["client_app_id"];
    if clientAppIdJson is string {
        return clientAppIdJson;
    }

    json? clientIdJson = tokenMap["client_id"];
    if clientIdJson is string {
        return clientIdJson;
    }

    json? subJson = tokenMap["sub"];
    if subJson is string {
        string? clientAppId = common:getUserClientApp(subJson);
        if clientAppId is string {
            return clientAppId;
        }
        [string, string?]|error fhirResult = fhir:resolvePatientBySub(fhir:fhirServerClient, subJson);
        if fhirResult is [string, string?] {
            string? resolvedClientAppId = fhirResult[1];
            if resolvedClientAppId is string {
                common:setUserClientApp(subJson, resolvedClientAppId);
                return resolvedClientAppId;
            }
        }
        return subJson;
    }

    json? issJson = tokenMap["iss"];
    if issJson is string {
        return issJson;
    }

    return error("Missing client identifier in access token");
}

// Validate permission ticket follows SMART spec
public function validateSmartPermissionTicket(json permissionTicket) returns boolean|error {
    log:printInfo("[SMART VALIDATION] Validating permission ticket");

    if permissionTicket !is map<json> {
        log:printError("[SMART VALIDATION] Permission ticket is not a JSON object");
        return false;
    }

    map<json> ticketMap = <map<json>>permissionTicket;

    if !ticketMap.hasKey("iss") || !ticketMap.hasKey("aud") {
        log:printError("[SMART VALIDATION] Missing iss or aud claim");
        return false;
    }

    if !ticketMap.hasKey("exp") {
        log:printError("[SMART VALIDATION] Missing exp claim");
        return false;
    }

    json? expJson = ticketMap["exp"];
    if expJson is int {
        int currentTime = time:utcNow()[0];
        if currentTime > expJson {
            log:printError("[SMART VALIDATION] Permission ticket expired");
            return error("Permission ticket expired");
        }
    }

    if !ticketMap.hasKey("authorization_details") && !ticketMap.hasKey("permission_tickets") {
        log:printError("[SMART VALIDATION] Missing authorization_details or permission_tickets");
        return error("Missing authorization_details or permission_tickets");
    }

    log:printInfo("[SMART VALIDATION] Permission ticket valid");
    return true;
}

// Extract authorization details from permission ticket
public function extractSmartAuthorizationDetails(json permissionTicket) returns common:AuthorizationDetail[]|error {
    log:printInfo("[SMART AUTH] Extracting authorization details");

    if permissionTicket !is map<json> {
        log:printError("[SMART AUTH] Permission ticket is not a JSON object");
        return error("Invalid permission ticket format");
    }

    map<json> ticketMap = <map<json>>permissionTicket;

    json? authDetailsJson = ticketMap["authorization_details"];
    if authDetailsJson is json[] {
        common:AuthorizationDetail[] details = [];
        foreach json detail in authDetailsJson {
            common:AuthorizationDetail authDetail = check detail.cloneWithType();
            details.push(authDetail);
        }
        return details;
    }

    json? permissionTicketsJson = ticketMap["permission_tickets"];
    if permissionTicketsJson is json[] && permissionTicketsJson.length() > 0 {
        json firstTicket = permissionTicketsJson[0];
        if firstTicket is map<json> {
            json? ticketContext = firstTicket["ticket_context"];
            if ticketContext is map<json> {
                json? capability = ticketContext["capability"];
                if capability is map<json> {
                    json? scopesJsonRaw = capability["scopes"];
                    if scopesJsonRaw is json[] {
                        string[] scopes = [];
                        foreach json scopeItem in scopesJsonRaw {
                            if scopeItem is string {
                                scopes.push(scopeItem);
                            }
                        }

                        if scopes.length() > 0 {
                            common:AuthorizationDetail[] details = [];
                            foreach string scope in scopes {
                                string:RegExp slashPattern = re `/`;
                                string[] parts = slashPattern.split(scope);
                                if parts.length() == 2 {
                                    string:RegExp dotPattern = re `\.`;
                                    string[] resourceParts = dotPattern.split(parts[1]);
                                    if resourceParts.length() == 2 {
                                        string resourceType = resourceParts[0];
                                        string action = resourceParts[1];
                                        common:AuthorizationDetail detail = {
                                            'type: "fhir",
                                            fhirContext: [],
                                            actions: [action],
                                            resourceType: resourceType
                                        };
                                        details.push(detail);
                                    }
                                }
                            }
                            if details.length() > 0 {
                                return details;
                            }
                        }
                    }
                }
            }
        }
    }

    log:printError("[SMART AUTH] Invalid authorization_details or permission_tickets format");
    return error("Invalid authorization_details or permission_tickets format");
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
                    capacity: 10,
                    evictionFactor: 0.25,
                    evictionPolicy: "LRU",
                    defaultMaxAge: 3600
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

    log:printInfo(string `[TOKEN EXCHANGE] Demographics extracted from ID token: ${demographics.family}, ${demographics.given.toString()}, DOB: ${demographics.birthDate}`);

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

    log:printInfo(string `[TOKEN EXCHANGE] Parsed demographics: ${demographics.family}, ${demographics.given.toString()}, DOB: ${demographics.birthDate}`);

    return demographics;
}

// Generate broker access token for token exchange flow
public function generateBrokerAccessToken(string patientId, string subject, string scope) returns string|error {
    log:printInfo(string `[TOKEN EXCHANGE] Generating broker access token for patient: ${patientId}`);

    json tokenPayload = {
        "sub": subject,
        "patient": patientId,
        "scope": scope,
        "aud": "https://fhir-broker/",
        "iss": "https://broker.example.org",
        "iat": time:utcNow()[0],
        "exp": time:utcNow()[0] + common:TOKEN_EXPIRY_SECONDS,
        "token_type": "bearer"
    };

    string headerJson = string `{"alg":"none","typ":"JWT"}`;
    string header = toBase64Url(headerJson.toBytes());
    string payload = toBase64Url(tokenPayload.toJsonString().toBytes());

    string accessToken = string `${header}.${payload}.broker-sig`;
    log:printInfo(string `[TOKEN EXCHANGE] Access token generated with scope: ${scope}`);

    return accessToken;
}

// ============================================================================
// SUBSCRIPTION TOKEN GENERATION & VALIDATION (RSA-SHA256)
// ============================================================================

// Generate an RSA-signed subscription token for a client
public function generateSubscriptionToken(string clientId, string subscriptionId, string brokerScopedPatientId, string[] resourceTypes) returns string|error {
    log:printInfo(string `[SUBSCRIPTION TOKEN] Generating RSA-signed token for client=${clientId}, subscription=${subscriptionId}`);

    map<json> customClaims = {
        "client_id": clientId,
        "subscription_id": subscriptionId,
        "patient": brokerScopedPatientId,
        "resource_types": resourceTypes.toJson(),
        "token_type": "subscription"
    };

    jwt:IssuerConfig issuerConfig = {
        issuer: subscriptionTokenIssuer,
        expTime: <decimal>common:SUBSCRIPTION_TOKEN_EXPIRY_SECONDS,
        signatureConfig: {
            algorithm: jwt:RS256,
            config: {
                keyFile: subscriptionTokenPrivateKeyPath
            }
        },
        customClaims: customClaims
    };

    string token = check jwt:issue(issuerConfig);
    log:printInfo(string `[SUBSCRIPTION TOKEN] Token generated successfully for client=${clientId}`);
    return token;
}

// Validate a broker-issued subscription token (RSA-SHA256)
public function validateSubscriptionToken(string token) returns common:ValidatedSubscriptionToken|error {
    log:printInfo("[SUBSCRIPTION TOKEN] Validating broker-issued subscription token");

    jwt:ValidatorConfig validatorConfig = {
        issuer: subscriptionTokenIssuer,
        clockSkew: common:JWT_CLOCK_SKEW,
        signatureConfig: {
            certFile: subscriptionTokenCertPath
        }
    };

    jwt:Payload validatedPayload = check jwt:validate(token, validatorConfig);

    map<json> claims = {};
    json payloadJson = validatedPayload.toJson();
    if payloadJson is map<json> {
        claims = payloadJson.clone();
    }

    string? clientId = ();
    json? clientIdJson = claims["client_id"];
    if clientIdJson is string {
        clientId = clientIdJson;
    }

    string? subscriptionId = ();
    json? subIdJson = claims["subscription_id"];
    if subIdJson is string {
        subscriptionId = subIdJson;
    }

    string? patient = ();
    json? patientJson = claims["patient"];
    if patientJson is string {
        patient = patientJson;
    }

    string[]? resourceTypes = ();
    json? rtJson = claims["resource_types"];
    if rtJson is json[] {
        string[] rt = [];
        foreach json item in rtJson {
            if item is string {
                rt.push(item);
            }
        }
        resourceTypes = rt;
    }

    if clientId is () || subscriptionId is () || patient is () {
        return error("Subscription token missing required claims (client_id, subscription_id, patient)");
    }

    log:printInfo(string `[SUBSCRIPTION TOKEN] Token validated: client=${clientId}, patient=${patient}`);
    return {
        clientId: clientId,
        subscriptionId: subscriptionId,
        patient: patient,
        resourceTypes: resourceTypes
    };
}

// Validate an access token for subscription endpoints
// Tries broker-issued subscription token first, then falls back to Asgardeo token
public function validateSubscriptionAccessToken(string token) returns common:ValidatedSubscriptionToken|error {
    common:ValidatedSubscriptionToken|error brokerResult = validateSubscriptionToken(token);
    if brokerResult is common:ValidatedSubscriptionToken {
        return brokerResult;
    }
    log:printInfo("[SUBSCRIPTION AUTH] Not a broker token, trying Asgardeo validation");

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
                log:printInfo(string `[SUBSCRIPTION AUTH] Resolved patient from FHIR: ${patient ?: ""}`);
            }
        }
    }

    log:printInfo(string `[SUBSCRIPTION AUTH] Asgardeo token validated: client=${clientId}`);
    return {
        clientId: clientId,
        subscriptionId: "",
        patient: patient ?: ""
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
        return <http:Unauthorized>{
            body: {
                "error": "unauthorized",
                "error_description": "Invalid Authorization header: " + tokenResult.message()
            }
        };
    }

    common:ValidatedSubscriptionToken|error validationResult = validateSubscriptionAccessToken(tokenResult);
    if validationResult is error {
        log:printWarn(string `[AUTHZ] Token validation failed: ${validationResult.message()}`);
        return <http:Unauthorized>{
            body: {
                "error": "invalid_token",
                "error_description": "Token validation failed: " + validationResult.message()
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
