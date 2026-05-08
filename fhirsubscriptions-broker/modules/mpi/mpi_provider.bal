// MPI Provider Dispatch Layer
// All MPI operations are routed to the OpenHIE Client Registry (CR) provider.
// To add an alternative provider, reintroduce a dispatch switch here.

import wso2healthcare/broker.common;

// Resolve hospital-scoped patient ID to broker-scoped patient ID
public function resolveToBrokerScopedId(string systemId, string systemPatientId) returns string|error {
    return crResolveToBrokerScopedId(systemId, systemPatientId);
}

// Search for patient by demographics
public function searchPatientByDemographics(common:ClientDemographics demographics) returns string|error {
    return crSearchByDemographics(demographics);
}

// Create new patient
public function createPatientInMPI(common:ClientDemographics demographics, string systemId, string systemPatientId) returns string|error {
    return crCreatePatient(demographics, systemId, systemPatientId);
}

// Add identifier mapping
public function addMPIMapping(string systemId, string systemPatientId, string brokerScopedPatientId, common:ClientDemographics demographics) returns error? {
    return crAddMapping(systemId, systemPatientId, brokerScopedPatientId, demographics);
}
