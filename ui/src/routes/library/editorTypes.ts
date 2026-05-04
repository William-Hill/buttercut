// ui/src/routes/library/editorTypes.ts

export type ReplaceScope = "clip" | "library" | "trust";

export interface TranscriptEdit {
  segment_index: number;
  word_index: number;
  old_tokens: string[];
  new_tokens: string[];
}

export interface FinderMatch {
  clip: string;
  segment_index: number;
  word_index: number;
  matched_tokens: string[];
  context_snippet: string;
}

export interface FinderResult {
  matches: FinderMatch[];
}

export interface ApplyEditResult {
  edit_count: number;
}

export interface ApplyLibraryReplaceResult {
  edit_count: number;
  affected_clips: string[];
}

export interface TranscriptEditedEvent {
  library: string;
  clip: string;
  edit_count: number;
}

// One-level undo entry. Stored in memory; cleared on clip change.
export interface UndoEntry {
  scope: ReplaceScope;
  // For clip scope: the inverse edit. For library/trust: the reverse replace
  // payload, plus whether to remove the term from user_context (only true if
  // the trust=true edit was the one that ADDED the term).
  inverse_edit?: TranscriptEdit & { clip: string };
  inverse_replace?: { old_tokens: string[]; new_tokens: string[]; remove_user_context_term: string | null };
}
