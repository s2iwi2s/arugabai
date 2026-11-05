-- 2. Create database
CREATE DATABASE arugabai;

-- Connect to the newly created database
\c arugabai

-- 3. Bootstrap (Execute the superuser script mounted inside the container)
\i /tmp/00_superuser.sql

-- 4. Safely handle migrator role configuration
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'migrator') THEN
        CREATE ROLE migrator WITH LOGIN;
    END IF;
END
$$;
ALTER ROLE migrator PASSWORD $$test-only-password-not-secret$$;

-- 5. Safely handle app_rw role configuration
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'app_rw') THEN
        CREATE ROLE app_rw WITH LOGIN;
    END IF;
END
$$;
ALTER ROLE app_rw PASSWORD $$test-only-password-not-secret$$;
