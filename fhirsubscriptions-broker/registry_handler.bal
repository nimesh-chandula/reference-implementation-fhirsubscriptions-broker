// Client registry management handlers

import ballerina/http;
import ballerina/log;

import nimesh_chandula/broker.audit;
import nimesh_chandula/broker.auth;
import nimesh_chandula/broker.common;

// List all registered clients (both static from Config.toml and dynamic)
function handleListRegistry() returns json {
    map<json> allClients = {};

    foreach var [key, reg] in auth:clientRegistry.entries() {
        allClients[key] = {
            "issuer": reg.issuer,
            "jwksUri": reg.jwksUri,
            "allowedScopes": reg.allowedScopes,
            "source": "config"
        };
    }

    foreach var [key, reg] in auth:dynamicClientRegistry.entries() {
        allClients[key] = {
            "issuer": reg.issuer,
            "jwksUri": reg.jwksUri,
            "allowedScopes": reg.allowedScopes,
            "source": "dynamic"
        };
    }

    return allClients;
}

// Register a new client dynamically
function handleRegisterClient(http:Request req) returns json|http:BadRequest {
    json|error payload = req.getJsonPayload();
    if payload is error {
        return <http:BadRequest>{
            body: {"error": "invalid_request", "error_description": "Invalid JSON payload"}
        };
    }

    json|error nameJson = payload.name;
    json|error issuerJson = payload.issuer;
    json|error jwksUriJson = payload.jwksUri;

    if nameJson is error || issuerJson is error || jwksUriJson is error {
        return <http:BadRequest>{
            body: {"error": "invalid_request", "error_description": "Missing required fields: name, issuer, jwksUri"}
        };
    }

    string name = nameJson.toString();
    string issuer = issuerJson.toString();
    string jwksUri = jwksUriJson.toString();

    if name.trim().length() == 0 || issuer.trim().length() == 0 || jwksUri.trim().length() == 0 {
        return <http:BadRequest>{
            body: {"error": "invalid_request", "error_description": "Fields name, issuer, jwksUri must not be empty"}
        };
    }

    string[]? allowedScopes = ();
    json|error scopesJson = payload.allowedScopes;
    if scopesJson is json {
        json[]|error scopeArr = scopesJson.ensureType();
        if scopeArr is json[] {
            string[] scopes = [];
            foreach var s in scopeArr {
                scopes.push(s.toString());
            }
            allowedScopes = scopes;
        }
    }

    foreach var reg in auth:clientRegistry {
        if reg.issuer == issuer {
            return <http:BadRequest>{
                body: {"error": "duplicate_issuer", "error_description": string `Issuer '${issuer}' is already registered in static config`}
            };
        }
    }
    foreach var reg in auth:dynamicClientRegistry {
        if reg.issuer == issuer {
            return <http:BadRequest>{
                body: {"error": "duplicate_issuer", "error_description": string `Issuer '${issuer}' is already registered dynamically`}
            };
        }
    }

    common:ClientRegistration newClient = {
        issuer: issuer,
        jwksUri: jwksUri,
        allowedScopes: allowedScopes
    };

    auth:dynamicClientRegistry[name] = newClient;

    log:printInfo(string `[CLIENT REGISTRY] Registered new client: ${name} (issuer: ${issuer})`);

    audit:auditClientRegistered(name, true);

    return {
        "message": string `Client '${name}' registered successfully`,
        "client": {
            "name": name,
            "issuer": issuer,
            "jwksUri": jwksUri,
            "allowedScopes": allowedScopes,
            "source": "dynamic"
        }
    };
}

// Delete a dynamically registered client
function handleDeleteClient(string clientName) returns json|http:NotFound|http:BadRequest {
    if auth:clientRegistry.hasKey(clientName) {
        return <http:BadRequest>{
            body: {"error": "cannot_delete", "error_description": string `Client '${clientName}' is registered in Config.toml and cannot be deleted via API`}
        };
    }

    if !auth:dynamicClientRegistry.hasKey(clientName) {
        return <http:NotFound>{
            body: {"error": "not_found", "error_description": string `Client '${clientName}' not found in dynamic registry`}
        };
    }

    _ = auth:dynamicClientRegistry.remove(clientName);
    log:printInfo(string `[CLIENT REGISTRY] Deleted client: ${clientName}`);

    audit:auditClientDeleted(clientName, true);

    return {
        "message": string `Client '${clientName}' deleted successfully`
    };
}
