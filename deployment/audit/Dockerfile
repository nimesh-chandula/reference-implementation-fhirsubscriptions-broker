# syntax=docker/dockerfile:1.6
# WSO2 Open Healthcare FHIR Audit Service (Ballerina)
# Source: https://github.com/wso2/open-healthcare-prebuilt-services/tree/main/miscellaneous/audit-service

ARG BAL_VERSION=2201.12.11

FROM ballerina/ballerina:${BAL_VERSION}-java21 AS build
ARG GIT_REF=main
ARG REPO_URL=https://github.com/wso2/open-healthcare-prebuilt-services.git
ARG SUBDIR=miscellaneous/audit-service
USER root
WORKDIR /src
RUN git clone --depth=1 --branch ${GIT_REF} ${REPO_URL} repo \
 && cd repo/${SUBDIR} \
 && bal build

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
ARG SUBDIR=miscellaneous/audit-service
COPY --from=build /src/repo/${SUBDIR}/target/bin/ /app/bin/
RUN ln -s "$(ls /app/bin/*.jar | head -n1)" /app/service.jar \
 && mkdir -p /tmp/audit-logs
EXPOSE 9093
ENTRYPOINT ["java","-jar","/app/service.jar"]
