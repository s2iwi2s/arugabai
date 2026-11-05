#!/usr/bin/env bash
set -e

# 1. Create the local env file
cat > .env.local << EOF
DB_URL=jdbc:postgresql://127.0.0.1:5432/arugabai
DB_APP_RW_PASSWORD_FILE=$(pwd)/src/test/resources/test-db-password.txt
JWT_SIGNING_KEY_FILE=$(pwd)/src/test/resources/test-session-key.b64
JWT_TTL_MINUTES=15
FIREBASE_PROJECT_ID=your-firebase-project-id
EOF

# 2. Export variables to the current shell session
set -a
source .env.local
set +a

# 3. Print requested verification outputs
echo "Evaluating environment variables:"
echo "$DB_URL"
echo "$DB_APP_RW_PASSWORD_FILE"

# 4. Wipe any stale DB cache and spin up the architecture
echo "Starting Docker environment..."
docker compose down -v
docker compose up

