import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import { writeFileSync, readFileSync, existsSync, unlinkSync, mkdirSync, readdirSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import crypto from 'crypto';

const __dirname = dirname(fileURLToPath(import.meta.url));

const app = express();
app.use(cors());
app.use(express.json());

const PORT = process.env.PORT || 3001;
const ACCESS_PASSWORD = process.env.ACCESS_PASSWORD || '';
const JOBS_PENDING = join(__dirname, 'jobs/pending');
const JOBS_DONE = join(__dirname, 'jobs/done');

// Ensure dirs exist
mkdirSync(JOBS_PENDING, { recursive: true });
mkdirSync(JOBS_DONE, { recursive: true });

// ---------- Password protection ----------

// Serve static frontend (built dist/)
const distPath = join(__dirname, 'dist');
if (existsSync(distPath)) {
  // Login page (injected before static files)
  app.get('/login', (req, res) => {
    res.send(`<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Login - Dev Blog Platform</title>
<style>
  body{display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#0f172a;font-family:system-ui,sans-serif;color:#e2e8f0}
  .box{background:#1e293b;padding:2rem;border-radius:12px;width:320px;text-align:center}
  h2{margin:0 0 1.5rem;font-size:1.25rem}
  input{width:100%;padding:10px 12px;border:1px solid #334155;border-radius:8px;background:#0f172a;color:#e2e8f0;font-size:1rem;box-sizing:border-box}
  button{width:100%;padding:10px;margin-top:1rem;border:none;border-radius:8px;background:#3b82f6;color:#fff;font-size:1rem;cursor:pointer}
  button:hover{background:#2563eb}
  .err{color:#f87171;margin-top:.75rem;font-size:.875rem;display:none}
</style></head><body>
<div class="box">
  <h2>Dev Blog Platform</h2>
  <form onsubmit="return go()">
    <input type="password" id="pw" placeholder="Access Password" autofocus>
    <button type="submit">Enter</button>
  </form>
  <div class="err" id="err">Wrong password</div>
</div>
<script>
function go(){
  var pw=document.getElementById('pw').value;
  if(!pw)return false;
  fetch('/api/health',{headers:{'x-access-password':pw}}).then(function(r){
    if(r.ok){localStorage.setItem('_ap',pw);location.href='/';}
    else{document.getElementById('err').style.display='block';}
  });
  return false;
}
</script></body></html>`);
  });

  // Auth middleware: protect API routes, let static files through (frontend JS handles auth)
  if (ACCESS_PASSWORD) {
    app.use((req, res, next) => {
      if (req.path === '/login') return next();
      if (req.path.startsWith('/api/')) {
        const pw = req.headers['x-access-password'] || req.query.pw;
        if (pw !== ACCESS_PASSWORD) {
          return res.status(401).json({ error: 'Unauthorized' });
        }
      }
      next();
    });
  }

  app.use(express.static(distPath));
  // SPA fallback: serve index.html for any non-API route
  app.get('/{*splat}', (req, res, next) => {
    if (req.path.startsWith('/api/')) return next();
    res.sendFile(join(distPath, 'index.html'));
  });
}

// ---------- Job-based article generation ----------

function submitJob(topic, outputMode = 'article', answer = '') {
  const jobId = crypto.randomUUID();
  const jobFile = join(JOBS_PENDING, `${jobId}.json`);
  const jobData = { topic, outputMode };
  if (answer) jobData.answer = answer;
  writeFileSync(jobFile, JSON.stringify(jobData));
  console.log(`[server] Job ${jobId} submitted: "${topic}" (mode: ${outputMode})${answer ? ' [with answer]' : ''}`);
  return jobId;
}

function waitForResult(jobId, timeoutMs = 600000) {
  return new Promise((resolve, reject) => {
    const resultFile = join(JOBS_DONE, `${jobId}.json`);
    const startTime = Date.now();
    const interval = setInterval(() => {
      if (existsSync(resultFile)) {
        clearInterval(interval);
        try {
          const data = JSON.parse(readFileSync(resultFile, 'utf-8'));
          unlinkSync(resultFile); // cleanup
          if (data.status === 'done') {
            resolve({ content: data.content, outputMode: data.outputMode || 'article', warnings: data.warnings || null });
          } else if (data.status === 'review') {
            resolve({ status: 'review', contextFile: data.contextFile, sources: data.sources, summary: data.summary, rawContext: data.rawContext });
          } else if (data.status === 'outline_review') {
            resolve({ status: 'outline_review', outline: data.outline, allSources: data.allSources });
          } else if (data.status === 'clarification') {
            resolve({ status: 'clarification', question: data.question });
          } else {
            reject(new Error(data.error || 'Worker reported error'));
          }
        } catch (err) {
          reject(new Error(`Failed to read result: ${err.message}`));
        }
      } else if (Date.now() - startTime > timeoutMs) {
        clearInterval(interval);
        reject(new Error('Timeout waiting for worker (10 min)'));
      }
    }, 2000); // poll every 2 seconds
  });
}

function cleanContent(content) {
  // Remove markdown code block wrappers
  content = content.replace(/```html\n?/gi, '').replace(/```\n?/g, '');

  // Strip AI thinking/planning text before the first HTML tag
  const firstHtmlTag = content.search(/<(?:h[1-6]|p|div|section|article|main|header|ul|ol|table|figure|style)\b/i);
  if (firstHtmlTag > 0) {
    content = content.slice(firstHtmlTag);
  } else if (firstHtmlTag === -1) {
    // No HTML tags found at all — convert markdown to basic HTML
    content = markdownToHtml(content);
  }

  // Strip trailing non-HTML summary text
  const trailingPattern = content.search(/\n---\n+[\s\S]*?\*\*Article Complete/i);
  if (trailingPattern > 0) {
    content = content.slice(0, trailingPattern);
  }
  const trailingChinese = content.search(/\n---\n+[\s\S]*?完[美成]/);
  if (trailingChinese > 0) {
    content = content.slice(0, trailingChinese);
  }

  // Ensure article wrapper
  if (!content.includes('<article')) {
    content = `<article class="prose max-w-none">${content}</article>`;
  }

  return content;
}

// Basic markdown → HTML converter (fallback when Claude outputs markdown instead of HTML)
function markdownToHtml(md) {
  let html = md;
  // Code blocks first (before other processing)
  html = html.replace(/```(\w*)\n([\s\S]*?)```/g, (_, lang, code) =>
    `<pre><code class="language-${lang || 'text'}">${code.replace(/</g, '&lt;').replace(/>/g, '&gt;')}</code></pre>`
  );
  // Headings (must be at start of line)
  html = html.replace(/^######\s+(.+)$/gm, '<h6>$1</h6>');
  html = html.replace(/^#####\s+(.+)$/gm, '<h5>$1</h5>');
  html = html.replace(/^####\s+(.+)$/gm, '<h4>$1</h4>');
  html = html.replace(/^###\s+(.+)$/gm, '<h3>$1</h3>');
  html = html.replace(/^##\s+(.+)$/gm, '<h2>$1</h2>');
  html = html.replace(/^#\s+(.+)$/gm, '<h2>$1</h2>');
  // Bold and italic
  html = html.replace(/\*\*\*(.+?)\*\*\*/g, '<strong><em>$1</em></strong>');
  html = html.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
  html = html.replace(/\*(.+?)\*/g, '<em>$1</em>');
  // Inline code
  html = html.replace(/`([^`]+)`/g, '<code>$1</code>');
  // Horizontal rules
  html = html.replace(/^---+$/gm, '<hr>');
  // Unordered lists (consecutive - lines)
  html = html.replace(/^(?:[-*]\s+.+\n?)+/gm, (block) => {
    const items = block.trim().split('\n').map(line =>
      `<li>${line.replace(/^[-*]\s+/, '')}</li>`
    ).join('\n');
    return `<ul>${items}</ul>\n`;
  });
  // Ordered lists (consecutive numbered lines)
  html = html.replace(/^(?:\d+\.\s+.+\n?)+/gm, (block) => {
    const items = block.trim().split('\n').map(line =>
      `<li>${line.replace(/^\d+\.\s+/, '')}</li>`
    ).join('\n');
    return `<ol>${items}</ol>\n`;
  });
  // Tables
  html = html.replace(/^(\|.+\|)\n(\|[\s:|-]+\|)\n((?:\|.+\|\n?)+)/gm, (_, header, sep, body) => {
    const thCells = header.split('|').filter(c => c.trim()).map(c => `<th>${c.trim()}</th>`).join('');
    const rows = body.trim().split('\n').map(row => {
      const cells = row.split('|').filter(c => c.trim()).map(c => `<td>${c.trim()}</td>`).join('');
      return `<tr>${cells}</tr>`;
    }).join('\n');
    return `<table class="specs-table"><thead><tr>${thCells}</tr></thead><tbody>${rows}</tbody></table>\n`;
  });
  // Wrap remaining plain text paragraphs
  html = html.replace(/^(?!<[a-z])[^\n]+$/gm, (line) => {
    if (line.trim()) return `<p>${line}</p>`;
    return '';
  });
  // Clean up extra newlines
  html = html.replace(/\n{3,}/g, '\n\n');
  return html.trim();
}

// ---------- Routes ----------

// In-memory job tracking (for poll-based results)
const jobResults = new Map(); // jobId -> { status, data, createdAt }

// Submit job (returns immediately with jobId)
app.post('/api/generate', (req, res) => {
  const { topics, outputMode, answer } = req.body;

  if (!topics || !Array.isArray(topics) || topics.length === 0) {
    return res.status(400).json({ error: 'topics array is required' });
  }

  const mode = outputMode || 'article';
  const topic = topics[0]; // Process one topic at a time
  console.log(`\n[server] Submitting: "${topic}" (mode: ${mode})${answer ? ' [with answer]' : ''}`);

  const jobId = submitJob(topic, mode, answer || '');
  jobResults.set(jobId, { status: 'processing', createdAt: Date.now() });

  // Process in background
  waitForResult(jobId).then(result => {
    if (result.status === 'review') {
      jobResults.set(jobId, {
        status: 'review',
        topic, outputMode: mode,
        contextFile: result.contextFile,
        sources: result.sources,
        summary: result.summary,
        rawContext: result.rawContext,
        createdAt: Date.now(),
      });
      console.log(`[server] Job ${jobId} review ready (${result.sources?.length || 0} sources)`);
      return;
    }

    if (result.status === 'outline_review') {
      jobResults.set(jobId, {
        status: 'outline_review',
        topic, outputMode: mode,
        outline: result.outline,
        allSources: result.allSources,
        createdAt: Date.now(),
      });
      console.log(`[server] Job ${jobId} outline_review ready`);
      return;
    }

    if (result.status === 'clarification') {
      jobResults.set(jobId, {
        status: 'clarification',
        question: result.question,
        jobContext: { topic, outputMode: mode },
      });
      return;
    }

    const resultMode = result.outputMode || 'article';
    let article;

    if (resultMode === 'compare') {
      let compareData;
      try { compareData = JSON.parse(result.content); } catch { compareData = null; }
      article = {
        id: `article_${Date.now()}`,
        title: topic, modelName: topic.split(' ').slice(0, 3).join(' '),
        keyword: topic, createdAt: new Date().toISOString(),
        outputMode: 'compare', content: compareData || result.content,
        compareData, warnings: result.warnings,
      };
    } else {
      article = {
        id: `article_${Date.now()}`,
        title: topic, modelName: topic.split(' ').slice(0, 3).join(' '),
        keyword: topic, createdAt: new Date().toISOString(),
        outputMode: 'article', content: cleanContent(result.content),
        warnings: result.warnings,
      };
    }

    jobResults.set(jobId, { status: 'done', article });
    console.log(`[server] Job ${jobId} done (${resultMode}, ${Math.round(result.content.length / 1024)}KB)`);
  }).catch(err => {
    console.error(`[server] Job ${jobId} failed:`, err.message);
    jobResults.set(jobId, { status: 'error', error: err.message });
  });

  res.json({ jobId });
});

// Poll job status
app.get('/api/jobs/:jobId', (req, res) => {
  const { jobId } = req.params;
  const job = jobResults.get(jobId);

  if (!job) {
    return res.status(404).json({ status: 'not_found' });
  }

  if (job.status === 'processing') {
    return res.json({ status: 'processing' });
  }

  if (job.status === 'review') {
    // Don't delete — user reviews and confirms
    return res.json({ status: 'review', sources: job.sources, summary: job.summary, rawContext: job.rawContext });
  }

  // outline_review removed — architect merged into write agent

  if (job.status === 'clarification') {
    // Don't delete — user may need to re-poll after answering
    return res.json({ status: 'clarification', question: job.question, jobContext: job.jobContext });
  }

  if (job.status === 'done') {
    jobResults.delete(jobId); // cleanup after delivery
    return res.json({ status: 'done', articles: [job.article] });
  }

  if (job.status === 'error') {
    jobResults.delete(jobId);
    return res.json({ status: 'error', error: job.error });
  }

  res.json({ status: job.status });
});

// Helper: start generate phase and wait for result
function startGenerateAndWait(jobId, topic, outputMode, extraJobData = {}) {
  const jobFile = join(JOBS_PENDING, `${jobId}.json`);
  writeFileSync(jobFile, JSON.stringify({ topic, outputMode, phase: 'generate', ...extraJobData }));
  jobResults.set(jobId, { status: 'processing', createdAt: Date.now() });

  waitForResult(jobId).then(result => {
    if (result.status === 'clarification') {
      jobResults.set(jobId, {
        status: 'clarification',
        question: result.question,
        jobContext: { topic, outputMode },
      });
      return;
    }

    const resultMode = result.outputMode || 'article';
    let article;
    if (resultMode === 'compare') {
      let compareData;
      try { compareData = JSON.parse(result.content); } catch { compareData = null; }
      article = {
        id: `article_${Date.now()}`, title: topic,
        modelName: topic.split(' ').slice(0, 3).join(' '),
        keyword: topic, createdAt: new Date().toISOString(),
        outputMode: 'compare', content: compareData || result.content,
        compareData, warnings: result.warnings,
      };
    } else {
      article = {
        id: `article_${Date.now()}`, title: topic,
        modelName: topic.split(' ').slice(0, 3).join(' '),
        keyword: topic, createdAt: new Date().toISOString(),
        outputMode: 'article', content: cleanContent(result.content),
        warnings: result.warnings,
      };
    }
    jobResults.set(jobId, { status: 'done', article });
    console.log(`[server] Job ${jobId} done (${resultMode})`);
  }).catch(err => {
    console.error(`[server] Job ${jobId} generate failed:`, err.message);
    jobResults.set(jobId, { status: 'error', error: err.message });
  });
}

// Confirm or request more search for a reviewed job
app.post('/api/jobs/:jobId/confirm', (req, res) => {
  const { jobId } = req.params;
  const { action, feedback, removedUrls = [], editedOutline } = req.body;
  const job = jobResults.get(jobId);

  if (!job || job.status !== 'review') {
    return res.status(400).json({ error: 'Job not in review status' });
  }

  const { topic, outputMode } = job;
  const jobFile = join(JOBS_PENDING, `${jobId}.json`);

  if (action === 'search_more' && job.status === 'review') {
    console.log(`[server] Job ${jobId} search_more: "${feedback}"`);
    writeFileSync(jobFile, JSON.stringify({ topic, outputMode, phase: 'search_more', feedback, removedUrls }));
    jobResults.set(jobId, { status: 'processing', createdAt: Date.now() });

    waitForResult(jobId).then(result => {
      if (result.status === 'review') {
        jobResults.set(jobId, {
          status: 'review', topic, outputMode,
          contextFile: result.contextFile,
          sources: result.sources,
          summary: result.summary,
          rawContext: result.rawContext,
          createdAt: Date.now(),
        });
        console.log(`[server] Job ${jobId} updated review (${result.sources?.length || 0} sources)`);
      } else {
        jobResults.set(jobId, { status: 'error', error: 'Unexpected result from search_more' });
      }
    }).catch(err => {
      jobResults.set(jobId, { status: 'error', error: err.message });
    });

  } else {
    // Default from review: confirm sources → go directly to generate (architect merged into write)
    console.log(`[server] Job ${jobId} confirmed → generate (architect+write merged)`);
    startGenerateAndWait(jobId, topic, outputMode, { removedUrls });
  }

  res.json({ status: 'ok' });
});

// Cleanup stale jobs every 30 min
setInterval(() => {
  const now = Date.now();
  for (const [id, job] of jobResults) {
    if (now - job.createdAt > 30 * 60 * 1000) jobResults.delete(id);
  }
}, 30 * 60 * 1000);

// ---------- SEO Stats (reads from Feishu Bitable) ----------

const FEISHU_BASE = 'https://open.feishu.cn/open-apis';
const FEISHU_APP_ID = process.env.FEISHU_APP_ID || 'cli_a906813bd8381ced';
const FEISHU_APP_SECRET = process.env.FEISHU_APP_SECRET || 'yA5AH4uJ0BoL4nX4X6IXMt2q3r5VOklz';
const FEISHU_BITABLE_APP_TOKEN = process.env.FEISHU_BITABLE_APP_TOKEN || 'Da5YbqRr4aMr13sPWNncEJ5zn6d';
const FEISHU_TABLE_HISTORY = process.env.FEISHU_TABLE_HISTORY || 'tblxQQRXjMJZADcg';

let feishuToken = null;
let feishuTokenExpiry = 0;

async function getFeishuToken() {
  if (Date.now() < feishuTokenExpiry && feishuToken) return feishuToken;
  const resp = await fetch(`${FEISHU_BASE}/auth/v3/tenant_access_token/internal`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ app_id: FEISHU_APP_ID, app_secret: FEISHU_APP_SECRET }),
  });
  const data = await resp.json();
  feishuToken = data.tenant_access_token;
  feishuTokenExpiry = Date.now() + (data.expire - 60) * 1000;
  return feishuToken;
}

async function listFeishuRecords(tableId) {
  const token = await getFeishuToken();
  const records = [];
  let pageToken = null;
  while (true) {
    const params = new URLSearchParams({ page_size: '500' });
    if (pageToken) params.set('page_token', pageToken);
    const resp = await fetch(
      `${FEISHU_BASE}/bitable/v1/apps/${FEISHU_BITABLE_APP_TOKEN}/tables/${tableId}/records?${params}`,
      { headers: { Authorization: `Bearer ${token}` } },
    );
    const data = (await resp.json()).data;
    records.push(...(data.items || []));
    if (!data.has_more) break;
    pageToken = data.page_token;
  }
  return records;
}

const FEISHU_TABLE_ARTICLES = process.env.FEISHU_TABLE_ARTICLES || 'tbltOmddxwR7yVyv';

app.get('/api/seo/ashuia-trends', async (req, res) => {
  try {
    // Get all 阿水 articles from main table
    const articleRecords = await listFeishuRecords(FEISHU_TABLE_ARTICLES);
    // Get history snapshots
    const historyRecords = await listFeishuRecords(FEISHU_TABLE_HISTORY);

    // Build all 阿水 articles list from main table
    const allArticles = {};
    for (const rec of articleRecords) {
      const f = rec.fields;
      if (f.author === '阿水' && f.slug) {
        allArticles[f.slug] = {
          title: f.title || f.slug,
          url: f.url || '',
          category: f.category || '',
          publishTime: f.publish_time || '',
        };
      }
    }

    // Group history by article
    const historyMap = {};
    const weekSet = new Set();
    for (const rec of historyRecords) {
      const f = rec.fields;
      const week = f.week_date || '';
      const slug = f.slug || '';
      if (!week || !slug) continue;
      weekSet.add(week);
      if (!historyMap[slug]) historyMap[slug] = {};
      historyMap[slug][week] = {
        clicks: Number(f.clicks_7d) || 0,
        impressions: Number(f.impressions_7d) || 0,
        ctr: Number(f.ctr_7d) || 0,
        position: Number(f.avg_position_7d) || 0,
      };
    }

    const weeks = [...weekSet].sort();
    const latestWeek = weeks[weeks.length - 1] || '';

    // Build article list: ALL 阿水 articles, merge with history data
    const articles = Object.entries(allArticles).map(([slug, meta]) => {
      const weeksData = historyMap[slug] || {};
      return {
        slug,
        title: meta.title,
        url: meta.url,
        category: meta.category,
        publishTime: meta.publishTime,
        weeks: weeksData,
        latestClicks: weeksData[latestWeek]?.clicks || 0,
      };
    }).sort((a, b) => b.latestClicks - a.latestClicks);

    // Weekly totals for all 阿水 articles
    const weeklyTotals = weeks.map(w => {
      let clicks = 0, impressions = 0, posSum = 0, posCount = 0;
      for (const art of articles) {
        const d = art.weeks[w];
        if (d) {
          clicks += d.clicks;
          impressions += d.impressions;
          if (d.position > 0) { posSum += d.position; posCount++; }
        }
      }
      const avgPos = posCount > 0 ? Math.round(posSum / posCount * 10) / 10 : 0;
      const ctr = impressions > 0 ? Math.round(clicks / impressions * 10000) / 100 : 0;
      return { week: w, clicks, impressions, ctr, avgPosition: avgPos, articles: posCount };
    });

    res.json({ weeks, articles, weeklyTotals });
  } catch (err) {
    console.error('[seo] Error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/health', (req, res) => {
  res.json({
    status: 'ok',
    engine: 'claude-code (file queue)',
    pendingJobs: existsSync(JOBS_PENDING) ? readdirSync(JOBS_PENDING).length : 0,
    timestamp: new Date().toISOString(),
  });
});

const server = app.listen(PORT, () => {
  console.log(`\n[server] Dev Blog Backend on http://localhost:${PORT}`);
  console.log(`[server] Engine: File queue -> worker.sh -> claude -p`);
  console.log(`[server] POST /api/generate  - Generate articles`);
  console.log(`[server] GET  /api/health    - Health check`);
  console.log(`\nIMPORTANT: Make sure worker.sh is running in a separate terminal!`);
  console.log(`  cd ~/dev-blog-platform && ./worker.sh\n`);
});

// Article generation takes 5-10 min; prevent Node.js from killing the connection
server.timeout = 0;
server.headersTimeout = 0;
server.requestTimeout = 0;
server.keepAliveTimeout = 700000; // 11+ min
