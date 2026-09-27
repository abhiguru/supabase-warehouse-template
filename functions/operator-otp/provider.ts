// MSG91's current /api/v5/flow endpoint uses template_id and returns a request ID
// on accepted submissions. Acceptance is not a delivery receipt.
export async function deliverOtp(
  phone: string,
  code: string,
  authKey: string | undefined,
  templateId: string | undefined,
  send: typeof fetch = fetch,
): Promise<string> {
  if (!authKey || !templateId || authKey.startsWith('your-') || templateId.startsWith('your-')) {
    throw new Error('MSG91 credentials missing');
  }
  const response = await send('https://control.msg91.com/api/v5/flow', {
    method: 'POST',
    headers: { authkey: authKey, accept: 'application/json', 'Content-Type': 'application/json' },
    body: JSON.stringify({ template_id: templateId, recipients: [{ mobiles: phone, VAR1: code }] }),
    signal: AbortSignal.timeout(10000),
    redirect: 'error',
  });
  if (!response.ok) throw new Error(`MSG91 request failed (${response.status})`);
  const result = await response.json();
  if ((result?.type !== 'success' && result?.status !== 'success') ||
      typeof result.message !== 'string' || !result.message.trim()) {
    throw new Error('MSG91 declined request');
  }
  return result.message;
}
