# ---------------------------------------------------------------------------
# Stage 1: Build the jar with Maven (nothing from this stage ships to prod)
# ---------------------------------------------------------------------------
FROM maven:3.9.6-eclipse-temurin-17 AS build
WORKDIR /workspace

# Copy only the POM first so Docker can cache the dependency layer
# independently of source changes -> much faster rebuilds.
COPY pom.xml .
RUN mvn -B dependency:go-offline

COPY src ./src
RUN mvn -B clean package -DskipTests

# ---------------------------------------------------------------------------
# Stage 2: Minimal runtime image
# ---------------------------------------------------------------------------
# Ubuntu/Jammy, not Alpine: eclipse-temurin's *-jre-alpine tags only publish
# an amd64 manifest (no arm64) as of this writing, so that base breaks any
# build on Apple Silicon / arm64 CI runners. Jammy is genuinely multi-arch.
FROM eclipse-temurin:17-jre-jammy AS runtime

# Run as a non-root, unprivileged user (never run app containers as root)
RUN addgroup --system spring \
  && adduser --system --no-create-home --ingroup spring --disabled-login spring
USER spring:spring

WORKDIR /app
COPY --from=build --chown=spring:spring /workspace/target/*.jar app.jar

# OCI labels make the image traceable back to source + commit in the registry
ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown
LABEL org.opencontainers.image.source="https://github.com/Auduj01/sample-app-delivery-pipeline" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}"

EXPOSE 8000

# Container-level healthcheck backed by Spring Boot Actuator (see application.properties)
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
  CMD wget -q -O- http://127.0.0.1:8000/actuator/health || exit 1

ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "-jar", "app.jar"]
