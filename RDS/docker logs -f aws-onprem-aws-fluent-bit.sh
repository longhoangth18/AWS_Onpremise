#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${BASE_DIR:-$PWD/aws-onprem-rds-only}"

MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-root123}"
MYSQL_DATABASE="${MYSQL_DATABASE:-appdb}"
MYSQL_USER="${MYSQL_USER:-appuser}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-app123}"

AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-123456789012}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"

DB_INSTANCE_IDENTIFIER="${DB_INSTANCE_IDENTIFIER:-lab-mysql}"
DB_RESOURCE_ID="${DB_RESOURCE_ID:-db-aws-onprem123456789}"

SOURCE_IP_ADDRESS="${SOURCE_IP_ADDRESS:-10.0.0.10}"
IAM_ROLE_NAME="${IAM_ROLE_NAME:-aws-onpremAWSRole}"
IAM_SESSION_NAME="${IAM_SESSION_NAME:-aws-onpremSession}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERROR] Missing required command: $1"
    exit 1
  }
}

need_cmd docker
need_cmd python3

mkdir -p \
  "$BASE_DIR/mysql/init" \
  "$BASE_DIR/mysql/conf.d" \
  "$BASE_DIR/fluent-bit" \
  "$BASE_DIR/logs"

cat > "$BASE_DIR/docker-compose.yml" <<EOF
services:
  mysql:
    image: mysql:8.0
    container_name: aws-onprem-rds-mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    command:
      - --general-log=1
      - --general-log-file=/var/lib/mysql/general.log
      - --slow-query-log=1
      - --slow-query-log-file=/var/lib/mysql/slow.log
      - --long-query-time=0.1
      - --log-error=/var/lib/mysql/error.log
      - --log-output=FILE
      - --secure-file-priv=
    ports:
      - "3306:3306"
    volumes:
      - mysql_data:/var/lib/mysql
      - ./mysql/init:/docker-entrypoint-initdb.d:ro
      - ./mysql/conf.d:/etc/mysql/conf.d:ro
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p${MYSQL_ROOT_PASSWORD} --silent"]
      interval: 10s
      timeout: 5s
      retries: 20

  fluent-bit:
    image: fluent/fluent-bit:3.1
    container_name: aws-onprem-rds-fluent-bit
    restart: unless-stopped
    depends_on:
      mysql:
        condition: service_healthy
    volumes:
      - ./logs:/logs
      - ./fluent-bit/fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf:ro
      - ./fluent-bit/parsers.conf:/fluent-bit/etc/parsers.conf:ro

volumes:
  mysql_data:
EOF

cat > "$BASE_DIR/mysql/conf.d/my.cnf" <<'EOF'
[mysqld]
skip-host-cache
skip-name-resolve
EOF

