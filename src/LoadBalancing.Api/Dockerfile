# syntax=docker/dockerfile:1
# Build context: repository root  ->  docker build -f src/LoadBalancing.Api/Dockerfile .

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG APP_VERSION=dev
WORKDIR /src

COPY src/LoadBalancing.Api/LoadBalancing.Api.csproj src/LoadBalancing.Api/
RUN dotnet restore src/LoadBalancing.Api/LoadBalancing.Api.csproj

COPY src/LoadBalancing.Api/ src/LoadBalancing.Api/
RUN dotnet publish src/LoadBalancing.Api/LoadBalancing.Api.csproj \
      -c Release -o /app --no-restore \
      -p:InformationalVersion=${APP_VERSION} \
      -p:UseAppHost=false

# Chiseled = distroless Ubuntu: no shell, no package manager, runs as non-root (uid 1654).
FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled AS runtime
ARG APP_VERSION=dev
ENV ASPNETCORE_HTTP_PORTS=8080 \
    APP_VERSION=${APP_VERSION} \
    DOTNET_gcServer=0
WORKDIR /app
COPY --from=build /app .
EXPOSE 8080
USER $APP_UID
ENTRYPOINT ["dotnet", "LoadBalancing.Api.dll"]
