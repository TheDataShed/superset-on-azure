FROM apache/superset@sha256:ca28a9627fc0d3434d8c8fa53680161e05b0732da5f263a332b78bbf06e5f4f8

COPY --chown=superset ./docker/ /app/docker/

# Database connectivity libraries
# <https://superset.apache.org/docs/databases/installing-database-drivers#supported-databases-and-dependencies>
COPY db-drivers.txt .
RUN pip install --no-cache --requirement db-drivers.txt
