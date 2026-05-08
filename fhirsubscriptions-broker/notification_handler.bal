// Notification processing and retrieval handlers

import ballerina/http;
import ballerina/log;

import wso2healthcare/broker.audit;
import wso2healthcare/broker.common;
import wso2healthcare/broker.fhir;
import wso2healthcare/broker.mpi;

// Handle incoming FHIR notification bundle
function handleNotificationRequest(json payload) returns http:Ok|http:BadRequest|http:InternalServerError {
    log:printInfo("========== FHIR NOTIFICATION RECEIVED ==========");

    if payload !is map<json> {
        log:printError("[NOTIFICATION] Payload is not a valid JSON object");
        return <http:BadRequest>{};
    }

    map<json> fhirNotification = payload;
    log:printInfo(string `[NOTIFICATION] Payload type: ${(typeof payload).toString()}`);

    log:printInfo("[NOTIFICATION] Step 1: Grouping resources by patient");
    map<common:PatientResourceGroup> patientGroups = fhir:groupResourcesByPatient(fhirNotification);

    if patientGroups.length() == 0 {
        log:printWarn("[NOTIFICATION] No patient resources found in notification Bundle");
        return <http:Ok>{};
    }

    log:printInfo(string `[NOTIFICATION] Found ${patientGroups.length()} patients in notification`);

    audit:auditNotificationReceived("external", patientGroups.length(), true);

    log:printInfo("[NOTIFICATION] Step 2: Resolving patients through MPI");

    common:PatientResolutionResult[] resolvedPatients = [];
    common:PatientResolutionResult[] failedPatients = [];

    foreach string localRef in patientGroups.keys() {
        common:PatientResourceGroup? group = patientGroups[localRef];
        if group is common:PatientResourceGroup {
            common:PatientResolutionResult result = mpi:resolvePatientThroughMPI(group);

            if result.brokerScopedPatientId is string {
                resolvedPatients.push(result);
                log:printInfo(string `[NOTIFICATION] Patient ${localRef} resolved to: ${<string>result.brokerScopedPatientId} (${result.status})`);
            } else {
                failedPatients.push(result);
                log:printWarn(string `[NOTIFICATION] Patient ${localRef} resolution failed: ${result.message ?: "unknown"}`);
            }
        }
    }

    log:printInfo(string `[NOTIFICATION] Resolution complete: ${resolvedPatients.length()} resolved, ${failedPatients.length()} failed`);

    log:printInfo("[NOTIFICATION] Step 3: Routing notifications via Group membership");

    int totalClientsMatched = 0;
    int totalNotificationsSent = 0;
    int totalNotificationsFailed = 0;
    json[] patientResults = [];

    foreach common:PatientResolutionResult resolution in resolvedPatients {
        string brokerScopedId = <string>resolution.brokerScopedPatientId;

        log:printInfo(string `[NOTIFICATION] Querying group memberships for patient: ${brokerScopedId}`);

        common:GroupMembershipResult[]|error groupResults = fhir:searchGroupsByPatient(fhir:fhirServerClient, brokerScopedId);

        if groupResults is error {
            log:printError(string `[NOTIFICATION] Failed to search groups for ${brokerScopedId}: ${groupResults.message()}`);
            patientResults.push({
                "localPatientRef": resolution.localPatientRef,
                "brokerScopedPatientId": brokerScopedId,
                "status": "group_search_failed",
                "error": groupResults.message()
            });
            continue;
        }

        if groupResults.length() == 0 {
            log:printInfo(string `[NOTIFICATION] No group memberships found for patient: ${brokerScopedId}`);
            patientResults.push({
                "localPatientRef": resolution.localPatientRef,
                "brokerScopedPatientId": brokerScopedId,
                "resolutionStatus": resolution.status,
                "clientsMatched": 0,
                "notificationsSent": 0
            });
            continue;
        }

        common:PatientResourceGroup? originalGroup = patientGroups[resolution.localPatientRef];
        if originalGroup is () {
            continue;
        }

        map<json>[] resourceBundles = fhir:buildPerResourceNotificationBundles(originalGroup, brokerScopedId);

        int patientSuccessCount = 0;
        int patientFailCount = 0;
        int clientsMatched = 0;

        foreach map<json> resourceBundle in resourceBundles {
            string? bundleResourceType = extractResourceTypeFromBundle(resourceBundle);
            if bundleResourceType is () {
                continue;
            }

            string[] matchedClientIds = [];
            foreach common:GroupMembershipResult groupResult in groupResults {
                if groupResult.resourceType == bundleResourceType {
                    boolean alreadyMatched = false;
                    foreach string existingClient in matchedClientIds {
                        if existingClient == groupResult.clientId {
                            alreadyMatched = true;
                            break;
                        }
                    }
                    if !alreadyMatched {
                        matchedClientIds.push(groupResult.clientId);
                    }
                }
            }

            clientsMatched += matchedClientIds.length();

            foreach string matchedClientId in matchedClientIds {
                error? result = fhir:publishToTopic(
                    matchedClientId,
                    resourceBundle,
                    fhir:brokerBaseUrl,
                    webSubHubUrl,
                    common:clientNotificationHeaders,
                    fhir:fhirServerClient,
                    common:clientEventCounters
                );

                if result is error {
                    log:printError(string `[NOTIFICATION] Failed to publish to client ${matchedClientId}`, result);
                    audit:auditNotificationRouted(matchedClientId, brokerScopedId, bundleResourceType, false, result.message());
                    patientFailCount += 1;
                } else {
                    log:printInfo(string `[NOTIFICATION] Published ${bundleResourceType} to client ${matchedClientId}`);
                    audit:auditNotificationRouted(matchedClientId, brokerScopedId, bundleResourceType, true);
                    patientSuccessCount += 1;
                }
            }
        }

        totalClientsMatched += clientsMatched;
        totalNotificationsSent += patientSuccessCount;
        totalNotificationsFailed += patientFailCount;

        patientResults.push({
            "localPatientRef": resolution.localPatientRef,
            "brokerScopedPatientId": brokerScopedId,
            "resolutionStatus": resolution.status,
            "groupMemberships": groupResults.length(),
            "clientsMatched": clientsMatched,
            "notificationsSent": patientSuccessCount,
            "notificationsFailed": patientFailCount
        });
    }

    foreach common:PatientResolutionResult failed in failedPatients {
        patientResults.push({
            "localPatientRef": failed.localPatientRef,
            "status": failed.status,
            "message": failed.message,
            "clinicalResourceCount": failed.clinicalResources.length()
        });
    }

    log:printInfo("========== NOTIFICATION PROCESSING COMPLETE ==========");
    log:printInfo(string `[NOTIFICATION] Summary: ${resolvedPatients.length()} patients resolved, ${totalClientsMatched} clients matched, ${totalNotificationsSent} sent, ${totalNotificationsFailed} failed`);

    return <http:Ok>{};
}

// Extract the clinical resource type from a per-resource notification bundle
function extractResourceTypeFromBundle(map<json> resourceBundle) returns string? {
    json? entriesJson = resourceBundle["entry"];
    if entriesJson !is json[] {
        return ();
    }
    foreach json entry in entriesJson {
        if entry !is map<json> {
            continue;
        }
        json? resourceJson = entry["resource"];
        if resourceJson !is map<json> {
            continue;
        }
        json? resType = resourceJson["resourceType"];
        if resType is string && resType != "Patient" {
            return resType;
        }
    }
    return ();
}
