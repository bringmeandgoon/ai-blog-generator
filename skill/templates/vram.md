# VRAM / Hardware Requirements Article Template

**For articles like: "[Model] VRAM requirements", "[Model] GPU guide"**

## Sections (in this order)

1. **Quick Answer callout** — "Testing: [GPU] with [quant]. Production: [GPU] with [quant]. Or skip hardware: API at $X/M tokens."

2. **Model Overview** — Parameters, architecture (dense vs MoE), why VRAM matters for this model
   - 📌 From HF model card `--- Model ---`

3. **VRAM Requirements by Quantization** (table) — BF16 (full precision), FP8/Q8_0 (8-bit), Q4_K_M, Q2_K with exact VRAM numbers. ALWAYS include 8-bit as the most common production precision.
   - 📌 From `--- Unsloth GGUF Quantization Sizes ---`
   - FP8 / 8-bit VRAM: use the Q8_0 size from the Unsloth GGUF repo (file size ≈ minimum VRAM)

4. **GPU Recommendations** (decision table) — Scenario (testing/production/budget) → GPU → Quantization → Cost
   - 📌 GPU pricing from `--- Novita AI GPU Instance Pricing ---`

5. **API Alternative** — Skip hardware, use API instead
   - 📌 From `>>> USE THIS PRICE <<<`

6. **Deployment Decision Matrix** — Qualitative comparison (NO dollar amounts), columns: Local / Cloud API / Self-Hosted Cloud GPU, rows: Data sovereignty, Setup time, Ops overhead, Scaling, Cost model, Best price/perf at scale, Customization, Time-to-production

7. **Conclusion + Key Takeaways + FAQ**

## Constraints

- Use plain language: "you need X GB of VRAM" not "the model requires X GB"
- Always include API as the easiest alternative
- GPU recommendations may include specific instance types and hourly costs
- **NO quantitative cost comparisons** between deployment methods (no "$X/month vs $Y/month", no "N% cheaper"). Use qualitative descriptors only: "CapEx (hardware)", "Pay-per-token", "OpEx (GPU instances)"

## Thesis Template

"To run [Model]: testing needs [GPU], production needs [GPU]. Here's exactly what to pick."
