# PDF Generation

## Overview

PDFs are generated using [Gotenberg](https://gotenberg.dev/), a Chromium-based HTML-to-PDF conversion service. This gives full CSS support (Flexbox, Grid, @page rules) for pixel-perfect documents.

## How It Works

```
Edge Function → Build HTML → POST to Gotenberg → PDF bytes → Response
```

## Quick Test

```bash
curl -X POST http://localhost:8000/functions/v1/generate-sample-pdf \
  -H "Authorization: Bearer YOUR_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"title": "Monthly Report"}' \
  --output report.pdf
```

## Gotenberg Client

The shared library `_shared/gotenberg-client.ts` provides:

```typescript
import { htmlToPdf, createFooterHtml } from '../_shared/gotenberg-client.ts'

// Convert HTML to PDF
const pdfBytes = await htmlToPdf(htmlString, {
  paperWidth: 8.27,    // A4
  paperHeight: 11.69,
  marginTop: 0.39,
  landscape: false,
  printBackground: true,
  footerHtml: createFooterHtml('Company', 'Invoice', 'INV-001'),
});
```

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `paperWidth` | 8.27 (A4) | Width in inches |
| `paperHeight` | 11.69 (A4) | Height in inches |
| `marginTop/Right/Bottom/Left` | Corporate defaults | Margins in inches |
| `landscape` | false | Page orientation |
| `printBackground` | true | Render background colors |
| `scale` | 1.0 | Content scale (0.1-2.0) |
| `waitDelay` | - | Wait before converting (e.g., '1s') |
| `headerHtml` | - | HTML for page header |
| `footerHtml` | - | HTML for page footer |

## Footer with Page Numbers

Gotenberg supports special CSS classes for page numbers:
- `<span class="pageNumber"></span>` — Current page
- `<span class="totalPages"></span>` — Total pages

The `createFooterHtml()` helper uses these automatically.

## Health Check

```bash
curl http://localhost:3100/health
```

## Resource Limits

Gotenberg runs Chromium, which can consume significant memory. The default limit is 1GB with 256MB reserved. Adjust in `docker-compose.yml` if needed.
