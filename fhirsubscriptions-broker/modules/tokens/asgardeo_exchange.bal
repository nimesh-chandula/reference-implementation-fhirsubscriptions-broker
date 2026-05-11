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

// 2nd Asgardeo App — Token Exchange and Refresh
// Broker exchanges 1st app's ID token for a signed access token from this app
// using RFC 8693 Token Exchange grant type.

import ballerina/http;
import ballerina/log;

// 2nd Asgardeo app configuration. The broker authenticates as a confidential
// client to mint access tokens with the broker's required custom claims.
configurable string asgardeoTokenExchangeUrl = "https://api.asgardeo.io/t/orgfhirbroker/oauth2/token";
configurable string asgardeoTokenExchangeClientId = "";
configurable string asgardeoTokenExchangeClientSecret = "";
configurable string asgardeoTokenExchangeScopes = "system/Subscription.crud system/Patient.read";

// Exchange a 1st Asgardeo app ID token for a signed access token from the 2nd Asgardeo app
function exchangeTokenWithAsgardeo(string subjectToken, string clientAppId, string brokerScopedPatientId) returns json|error {
    log:printInfo("[ASGARDEO TOKEN EXCHANGE] Calling 2nd Asgardeo app for token exchange");

    if asgardeoTokenExchangeClientId == "" || asgardeoTokenExchangeClientSecret == "" {
        return error("2nd Asgardeo app credentials not configured (asgardeoTokenExchangeClientId/Secret)");
    }

    http:Client|error tokenClient = new (asgardeoTokenExchangeUrl, {
        timeout: 15
    });

    if tokenClient is error {
        log:printError(string `[ASGARDEO TOKEN EXCHANGE] Failed to create HTTP client: ${tokenClient.message()}`);
        return error("Failed to connect to 2nd Asgardeo app: " + tokenClient.message());
    }

    string formBody = string `grant_type=${TOKEN_EXCHANGE_GRANT_TYPE}`
        + string `&subject_token=${subjectToken}`
        + string `&subject_token_type=urn:ietf:params:oauth:token-type:jwt`
        + string `&client_id=${asgardeoTokenExchangeClientId}`
        + string `&client_secret=${asgardeoTokenExchangeClientSecret}`
        + string `&scope=${asgardeoTokenExchangeScopes}`
        + string `&client_app_id=${clientAppId}`
        + string `&patient=${brokerScopedPatientId}`;

    http:Request req = new;
    req.setTextPayload(formBody, "application/x-www-form-urlencoded");

    http:Response|error response = tokenClient->post("", req);

    if response is error {
        log:printError(string `[ASGARDEO TOKEN EXCHANGE] Token exchange call failed: ${response.message()}`);
        return error("Token exchange with 2nd Asgardeo app failed: " + response.message());
    }

    int statusCode = response.statusCode;
    json|error responseBody = response.getJsonPayload();

    if responseBody is error {
        log:printError(string `[ASGARDEO TOKEN EXCHANGE] Failed to parse response: ${responseBody.message()}`);
        return error("Invalid response from 2nd Asgardeo app");
    }

    if statusCode != 200 {
        string errorDesc = "";
        if responseBody is map<json> {
            json? errJson = responseBody["error_description"];
            if errJson is string {
                errorDesc = errJson;
            }
        }
        log:printError(string `[ASGARDEO TOKEN EXCHANGE] Token exchange failed (${statusCode}): ${errorDesc}`);
        return error(string `2nd Asgardeo app token exchange failed: ${errorDesc}`);
    }

    log:printInfo("[ASGARDEO TOKEN EXCHANGE] Token exchange successful");
    return responseBody;
}

// Refresh an Asgardeo access token using a refresh_token grant
function refreshAsgardeoToken(string refreshToken) returns json|error {
    log:printInfo("[ASGARDEO REFRESH] Calling 2nd Asgardeo app for token refresh");

    if asgardeoTokenExchangeClientId == "" || asgardeoTokenExchangeClientSecret == "" {
        return error("2nd Asgardeo app credentials not configured");
    }

    http:Client|error tokenClient = new (asgardeoTokenExchangeUrl, {
        timeout: 15
    });
    if tokenClient is error {
        return error("Failed to connect to Asgardeo: " + tokenClient.message());
    }

    string formBody = "grant_type=refresh_token"
        + string `&refresh_token=${refreshToken}`
        + string `&client_id=${asgardeoTokenExchangeClientId}`
        + string `&client_secret=${asgardeoTokenExchangeClientSecret}`;

    http:Request req = new;
    req.setTextPayload(formBody, "application/x-www-form-urlencoded");

    http:Response|error response = tokenClient->post("", req);
    if response is error {
        return error("Refresh call failed: " + response.message());
    }

    json|error responseBody = response.getJsonPayload();
    if responseBody is error {
        return error("Invalid response from Asgardeo refresh");
    }

    if response.statusCode != 200 {
        string errorDesc = "";
        if responseBody is map<json> {
            json? errJson = responseBody["error_description"];
            if errJson is string {
                errorDesc = errJson;
            }
        }
        log:printError(string `[ASGARDEO REFRESH] Refresh failed (${response.statusCode}): ${errorDesc}`);
        return error(string `Asgardeo refresh failed: ${errorDesc}`);
    }

    log:printInfo("[ASGARDEO REFRESH] Token refresh successful");
    return responseBody;
}
