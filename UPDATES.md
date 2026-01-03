# PostgreSQL 17 Custom Image Updates

This document outlines the changes made to add **PostGIS 3.6.1** and **H3-pg 4.2.3** extensions to the Supabase PostgreSQL 17 Docker image.

## Summary of Changes

| Component | Version | Description |
|-----------|---------|-------------|
| PostgreSQL | 17.6 | Base database |
| PostGIS | 3.6.1 | Geospatial extension (upgraded from 3.3.7) |
| h3 | 4.2.3 | Uber's hexagonal hierarchical geospatial indexing |
| h3_postgis | 4.2.3 | PostGIS integration for H3 |

---

## Files Modified

### 1. `Dockerfile-17`

Updated ARG variables (legacy, actual versions managed by Nix):

```dockerfile
ARG postgresql_major=17
ARG postgis_release=3.6.1
ARG h3_release=4.2.3
```

### 2. `nix/ext/versions.json`

Added version entries for PostGIS 3.6.1 and h3 4.2.3:

```json
{
  "postgis": {
    "3.6.1": {
      "postgresql": ["17"],
      "hash": "sha256-7Az6q0dWMBBiEdGA1x30Z4LkHhC23/6R15yoGOzSy7Q="
    }
  },
  "h3": {
    "4.2.3": {
      "postgresql": ["15", "17"],
      "hash": "sha256-kTh0Y0C2pNB5Ul1rp77ets/5VeU1zw1WasGHkOaDMh8="
    }
  }
}
```

### 3. `nix/ext/h3.nix` (New File)

Created Nix derivation to build:
- **h3 C library** (v4.2.0) - Core hexagonal indexing library from Uber
- **h3-pg** (v4.2.3) - PostgreSQL bindings

Key features:
- Fetches source from `postgis/h3-pg` GitHub repository
- Builds h3 C library as a dependency
- Custom `installPhase` to handle Nix store path constraints
- Produces both `h3` and `h3_postgis` extensions

### 4. `nix/packages/postgres.nix`

Added h3 to the list of extensions:

```nix
ourExtensions = [
  # ... existing extensions ...
  ../ext/h3.nix
];
```

### 5. `nix/ext/postgis.nix`

Added `postConfigure` patch for PostGIS 3.6.x compatibility:

```nix
postConfigure = ''
  # Disable install-extension-upgrades-from-known-versions target
  # which tries to write to read-only PostgreSQL share directory
  if [ -f "GNUmakefile" ]; then
    sed -i 's|install-extension-upgrades-from-known-versions||g' GNUmakefile
  fi
  if [ -f "extensions/Makefile" ]; then
    sed -i 's|install-extension-upgrades-from-known-versions||g' extensions/Makefile
  fi
'';
```

### 6. `ansible/files/postgresql_config/supautils.conf.j2`

Added `h3` and `h3_postgis` to privileged extensions list:

```
supautils.privileged_extensions = '... h3, h3_postgis, ...'
```

This allows non-superuser roles (like `postgres`) to create these extensions via supautils.

### 7. `ansible/files/postgresql_extension_custom_scripts/h3/after-create.sql` (New File)

Grants permissions after extension creation:

```sql
-- Grants execute on all h3 functions to postgres, anon, authenticated, service_role
-- Grants usage on h3 types to API roles
```

### 8. `ansible/files/postgresql_extension_custom_scripts/h3_postgis/after-create.sql` (New File)

Same permission grants for h3_postgis functions.

---

## Build Commands

### Build the Docker Image

```bash
# Standard build
docker build -f Dockerfile-17 -t supabase-postgres:17-custom .

# Build with no cache (recommended after Nix changes)
docker build --no-cache -f Dockerfile-17 -t supabase-postgres:17-custom .

# Build with progress output
docker build --progress=plain -f Dockerfile-17 -t supabase-postgres:17-custom .
```

### Tag and Push to Docker Hub

```bash
# Tag for your registry
docker tag supabase-postgres:17-custom YOUR_USERNAME/supabase-postgres:17-custom

# Login and push
docker login
docker push YOUR_USERNAME/supabase-postgres:17-custom
```

---

## Test Suite

### Quick Verification

```bash
# Start container
docker run -d --name test-pg \
  -e POSTGRES_PASSWORD=testpassword \
  supabase-postgres:17-custom

# Wait for initialization
sleep 30

# Check available extensions
docker exec test-pg psql -U postgres -d postgres -c \
  "SELECT name, default_version FROM pg_available_extensions 
   WHERE name IN ('h3', 'h3_postgis', 'postgis') ORDER BY name;"
```

Expected output:
```
    name    | default_version 
------------+-----------------
 h3         | 4.2.3
 h3_postgis | 4.2.3
 postgis    | 3.6.1
```

### Extension Creation Test

```bash
docker exec test-pg psql -U postgres -d postgres -c "
  CREATE EXTENSION h3 WITH SCHEMA extensions;
  CREATE EXTENSION postgis WITH SCHEMA extensions;
  CREATE EXTENSION h3_postgis WITH SCHEMA extensions CASCADE;
"
```

### Extension Ownership Test

