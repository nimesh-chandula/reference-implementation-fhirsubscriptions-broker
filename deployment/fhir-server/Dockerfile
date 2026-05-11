# syntax=docker/dockerfile:1.6
# WSO2 Open Healthcare FHIR Server (Ballerina)
# Source: https://github.com/wso2/open-healthcare-prebuilt-services/tree/main/miscellaneous/fhir-server

ARG BAL_VERSION=2201.12.11

FROM ballerina/ballerina:${BAL_VERSION}-java21 AS build
ARG GIT_REF=main
ARG REPO_URL=https://github.com/wso2/open-healthcare-prebuilt-services.git
ARG SUBDIR=miscellaneous/fhir-server
USER root
WORKDIR /src
RUN git clone --depth=1 --branch ${GIT_REF} ${REPO_URL} repo \
 && cd repo/${SUBDIR} \
 && bal build

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
ARG SUBDIR=miscellaneous/fhir-server
COPY --from=build /src/repo/${SUBDIR}/target/bin/ /app/bin/
COPY --from=build /src/repo/${SUBDIR}/Config.toml /app/Config.toml
RUN addgroup -S fhirsvc && adduser -S -G fhirsvc fhirsvc \
 && ln -s "$(ls /app/bin/*.jar | head -n1)" /app/service.jar \
 && mkdir -p /app/data \
 && chown -R fhirsvc:fhirsvc /app
USER fhirsvc
ENV BAL_CONFIG_FILES=/app/Config.toml
EXPOSE 9090
ENTRYPOINT ["java","-jar","/app/service.jar"]
