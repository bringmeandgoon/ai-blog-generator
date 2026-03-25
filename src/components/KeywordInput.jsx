import { useState, useEffect, useRef } from 'react';
import { generateArticlesWithSkill, confirmJob, confirmOutline, addUrlToJob } from '../utils/skillCaller';
import { storage } from '../utils/storage';
import SourceReview from './SourceReview';
import OutlineEditor from './OutlineEditor';

export default function KeywordInput({ onArticlesGenerated }) {
  const [input, setInput] = useState('');
  const [outputMode, setOutputMode] = useState('article');
  const [isGenerating, setIsGenerating] = useState(false);
  const [error, setError] = useState('');
  const [progress, setProgress] = useState('');
  const [elapsed, setElapsed] = useState(0);
  const [clarification, setClarification] = useState(null);
  const [clarificationAnswer, setClarificationAnswer] = useState('');
  const [reviewData, setReviewData] = useState(null); // { sources, summary, rawContext, jobId }
  const [outlineData, setOutlineData] = useState(null); // { outline, allSources, jobId }
  const [writeReviewData, setWriteReviewData] = useState(null); // { article, jobId }
  const editRef = useRef(null);
  const timerRef = useRef(null);

  const hasVs = /\bvs\b/i.test(input);

  useEffect(() => {
    if (isGenerating) {
      setElapsed(0);
      timerRef.current = setInterval(() => {
        setElapsed(prev => prev + 1);
      }, 1000);
    } else {
      if (timerRef.current) {
        clearInterval(timerRef.current);
        timerRef.current = null;
      }
    }
    return () => {
      if (timerRef.current) clearInterval(timerRef.current);
    };
  }, [isGenerating]);

  const formatTime = (seconds) => {
    const m = Math.floor(seconds / 60);
    const s = seconds % 60;
    if (m > 0) return `${m}m ${s}s`;
    return `${s}s`;
  };

  /**
   * Handle any result from polling — could be review, clarification, or articles
   */
  const handleResult = (result) => {
    if (result && result.review) {
      setReviewData(result);
      setOutlineData(null);
      setProgress('');
      setIsGenerating(false);
      return;
    }

    // outline_review removed — architect merged into write agent

    if (result && result.clarification) {
      setClarification({
        question: result.question,
        topic: result.context.topic,
        outputMode: result.context.outputMode,
      });
      setClarificationAnswer('');
      setProgress('');
      setIsGenerating(false);
      return;
    }

    // Done — result is articles array
    const articles = result;
    articles.forEach(article => storage.saveArticle(article));
    onArticlesGenerated(articles);
    setInput('');
    setProgress('');
    setReviewData(null);
    setOutlineData(null);
    setWriteReviewData(null);
  };

  const handleGenerate = async () => {
    setError('');
    setProgress('');
    setReviewData(null);
    setOutlineData(null);
    setWriteReviewData(null);

    const topics = input
      .split(/[;；,，]/)
      .map(s => s.trim())
      .filter(s => s);

    if (topics.length === 0) {
      setError('请输入至少一个主题\n例如: minimax m2.1 vram; minimax m2.1 api provider');
      return;
    }

    setIsGenerating(true);
    setProgress('正在预搜索...');

    try {
      const mode = hasVs ? outputMode : 'article';
      const result = await generateArticlesWithSkill(topics, mode);
      handleResult(result);
    } catch (err) {
      setError(`生成失败: ${err.message}`);
      setProgress('');
    } finally {
      setIsGenerating(false);
    }
  };

  const handleConfirmGenerate = async (removedUrls = []) => {
    if (!reviewData) return;

    setError('');
    setIsGenerating(true);
    setProgress('Sources confirmed, generating outline...');

    try {
      // Now goes to architect phase (not directly generate)
      const result = await confirmJob(reviewData.jobId, 'generate', '', removedUrls);
      handleResult(result);
    } catch (err) {
      setError(`生成失败: ${err.message}`);
      setProgress('');
    } finally {
      setIsGenerating(false);
    }
  };

  const handleConfirmOutline = async (editedOutline) => {
    if (!outlineData) return;

    setError('');
    setIsGenerating(true);
    setProgress('Outline confirmed, generating article...');

    try {
      const result = await confirmOutline(outlineData.jobId, editedOutline);
      handleResult(result);
    } catch (err) {
      setError(`生成失败: ${err.message}`);
      setProgress('');
    } finally {
      setIsGenerating(false);
    }
  };

  const handleAddUrl = async (url) => {
    if (!reviewData || !url) return;
    const data = await addUrlToJob(reviewData.jobId, url);
    if (data.source) {
      setReviewData(prev => ({ ...prev, sources: [...(prev.sources || []), data.source] }));
    }
  };

  const handleClarificationSubmit = async () => {
    if (!clarificationAnswer.trim() || !clarification) return;

    setError('');
    setIsGenerating(true);
    setProgress('正在用你的回答重新生成文章...');
    const { topic, outputMode: cMode } = clarification;
    setClarification(null);

    try {
      const result = await generateArticlesWithSkill([topic], cMode, clarificationAnswer.trim());
      handleResult(result);
    } catch (err) {
      setError(`生成失败: ${err.message}`);
      setProgress('');
    } finally {
      setIsGenerating(false);
    }
  };

  // Set editable content when writeReviewData arrives
  useEffect(() => {
    if (writeReviewData && editRef.current) {
      editRef.current.innerHTML = writeReviewData.article?.content || '';
    }
  }, [writeReviewData]);

  // Show WriteReview when article is ready for humanization review
  if (writeReviewData && !isGenerating) {
    return (
      <div className="fixed inset-0 z-50 bg-white overflow-y-auto">
        <div className="max-w-5xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
          <div className="mb-6">
            <div className="flex items-center mb-2">
              <div className="w-8 h-8 rounded-lg bg-green-500 flex items-center justify-center mr-3">
                <svg className="w-4 h-4 text-white" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
                </svg>
              </div>
              <h2 className="text-xl font-display font-black text-dark-900">Article Draft Ready</h2>
            </div>
            <p className="text-sm text-dark-500 ml-11">直接在下方编辑文章草稿（可增删内容），确认后点 "Approve & Polish" 进行润色校验。</p>
          </div>

          <div
            ref={editRef}
            contentEditable={true}
            suppressContentEditableWarning={true}
            className="prose max-w-none border border-dark-200 rounded-xl p-6 mb-6 bg-white overflow-auto max-h-[60vh] text-sm outline-none focus:ring-2 focus:ring-primary-300 cursor-text"
          />

          {error && (
            <div className="mb-4 p-4 rounded-xl bg-red-50 border border-red-200 text-red-700 animate-scale-in">
              <div className="flex items-start">
                <svg className="w-5 h-5 mr-2 mt-0.5 flex-shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                <div className="whitespace-pre-line text-sm">{error}</div>
              </div>
            </div>
          )}

          <div className="flex gap-3">
            <button
              onClick={async () => {
                setError('');
                setIsGenerating(true);
                setProgress('正在润色并校验...');
                const jobId = writeReviewData.jobId;
                const editedContent = editRef.current?.innerHTML || writeReviewData.article?.content || '';
                setWriteReviewData(null);
                try {
                  const result = await confirmJob(jobId, 'confirm_write', '', [], editedContent);
                  handleResult(result);
                } catch (err) {
                  setError(`润色失败: ${err.message}`);
                  setProgress('');
                } finally {
                  setIsGenerating(false);
                }
              }}
              className="btn btn-primary flex-1"
            >
              Approve &amp; Polish (Rewrite + QC)
            </button>
            <button
              onClick={() => { setWriteReviewData(null); setError(''); }}
              className="btn bg-dark-100 text-dark-600 hover:bg-dark-200"
            >
              Cancel
            </button>
          </div>
        </div>
      </div>
    );
  }

  // Show OutlineEditor when we have outline data (and not generating)
  if (outlineData && !isGenerating) {
    return (
      <div className="fixed inset-0 z-50 bg-white overflow-y-auto">
        <div className="max-w-5xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
          <OutlineEditor
            data={outlineData}
            onConfirm={handleConfirmOutline}
            onCancel={() => { setOutlineData(null); setReviewData(null); setError(''); }}
          />
          {error && (
            <div className="mt-4 p-4 rounded-xl bg-red-50 border border-red-200 text-red-700 animate-scale-in">
              <div className="flex items-start">
                <svg className="w-5 h-5 mr-2 mt-0.5 flex-shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                <div className="whitespace-pre-line text-sm">{error}</div>
              </div>
            </div>
          )}
        </div>
      </div>
    );
  }

  // Show SourceReview when we have review data (and not generating)
  // Uses fixed overlay to cover full page for better readability
  if (reviewData && !isGenerating) {
    return (
      <div className="fixed inset-0 z-50 bg-white overflow-y-auto">
        <div className="max-w-5xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
          <SourceReview
            data={reviewData}
            onConfirm={handleConfirmGenerate}
            onAddUrl={handleAddUrl}
            isLoading={isGenerating}
          />
          {error && (
            <div className="mt-4 p-4 rounded-xl bg-red-50 border border-red-200 text-red-700 animate-scale-in">
              <div className="flex items-start">
                <svg className="w-5 h-5 mr-2 mt-0.5 flex-shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                <div className="whitespace-pre-line text-sm">{error}</div>
              </div>
            </div>
          )}
          <button
            onClick={() => { setReviewData(null); setError(''); }}
            className="mt-3 btn bg-dark-100 text-dark-600 hover:bg-dark-200 w-full"
          >
            Cancel & Start Over
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="card p-6">
      <div className="mb-6">
        <div className="flex items-center mb-2">
          <div className="w-8 h-8 rounded-lg bg-primary-500 flex items-center justify-center mr-3">
            <svg className="w-4 h-4 text-white" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
            </svg>
          </div>
          <h2 className="text-xl font-display font-black text-dark-900">Generate Blog</h2>
        </div>
      </div>

      <div className="mb-4">
        <label className="block text-sm font-medium text-dark-600 mb-2">
          Article Topics
          <span className="text-dark-400 font-normal ml-2">(separate with ; or ,)</span>
        </label>
        <textarea
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="minimax m2.1 vram; minimax m2.1 api provider; deepseek v3 pricing"
          rows={4}
          className="textarea font-mono text-sm"
          disabled={isGenerating}
        />
        <div className="flex items-center mt-2 text-xs text-dark-400">
          <svg className="w-4 h-4 mr-1" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
          </svg>
          <span>One article per topic · Pre-search → Review sources → Generate</span>
        </div>
      </div>

      {/* Output mode toggle — only shown when "vs" is detected */}
      {hasVs && (
        <div className="mb-4 p-3 rounded-xl bg-dark-50 border border-dark-200 animate-scale-in">
          <label className="block text-xs font-medium text-dark-500 mb-2">Output Format</label>
          <div className="flex rounded-lg bg-dark-100 p-1">
            <button
              type="button"
              onClick={() => setOutputMode('article')}
              disabled={isGenerating}
              className={`flex-1 flex items-center justify-center gap-2 px-3 py-2 rounded-md text-sm font-medium transition-all ${
                outputMode === 'article'
                  ? 'bg-white text-dark-900 shadow-sm'
                  : 'text-dark-500 hover:text-dark-700'
              }`}
            >
              <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
              </svg>
              Article
            </button>
            <button
              type="button"
              onClick={() => setOutputMode('compare')}
              disabled={isGenerating}
              className={`flex-1 flex items-center justify-center gap-2 px-3 py-2 rounded-md text-sm font-medium transition-all ${
                outputMode === 'compare'
                  ? 'bg-white text-dark-900 shadow-sm'
                  : 'text-dark-500 hover:text-dark-700'
              }`}
            >
              <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z" />
              </svg>
              Compare Page
            </button>
          </div>
        </div>
      )}

      {clarification && !isGenerating && (
        <div className="mb-4 p-4 rounded-xl bg-amber-50 border border-amber-300 animate-scale-in">
          <div className="flex items-start mb-3">
            <svg className="w-5 h-5 mr-2 mt-0.5 flex-shrink-0 text-amber-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M8.228 9c.549-1.165 2.03-2 3.772-2 2.21 0 4 1.343 4 3 0 1.4-1.278 2.575-3.006 2.907-.542.104-.994.54-.994 1.093m0 3h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
            <div>
              <div className="font-semibold text-amber-800 mb-1">Claude needs clarification</div>
              <div className="text-sm text-amber-700 whitespace-pre-line">{clarification.question}</div>
            </div>
          </div>
          <textarea
            value={clarificationAnswer}
            onChange={(e) => setClarificationAnswer(e.target.value)}
            placeholder="Type your answer here..."
            rows={2}
            className="textarea font-mono text-sm mb-3"
          />
          <div className="flex gap-2">
            <button
              onClick={handleClarificationSubmit}
              disabled={!clarificationAnswer.trim()}
              className="btn btn-primary flex-1"
            >
              Submit Answer & Generate
            </button>
            <button
              onClick={() => { setClarification(null); setClarificationAnswer(''); }}
              className="btn bg-dark-100 text-dark-600 hover:bg-dark-200"
            >
              Cancel
            </button>
          </div>
        </div>
      )}

      {isGenerating && (
        <div className="mb-4 p-4 rounded-xl bg-primary-50 border border-primary-200 animate-scale-in">
          <div className="flex items-center justify-between mb-2">
            <div className="flex items-center">
              <div className="spinner border-primary-500 mr-3"></div>
              <div className="font-semibold text-primary-700">{progress}</div>
            </div>
            <div className="text-2xl font-mono font-bold text-primary-700">
              {formatTime(elapsed)}
            </div>
          </div>
          <div className="text-sm text-primary-600">
            {progress === '正在润色并校验...' ? '正在润色去 AI 味并进行质量校验...' : outlineData ? 'Claude Code 正在根据 outline 生成文章...' : reviewData ? '正在生成文章大纲...' : '正在搜索数据源，完成后会展示结果供你审核'}
          </div>
        </div>
      )}

      {error && (
        <div className="mb-4 p-4 rounded-xl bg-red-50 border border-red-200 text-red-700 animate-scale-in">
          <div className="flex items-start">
            <svg className="w-5 h-5 mr-2 mt-0.5 flex-shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
            <div className="whitespace-pre-line text-sm">{error}</div>
          </div>
        </div>
      )}

      <button
        onClick={handleGenerate}
        disabled={isGenerating || !input.trim()}
        className="btn btn-primary w-full group relative overflow-hidden"
      >
        <span className="relative z-10 flex items-center justify-center">
          {isGenerating ? (
            <>
              <div className="spinner border-white mr-2"></div>
              Searching... ({input.split(/[;；,，]/).filter(s => s.trim()).length} topics)
            </>
          ) : (
            <>
              <svg className="w-5 h-5 mr-2 group-hover:rotate-12 transition-transform" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
              </svg>
              Search & Review Sources
            </>
          )}
        </span>
      </button>

    </div>
  );
}
