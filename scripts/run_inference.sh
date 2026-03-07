#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
V1_FUNCTION="bedrock-rag-dev-rag-citations-v1"
V2_FUNCTION="bedrock-rag-dev-rag-citations-v2"
AWS_REGION="us-east-1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$SCRIPT_DIR/tmp"
OUT_FILE="$OUT_DIR/comparison.html"

# ---------------------------------------------------------------------------
# Query — overridable via $1
# ---------------------------------------------------------------------------
QUERY="${1:-Give me a detailed overview of each topic covered across all the documents in the knowledge base, citing specific facts and details from each source.}"

echo "Query: $QUERY"
echo "Invoking $V1_FUNCTION and $V2_FUNCTION in parallel..."

mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# Invoke both Lambdas in parallel
# ---------------------------------------------------------------------------
aws lambda invoke \
  --function-name "$V1_FUNCTION" \
  --region "$AWS_REGION" \
  --payload "$(echo '{}' | jq --arg q "$QUERY" '. + {query: $q}')" \
  --cli-binary-format raw-in-base64-out \
  /tmp/v1_raw.json > /tmp/v1_invoke.log 2>&1 &

aws lambda invoke \
  --function-name "$V2_FUNCTION" \
  --region "$AWS_REGION" \
  --payload "$(echo '{}' | jq --arg q "$QUERY" '. + {query: $q}')" \
  --cli-binary-format raw-in-base64-out \
  /tmp/v2_raw.json > /tmp/v2_invoke.log 2>&1 &

wait
echo "Both Lambdas returned."

# ---------------------------------------------------------------------------
# Helper: check for Lambda-level errors (unhandled exceptions)
# ---------------------------------------------------------------------------
check_lambda_error() {
  local raw_file="$1"
  local label="$2"
  local err
  err=$(jq -r '.errorMessage // empty' "$raw_file")
  if [[ -n "$err" ]]; then
    echo "ERROR: $label returned a Lambda error:" >&2
    echo "  $err" >&2
    exit 1
  fi
}

check_lambda_error /tmp/v1_raw.json "$V1_FUNCTION"
check_lambda_error /tmp/v2_raw.json "$V2_FUNCTION"

# ---------------------------------------------------------------------------
# Parse responses
# ---------------------------------------------------------------------------
V1_HTML=$(jq -r '.body | fromjson | .html_response' /tmp/v1_raw.json)
V1_REFS=$(jq -r '.body | fromjson | .references' /tmp/v1_raw.json)
V1_LATENCY=$(jq -r '.body | fromjson | .latency_ms' /tmp/v1_raw.json)
V1_COUNT=$(jq -r '.body | fromjson | .citation_count' /tmp/v1_raw.json)

V2_HTML=$(jq -r '.body | fromjson | .html_response' /tmp/v2_raw.json)
V2_REFS=$(jq -r '.body | fromjson | .references' /tmp/v2_raw.json)
V2_LATENCY=$(jq -r '.body | fromjson | .latency_ms' /tmp/v2_raw.json)
V2_COUNT=$(jq -r '.body | fromjson | .citation_count' /tmp/v2_raw.json)

# Build references <ol> items (handles both .text and .cited_text field names)
V1_REFS_HTML=$(echo "$V1_REFS" | jq -r \
  '.[] | "<li id=\"ref-\(.ref_n)\"><strong>[\(.ref_n)]</strong> <a href=\"\(.source)\">\(.source | split("/") | last)</a><br><em>\((.text // .cited_text // "") | .[0:150])</em></li>"' \
  | tr '\n' ' ')

V2_REFS_HTML=$(echo "$V2_REFS" | jq -r \
  '.[] | "<li id=\"ref-\(.ref_n)\"><strong>[\(.ref_n)]</strong> <a href=\"\(.source)\">\(.source | split("/") | last)</a><br><em>\((.text // .cited_text // "") | .[0:150])</em></li>"' \
  | tr '\n' ' ')

# Compute latency diff
DIFF_MS=$(( V2_LATENCY - V1_LATENCY ))
if (( DIFF_MS < 0 )); then
  FASTER_LABEL="V1 is $(( -DIFF_MS ))ms faster"
else
  FASTER_LABEL="V2 is ${DIFF_MS}ms faster"
fi

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')

