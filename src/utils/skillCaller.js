// dev-blog-writer skill 调用工具 - 通过后端调用 Claude Code CLI

import { storage } from './storage';

function getAuthHeaders() {
  const headers = {};
  const savedPw = localStorage.getItem('_ap');
  if (savedPw) headers['x-access-password'] = savedPw;
  return headers;
}

function checkAuth(response) {
  if (response.status === 401) {
    localStorage.removeItem('_ap');
    window.location.href = '/login';
    throw new Error('Unauthorized');
  }
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * Poll a jobId until terminal state (review/done/clarification/error)
 */
async function pollJob(jobId, maxWait = 10 * 60 * 1000) {
  const start = Date.now();

  while (Date.now() - start < maxWait) {
    await sleep(3000);

    const pollResp = await fetch(`/api/jobs/${jobId}`, {
      headers: getAuthHeaders(),
    });

    checkAuth(pollResp);
    if (!pollResp.ok) {
      throw new Error(`Poll error (${pollResp.status})`);
    }

    const data = await pollResp.json();

    if (data.status === 'processing') {
      continue;
    }

    if (data.status === 'review') {
      return { review: true, sources: data.sources, summary: data.summary, rawContext: data.rawContext, jobId };
    }

    // outline_review removed — architect merged into write agent

    if (data.status === 'clarification') {
      return { clarification: true, question: data.question, context: data.jobContext };
    }

    if (data.status === 'done') {
      if (data.articles) {
        data.articles.forEach(article => storage.saveArticle(article));
      }
      return data.articles || [];
    }

    if (data.status === 'error') {
      throw new Error(data.error || 'Generation failed');
    }
  }

  throw new Error('Timeout: 超过 10 分钟');
}

/**
 * 提交生成任务 → 轮询直到 review/done/clarification
 */
export async function generateArticlesWithSkill(topics, outputMode = 'article', answer = '') {
  console.log(`提交生成任务: ${topics.length} 篇 (mode: ${outputMode})${answer ? ' [with answer]' : ''}`);

  const body = { topics, outputMode };
  if (answer) body.answer = answer;

  const submitResp = await fetch('/api/generate', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...getAuthHeaders() },
    body: JSON.stringify(body),
  });

  checkAuth(submitResp);
  if (!submitResp.ok) {
    const err = await submitResp.json().catch(() => ({}));
    throw new Error(err.error || `Server error (${submitResp.status})`);
  }

  const { jobId } = await submitResp.json();
  console.log(`Job submitted: ${jobId}, polling...`);

  return pollJob(jobId);
}

/**
 * Confirm reviewed job → architect phase (sources confirmed), or search more
 */
export async function confirmJob(jobId, action = 'generate', feedback = '', removedUrls = []) {
  console.log(`Confirm job ${jobId}: ${action}${feedback ? ` — "${feedback}"` : ''}${removedUrls.length ? ` (${removedUrls.length} removed)` : ''}`);

  const resp = await fetch(`/api/jobs/${jobId}/confirm`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...getAuthHeaders() },
    body: JSON.stringify({ action, feedback, removedUrls }),
  });

  checkAuth(resp);
  if (!resp.ok) {
    const err = await resp.json().catch(() => ({}));
    throw new Error(err.error || `Confirm failed (${resp.status})`);
  }

  return pollJob(jobId);
}

/**
 * Confirm outline → generate article
 */
export async function confirmOutline(jobId, editedOutline) {
  console.log(`Confirm outline for job ${jobId}`);

  const resp = await fetch(`/api/jobs/${jobId}/confirm`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...getAuthHeaders() },
    body: JSON.stringify({ action: 'confirm_outline', editedOutline }),
  });

  checkAuth(resp);
  if (!resp.ok) {
    const err = await resp.json().catch(() => ({}));
    throw new Error(err.error || `Confirm outline failed (${resp.status})`);
  }

  return pollJob(jobId);
}