cat > "$BASE_DIR/mysql/init/01_seed.sql" <<EOF
CREATE TABLE IF NOT EXISTS demo_log (
  id INT AUTO_INCREMENT PRIMARY KEY,
  msg VARCHAR(255),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO demo_log(msg) VALUES ('seed-row-1'), ('seed-row-2'), ('seed-row-3');
EOF

cat > "$BASE_DIR/fluent-bit/parsers.conf" <<'EOF'
[PARSER]
    Name   json_plain
    Format json
EOF

cat > "$BASE_DIR/fluent-bit/fluent-bit.conf" <<'EOF'
[SERVICE]
    Flush         1
    Daemon        Off
    Log_Level     info
    Parsers_File  /fluent-bit/etc/parsers.conf

[INPUT]
    Name              tail
    Tag               aws.rds
    Path              /logs/rds_events.jsonl
    DB                /tmp/rds_events.db
    Read_from_Head    true
    Refresh_Interval  1
    Parser            json_plain

[OUTPUT]
    Name    stdout
    Match   aws.rds
    Format  json_lines
EOF

cat > "$BASE_DIR/generate_logs.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

cd "\$(dirname "\$0")"

wait_mysql() {
  echo "[*] Waiting for MySQL..."
  until docker exec aws-onprem-rds-mysql mysqladmin ping -h 127.0.0.1 -uroot -p${MYSQL_ROOT_PASSWORD} --silent >/dev/null 2>&1; do
    sleep 2
  done
}

run_mysql_activity() {
  echo "[*] Generating real MySQL activity..."

  docker exec aws-onprem-rds-mysql mysql -u${MYSQL_USER} -p${MYSQL_PASSWORD} -D ${MYSQL_DATABASE} -e \
    "INSERT INTO demo_log(msg) VALUES('rds-general-1'); SELECT * FROM demo_log ORDER BY id DESC LIMIT 2;" >/dev/null 2>&1 || true

  docker exec aws-onprem-rds-mysql mysql -u${MYSQL_USER} -p${MYSQL_PASSWORD} -D ${MYSQL_DATABASE} -e \
    "UPDATE demo_log SET msg='rds-general-2' WHERE id=1; SELECT * FROM demo_log WHERE id=1;" >/dev/null 2>&1 || true

  docker exec aws-onprem-rds-mysql mysql -u${MYSQL_USER} -p${MYSQL_PASSWORD} -D ${MYSQL_DATABASE} -e \
    "SELECT COUNT(*) FROM demo_log a, demo_log b, demo_log c;" >/dev/null 2>&1 || true

  docker exec aws-onprem-rds-mysql mysql -u${MYSQL_USER} -p${MYSQL_PASSWORD} -D ${MYSQL_DATABASE} -e \
    "SELECT * FROM table_does_not_exist;" >/dev/null 2>&1 || true

  docker exec aws-onprem-rds-mysql mysql -u${MYSQL_USER} -pwrongpass -D ${MYSQL_DATABASE} -e \
    "SELECT 1;" >/dev/null 2>&1 || true
}

python3 - <<'PY'
import json
from datetime import datetime, timezone
from pathlib import Path

logs_dir = Path("./logs")
logs_dir.mkdir(parents=True, exist_ok=True)

AWS_ACCOUNT_ID = "${AWS_ACCOUNT_ID}"
AWS_REGION = "${AWS_REGION}"
DB_INSTANCE_IDENTIFIER = "${DB_INSTANCE_IDENTIFIER}"
DB_RESOURCE_ID = "${DB_RESOURCE_ID}"
SOURCE_IP_ADDRESS = "${SOURCE_IP_ADDRESS}"
IAM_ROLE_NAME = "${IAM_ROLE_NAME}"
IAM_SESSION_NAME = "${IAM_SESSION_NAME}"

def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def common_identity(ts):
    return {
        "type": "AssumedRole",
        "principalId": "aws-onpremPRINCIPALID",
        "arn": f"arn:aws:sts::{AWS_ACCOUNT_ID}:assumed-role/{IAM_ROLE_NAME}/{IAM_SESSION_NAME}",
        "accountId": AWS_ACCOUNT_ID,
        "accessKeyId": "aws-onpremACCESSKEY",
        "sessionContext": {
            "sessionIssuer": {
                "type": "Role",
                "principalId": "aws-onpremROLEID",
                "arn": f"arn:aws:iam::{AWS_ACCOUNT_ID}:role/{IAM_ROLE_NAME}",
                "accountId": AWS_ACCOUNT_ID,
                "userName": IAM_ROLE_NAME
            },
            "attributes": {
                "creationDate": ts,
                "mfaAuthenticated": "false"
            }
        }
    }

def append_jsonl(path, obj):
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\\n")

rds_path = logs_dir / "rds_events.jsonl"

events = [
    {
        "name": "WriteDBLogEntry",
        "logType": "general",
        "status": "OK",
        "message": "Query executed: INSERT INTO demo_log(msg) VALUES('rds-general-1'); SELECT * FROM demo_log ORDER BY id DESC LIMIT 2;",
        "rawTag": "mysql.general"
    },
    {
        "name": "WriteDBLogEntry",
        "logType": "general",
        "status": "OK",
        "message": "Query executed: UPDATE demo_log SET msg='rds-general-2' WHERE id=1; SELECT * FROM demo_log WHERE id=1;",
        "rawTag": "mysql.general"
    },
    {
        "name": "WriteDBLogSlowQuery",
        "logType": "slowquery",
        "status": "OK",
        "message": "Slow query detected: SELECT COUNT(*) FROM demo_log a, demo_log b, demo_log c;",
        "rawTag": "mysql.slow"
    },
    {
        "name": "WriteDBLogError",
        "logType": "error",
        "status": "ERROR",
        "message": "SQL error: Table 'appdb.table_does_not_exist' doesn't exist.",
        "rawTag": "mysql.error"
    },
    {
        "name": "WriteDBLogError",
        "logType": "error",
        "status": "ERROR",
        "message": "Access denied for user with invalid password.",
        "rawTag": "mysql.error"
    }
]

for item in events:
    ts = now_iso()
    evt = {
        "sourcetype": "aws:rds",
        "source": "aws-onprem:rds:mysql",
        "record": {
            "eventVersion": "1.10",
            "userIdentity": common_identity(ts),
            "eventTime": ts,
            "eventSource": "rds.amazonaws.com",
            "eventName": item["name"],
            "awsRegion": AWS_REGION,
            "sourceIPAddress": SOURCE_IP_ADDRESS,
            "userAgent": "aws-onprem-rds-lab",
            "requestParameters": {
                "dBInstanceIdentifier": DB_INSTANCE_IDENTIFIER,
                "dBInstanceArn": f"arn:aws:rds:{AWS_REGION}:{AWS_ACCOUNT_ID}:db:{DB_INSTANCE_IDENTIFIER}",
                "engine": "mysql",
                "logType": item["logType"],
                "logGroup": f"/aws/rds/instance/{DB_INSTANCE_IDENTIFIER}/{item['logType']}",
                "logStream": f"{DB_RESOURCE_ID}-{item['logType']}"
            },
            "responseElements": {
                "status": item["status"]
            },
            "additionalEventData": {
                "eventCategory": "DatabaseLog",
                "message": item["message"],
                "rawTag": item["rawTag"]
            },
            "resources": [
                {
                    "accountId": AWS_ACCOUNT_ID,
                    "type": "AWS::RDS::DBInstance",
                    "ARN": f"arn:aws:rds:{AWS_REGION}:{AWS_ACCOUNT_ID}:db:{DB_INSTANCE_IDENTIFIER}"
                }
            ],
            "eventType": "AwsApiCall",
            "managementEvent": True,
            "recipientAccountId": AWS_ACCOUNT_ID
        }
    }
    append_jsonl(rds_path, evt)

print("[OK] RDS events written to logs/rds_events.jsonl")
PY

wait_mysql
run_mysql_activity
echo "[OK] Real DB activity generated."
echo "[*] Watch RDS logs:"
echo "    docker logs -f aws-onprem-rds-fluent-bit"
EOF
chmod +x "$BASE_DIR/generate_logs.sh"

cat > "$BASE_DIR/README.txt" <<EOF
AWS on-prem RDS only lab

Start:
  cd "$BASE_DIR"
  docker compose up -d

Generate logs:
  ./generate_logs.sh

Watch logs:
  docker logs -f aws-onprem-rds-fluent-bit

Stop:
  docker compose down

Remove all data:
  docker compose down -v

Files:
  logs/rds_events.jsonl

Sourcetype:
  aws:rds
EOF

: > "$BASE_DIR/logs/rds_events.jsonl"

cd "$BASE_DIR"

echo "[*] Starting Docker services..."
docker compose up -d

echo "[*] Waiting for MySQL health..."
for _ in \$(seq 1 60); do
  STATUS="\$(docker inspect --format='{{json .State.Health.Status}}' aws-onprem-rds-mysql 2>/dev/null || true)"
  if [ "\$STATUS" = "\"healthy\"" ]; then
    break
  fi
  sleep 2
done

echo "[*] Generating initial logs..."
./generate_logs.sh

echo
echo "[OK] Environment is ready."
echo "Base dir: $BASE_DIR"
echo
echo "Useful commands:"
echo "  cd \"$BASE_DIR\""
echo "  ./generate_logs.sh"
echo "  docker logs -f aws-onprem-rds-fluent-bit"
echo "  cat logs/rds_events.jsonl"
echo "  docker compose down"
