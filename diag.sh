#!/bin/bash
# EFStatus Diagnostic Script
# Prints all API field names returned by your EcoFlow device.
# NO credentials or private data are included in the output.

if [ "$#" -lt 6 ]; then
  echo "Usage: ./diag.sh --access-key YOUR_KEY --secret-key YOUR_SECRET --serial YOUR_SERIAL"
  exit 1
fi

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --access-key) ACCESS_KEY="$2"; shift ;;
    --secret-key) SECRET_KEY="$2"; shift ;;
    --serial)     SERIAL="$2";     shift ;;
  esac
  shift
done

NONCE=$(( RANDOM * RANDOM ))
TIMESTAMP=$(( $(date +%s) * 1000 ))
RAW="accessKey=${ACCESS_KEY}&nonce=${NONCE}&timestamp=${TIMESTAMP}"

SIG=$(echo -n "$RAW" | openssl dgst -sha256 -hmac "$SECRET_KEY" | awk '{print $2}')

RESPONSE=$(curl -s "https://api.ecoflow.com/iot-open/sign/device/quota/all?sn=${SERIAL}" \
  -H "accessKey: ${ACCESS_KEY}" \
  -H "nonce: ${NONCE}" \
  -H "timestamp: ${TIMESTAMP}" \
  -H "sign: ${SIG}" \
  -H "Content-Type: application/json")

echo ""
echo "=== EFStatus Diagnostic Output ==="
echo "Share the output below as a GitHub issue or DM."
echo "Your credentials and serial number are NOT included."
echo "==================================="
echo ""

# Extract and print only field names and values — no credentials
echo "$RESPONSE" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    data = r.get('data', {})
    if not data:
        print('ERROR: No data returned. Check your credentials and serial number.')
        sys.exit(1)
    print(f'Device returned {len(data)} fields:\n')
    for k, v in sorted(data.items()):
        if not isinstance(v, (list, dict)):
            print(f'  {k}: {v}')
    print()
    print('Array/object fields (names only):')
    for k, v in sorted(data.items()):
        if isinstance(v, (list, dict)):
            print(f'  {k}')
except Exception as e:
    print(f'Parse error: {e}')
    print('Raw response:', sys.stdin.read())
"
