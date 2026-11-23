#!/bin/bash
# Centraliza en DefectDojo los reportes de Semgrep (SAST), Trivy (SCA),
# Gitleaks y TruffleHog (secretos) y OWASP ZAP (DAST) via reimport-scan.
#
# Uso:
#   ./upload_to_defectdojo.sh                         # sube todos los reportes de reports/
#   ./upload_to_defectdojo.sh <scan_type> <archivo> [test_title]
#
# reimport-scan + engagement/test fijos por rama permite que DefectDojo
# deduplique hallazgos entre ejecuciones (no se duplican en cada pipeline).
#
# Variables de entorno requeridas (GitHub: Settings > Secrets and variables > Actions):
#   DEFECTDOJO_URL            URL base accesible desde el runner (ej: https://dojo.ejemplo.com)
#   DEFECTDOJO_TOKEN          API token (secret)
#   DEFECTDOJO_PRODUCT_ID     ID del producto destino
#
# Contexto de CI: usa las variables de GitHub Actions (GITHUB_REF_NAME,
# GITHUB_RUN_ID, GITHUB_SHA) y, si no existen, las de GitLab o git local.

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for var in DEFECTDOJO_URL DEFECTDOJO_TOKEN DEFECTDOJO_PRODUCT_ID; do
  if [[ -z "${!var}" ]]; then
    echo "Variable requerida no definida: $var"
    exit 1
  fi
done
DEFECTDOJO_URL="${DEFECTDOJO_URL%/}"

BRANCH="${GITHUB_REF_NAME:-${CI_COMMIT_REF_NAME:-$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo local)}}"
RUN_ID="${GITHUB_RUN_ID:-${CI_PIPELINE_ID:-local}}"
COMMIT="${GITHUB_SHA:-${CI_COMMIT_SHA:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}}"
COMMIT="${COMMIT:0:8}"

ENGAGEMENT_NAME="CI - ${BRANCH}"

# reimport-scan con auto_create_context requiere product_name (no basta product_id).
resolve_product_name() {
  local body
  body=$(curl -sf -H "Authorization: Token $DEFECTDOJO_TOKEN" \
    "$DEFECTDOJO_URL/api/v2/products/$DEFECTDOJO_PRODUCT_ID/") || return 1
  if command -v jq >/dev/null 2>&1; then
    echo "$body" | jq -r '.name'
  else
    echo "$body" | grep -o '"name": *"[^"]*"' | head -1 | cut -d'"' -f4
  fi
}

PRODUCT_NAME="$(resolve_product_name || true)"
if [[ -z "$PRODUCT_NAME" || "$PRODUCT_NAME" == "null" ]]; then
  echo "No se pudo resolver el nombre del producto (URL=$DEFECTDOJO_URL, DEFECTDOJO_PRODUCT_ID=$DEFECTDOJO_PRODUCT_ID)"
  exit 1
fi

upload() {
  local scan_type="$1" report_file="$2" test_title="${3:-$1}"
  local upload_file="$report_file" clean_file=""

  if [[ ! -f "$report_file" ]]; then
    echo "[$test_title] archivo no encontrado: $report_file — omitiendo"
    return 0
  fi
  # Reportes vacíos o sin hallazgos ("[]", "{}") no se suben.
  if [[ ! -s "$report_file" || "$(tr -d '[:space:]' < "$report_file")" =~ ^(\[\]|\{\})$ ]]; then
    echo "[$test_title] reporte vacío: $report_file — omitiendo"
    return 0
  fi

  # TruffleHog genera NDJSON con secuencias de escape; se dejan solo las
  # líneas con hallazgos reales (tienen SourceMetadata).
  if [[ "$scan_type" == "Trufflehog Scan" ]]; then
    clean_file="$(mktemp)"
    grep '"SourceMetadata"' "$report_file" | sed 's/\r//' | grep '^{' > "$clean_file" || true
    if [[ ! -s "$clean_file" ]]; then
      echo "[$test_title] sin hallazgos válidos tras limpieza — omitiendo"
      rm -f "$clean_file"
      return 0
    fi
    upload_file="$clean_file"
  fi

  echo "[$test_title] subiendo '$report_file' ($scan_type) -> producto '$PRODUCT_NAME' / engagement '$ENGAGEMENT_NAME'..."

  local response http_status body
  response=$(curl -s -w "\n%{http_code}" \
    -X POST "$DEFECTDOJO_URL/api/v2/reimport-scan/" \
    -H "Authorization: Token $DEFECTDOJO_TOKEN" \
    --form-string "scan_type=$scan_type" \
    -F "file=@$upload_file" \
    --form-string "product_name=$PRODUCT_NAME" \
    --form-string "engagement_name=$ENGAGEMENT_NAME" \
    --form-string "test_title=$test_title" \
    --form-string "auto_create_context=true" \
    --form-string "active=true" \
    --form-string "verified=false" \
    --form-string "close_old_findings=true" \
    --form-string "close_old_findings_product_scope=false" \
    --form-string "version=$RUN_ID" \
    --form-string "build_id=$RUN_ID" \
    --form-string "commit_hash=$COMMIT" \
    --form-string "branch_tag=$BRANCH") || true

  [[ -n "$clean_file" ]] && rm -f "$clean_file"

  http_status=$(echo "$response" | tail -1)
  body=$(echo "$response" | head -n -1)

  if [[ "$http_status" == "201" ]]; then
    echo "[$test_title] OK importado (HTTP 201)"
  else
    echo "[$test_title] ERROR (HTTP $http_status): $body"
    return 1
  fi
}

# Modo manual: un solo reporte.
if [[ $# -ge 2 ]]; then
  upload "$1" "$2" "${3:-$1}"
  exit $?
elif [[ $# -ne 0 ]]; then
  echo "Uso: $0 [<scan_type> <report_file> [test_title]]"
  exit 1
fi

# Modo por defecto: todos los reportes de las herramientas del proyecto.
# Cada reporte tiene su propio test_title para que close_old_findings
# no cierre hallazgos de otro reporte del mismo tipo.
FAILED=0
upload "Semgrep JSON Report" "$ROOT/reports/sast/semgrep-report.json"    "Semgrep (SAST)"        || FAILED=1
upload "Trivy Scan"          "$ROOT/reports/sca/trivy-report.json"       "Trivy (SCA)"           || FAILED=1
upload "Gitleaks Scan"       "$ROOT/reports/secrets/gitleaks-report.json" "Gitleaks (Secrets)"   || FAILED=1
upload "Trufflehog Scan"     "$ROOT/reports/secrets/trufflehog-report.json" "TruffleHog (Secrets)" || FAILED=1
upload "ZAP Scan"            "$ROOT/reports/dast/baseline.xml"           "ZAP Baseline (DAST)"   || FAILED=1
upload "ZAP Scan"            "$ROOT/reports/dast/baseline-api.xml"       "ZAP Baseline API (DAST)" || FAILED=1

exit $FAILED
