import { serve } from 'https://deno.land/std@0.192.0/http/server.ts';
import { documentPdf } from '../_shared/document-pdf.ts';
serve(documentPdf('dispatch'));