```bash
docker exec test-pg psql -U postgres -d postgres -c "
  SELECT extname, extowner::regrole 
  FROM pg_extension 
  WHERE extname IN ('h3', 'h3_postgis', 'postgis');
"
```

Expected: All owned by `supabase_admin`

### H3 Function Test

```bash
docker exec test-pg psql -U postgres -d postgres -c "
  SELECT extensions.h3_latlng_to_cell(POINT(37.3615593, -122.0553238), 5)::text;
"
```

Expected: `85e35e73fffffff`

### API Role Permissions Test

```bash
# Test as anon role
docker exec test-pg psql -U postgres -d postgres -c "
  SET ROLE anon;
  SELECT extensions.h3_latlng_to_cell(POINT(37.3615593, -122.0553238), 5)::text;
"

# Test as authenticated role
docker exec test-pg psql -U postgres -d postgres -c "
  SET ROLE authenticated;
  SELECT extensions.h3_latlng_to_cell(POINT(37.3615593, -122.0553238), 5)::text;
"
```

### H3 + PostGIS Integration Test

```bash
docker exec test-pg psql -U postgres -d postgres -c "
  SELECT ST_AsText(
    extensions.h3_cell_to_boundary_geometry('85e35e73fffffff'::extensions.h3index)
  );
"
```

### Full Workflow Test

```bash
docker exec test-pg psql -U postgres -d postgres -c "
  -- Create table with h3 index
  CREATE TABLE locations (
      id SERIAL PRIMARY KEY,
      name TEXT,
      h3_index extensions.h3index
  );

  -- Insert data
  INSERT INTO locations (name, h3_index) VALUES 
  ('Apple HQ', extensions.h3_latlng_to_cell(POINT(37.334722, -122.009166), 9)),
  ('Google HQ', extensions.h3_latlng_to_cell(POINT(37.422, -122.084), 9));

  -- Query with h3 distance
  SELECT name, h3_index::text,
         extensions.h3_grid_distance(
           h3_index, 
           extensions.h3_latlng_to_cell(POINT(37.334722, -122.009166), 9)
         ) as distance_from_apple
  FROM locations;
"
```

### Cleanup

```bash
docker stop test-pg && docker rm test-pg
```

---

## Usage Examples

### Basic H3 Indexing

```sql
-- Convert lat/lng to H3 cell at resolution 9
SELECT extensions.h3_latlng_to_cell(POINT(37.7749, -122.4194), 9) as sf_h3;

-- Get H3 cell resolution
SELECT extensions.h3_get_resolution('89283082837ffff'::extensions.h3index);

-- Get neighboring cells (k-ring)
SELECT extensions.h3_grid_disk('89283082837ffff'::extensions.h3index, 1);
```

### H3 with PostGIS

```sql
-- Convert H3 cell to PostGIS polygon
SELECT ST_AsGeoJSON(
  extensions.h3_cell_to_boundary_geometry('89283082837ffff'::extensions.h3index)
);

-- Convert PostGIS point to H3
SELECT extensions.h3_lat_lng_to_cell(
  ST_Y(geom), ST_X(geom), 9
) FROM my_points;

-- Find all H3 cells within a polygon
SELECT extensions.h3_polygon_to_cells(
  ST_GeomFromText('POLYGON((...))'), 
  9
);
```

### Distance Calculations

```sql
-- Grid distance between two cells
SELECT extensions.h3_grid_distance(
  '89283082837ffff'::extensions.h3index,
  '8928308280fffff'::extensions.h3index
);

-- Get path between cells
SELECT extensions.h3_grid_path_cells(
  '89283082837ffff'::extensions.h3index,
  '8928308280fffff'::extensions.h3index
);
```

### Hierarchical Operations

```sql
-- Get parent cell (lower resolution)
SELECT extensions.h3_cell_to_parent('89283082837ffff'::extensions.h3index, 7);

-- Get child cells (higher resolution)
SELECT extensions.h3_cell_to_children('87283082fffffff'::extensions.h3index, 9);
```

---

## Troubleshooting

### Extension Creation Fails with "role does not exist"

The Supabase init scripts create the required roles. Make sure the container fully initializes before testing:

```bash
docker logs container_name 2>&1 | grep "database system is ready"
```

### H3 Functions Not Found

Ensure you're using the correct schema prefix:

```sql
-- If installed in extensions schema
SELECT extensions.h3_latlng_to_cell(...);

-- Check where extension is installed
SELECT nspname FROM pg_namespace 
WHERE oid = (SELECT extnamespace FROM pg_extension WHERE extname = 'h3');
```

### Permission Denied Errors

The after-create.sql scripts should grant permissions automatically. To manually fix:

```sql
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO anon, authenticated, service_role;
```

---

## Version Compatibility Matrix

| PostgreSQL | PostGIS | h3-pg | h3 C lib |
|------------|---------|-------|----------|
| 17.x | 3.6.1 | 4.2.3 | 4.2.0 |
| 15.x | 3.3.7 | 4.2.3 | 4.2.0 |

---

## References

- [H3 Documentation](https://h3geo.org/)
- [h3-pg GitHub](https://github.com/postgis/h3-pg)
- [PostGIS Documentation](https://postgis.net/documentation/)
- [Supabase PostgreSQL](https://github.com/supabase/postgres)
