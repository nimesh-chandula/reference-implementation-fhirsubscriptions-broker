# syntax=docker/dockerfile:1.6
# FHIR Notification Broker (this repo)
# Build context: repository root (so COPY fhirsubscriptions-broker/ works).

ARG BAL_VERSION=2201.12.11

FROM ballerina/ballerina:${BAL_VERSION}-java21 AS build
USER root
WORKDIR /src
COPY fhirsubscriptions-broker/ /src/
RUN bal build

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=build /src/target/bin/ /app/bin/
RUN ln -s "$(ls /app/bin/*.jar | head -n1)" /app/service.jar
ENV BAL_CONFIG_FILES=/app/Config.toml
EXPOSE 9091
ENTRYPOINT ["java","-jar","/app/service.jar"]
