/**
 * Draft ids that have been sent in this session, wherever the send came from (the assistant's
 * own tool, a draft card, or the composer opened from one). Assistant draft cards watch this so a
 * card can't sit there offering to send mail that already went out.
 */
const sent = new Map<string, string | undefined>(); // draft_id -> thread_id
const listeners = new Set<() => void>();

export function markDraftSent(draftId?: string | null, threadId?: string) {
  if (!draftId) return;
  sent.set(draftId, threadId);
  listeners.forEach((l) => l());
}

export function draftSentThread(draftId: string): string | undefined | null {
  return sent.has(draftId) ? sent.get(draftId) : null;
}

export function subscribeSentDrafts(fn: () => void): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}
