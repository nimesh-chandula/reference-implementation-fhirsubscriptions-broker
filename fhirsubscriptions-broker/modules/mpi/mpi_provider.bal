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

// MPI Provider Dispatch Layer
// All MPI operations are routed to the OpenHIE Client Registry (CR) provider.
// To add an alternative provider, reintroduce a dispatch switch here.

import wso2healthcare/broker.common;

// Resolve hospital-scoped patient ID to broker-scoped patient ID
function resolveToBrokerScopedId(string systemId, string systemPatientId) returns string|error {
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
function addMPIMapping(string systemId, string systemPatientId, string brokerScopedPatientId, common:ClientDemographics demographics) returns error? {
    return crAddMapping(systemId, systemPatientId, brokerScopedPatientId, demographics);
}
