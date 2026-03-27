#!/bin/bash
# Worker Check Agent: post-generation quality check + data cross-validation (claude -p)
# Sourced by worker.sh — do NOT run directly.

# Run quality check and data cross-validation on generated article
# Expects globals: RESULT, PRE_CONTEXT, CHECK_RULES, MODEL, JOBS_DIR
# Sets globals: CHECK_RESULT, CHECK_WARNINGS
run_check() {
  local JOBID="$1" TOPIC="$2"
  local WARNINGS="${WRITE_WARNINGS:-}"

  # Detect canonical model name from topic
  BLOG_MODEL_NAME=$(echo "$TOPIC" | python3 -c "
import re, sys
t = sys.stdin.read().strip()
t = re.sub(r'\b(vram|gpu|api|provider|pricing|how|to|access|use|in|with|on)\b', '', t, flags=re.IGNORECASE)
print(re.sub(r'\s+', ' ', t).strip())
" 2>/dev/null)

  # --- Step 1: Quality check & correction ---
  echo "[worker] [$JOBID] Running quality check (Step 1)..."
  echo "$RESULT" > /tmp/blog_data/_qc_input.txt

  CHECK_PROMPT_FILE="$JOBS_DIR/logs/${JOBID}.check_prompt"
  ARTICLE_CONTENT=$(cat /tmp/blog_data/_qc_input.txt | head -c 50000)
  cat > "$CHECK_PROMPT_FILE" << __CHECK_EOF__
CANONICAL MODEL NAME: ${BLOG_MODEL_NAME}

DATA FILES (read these to verify numbers before fixing):
- Novita API pricing → /tmp/blog_data/novita.json
- Model params/architecture → /tmp/blog_data/hf_detail_a.json, /tmp/blog_data/config_a.json
- Benchmarks & README → /tmp/blog_data/readme_a.md
- VRAM/quantization → /tmp/blog_data/hf_gguf_*.json (read all matching files)
- Search results → /tmp/blog_data/tavily_fanout_*.json

=== ARTICLE TO REVIEW & FIX ===
${ARTICLE_CONTENT}

Instructions:
1. Read the data files above to verify factual claims (prices, VRAM, params, benchmarks).
2. Fix all issues you can verify from the data.
3. For claims you CANNOT verify (e.g. latest model version, competitor pricing), add an HTML comment: <!-- REVIEW NOTE: [what needs manual verification] -->
4. Output the corrected article ONLY. No report, no commentary.
__CHECK_EOF__

  CHECK_RESULTFILE="$JOBS_DIR/logs/${JOBID}.check_result"
  CHECK_LOGFILE="$JOBS_DIR/logs/${JOBID}.check_log"

  cat "$CHECK_PROMPT_FILE" | claude -p \
    --system-prompt "$CHECK_RULES" \
    --model "$MODEL" \
    --output-format text \
    --permission-mode bypassPermissions \
    >"$CHECK_RESULTFILE" 2>"$CHECK_LOGFILE" &
  CHECK_PID=$!

  # Wait with timeout (5 min)
  CHECK_ELAPSED=0
  CHECK_TIMEOUT=300
  while kill -0 $CHECK_PID 2>/dev/null; do
    sleep 3
    CHECK_ELAPSED=$((CHECK_ELAPSED + 3))
    if [ $CHECK_ELAPSED -ge $CHECK_TIMEOUT ]; then
      echo "[worker] [$JOBID] Check claude -p timed out after ${CHECK_TIMEOUT}s"
      kill $CHECK_PID 2>/dev/null; sleep 1; kill -9 $CHECK_PID 2>/dev/null
      break
    fi
  done
  wait $CHECK_PID 2>/dev/null

  CHECKED_RESULT=""
  [ -f "$CHECK_RESULTFILE" ] && CHECKED_RESULT=$(cat "$CHECK_RESULTFILE")
  rm -f "$CHECK_PROMPT_FILE" "$CHECK_RESULTFILE"

  # Post-process: strip <think> tags and markdown fences
  CHECKED_RESULT=$(echo "$CHECKED_RESULT" | python3 << 'POSTPROCESS_EOF'
import sys, re
content = sys.stdin.read()
if '<think>' in content:
    content = re.sub(r'<think>[\s\S]*?</think>', '', content).strip()
content = re.sub(r'^```html\n?', '', content, flags=re.IGNORECASE)
content = re.sub(r'\n?```$', '', content)
print(content, end='')
POSTPROCESS_EOF
)

  if [ -n "$CHECKED_RESULT" ] && [ $(echo "$CHECKED_RESULT" | wc -c | tr -d ' ') -gt 2000 ]; then
    ORIGINAL_LEN=$(echo "$RESULT" | wc -c | tr -d ' ')
    CHECKED_LEN=$(echo "$CHECKED_RESULT" | wc -c | tr -d ' ')
    MIN_LEN=$(echo "$RESULT" | python3 -c "import sys; print(int(len(sys.stdin.read()) * 0.6))")
    if [ "$CHECKED_LEN" -ge "$MIN_LEN" ]; then
      echo "[worker] [$JOBID] Quality check done (${ORIGINAL_LEN} → ${CHECKED_LEN} chars)"
      RESULT="$CHECKED_RESULT"
    else
      echo "[worker] [$JOBID] Quality check sanity fail (too short), keeping original"
    fi
  else
    echo "[worker] [$JOBID] Quality check returned empty/short result, keeping original"
  fi
  rm -f /tmp/blog_data/_qc_input.txt

  # --- Step 2: Data cross-validation ---
  if [ -n "$PRE_CONTEXT" ] && [ -n "$RESULT" ] && [ $(echo "$RESULT" | wc -c | tr -d ' ') -gt 3000 ]; then
    echo "[worker] [$JOBID] Running data cross-validation (Step 2)..."
    echo "$RESULT" > /tmp/blog_data/_qc_xval_input.txt

    XVAL_ARTICLE=$(cat /tmp/blog_data/_qc_xval_input.txt | head -c 15000)
    XVAL_CONTEXT=$(echo "$PRE_CONTEXT" | head -c 15000)
    XVAL_PROMPT_FILE="$JOBS_DIR/logs/${JOBID}.xval_prompt"
    cat > "$XVAL_PROMPT_FILE" << __XVAL_EOF__
Compare the article against the research data. For each number, benchmark score, or price in the article, verify it exists in the research data.

Article:
${XVAL_ARTICLE}

Research Data:
${XVAL_CONTEXT}

Output JSON only:
{"verified": [{"claim": "...", "source": "...", "status": "match"}], "unverified": [{"claim": "...", "status": "no_source_found"}], "summary": "X verified, Y unverified"}
__XVAL_EOF__

    XVAL_RESULTFILE="$JOBS_DIR/logs/${JOBID}.xval_result"
    XVAL_LOGFILE="$JOBS_DIR/logs/${JOBID}.xval_log"

    cat "$XVAL_PROMPT_FILE" | claude -p \
      --system-prompt "You are a data verification assistant. Output valid JSON only. No explanation, no markdown fences." \
      --model "$MODEL" \
      --output-format text \
      --permission-mode bypassPermissions \
      >"$XVAL_RESULTFILE" 2>"$XVAL_LOGFILE" &
    XVAL_PID=$!

    XVAL_ELAPSED=0
    XVAL_TIMEOUT=120
    while kill -0 $XVAL_PID 2>/dev/null; do
      sleep 3
      XVAL_ELAPSED=$((XVAL_ELAPSED + 3))
      if [ $XVAL_ELAPSED -ge $XVAL_TIMEOUT ]; then
        echo "[worker] [$JOBID] Cross-validation timed out"
        kill $XVAL_PID 2>/dev/null; sleep 1; kill -9 $XVAL_PID 2>/dev/null
        break
      fi
    done
    wait $XVAL_PID 2>/dev/null

    QC_XVAL_RAW=""
    [ -f "$XVAL_RESULTFILE" ] && QC_XVAL_RAW=$(cat "$XVAL_RESULTFILE")
    rm -f "$XVAL_PROMPT_FILE" "$XVAL_RESULTFILE"

    # Parse JSON
    QC_XVAL_REPORT=$(echo "$QC_XVAL_RAW" | python3 << 'XVAL_PARSE_EOF'
import sys, re, json
content = sys.stdin.read()
if '<think>' in content:
    content = re.sub(r'<think>[\s\S]*?</think>', '', content).strip()
m = re.search(r'\{[\s\S]*\}', content)
if m:
    try:
        print(json.dumps(json.loads(m.group()), ensure_ascii=False))
    except:
        print(json.dumps({"error": "parse error"}))
else:
    print(json.dumps({"error": "no JSON in response"}))
XVAL_PARSE_EOF
)

    UNVERIFIED_COUNT=$(echo "$QC_XVAL_REPORT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('unverified',[])))" 2>/dev/null || echo "0")
    if [ "$UNVERIFIED_COUNT" -gt 0 ]; then
      echo -e "[worker] [$JOBID] \033[33mCross-validation: $UNVERIFIED_COUNT unverified claims\033[0m"
      WARNINGS="${WARNINGS:+${WARNINGS},}UNVERIFIED_CLAIMS(${UNVERIFIED_COUNT})"
    else
      echo "[worker] [$JOBID] Cross-validation: all claims verified"
    fi

    if [ "$UNVERIFIED_COUNT" -gt 0 ] && [ -n "$RESULT" ]; then
      CLAIMS_JSON=$(echo "$QC_XVAL_REPORT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
claims = [c.get('claim','') if isinstance(c, dict) else str(c) for c in d.get('unverified', [])]
print(json.dumps(claims, ensure_ascii=False))
" 2>/dev/null || echo "[]")
      if [ "$CLAIMS_JSON" != "[]" ]; then
        RESULT="${RESULT}
<!-- QC_UNVERIFIED: ${CLAIMS_JSON} -->"
        echo "[worker] [$JOBID] Injected $UNVERIFIED_COUNT unverified claims into article HTML"
      fi
    fi

    echo "$QC_XVAL_REPORT" > "$JOBS_DIR/logs/${JOBID}.qc_xval.json"
    rm -f /tmp/blog_data/_qc_xval_input.txt
  fi

  # Export results
  CHECK_RESULT="$RESULT"
  CHECK_WARNINGS="$WARNINGS"
}