# ---------------------------------------------------------------------------
# Write HTML
# ---------------------------------------------------------------------------
cat > "$OUT_FILE" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Citation Comparison</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      font-size: 14px;
      background: #f4f4f7;
      color: #1a1a2e;
      display: flex;
      flex-direction: column;
      height: 100vh;
    }
    header {
      background: #1a1a2e;
      color: #fff;
      padding: 14px 24px;
      flex-shrink: 0;
    }
    header h1 { font-size: 18px; margin-bottom: 4px; }
    header .meta { font-size: 12px; color: #a0a8c0; }
    .query-box {
      background: #23234a;
      color: #e0e4f4;
      padding: 10px 24px;
      font-style: italic;
      font-size: 13px;
      flex-shrink: 0;
    }
    .columns {
      display: flex;
      flex: 1;
      overflow: hidden;
      gap: 1px;
      background: #d0d4e0;
    }
    .col {
      background: #fff;
      flex: 1;
      display: flex;
      flex-direction: column;
      overflow: hidden;
    }
    .col-header {
      background: #1a1a2e;
      color: #fff;
      padding: 10px 16px;
      font-weight: 600;
      font-size: 13px;
      flex-shrink: 0;
    }
    .col-header .subtitle {
      font-size: 11px;
      font-weight: 400;
      color: #8892b0;
      margin-top: 2px;
    }
    .col-body {
      flex: 1;
      overflow-y: auto;
      padding: 16px;
    }
    .answer { line-height: 1.7; }
    .answer sup a {
      color: #4a90e2;
      text-decoration: none;
      font-size: 10px;
    }
    .answer sup a:hover { text-decoration: underline; }
    hr { border: none; border-top: 1px solid #e0e4ed; margin: 16px 0; }
    .refs-title {
      font-size: 12px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      color: #666;
      margin-bottom: 8px;
    }
    ol.refs {
      padding-left: 18px;
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    ol.refs li {
      font-size: 12px;
      line-height: 1.5;
      color: #444;
    }
    ol.refs li a { color: #4a90e2; word-break: break-all; }
    ol.refs li em { color: #666; }
    .latency-badge {
      display: inline-block;
      margin-top: 12px;
      background: #eef2ff;
      border: 1px solid #c7d2fe;
      border-radius: 4px;
      padding: 3px 8px;
      font-size: 11px;
      color: #3730a3;
    }
    footer {
      background: #1a1a2e;
      color: #a0a8c0;
      text-align: center;
      padding: 10px 24px;
      font-size: 12px;
      flex-shrink: 0;
    }
    footer strong { color: #fff; }
  </style>
</head>
<body>
  <header>
    <h1>Citation Comparison &mdash; V1 vs V2</h1>
    <div class="meta">Generated: $TIMESTAMP</div>
  </header>
  <div class="query-box">&ldquo;$QUERY&rdquo;</div>

  <div class="columns">
    <!-- V1 -->
    <div class="col">
      <div class="col-header">
        Option 1: RetrieveAndGenerate + Span
        <div class="subtitle">bedrock-agent-runtime · retrieve_and_generate · citation spans</div>
      </div>
      <div class="col-body">
        <div class="answer">$V1_HTML</div>
        <hr>
        <div class="refs-title">References ($V1_COUNT)</div>
        <ol class="refs">$V1_REFS_HTML</ol>
        <div class="latency-badge">&#9201; ${V1_LATENCY}ms</div>
      </div>
    </div>

    <!-- V2 -->
    <div class="col">
      <div class="col-header">
        Option 2: Retrieve + Converse Citations API
        <div class="subtitle">bedrock-agent-runtime · retrieve · bedrock-runtime · converse</div>
      </div>
      <div class="col-body">
        <div class="answer">$V2_HTML</div>
        <hr>
        <div class="refs-title">References ($V2_COUNT)</div>
        <ol class="refs">$V2_REFS_HTML</ol>
        <div class="latency-badge">&#9201; ${V2_LATENCY}ms</div>
      </div>
    </div>
  </div>

  <footer>
    <strong>V1:</strong> ${V1_LATENCY}ms &nbsp;|&nbsp;
    <strong>V2:</strong> ${V2_LATENCY}ms &nbsp;|&nbsp;
    <strong>Diff:</strong> $FASTER_LABEL
  </footer>
</body>
</html>
HTML

echo "Comparison written to: $OUT_FILE"
open -a 'Google Chrome' "$OUT_FILE"
